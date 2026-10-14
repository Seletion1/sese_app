/**
 * routing.ts — Road-network distance & duration fetcher.
 *
 * Sequential fallback order (see `mapQuotas.ts`):
 *   1. Google Maps Directions (free-tier allowance first).
 *   2. Mapbox Directions (automatic rollover past Google's cap).
 *   3. Crow-flies estimation by the CALLER (CartoDB has no routing API —
 *      pinning the Hub routing slot to `cartodb` skips paid engines
 *      entirely and goes straight to estimation).
 *   4. Google Pay-As-You-Go overflow (same Directions API, recorded as
 *      `payg`; Cloud Billing budgets — not code — cap the spend).
 *
 * The Hub routing slot (`system_config/remote_keys` `feature_routing`)
 * pins one engine: `google` (Directions only), `mapbox` (Mapbox only),
 * `cartodb` (estimation only — zero paid calls), or `auto` (the chain).
 *
 * On total failure the caller receives a thrown Error; the `calculateFare`
 * function in `index.ts` catches it and falls back to crow-flies
 * estimation, which is the right server-authoritative degradation path.
 */

import { nextEngine, recordCall } from "./mapQuotas";
import * as admin from "firebase-admin";

const quotaDb = () => admin.firestore();

/** Hub routing-slot pin (`auto` = follow the quota chain). */
async function routingPin(): Promise<string> {
  try {
    const snap = await quotaDb()
      .collection("system_config")
      .doc("remote_keys")
      .get();
    const d = snap.exists ? snap.data()! : {};
    const nested = d.featureProviders as Record<string, unknown> | undefined;
    const raw =
      nested?.routing ?? d.feature_routing ?? d["featureRouting"] ?? "auto";
    const code = String(raw ?? "auto").trim().toLowerCase();
    if (code === "google" || code === "google_maps") return "google";
    if (code === "mapbox") return "mapbox";
    if (
      code === "cartodb" ||
      code === "osm" ||
      code === "open_street_map"
    ) {
      return "cartodb";
    }
    return "auto";
  } catch {
    return "auto";
  }
}

export interface RouteResult {
  distanceKm: number;
  durationMins: number;
}

interface GoogleDirectionsResponse {
  status: string;
  routes?: Array<{
    legs?: Array<{
      distance?: { value?: number }; // metres
      duration?: { value?: number }; // seconds
      duration_in_traffic?: { value?: number }; // seconds
    }>;
  }>;
  error_message?: string;
}

/**
 * Fetches the fastest driving route between two coordinates, following the
 * Hub routing pin + quota chain (Google → Mapbox → PAYG overflow).
 *
 * Throws `Error` on any failure — callers should catch and fall back to
 * crow-flies distance if needed (see `calculateFare` in index.ts).
 */
export async function fetchRoute(
  pickupLat: number,
  pickupLng: number,
  dropoffLat: number,
  dropoffLng: number
): Promise<RouteResult> {
  const pin = await routingPin();
  if (pin === "cartodb") {
    // Zero-paid-calls mode: straight to caller-side estimation.
    throw new Error(
      "Routing pinned to CartoDB (no routing API) — use estimation."
    );
  }

  const ordered =
    pin === "google"
      ? (["google", "googlePayg"] as const)
      : pin === "mapbox"
        ? (["mapbox"] as const)
        : ((await nextEngine()).engine === "mapbox"
            ? (["mapbox", "googlePayg"] as const)
            : (["google", "mapbox", "googlePayg"] as const));

  const errors: string[] = [];
  for (const engine of ordered) {
    try {
      if (engine === "mapbox") {
        const result = await fetchMapboxRoute(
          pickupLat,
          pickupLng,
          dropoffLat,
          dropoffLng
        );
        await recordCall("mapbox");
        return result;
      }
      const result = await fetchGoogleRoute(
        pickupLat,
        pickupLng,
        dropoffLat,
        dropoffLng
      );
      await recordCall(engine === "googlePayg" ? "googlePayg" : "google");
      return result;
    } catch (e) {
      errors.push(`${engine}: ${e instanceof Error ? e.message : e}`);
    }
  }
  throw new Error(`All routing engines failed — ${errors.join(" | ")}`);
}

/**
 * Google Maps Directions engine (free-tier AND pay-as-you-go overflow —
 * same API; the quota layer decides which allowance this call consumes).
 * Traffic-aware duration (`duration_in_traffic`) when available.
 */
async function fetchGoogleRoute(
  pickupLat: number,
  pickupLng: number,
  dropoffLat: number,
  dropoffLng: number
): Promise<RouteResult> {
  const apiKey =
    process.env.GOOGLE_MAPS_API_KEY ?? process.env.MAPS_API_KEY ?? "";
  if (!apiKey) {
    throw new Error(
      "GOOGLE_MAPS_API_KEY is not configured — cannot compute route."
    );
  }

  const url = new URL("https://maps.googleapis.com/maps/api/directions/json");
  url.searchParams.set("origin", `${pickupLat},${pickupLng}`);
  url.searchParams.set("destination", `${dropoffLat},${dropoffLng}`);
  url.searchParams.set("mode", "driving");
  url.searchParams.set("departure_time", "now");
  url.searchParams.set("traffic_model", "best_guess");
  url.searchParams.set("language", "en");
  url.searchParams.set("key", apiKey);

  const ctrl = new AbortController();
  const timer = setTimeout(() => ctrl.abort(), 10_000);

  let body: GoogleDirectionsResponse;
  try {
    const res = await fetch(url, { signal: ctrl.signal });
    if (!res.ok) {
      throw new Error(
        `Directions API HTTP error ${res.status}: ${res.statusText}`
      );
    }
    body = (await res.json()) as GoogleDirectionsResponse;
  } finally {
    clearTimeout(timer);
  }

  if (
    body.status !== "OK" ||
    !body.routes?.length ||
    !body.routes[0].legs?.length
  ) {
    throw new Error(
      `Google Maps Directions error (${body.status}): ${
        body.error_message ?? "no route"
      }`
    );
  }

  const leg = body.routes[0].legs[0];
  const distanceKm = (leg.distance?.value ?? 0) / 1000;
  const durationSec =
    leg.duration_in_traffic?.value ?? leg.duration?.value ?? 0;
  const durationMins = durationSec / 60;

  return { distanceKm, durationMins };
}

interface MapboxDirectionsResponse {
  code?: string;
  message?: string;
  routes?: Array<{
    distance?: number; // metres
    duration?: number; // seconds
  }>;
}

/**
 * Mapbox Directions engine (quota-chain rollover target). Token from
 * `MAPBOX_TOKEN` env (server-side only — never ships to clients).
 */
async function fetchMapboxRoute(
  pickupLat: number,
  pickupLng: number,
  dropoffLat: number,
  dropoffLng: number
): Promise<RouteResult> {
  const token = process.env.MAPBOX_TOKEN ?? "";
  if (!token) {
    throw new Error("MAPBOX_TOKEN is not configured — cannot compute route.");
  }
  const coords =
    `${pickupLng},${pickupLat};${dropoffLng},${dropoffLat}`;
  const url = new URL(
    `https://api.mapbox.com/directions/v5/mapbox/driving/${coords}`
  );
  url.searchParams.set("overview", "false");
  url.searchParams.set("access_token", token);

  const ctrl = new AbortController();
  const timer = setTimeout(() => ctrl.abort(), 10_000);
  let body: MapboxDirectionsResponse;
  try {
    const res = await fetch(url, { signal: ctrl.signal });
    if (!res.ok) {
      throw new Error(
        `Mapbox Directions HTTP error ${res.status}: ${res.statusText}`
      );
    }
    body = (await res.json()) as MapboxDirectionsResponse;
  } finally {
    clearTimeout(timer);
  }

  if (body.code !== "Ok" || !body.routes?.length) {
    throw new Error(
      `Mapbox Directions error (${body.code ?? "unknown"}): ${
        body.message ?? "no route"
      }`
    );
  }
  const route = body.routes[0];
  return {
    distanceKm: (route.distance ?? 0) / 1000,
    durationMins: (route.duration ?? 0) / 60,
  };
}
