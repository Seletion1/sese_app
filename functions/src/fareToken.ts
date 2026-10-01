import * as crypto from "crypto";

const FARE_SIGNING_SECRET =
  process.env.FARE_SIGNING_SECRET ?? "sese-default-insecure-fare-token-secret-change-me";

export interface FareTokenPayload {
  uid: string;
  serviceType: string;
  pickup: { lat: number; lng: number };
  dropoff: { lat: number; lng: number };
  distanceKm: number;
  durationMins: number;
  tiers: Array<{ tierId: string; fareAmount: number }>;
  timestamp: number;
}

/**
 * Creates a signed base64 HMAC-SHA256 token encoding the authoritative fare calculation.
 * The client cannot forge or alter the fares without invalidating the token.
 */
export function generateFareToken(payload: FareTokenPayload): string {
  const json = JSON.stringify(payload);
  const hmac = crypto.createHmac("sha256", FARE_SIGNING_SECRET);
  hmac.update(json);
  const signature = hmac.digest("hex");
  const encodedData = Buffer.from(json, "utf-8").toString("base64url");
  return `${encodedData}.${signature}`;
}

/**
 * Verifies a fareToken and returns the verified payload, or null if invalid or tampered.
 */
export function verifyFareToken(token: string, maxAgeMs = 30 * 60 * 1000): FareTokenPayload | null {
  try {
    const [encodedData, signature] = token.split(".");
    if (!encodedData || !signature) return null;

    const json = Buffer.from(encodedData, "base64url").toString("utf-8");
    const hmac = crypto.createHmac("sha256", FARE_SIGNING_SECRET);
    hmac.update(json);
    const expectedSig = hmac.digest("hex");

    if (!crypto.timingSafeEqual(Buffer.from(signature), Buffer.from(expectedSig))) {
      return null;
    }

    const payload = JSON.parse(json) as FareTokenPayload;
    const now = Date.now();
    if (now - payload.timestamp > maxAgeMs) {
      // Expired token
      return null;
    }

    return payload;
  } catch {
    return null;
  }
}
