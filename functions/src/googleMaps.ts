import * as admin from "firebase-admin";
import { HttpsError } from "firebase-functions/v2/https";
import { guardedOnCall } from "./accountGuard";

/**
 * Server-side Google Maps Platform proxy is intentionally disabled.
 *
 * Zero server-side billable Google Maps API keys are stored or called by Cloud
 * Functions. Client apps use platform-restricted SDK keys from
 * `system_config/api_keys` or free OSRM/Nominatim services.
 */

interface ProxyRequest {
  action?: string;
  input?: string;
  lat?: number;
  lng?: number;
  originLat?: number;
  originLng?: number;
  destLat?: number;
  destLng?: number;
}

const PROXY_RATE_LIMIT_PER_MIN = 60;
const PROXY_RATE_WINDOW_MS = 60_000;
const _proxyBuckets = new Map<string, number[]>();

function checkProxyRateLimitInMemory(uid: string): void {
  const now = Date.now();
  const prev = _proxyBuckets.get(uid) ?? [];
  const recent = prev.filter((t) => now - t < PROXY_RATE_WINDOW_MS);
  if (recent.length >= PROXY_RATE_LIMIT_PER_MIN) {
    throw new HttpsError(
      "resource-exhausted",
      "Too many location searches. Please wait a moment and try again."
    );
  }
  recent.push(now);
  _proxyBuckets.set(uid, recent);
}

/**
 * Per-UID sliding-window rate limiter (60s window, 30 requests/min).
 */
export async function checkProxyRateLimit(uid: string): Promise<void> {
  const now = Date.now();
  const bucketKey = Math.floor(now / PROXY_RATE_WINDOW_MS);
  const docRef = admin
    .firestore()
    .collection("rate_limits")
    .doc(`maps_proxy_${uid}_${bucketKey}`);
  try {
    const count = await admin.firestore().runTransaction(async (tx) => {
      const snap = await tx.get(docRef);
      const current = snap.exists ? Number(snap.data()?.count ?? 0) : 0;
      const next = current + 1;
      if (next > PROXY_RATE_LIMIT_PER_MIN) {
        return next;
      }
      tx.set(
        docRef,
        {
          uid,
          count: next,
          windowStart: bucketKey * PROXY_RATE_WINDOW_MS,
          expiresAt: new Date(now + 2 * PROXY_RATE_WINDOW_MS),
        },
        { merge: true }
      );
      return next;
    });
    if (count > PROXY_RATE_LIMIT_PER_MIN) {
      throw new HttpsError(
        "resource-exhausted",
        "Too many location searches. Please wait a moment and try again."
      );
    }
  } catch (err) {
    if (err instanceof HttpsError) throw err;
    checkProxyRateLimitInMemory(uid);
  }
}

export const googleMapsProxy = guardedOnCall<ProxyRequest>(async (request) => {
  if (!request.auth) {
    throw new HttpsError("unauthenticated", "You must sign in to search.");
  }

  throw new HttpsError(
    "failed-precondition",
    "Server-side Google Maps proxy is disabled."
  );
});
