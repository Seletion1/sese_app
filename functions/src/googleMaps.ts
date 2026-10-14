import { onCall, HttpsError } from "firebase-functions/v2/https";
import { nextEngine, recordCall } from "./mapQuotas";

/**
 * Google Maps Platform proxy: the ONLY place the server-side Google key
 * is used. Clients never hold a web-services key — Place Autocomplete,
 * Place Details, Geocoding, and Directions all go through this callable,
 * which attaches the restricted key server-side.
 *
 * KEY DELIVERY: `GOOGLE_MAPS_API_KEY` ships via `functions/.env`
 * (git-ignored, deployed as a plain env var like `PAYSTACK_API_KEY`).
 * Restrict it in Cloud Console by API scope (Places, Directions,
 * Geocoding) — no app restriction is possible on a server key, which is
 * exactly why it must never ship in client code or native configs beyond
 * the SDK-render keys. The SDK-render keys in `AndroidManifest.xml` /
 * `AppDelegate.swift` are a DIFFERENT, app-restricted key pair surface.
 *
 * QUOTA DISCIPLINE: every action validates inputs strictly (length caps,
 * coordinate ranges) so a hostile client cannot turn this into an
 * unlimited Google-billing oracle. Clients additionally debounce (400ms)
 * and serve recents from cache — this function is the last resort, not
 * the first call.
 */

type ProxyAction =
  | "autocomplete"
  | "details"
  | "geocode"
  | "reverseGeocode"
  | "directions";

interface ProxyRequest {
  action?: ProxyAction;
  /** autocomplete/details/geocode: free-text query or place_id. */
  input?: string;
  /** Bias autocomplete around the user (decimal degrees). */
  lat?: number;
  lng?: number;
  /** directions endpoints. */
  originLat?: number;
  originLng?: number;
  destLat?: number;
  destLng?: number;
}

/** Prediction shape mirrored by Dart `PlacePrediction`. */
export interface PredictionDTO {
  placeId: string;
  description: string;
  mainText: string;
  secondaryText: string;
}

/** Details shape mirrored by Dart `PlaceDetails`. */
export interface DetailsDTO {
  placeId: string;
  lat: number;
  lng: number;
  formattedAddress: string;
  name: string;
}

interface LatLngDTO {
  lat: number;
  lng: number;
}

const FETCH_TIMEOUT_MS = 9000;
const MAX_INPUT_LEN = 200;

function serverKey(): string {
  const key =
    process.env.GOOGLE_MAPS_API_KEY ?? process.env.GOOGLE_MAPS_KEY;
  if (!key) {
    throw new HttpsError(
      "failed-precondition",
      "Location search is unavailable right now. Please try again later."
    );
  }
  return key;
}

function isLat(v: unknown): v is number {
  return typeof v === "number" && Number.isFinite(v) && v >= -90 && v <= 90;
}

function isLng(v: unknown): v is number {
  return typeof v === "number" && Number.isFinite(v) && v >= -180 && v <= 180;
}

function cleanInput(raw: unknown): string {
  const s = (typeof raw === "string" ? raw : "").trim();
  if (!s) throw new HttpsError("invalid-argument", "Search text is empty.");
  if (s.length > MAX_INPUT_LEN) {
    throw new HttpsError("invalid-argument", "Search text is too long.");
  }
  return s;
}

async function googleGet(
  path: string,
  params: Record<string, string>
): Promise<Record<string, unknown>> {
  const url = new URL(`https://maps.googleapis.com${path}`);
  for (const [k, v] of Object.entries(params)) url.searchParams.set(k, v);
  url.searchParams.set("key", serverKey());
  const ctrl = new AbortController();
  const timer = setTimeout(() => ctrl.abort(), FETCH_TIMEOUT_MS);
  try {
    const res = await fetch(url, { signal: ctrl.signal });
    if (!res.ok) {
      throw new HttpsError(
        "unavailable",
        "Location service is unreachable. Check your connection."
      );
    }
    const json = (await res.json()) as Record<string, unknown>;
    // Quota attribution (single choke point: one upstream call per proxy
    // action). Within the free allowance this records `google`; past it the
    // call still proceeds (search must not break) but lands in the PAYG
    // overflow bucket so spend is auditable. Never throws — bookkeeping
    // must not fail a search.
    try {
      const verdict = await nextEngine();
      await recordCall(verdict.engine === "google" ? "google" : "googlePayg");
    } catch {
      // Quota layer is best-effort by contract (see mapQuotas.ts).
    }
    return json;
  } catch (e) {
    if (e instanceof HttpsError) throw e;
    throw new HttpsError(
      "unavailable",
      "Location service timed out. Check your connection."
    );
  } finally {
    clearTimeout(timer);
  }
}

/** Maps Google status strings to user-safe callable errors. */
function throwForStatus(
  status: string,
  action: string
): never {
  switch (status) {
    case "ZERO_RESULTS":
    case "NOT_FOUND":
      // Not an error for callers: empty result, same as offline miss.
      throw new HttpsError("not-found", "No matching places found.");
    case "OVER_QUERY_LIMIT":
    case "OVER_DAILY_LIMIT":
      throw new HttpsError(
        "resource-exhausted",
        "Search quota is exhausted. Try a recent location or try again later."
      );
    case "REQUEST_DENIED":
      throw new HttpsError(
        "failed-precondition",
        "Location search is unavailable right now. Please try again later."
      );
    case "INVALID_REQUEST":
      throw new HttpsError("invalid-argument", `Invalid ${action} request.`);
    default:
      throw new HttpsError(
        "internal",
        "Location lookup failed. Please try again."
      );
  }
}

function asPredictions(json: Record<string, unknown>): PredictionDTO[] {
  const list = json.predictions;
  if (!Array.isArray(list)) return [];
  const out: PredictionDTO[] = [];
  for (const item of list) {
    if (typeof item !== "object" || item === null) continue;
    const m = item as Record<string, unknown>;
    const placeId = typeof m.place_id === "string" ? m.place_id : "";
    const description =
      typeof m.description === "string" ? m.description : "";
    if (!placeId || !description) continue;
    const structured = (m.structured_formatting ?? {}) as Record<
      string,
      unknown
    >;
    out.push({
      placeId,
      description,
      mainText:
        typeof structured.main_text === "string"
          ? structured.main_text
          : description,
      secondaryText:
        typeof structured.secondary_text === "string"
          ? structured.secondary_text
          : "",
    });
  }
  return out.slice(0, 5);
}

function asLatLng(obj: unknown): LatLngDTO | null {
  if (typeof obj !== "object" || obj === null) return null;
  const m = obj as Record<string, unknown>;
  const lat = typeof m.lat === "number" ? m.lat : NaN;
  const lng = typeof m.lng === "number" ? m.lng : NaN;
  if (!isLat(lat) || !isLng(lng)) return null;
  return { lat, lng };
}

/**
 * Callable: Google Maps Platform proxy (autocomplete, details, geocode,
 * reverse-geocode, directions). Auth required; every branch validates and
 * maps Google statuses to user-safe errors. The server key never leaves
 * this function.
 */
export const googleMapsProxy = onCall<ProxyRequest>(async (request) => {
  if (!request.auth) {
    throw new HttpsError("unauthenticated", "You must sign in to search.");
  }
  const data = request.data ?? {};
  const action = data.action;
  if (
    action !== "autocomplete" &&
    action !== "details" &&
    action !== "geocode" &&
    action !== "reverseGeocode" &&
    action !== "directions"
  ) {
    throw new HttpsError("invalid-argument", "Unknown maps action.");
  }

  switch (action) {
    case "autocomplete": {
      const input = cleanInput(data.input);
      const params: Record<string, string> = {
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
      if (status !== "OK") throwForStatus(status, action);
      const result = (json.result ?? {}) as Record<string, unknown>;
      const geometry = (result.geometry ?? {}) as Record<string, unknown>;
      const point = asLatLng(geometry.location);
      if (!point) {
        throw new HttpsError("not-found", "That place has no coordinates.");
      }
      const dto: DetailsDTO = {
        placeId:
          typeof result.place_id === "string" ? result.place_id : placeId,
        lat: point.lat,
        lng: point.lng,
        formattedAddress:
          typeof result.formatted_address === "string"
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
        if (status === "ZERO_RESULTS") return { address: null };
        throwForStatus(status, action);
      }
      const first = Array.isArray(json.results) ? json.results[0] : null;
      const m =
        typeof first === "object" && first !== null
          ? (first as Record<string, unknown>)
          : {};
      const geometry = (m.geometry ?? {}) as Record<string, unknown>;
      const point = asLatLng(geometry.location);
      if (!point) throw new HttpsError("not-found", "No matching places found.");
      return {
        address: {
          placeId: typeof m.place_id === "string" ? m.place_id : "",
          lat: point.lat,
          lng: point.lng,
          formattedAddress:
            typeof m.formatted_address === "string"
              ? m.formatted_address
              : input,
          name: "",
        } satisfies DetailsDTO,
      };
    }

    case "reverseGeocode": {
      if (!isLat(data.lat) || !isLng(data.lng)) {
        throw new HttpsError("invalid-argument", "Invalid coordinates.");
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
      const m =
        typeof first === "object" && first !== null
          ? (first as Record<string, unknown>)
          : {};
      const formatted =
        typeof m.formatted_address === "string" && m.formatted_address
          ? m.formatted_address
          : `${data.lat.toFixed(5)}, ${data.lng.toFixed(5)}`;
      return { address: formatted };
    }

    case "directions": {
      if (
        !isLat(data.originLat) ||
        !isLng(data.originLng) ||
        !isLat(data.destLat) ||
        !isLng(data.destLng)
      ) {
        throw new HttpsError("invalid-argument", "Invalid route endpoints.");
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
      const first =
        typeof routes[0] === "object" && routes[0] !== null
          ? (routes[0] as Record<string, unknown>)
          : {};
      const poly =
        (first.overview_polyline ?? {}) as Record<string, unknown>;
      let distanceM = 0;
      let durationS = 0;
      const legs = Array.isArray(first.legs) ? first.legs : [];
      for (const leg of legs) {
        if (typeof leg !== "object" || leg === null) continue;
        const lm = leg as Record<string, unknown>;
        const d = (lm.distance ?? {}) as Record<string, unknown>;
        const t = (lm.duration ?? {}) as Record<string, unknown>;
        if (typeof d.value === "number") distanceM += d.value;
        if (typeof t.value === "number") durationS += t.value;
      }
      return {
        polyline: typeof poly.points === "string" ? poly.points : "",
        distanceM,
        durationS,
      };
    }
  }
});
