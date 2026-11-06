import assert from "node:assert";
import { test, describe } from "node:test";

process.env.FARE_SIGNING_SECRET = process.env.FARE_SIGNING_SECRET || "sese-test-fare-signing-secret-key-12345";

import { generateFareToken, verifyFareToken, FareTokenPayload } from "../fareToken";

describe("Fare Token Security & Signing Key Invariants", () => {
  test("generates and verifies valid fare token", () => {
    const payload: FareTokenPayload = {
      uid: "user_123",
      serviceType: "ride_economy",
      pickup: { lat: 6.5244, lng: 3.3792 },
      dropoff: { lat: 6.6018, lng: 3.3515 },
      distanceKm: 12.5,
      durationMins: 25,
      tiers: [{ tierId: "economy", fareAmount: 2500 }],
      timestamp: Date.now(),
    };

    const token = generateFareToken(payload);
    assert.ok(token);
    assert.ok(token.includes("."));

    const verified = verifyFareToken(token);
    assert.notStrictEqual(verified, null);
    assert.strictEqual(verified?.uid, "user_123");
    assert.strictEqual(verified?.tiers[0].fareAmount, 2500);
  });

  test("rejects tampered fare token signature", () => {
    const payload: FareTokenPayload = {
      uid: "user_123",
      serviceType: "ride_economy",
      pickup: { lat: 6.5244, lng: 3.3792 },
      dropoff: { lat: 6.6018, lng: 3.3515 },
      distanceKm: 12.5,
      durationMins: 25,
      tiers: [{ tierId: "economy", fareAmount: 2500 }],
      timestamp: Date.now(),
    };

    const token = generateFareToken(payload);
    const [encodedData, signature] = token.split(".");

    // Tamper with signature
    const tamperedSig = signature.substring(0, signature.length - 2) + "ff";
    const tamperedToken = `${encodedData}.${tamperedSig}`;

    const verified = verifyFareToken(tamperedToken);
    assert.strictEqual(verified, null);
  });

  test("rejects expired fare token", () => {
    const payload: FareTokenPayload = {
      uid: "user_123",
      serviceType: "ride_economy",
      pickup: { lat: 6.5244, lng: 3.3792 },
      dropoff: { lat: 6.6018, lng: 3.3515 },
      distanceKm: 12.5,
      durationMins: 25,
      tiers: [{ tierId: "economy", fareAmount: 2500 }],
      timestamp: Date.now() - (35 * 60 * 1000), // 35 minutes ago
    };

    const token = generateFareToken(payload);
    const verified = verifyFareToken(token); // maxAgeMs default is 30 mins
    assert.strictEqual(verified, null);
  });
});
