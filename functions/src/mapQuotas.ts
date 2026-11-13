import * as admin from "firebase-admin";

/**
 * mapQuotas.ts — Tiered map-API quota tracking + sequential fallback order.
 *
 * Fallback order (Hub-tunable caps, UTC calendar-month windows):
 *   1. Google Maps — free-tier / initial-credit allowance first.
 *   2. Mapbox — automatic rollover buffer once Google's cap is hit.
 *   3. Google Maps Pay-As-You-Go — final overflow once Mapbox free allowance
 *      is exhausted for the billing cycle.
 *
 * State lives in `system_config/map_quotas`.
 */

const db = () => admin.firestore();

/** Compiled defaults when the quotas doc is missing/unreadable. */
export const DEFAULT_GOOGLE_MONTHLY_CAP = 20000;
export const DEFAULT_MAPBOX_MONTHLY_CAP = 50000;

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
      googleCallsThisMonth: num(d.googleCallsThisMonth, 0),
      mapboxCallsThisMonth: num(d.mapboxCallsThisMonth, 0),
      paygCallsThisMonth: num(d.paygCallsThisMonth, 0),
      lastSyncedMonth: String(d.lastSyncedMonth ?? ""),
    };
  } catch {
    return {
      googleMonthlyCap: DEFAULT_GOOGLE_MONTHLY_CAP,
      mapboxMonthlyCap: DEFAULT_MAPBOX_MONTHLY_CAP,
      googleCallsThisMonth: 0,
      mapboxCallsThisMonth: 0,
      paygCallsThisMonth: 0,
      lastSyncedMonth: "",
    };
  }
}

/**
 * Routing verdict for the next billable maps call: which engine to use.
 * Month roll-over is applied lazily here.
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
