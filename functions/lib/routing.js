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
exports.fetchRoute = fetchRoute;
/**
 * routing.ts — OSRM road-network distance & duration fetcher.
 *
 * Connects to the OSRM public demo server (driving profile, OpenStreetMap
 * road network). No API key, no billing.
 *
 * Production note: the public demo endpoint (`router.project-osrm.org`) is
 * rate-limited and returns free-flow durations (no live traffic, unlike the
 * previous Google TRAFFIC_AWARE mode). At scale, self-host OSRM/Valhalla or
 * front this module with caching. The `OSRM_BASE_URL` env var switches the
 * endpoint without a redeploy of callers.
 */
const https = __importStar(require("https"));
const OSRM_BASE_URL = process.env.OSRM_BASE_URL || "https://router.project-osrm.org";
/**
 * Fetches the fastest driving route between two coordinates via OSRM.
 * Returns distance in km and duration in minutes.
 *
 * @throws Error if OSRM is unreachable or returns no route.
 */
async function fetchRoute(pickupLat, pickupLng, dropoffLat, dropoffLng) {
    var _a, _b, _c, _d;
    const path = `/route/v1/driving/${pickupLng},${pickupLat};${dropoffLng},${dropoffLat}` +
        `?overview=false`;
    const body = await getJson(OSRM_BASE_URL, path);
    if (body.code !== "Ok") {
        throw new Error(`OSRM routing error (${(_a = body.code) !== null && _a !== void 0 ? _a : "unknown"}): ${(_b = body.message) !== null && _b !== void 0 ? _b : "no route"}`);
    }
    if (!body.routes || body.routes.length === 0) {
        throw new Error("OSRM returned no routes for these coordinates.");
    }
    const route = body.routes[0];
    const distanceKm = ((_c = route.distance) !== null && _c !== void 0 ? _c : 0) / 1000; // metres → km
    const durationMins = ((_d = route.duration) !== null && _d !== void 0 ? _d : 0) / 60; // seconds → minutes
    return { distanceKm, durationMins };
}
/** Minimal Node https.request wrapper for GET that returns parsed JSON. */
function getJson(baseUrl, path) {
    return new Promise((resolve, reject) => {
        const url = new URL(path, baseUrl);
        const options = {
            hostname: url.hostname,
            port: 443,
            path: url.pathname + url.search,
            method: "GET",
            headers: {
                "User-Agent": "sese-ride-functions/1.0 (OpenStreetMap)",
            },
        };
        const req = https.request(options, (res) => {
            let data = "";
            res.on("data", (chunk) => (data += chunk));
            res.on("end", () => {
                if (res.statusCode !== 200) {
                    reject(new Error(`OSRM request failed with status ${res.statusCode}`));
                    return;
                }
                try {
                    resolve(JSON.parse(data));
                }
                catch (e) {
                    reject(new Error(`Invalid OSRM response: ${e}`));
                }
            });
        });
        req.on("error", reject);
        req.setTimeout(10000, () => {
            req.destroy(new Error("OSRM request timed out"));
        });
        req.end();
    });
}
//# sourceMappingURL=routing.js.map