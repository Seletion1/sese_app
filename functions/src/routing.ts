/**
 * routing.ts — Road-network distance & duration fetcher.
 *
 * Sequential fallback order (see `mapQuotas.ts`):
 *   1. Google Maps Directions (free-tier allowance first).
 *   2. Mapbox Directions (automatic rollover past Google's cap).
 *   3. Google Pay-As-You-Go overflow (same Directions API).
 *
 * The Hub routing slot (`system_config/remote_keys` `feature_routing`)
 * pins one engine: `google` (Directions only), `mapbox` (Mapbox only),
 * or `auto` (the chain).
 */

import { recordCall } from "./mapQuotas";
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
    return "auto";
  } catch {
    return "auto";
  }
}

export interface RouteResult {
  distanceKm: number;
  durationMins: number;
}

/**
 * Fetches the fastest driving route between two coordinates, following the
 * Hub routing pin + quota chain (Google → Mapbox → PAYG overflow).
 */
export async function fetchRoute(
  pickupLat: number,
  pickupLng: number,
  dropoffLat: number,
  dropoffLng: number
): Promise<RouteResult> {
  // Zero server-side billable Google Maps calls: use Mapbox if configured,
  // otherwise fall back to free OSRM public routing.
  const pin = await routingPin();
  if (pin !== "google" && process.env.MAPBOX_TOKEN) {
    try {
      const result = await fetchMapboxRoute(
        pickupLat,
        pickupLng,
        dropoffLat,
        dropoffLng
      );
      await recordCall("mapbox");
      return result;
    } catch {
      // Fall through to OSRM
    }
  }

  return fetchOsrmRoute(pickupLat, pickupLng, dropoffLat, dropoffLng);
}

async function fetchOsrmRoute(
  pickupLat: number,
  pickupLng: number,
  dropoffLat: number,
  dropoffLng: number
): Promise<RouteResult> {
  const url = new URL(
    `https://router.project-osrm.org/route/v1/driving/${pickupLng},${pickupLat};${dropoffLng},${dropoffLat}`
  );
  url.searchParams.set("overview", "false");

  const ctrl = new AbortController();
  const timer = setTimeout(() => ctrl.abort(), 8_000);
  try {
    const res = await fetch(url, { signal: ctrl.signal });
    if (!res.ok) {
      throw new Error(`OSRM HTTP ${res.status}`);
    }
    const body = (await res.json()) as {
      code?: string;
      routes?: Array<{ distance?: number; duration?: number }>;
    };
    if (body.code !== "Ok" || !body.routes?.length) {
      throw new Error(`OSRM error (${body.code ?? "unknown"})`);
    }
    const route = body.routes[0];
    return {
      distanceKm: (route.distance ?? 0) / 1000,
      durationMins: (route.duration ?? 0) / 60,
    };
  } finally {
    clearTimeout(timer);
  }
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
 * Mapbox Directions engine.
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
