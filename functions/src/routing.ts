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
import * as https from "https";

const OSRM_BASE_URL =
  process.env.OSRM_BASE_URL || "https://router.project-osrm.org";

export interface RouteResult {
  distanceKm: number;
  durationMins: number;
}

interface OsrmRoute {
  distance?: number; // metres
  duration?: number; // seconds
}

interface OsrmResponse {
  code?: string; // "Ok" on success
  routes?: OsrmRoute[];
  message?: string;
}

/**
 * Fetches the fastest driving route between two coordinates via OSRM.
 * Returns distance in km and duration in minutes.
 *
 * @throws Error if OSRM is unreachable or returns no route.
 */
export async function fetchRoute(
  pickupLat: number,
  pickupLng: number,
  dropoffLat: number,
  dropoffLng: number
): Promise<RouteResult> {
  const path =
    `/route/v1/driving/${pickupLng},${pickupLat};${dropoffLng},${dropoffLat}` +
    `?overview=false`;

  const body = await getJson<OsrmResponse>(OSRM_BASE_URL, path);

  if (body.code !== "Ok") {
    throw new Error(
      `OSRM routing error (${body.code ?? "unknown"}): ${body.message ?? "no route"}`
    );
  }

  if (!body.routes || body.routes.length === 0) {
    throw new Error("OSRM returned no routes for these coordinates.");
  }

  const route = body.routes[0];
  const distanceKm = (route.distance ?? 0) / 1000; // metres → km
  const durationMins = (route.duration ?? 0) / 60; // seconds → minutes

  return { distanceKm, durationMins };
}

/** Minimal Node https.request wrapper for GET that returns parsed JSON. */
function getJson<T>(baseUrl: string, path: string): Promise<T> {
  return new Promise((resolve, reject) => {
    const url = new URL(path, baseUrl);
    const options: https.RequestOptions = {
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
      res.on("data", (chunk: string) => (data += chunk));
      res.on("end", () => {
        if (res.statusCode !== 200) {
          reject(
            new Error(`OSRM request failed with status ${res.statusCode}`)
          );
          return;
        }
        try {
          resolve(JSON.parse(data) as T);
        } catch (e) {
          reject(new Error(`Invalid OSRM response: ${e}`));
        }
      });
    });

    req.on("error", reject);
    req.setTimeout(10_000, () => {
      req.destroy(new Error("OSRM request timed out"));
    });

    req.end();
  });
}
