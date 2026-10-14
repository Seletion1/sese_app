"use strict";
var __createBinding = (this && this.__createBinding) || (Object.create ? (function(o, m, k, k2) {
    if (k2 === undefined) k2 = k;
    var desc = Object.getOwnPropertyDescriptor(m, k);
    if (!desc || ("get" in desc ? !m.__esModule : desc.writable || desc.configurable)) {
      desc = { enumerable: true, get: function() { return m[k]; } };
    }
    Object.defineProperty(o, k2, desc);
}) : (function(o, m, k, k2) {
    if (k2 === undefined) k2 = k;
    o[k2] = m[k];
}));
var __setModuleDefault = (this && this.__setModuleDefault) || (Object.create ? (function(o, v) {
    Object.defineProperty(o, "default", { enumerable: true, value: v });
}) : function(o, v) {
    o["default"] = v;
});
var __importStar = (this && this.__importStar) || (function () {
    var ownKeys = function(o) {
        ownKeys = Object.getOwnPropertyNames || function (o) {
            var ar = [];
            for (var k in o) if (Object.prototype.hasOwnProperty.call(o, k)) ar[ar.length] = k;
            return ar;
        };
        return ownKeys(o);
    };
    return function (mod) {
        if (mod && mod.__esModule) return mod;
        var result = {};
        if (mod != null) for (var k = ownKeys(mod), i = 0; i < k.length; i++) if (k[i] !== "default") __createBinding(result, mod, k[i]);
        __setModuleDefault(result, mod);
        return result;
    };
})();
Object.defineProperty(exports, "__esModule", { value: true });
exports.DEFAULT_CARTO_MONTHLY_CAP = exports.DEFAULT_MAPBOX_MONTHLY_CAP = exports.DEFAULT_GOOGLE_MONTHLY_CAP = void 0;
exports.nextEngine = nextEngine;
exports.recordCall = recordCall;
const admin = __importStar(require("firebase-admin"));
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
exports.DEFAULT_GOOGLE_MONTHLY_CAP = 20000;
exports.DEFAULT_MAPBOX_MONTHLY_CAP = 50000;
// CartoDB anonymous raster tiles are free fair-use with no billable meter;
// the default mirrors CartoDB's published free-plan order of magnitude as
// a policy marker (see `cartoMonthlyCap` below).
exports.DEFAULT_CARTO_MONTHLY_CAP = 100000;
/** Month key `YYYY-MM` (UTC) for roll-over comparisons. */
function monthKey(nowMs) {
    const d = new Date(nowMs);
    const m = `${d.getUTCMonth() + 1}`.padStart(2, "0");
    return `${d.getUTCFullYear()}-${m}`;
}
function num(v, fallback) {
    return typeof v === "number" && Number.isFinite(v) && v >= 0
        ? Math.floor(v)
        : fallback;
}
async function readQuotas() {
    var _a;
    try {
        const snap = await db()
            .collection("system_config")
            .doc("map_quotas")
            .get();
        const d = snap.exists ? snap.data() : {};
        return {
            googleMonthlyCap: num(d.googleMonthlyCap, exports.DEFAULT_GOOGLE_MONTHLY_CAP),
            mapboxMonthlyCap: num(d.mapboxMonthlyCap, exports.DEFAULT_MAPBOX_MONTHLY_CAP),
            cartoMonthlyCap: num(d.cartoMonthlyCap, exports.DEFAULT_CARTO_MONTHLY_CAP),
            googleCallsThisMonth: num(d.googleCallsThisMonth, 0),
            mapboxCallsThisMonth: num(d.mapboxCallsThisMonth, 0),
            paygCallsThisMonth: num(d.paygCallsThisMonth, 0),
            lastSyncedMonth: String((_a = d.lastSyncedMonth) !== null && _a !== void 0 ? _a : ""),
        };
    }
    catch (_b) {
        return {
            googleMonthlyCap: exports.DEFAULT_GOOGLE_MONTHLY_CAP,
            mapboxMonthlyCap: exports.DEFAULT_MAPBOX_MONTHLY_CAP,
            cartoMonthlyCap: exports.DEFAULT_CARTO_MONTHLY_CAP,
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
async function nextEngine() {
    const q = await readQuotas();
    const now = monthKey(Date.now());
    const googleCalls = q.lastSyncedMonth === now ? q.googleCallsThisMonth : 0;
    const mapboxCalls = q.lastSyncedMonth === now ? q.mapboxCallsThisMonth : 0;
    if (googleCalls < q.googleMonthlyCap)
        return { engine: "google" };
    if (mapboxCalls < q.mapboxMonthlyCap)
        return { engine: "mapbox" };
    return { engine: "googlePayg" };
}
/**
 * Records one billable call against [provider] for the current UTC month.
 * Fire-and-forget safe (never throws) — quota bookkeeping must never fail
 * a routing call.
 */
async function recordCall(provider) {
    try {
        const ref = db().collection("system_config").doc("map_quotas");
        const now = monthKey(Date.now());
        await db().runTransaction(async (tx) => {
            var _a;
            const snap = await tx.get(ref);
            const d = snap.exists ? snap.data() : {};
            const sameMonth = String((_a = d.lastSyncedMonth) !== null && _a !== void 0 ? _a : "") === now;
            const field = provider === "google"
                ? "googleCallsThisMonth"
                : provider === "mapbox"
                    ? "mapboxCallsThisMonth"
                    : "paygCallsThisMonth";
            tx.set(ref, {
                [field]: (sameMonth ? num(d[field], 0) : 0) + 1,
                lastSyncedMonth: now,
                updatedAt: admin.firestore.FieldValue.serverTimestamp(),
            }, { merge: true });
        });
    }
    catch (e) {
        console.warn(`mapQuotas: recordCall(${provider}) failed: ${e}`);
    }
}
//# sourceMappingURL=mapQuotas.js.map