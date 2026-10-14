"use strict";
Object.defineProperty(exports, "__esModule", { value: true });
exports.googleMapsProxy = void 0;
const https_1 = require("firebase-functions/v2/https");
const mapQuotas_1 = require("./mapQuotas");
const FETCH_TIMEOUT_MS = 9000;
const MAX_INPUT_LEN = 200;
function serverKey() {
    var _a;
    const key = (_a = process.env.GOOGLE_MAPS_API_KEY) !== null && _a !== void 0 ? _a : process.env.GOOGLE_MAPS_KEY;
    if (!key) {
        throw new https_1.HttpsError("failed-precondition", "Location search is unavailable right now. Please try again later.");
    }
    return key;
}
function isLat(v) {
    return typeof v === "number" && Number.isFinite(v) && v >= -90 && v <= 90;
}
function isLng(v) {
    return typeof v === "number" && Number.isFinite(v) && v >= -180 && v <= 180;
}
function cleanInput(raw) {
    const s = (typeof raw === "string" ? raw : "").trim();
    if (!s)
        throw new https_1.HttpsError("invalid-argument", "Search text is empty.");
    if (s.length > MAX_INPUT_LEN) {
        throw new https_1.HttpsError("invalid-argument", "Search text is too long.");
    }
    return s;
}
async function googleGet(path, params) {
    const url = new URL(`https://maps.googleapis.com${path}`);
    for (const [k, v] of Object.entries(params))
        url.searchParams.set(k, v);
    url.searchParams.set("key", serverKey());
    const ctrl = new AbortController();
    const timer = setTimeout(() => ctrl.abort(), FETCH_TIMEOUT_MS);
    try {
        const res = await fetch(url, { signal: ctrl.signal });
        if (!res.ok) {
            throw new https_1.HttpsError("unavailable", "Location service is unreachable. Check your connection.");
        }
        const json = (await res.json());
        // Quota attribution (single choke point: one upstream call per proxy
        // action). Within the free allowance this records `google`; past it the
        // call still proceeds (search must not break) but lands in the PAYG
        // overflow bucket so spend is auditable. Never throws — bookkeeping
        // must not fail a search.
        try {
            const verdict = await (0, mapQuotas_1.nextEngine)();
            await (0, mapQuotas_1.recordCall)(verdict.engine === "google" ? "google" : "googlePayg");
        }
        catch (_a) {
            // Quota layer is best-effort by contract (see mapQuotas.ts).
        }
        return json;
    }
    catch (e) {
        if (e instanceof https_1.HttpsError)
            throw e;
        throw new https_1.HttpsError("unavailable", "Location service timed out. Check your connection.");
    }
    finally {
        clearTimeout(timer);
    }
}
/** Maps Google status strings to user-safe callable errors. */
function throwForStatus(status, action) {
    switch (status) {
        case "ZERO_RESULTS":
        case "NOT_FOUND":
            // Not an error for callers: empty result, same as offline miss.
            throw new https_1.HttpsError("not-found", "No matching places found.");
        case "OVER_QUERY_LIMIT":
        case "OVER_DAILY_LIMIT":
            throw new https_1.HttpsError("resource-exhausted", "Search quota is exhausted. Try a recent location or try again later.");
        case "REQUEST_DENIED":
            throw new https_1.HttpsError("failed-precondition", "Location search is unavailable right now. Please try again later.");
        case "INVALID_REQUEST":
            throw new https_1.HttpsError("invalid-argument", `Invalid ${action} request.`);
        default:
            throw new https_1.HttpsError("internal", "Location lookup failed. Please try again.");
    }
}
function asPredictions(json) {
    var _a;
    const list = json.predictions;
    if (!Array.isArray(list))
        return [];
    const out = [];
    for (const item of list) {
        if (typeof item !== "object" || item === null)
            continue;
        const m = item;
        const placeId = typeof m.place_id === "string" ? m.place_id : "";
        const description = typeof m.description === "string" ? m.description : "";
        if (!placeId || !description)
            continue;
        const structured = ((_a = m.structured_formatting) !== null && _a !== void 0 ? _a : {});
        out.push({
            placeId,
            description,
            mainText: typeof structured.main_text === "string"
                ? structured.main_text
                : description,
            secondaryText: typeof structured.secondary_text === "string"
                ? structured.secondary_text
                : "",
        });
    }
    return out.slice(0, 5);
}
function asLatLng(obj) {
    if (typeof obj !== "object" || obj === null)
        return null;
    const m = obj;
    const lat = typeof m.lat === "number" ? m.lat : NaN;
    const lng = typeof m.lng === "number" ? m.lng : NaN;
    if (!isLat(lat) || !isLng(lng))
        return null;
    return { lat, lng };
}
/**
 * Callable: Google Maps Platform proxy (autocomplete, details, geocode,
 * reverse-geocode, directions). Auth required; every branch validates and
 * maps Google statuses to user-safe errors. The server key never leaves
 * this function.
 */
exports.googleMapsProxy = (0, https_1.onCall)(async (request) => {
    var _a, _b, _c, _d, _e, _f, _g;
    if (!request.auth) {
        throw new https_1.HttpsError("unauthenticated", "You must sign in to search.");
    }
    const data = (_a = request.data) !== null && _a !== void 0 ? _a : {};
    const action = data.action;
    if (action !== "autocomplete" &&
        action !== "details" &&
        action !== "geocode" &&
        action !== "reverseGeocode" &&
        action !== "directions") {
        throw new https_1.HttpsError("invalid-argument", "Unknown maps action.");
    }
    switch (action) {
        case "autocomplete": {
            const input = cleanInput(data.input);
            const params = {
                input,
                components: "country:NG",
                language: "en",
            };
            if (isLat(data.lat) && isLng(data.lng)) {
                params.location = `${data.lat},${data.lng}`;
                params.radius = "50000";
            }
            const json = await googleGet("/maps/api/place/autocomplete/json", params);
            const status = typeof json.status === "string" ? json.status : "";
            if (status !== "OK") {
                if (status === "ZERO_RESULTS" || status === "REQUEST_DENIED") {
                    return { predictions: [] };
                }
                throwForStatus(status, action);
            }
            return { predictions: asPredictions(json) };
        }
        case "details": {
            const placeId = cleanInput(data.input);
            const json = await googleGet("/maps/api/place/details/json", {
                place_id: placeId,
                fields: "place_id,geometry,name,formatted_address",
                language: "en",
            });
            const status = typeof json.status === "string" ? json.status : "";
            if (status !== "OK")
                throwForStatus(status, action);
            const result = ((_b = json.result) !== null && _b !== void 0 ? _b : {});
            const geometry = ((_c = result.geometry) !== null && _c !== void 0 ? _c : {});
            const point = asLatLng(geometry.location);
            if (!point) {
                throw new https_1.HttpsError("not-found", "That place has no coordinates.");
            }
            const dto = {
                placeId: typeof result.place_id === "string" ? result.place_id : placeId,
                lat: point.lat,
                lng: point.lng,
                formattedAddress: typeof result.formatted_address === "string"
                    ? result.formatted_address
                    : "",
                name: typeof result.name === "string" ? result.name : "",
            };
            return { details: dto };
        }
        case "geocode": {
            const input = cleanInput(data.input);
            const json = await googleGet("/maps/api/geocode/json", {
                address: input,
                components: "country:NG",
                language: "en",
            });
            const status = typeof json.status === "string" ? json.status : "";
            if (status !== "OK") {
                if (status === "ZERO_RESULTS")
                    return { address: null };
                throwForStatus(status, action);
            }
            const first = Array.isArray(json.results) ? json.results[0] : null;
            const m = typeof first === "object" && first !== null
                ? first
                : {};
            const geometry = ((_d = m.geometry) !== null && _d !== void 0 ? _d : {});
            const point = asLatLng(geometry.location);
            if (!point)
                throw new https_1.HttpsError("not-found", "No matching places found.");
            return {
                address: {
                    placeId: typeof m.place_id === "string" ? m.place_id : "",
                    lat: point.lat,
                    lng: point.lng,
                    formattedAddress: typeof m.formatted_address === "string"
                        ? m.formatted_address
                        : input,
                    name: "",
                },
            };
        }
        case "reverseGeocode": {
            if (!isLat(data.lat) || !isLng(data.lng)) {
                throw new https_1.HttpsError("invalid-argument", "Invalid coordinates.");
            }
            const json = await googleGet("/maps/api/geocode/json", {
                latlng: `${data.lat},${data.lng}`,
                language: "en",
            });
            const status = typeof json.status === "string" ? json.status : "";
            if (status !== "OK") {
                if (status === "ZERO_RESULTS") {
                    return { address: `${data.lat.toFixed(5)}, ${data.lng.toFixed(5)}` };
                }
                throwForStatus(status, action);
            }
            const first = Array.isArray(json.results) ? json.results[0] : null;
            const m = typeof first === "object" && first !== null
                ? first
                : {};
            const formatted = typeof m.formatted_address === "string" && m.formatted_address
                ? m.formatted_address
                : `${data.lat.toFixed(5)}, ${data.lng.toFixed(5)}`;
            return { address: formatted };
        }
        case "directions": {
            if (!isLat(data.originLat) ||
                !isLng(data.originLng) ||
                !isLat(data.destLat) ||
                !isLng(data.destLng)) {
                throw new https_1.HttpsError("invalid-argument", "Invalid route endpoints.");
            }
            const json = await googleGet("/maps/api/directions/json", {
                origin: `${data.originLat},${data.originLng}`,
                destination: `${data.destLat},${data.destLng}`,
                mode: "driving",
                language: "en",
            });
            const status = typeof json.status === "string" ? json.status : "";
            if (status !== "OK") {
                if (status === "ZERO_RESULTS" || status === "NOT_FOUND") {
                    return { points: [], distanceM: 0, durationS: 0 };
                }
                throwForStatus(status, action);
            }
            const routes = Array.isArray(json.routes) ? json.routes : [];
            const first = typeof routes[0] === "object" && routes[0] !== null
                ? routes[0]
                : {};
            const poly = ((_e = first.overview_polyline) !== null && _e !== void 0 ? _e : {});
            let distanceM = 0;
            let durationS = 0;
            const legs = Array.isArray(first.legs) ? first.legs : [];
            for (const leg of legs) {
                if (typeof leg !== "object" || leg === null)
                    continue;
                const lm = leg;
                const d = ((_f = lm.distance) !== null && _f !== void 0 ? _f : {});
                const t = ((_g = lm.duration) !== null && _g !== void 0 ? _g : {});
                if (typeof d.value === "number")
                    distanceM += d.value;
                if (typeof t.value === "number")
                    durationS += t.value;
            }
            return {
                polyline: typeof poly.points === "string" ? poly.points : "",
                distanceM,
                durationS,
            };
        }
    }
});
//# sourceMappingURL=googleMaps.js.map