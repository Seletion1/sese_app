import * as admin from "firebase-admin";

/**
 * mapQuotas.ts — Tiered map-API quota tracking + sequential fallback order.
 *
 * Fallback order (Hub-tunable caps, UTC calendar-month windows):
 *   1. Google Maps — free-tier / initial-credit allowance first.
 *   2. Mapbox — automatic rollover once Google's cap is hit.
 *   3. CartoDB / coast — free basemaps + crow-flies estimation need no
 *      API calls, so they are the zero-cost overflow (no counter).
 *   4. Google Maps Pay-As-You-Go — final overflow once every free allowance
 *      is exhausted for the billing cycle (same Directions/Geocoding APIs,
 *      recorded separately as `payg` so spend is auditable).
 *
 * State lives in `system_config/map_quotas` (admin-managed caps, server-
 * managed counters, auto month roll-over). Clients never read this doc —
 * it is NOT in the public `isPublicSystemConfig` list — and the Hub edits
 * caps through the map card (admin scope required by firestore.rules).
 *
 * Honest billing note: code can ORDER the engines and cap the free tiers,
 * but it cannot cap billed spend — that is a Cloud Billing budget + alert
 * in the Cloud Console. The `payg` counters exist so those alerts can be
 * reconciled against actual overflow calls.
 */

const db = () => admin.firestore();

/** Compiled defaults when the quotas doc is missing/unreadable. */
export const DEFAULT_GOOGLE_MONTHLY_CAP = 20000;
export const DEFAULT_MAPBOX_MONTHLY_CAP = 50000;
// CartoDB anonymous raster tiles are free fair-use with no billable meter;
// the default mirrors CartoDB's published free-plan order of magnitude as
// a policy marker (see `cartoMonthlyCap` below).
export const DEFAULT_CARTO_MONTHLY_CAP = 100000;

export type QuotaProvider = "google" | "mapbox" | "googlePayg";

/** Month key `YYYY-MM` (UTC) for roll-over comparisons. */
function monthKey(nowMs: number): string {
  const d = new Date(nowMs);
  const m = `${d.getUTCMonth() + 1}`.padStart(2, "0");
  return `${d.getUTCFullYear()}-${m}`;
}

export interface MapQuotas {
  googleMonthlyCap: number;
  mapboxMonthlyCap: number;
  /**
   * CartoDB monthly policy threshold (advisory, NOT enforced).
   *
   * Why advisory: CartoDB raster tiles load directly client → CDN and never
   * touch our backend, so there is no server-side call stream to count or
   * gate — unlike the Google/Mapbox proxy + Directions paths. This cap is
   * stored alongside the enforced caps so the Hub shows one complete
   * per-provider quota picture and budget reviews have a number to compare
   * CDN-side analytics against. It never blocks, reroutes, or fails calls.
   */
  cartoMonthlyCap: number;
  googleCallsThisMonth: number;
  mapboxCallsThisMonth: number;
  paygCallsThisMonth: number;
  lastSyncedMonth: string;
}

function num(v: unknown, fallback: number): number {
  return typeof v === "number" && Number.isFinite(v) && v >= 0
    ? Math.floor(v)
    : fallback;
}

async function readQuotas(): Promise<MapQuotas> {
  try {
    const snap = await db()
      .collection("system_config")
      .doc("map_quotas")
      .get();
    const d = snap.exists ? snap.data()! : {};
    return {
      googleMonthlyCap: num(d.googleMonthlyCap, DEFAULT_GOOGLE_MONTHLY_CAP),
      mapboxMonthlyCap: num(d.mapboxMonthlyCap, DEFAULT_MAPBOX_MONTHLY_CAP),
      cartoMonthlyCap: num(d.cartoMonthlyCap, DEFAULT_CARTO_MONTHLY_CAP),
      googleCallsThisMonth: num(d.googleCallsThisMonth, 0),
      mapboxCallsThisMonth: num(d.mapboxCallsThisMonth, 0),
      paygCallsThisMonth: num(d.paygCallsThisMonth, 0),
      lastSyncedMonth: String(d.lastSyncedMonth ?? ""),
    };
  } catch {
    return {
      googleMonthlyCap: DEFAULT_GOOGLE_MONTHLY_CAP,
      mapboxMonthlyCap: DEFAULT_MAPBOX_MONTHLY_CAP,
      cartoMonthlyCap: DEFAULT_CARTO_MONTHLY_CAP,
      googleCallsThisMonth: 0,
      mapboxCallsThisMonth: 0,
      paygCallsThisMonth: 0,
      lastSyncedMonth: "",
    };
  }
}

/**
 * Routing verdict for the next billable maps call: which engine to use.
 * Month roll-over is applied lazily here (counters reset when the stored
 * month differs from the current UTC month).
 */
export async function nextEngine(): Promise<
  { engine: "google" } | { engine: "mapbox" } | { engine: "googlePayg" }
> {
  const q = await readQuotas();
  const now = monthKey(Date.now());
  const googleCalls = q.lastSyncedMonth === now ? q.googleCallsThisMonth : 0;
  const mapboxCalls = q.lastSyncedMonth === now ? q.mapboxCallsThisMonth : 0;
  if (googleCalls < q.googleMonthlyCap) return { engine: "google" };
  if (mapboxCalls < q.mapboxMonthlyCap) return { engine: "mapbox" };
  return { engine: "googlePayg" };
}

/**
 * Records one billable call against [provider] for the current UTC month.
 * Fire-and-forget safe (never throws) — quota bookkeeping must never fail
 * a routing call.
 */
export async function recordCall(
  provider: QuotaProvider
): Promise<void> {
  try {
    const ref = db().collection("system_config").doc("map_quotas");
    const now = monthKey(Date.now());
    await db().runTransaction(async (tx) => {
      const snap = await tx.get(ref);
      const d = snap.exists ? snap.data()! : {};
      const sameMonth = String(d.lastSyncedMonth ?? "") === now;
      const field =
        provider === "google"
          ? "googleCallsThisMonth"
          : provider === "mapbox"
            ? "mapboxCallsThisMonth"
            : "paygCallsThisMonth";
      tx.set(
        ref,
        {
          [field]: (sameMonth ? num(d[field], 0) : 0) + 1,
          lastSyncedMonth: now,
          updatedAt: admin.firestore.FieldValue.serverTimestamp(),
        },
        { merge: true }
      );
    });
  } catch (e) {
    console.warn(`mapQuotas: recordCall(${provider}) failed: ${e}`);
  }
}
