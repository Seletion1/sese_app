"use strict";
var __importDefault = (this && this.__importDefault) || function (mod) {
    return (mod && mod.__esModule) ? mod : { "default": mod };
};
Object.defineProperty(exports, "__esModule", { value: true });
const node_assert_1 = __importDefault(require("node:assert"));
const node_test_1 = require("node:test");
process.env.FARE_SIGNING_SECRET = process.env.FARE_SIGNING_SECRET || "sese-test-fare-signing-secret-key-12345";
const fareToken_1 = require("../fareToken");
(0, node_test_1.describe)("Fare Token Security & Signing Key Invariants", () => {
    (0, node_test_1.test)("generates and verifies valid fare token", () => {
        const payload = {
            uid: "user_123",
            serviceType: "ride_economy",
            pickup: { lat: 6.5244, lng: 3.3792 },
            dropoff: { lat: 6.6018, lng: 3.3515 },
            distanceKm: 12.5,
            durationMins: 25,
            tiers: [{ tierId: "economy", fareAmount: 2500 }],
            timestamp: Date.now(),
        };
        const token = (0, fareToken_1.generateFareToken)(payload);
        node_assert_1.default.ok(token);
        node_assert_1.default.ok(token.includes("."));
        const verified = (0, fareToken_1.verifyFareToken)(token);
        node_assert_1.default.notStrictEqual(verified, null);
        node_assert_1.default.strictEqual(verified === null || verified === void 0 ? void 0 : verified.uid, "user_123");
        node_assert_1.default.strictEqual(verified === null || verified === void 0 ? void 0 : verified.tiers[0].fareAmount, 2500);
    });
    (0, node_test_1.test)("rejects tampered fare token signature", () => {
        const payload = {
            uid: "user_123",
            serviceType: "ride_economy",
            pickup: { lat: 6.5244, lng: 3.3792 },
            dropoff: { lat: 6.6018, lng: 3.3515 },
            distanceKm: 12.5,
            durationMins: 25,
            tiers: [{ tierId: "economy", fareAmount: 2500 }],
            timestamp: Date.now(),
        };
        const token = (0, fareToken_1.generateFareToken)(payload);
        const [encodedData, signature] = token.split(".");
        // Tamper with signature
        const tamperedSig = signature.substring(0, signature.length - 2) + "ff";
        const tamperedToken = `${encodedData}.${tamperedSig}`;
        const verified = (0, fareToken_1.verifyFareToken)(tamperedToken);
        node_assert_1.default.strictEqual(verified, null);
    });
    (0, node_test_1.test)("rejects expired fare token", () => {
        const payload = {
            uid: "user_123",
            serviceType: "ride_economy",
            pickup: { lat: 6.5244, lng: 3.3792 },
            dropoff: { lat: 6.6018, lng: 3.3515 },
            distanceKm: 12.5,
            durationMins: 25,
            tiers: [{ tierId: "economy", fareAmount: 2500 }],
            timestamp: Date.now() - (35 * 60 * 1000), // 35 minutes ago
        };
        const token = (0, fareToken_1.generateFareToken)(payload);
        const verified = (0, fareToken_1.verifyFareToken)(token); // maxAgeMs default is 30 mins
        node_assert_1.default.strictEqual(verified, null);
    });
});
//# sourceMappingURL=fareToken.test.js.map