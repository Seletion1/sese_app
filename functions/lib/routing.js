"use strict";
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
exports.fetchRoute = fetchRoute;
const mapQuotas_1 = require("./mapQuotas");
const admin = __importStar(require("firebase-admin"));
const quotaDb = () => admin.firestore();
/** Hub routing-slot pin (`auto` = follow the quota chain). */
async function routingPin() {
    var _a, _b, _c;
    try {
        const snap = await quotaDb()
            .collection("system_config")
            .doc("remote_keys")
            .get();
        const d = snap.exists ? snap.data() : {};
        const nested = d.featureProviders;
        const raw = (_c = (_b = (_a = nested === null || nested === void 0 ? void 0 : nested.routing) !== null && _a !== void 0 ? _a : d.feature_routing) !== null && _b !== void 0 ? _b : d["featureRouting"]) !== null && _c !== void 0 ? _c : "auto";
        const code = String(raw !== null && raw !== void 0 ? raw : "auto").trim().toLowerCase();
        if (code === "google" || code === "google_maps")
            return "google";
        if (code === "mapbox")
            return "mapbox";
        if (code === "cartodb" ||
            code === "osm" ||
            code === "open_street_map") {
            return "cartodb";
        }
        return "auto";
    }
    catch (_d) {
        return "auto";
    }
}
/**
 * Fetches the fastest driving route between two coordinates, following the
 * Hub routing pin + quota chain (Google → Mapbox → PAYG overflow).
 *
 * Throws `Error` on any failure — callers should catch and fall back to
 * crow-flies distance if needed (see `calculateFare` in index.ts).
 */
async function fetchRoute(pickupLat, pickupLng, dropoffLat, dropoffLng) {
    const pin = await routingPin();
    if (pin === "cartodb") {
        // Zero-paid-calls mode: straight to caller-side estimation.
        throw new Error("Routing pinned to CartoDB (no routing API) — use estimation.");
    }
    const ordered = pin === "google"
        ? ["google", "googlePayg"]
        : pin === "mapbox"
            ? ["mapbox"]
            : ((await (0, mapQuotas_1.nextEngine)()).engine === "mapbox"
                ? ["mapbox", "googlePayg"]
                : ["google", "mapbox", "googlePayg"]);
    const errors = [];
    for (const engine of ordered) {
        try {
            if (engine === "mapbox") {
                const result = await fetchMapboxRoute(pickupLat, pickupLng, dropoffLat, dropoffLng);
                await (0, mapQuotas_1.recordCall)("mapbox");
                return result;
            }
            const result = await fetchGoogleRoute(pickupLat, pickupLng, dropoffLat, dropoffLng);
            await (0, mapQuotas_1.recordCall)(engine === "googlePayg" ? "googlePayg" : "google");
            return result;
        }
        catch (e) {
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
async function fetchGoogleRoute(pickupLat, pickupLng, dropoffLat, dropoffLng) {
    var _a, _b, _c, _d, _e, _f, _g, _h, _j, _k, _l;
    const apiKey = (_b = (_a = process.env.GOOGLE_MAPS_API_KEY) !== null && _a !== void 0 ? _a : process.env.MAPS_API_KEY) !== null && _b !== void 0 ? _b : "";
    if (!apiKey) {
        throw new Error("GOOGLE_MAPS_API_KEY is not configured — cannot compute route.");
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
    const timer = setTimeout(() => ctrl.abort(), 10000);
    let body;
    try {
        const res = await fetch(url, { signal: ctrl.signal });
        if (!res.ok) {
            throw new Error(`Directions API HTTP error ${res.status}: ${res.statusText}`);
        }
        body = (await res.json());
    }
    finally {
        clearTimeout(timer);
    }
    if (body.status !== "OK" ||
        !((_c = body.routes) === null || _c === void 0 ? void 0 : _c.length) ||
        !((_d = body.routes[0].legs) === null || _d === void 0 ? void 0 : _d.length)) {
        throw new Error(`Google Maps Directions error (${body.status}): ${(_e = body.error_message) !== null && _e !== void 0 ? _e : "no route"}`);
    }
    const leg = body.routes[0].legs[0];
    const distanceKm = ((_g = (_f = leg.distance) === null || _f === void 0 ? void 0 : _f.value) !== null && _g !== void 0 ? _g : 0) / 1000;
    const durationSec = (_l = (_j = (_h = leg.duration_in_traffic) === null || _h === void 0 ? void 0 : _h.value) !== null && _j !== void 0 ? _j : (_k = leg.duration) === null || _k === void 0 ? void 0 : _k.value) !== null && _l !== void 0 ? _l : 0;
    const durationMins = durationSec / 60;
    return { distanceKm, durationMins };
}
/**
 * Mapbox Directions engine (quota-chain rollover target). Token from
 * `MAPBOX_TOKEN` env (server-side only — never ships to clients).
 */
async function fetchMapboxRoute(pickupLat, pickupLng, dropoffLat, dropoffLng) {
    var _a, _b, _c, _d, _e, _f;
    const token = (_a = process.env.MAPBOX_TOKEN) !== null && _a !== void 0 ? _a : "";
    if (!token) {
        throw new Error("MAPBOX_TOKEN is not configured — cannot compute route.");
    }
    const coords = `${pickupLng},${pickupLat};${dropoffLng},${dropoffLat}`;
    const url = new URL(`https://api.mapbox.com/directions/v5/mapbox/driving/${coords}`);
    url.searchParams.set("overview", "false");
    url.searchParams.set("access_token", token);
    const ctrl = new AbortController();
    const timer = setTimeout(() => ctrl.abort(), 10000);
    let body;
    try {
        const res = await fetch(url, { signal: ctrl.signal });
        if (!res.ok) {
            throw new Error(`Mapbox Directions HTTP error ${res.status}: ${res.statusText}`);
        }
        body = (await res.json());
    }
    finally {
        clearTimeout(timer);
    }
    if (body.code !== "Ok" || !((_b = body.routes) === null || _b === void 0 ? void 0 : _b.length)) {
        throw new Error(`Mapbox Directions error (${(_c = body.code) !== null && _c !== void 0 ? _c : "unknown"}): ${(_d = body.message) !== null && _d !== void 0 ? _d : "no route"}`);
    }
    const route = body.routes[0];
    return {
        distanceKm: ((_e = route.distance) !== null && _e !== void 0 ? _e : 0) / 1000,
        durationMins: ((_f = route.duration) !== null && _f !== void 0 ? _f : 0) / 60,
    };
}
//# sourceMappingURL=routing.js.map