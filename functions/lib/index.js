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
exports.calculateFare = exports.onDriverVehicleVerified = exports.onDriverVerificationUpdated = exports.onUserVerificationUpdated = exports.reviewDriverVerification = exports.reviewCustomerVerification = exports.deleteAccount = exports.onAgentReplied = exports.onSupportMessageCreated = exports.respondSplitPayment = exports.requestSplitPayment = exports.transferWalletFunds = exports.settleTransfer = exports.processWalletWithdrawal = exports.resolveBankAccount = exports.paystackBanks = exports.paystackWebhook = exports.verifyPayment = exports.initializePayment = exports.scheduledResetStreaks = exports.onTripCancelled = exports.onTripCompleted = exports.goOffline = exports.goOnline = exports.onTripChatMessage = exports.verifyDeliveryPin = exports.increaseTripFare = exports.acceptBid = exports.rejectBid = exports.submitBid = exports.cancelTrip = exports.advanceTripStatus = exports.updateDriverLocation = exports.declineTrip = exports.acceptTrip = exports.recycleDueOrders = exports.sweepTripPings = exports.onTripCreated = exports.createTrip = void 0;
const admin = __importStar(require("firebase-admin"));
// DEPLOYMENT CREDENTIAL-PROBE GUARD.
// `admin.initializeApp()` calls google-gax, which probes the GCE metadata
// server for default credentials when ADC is absent. On a plain dev machine
// that probe hangs for ~45s and trips the Cloud Functions trigger-discovery
// timeout ("Cannot determine backend specification. Timeout after 10000").
// Outside Google Cloud there is no metadata server worth probing (emulators
// and local runs provide explicit credentials), so skip the probe unless
// GOOGLE_APPLICATION_CREDENTIALS is set. No effect on real Cloud Functions:
// they inject the project ID/credentials, which are already handled below.
if (!process.env.GOOGLE_APPLICATION_CREDENTIALS) {
    process.env.METADATA_SERVER_DETECTION = "assume-not-present";
}
// Initialize BEFORE importing/re-exporting any module that touches the
// Admin SDK, so trigger discovery (which requires this entry point in an
// isolated worker) never observes an uninitialized default app.
admin.initializeApp();
const https_1 = require("firebase-functions/v2/https");
const routing_1 = require("./routing");
const pricing_1 = require("./pricing");
const fareToken_1 = require("./fareToken");
var trips_1 = require("./trips");
Object.defineProperty(exports, "createTrip", { enumerable: true, get: function () { return trips_1.createTrip; } });
Object.defineProperty(exports, "onTripCreated", { enumerable: true, get: function () { return trips_1.onTripCreated; } });
Object.defineProperty(exports, "sweepTripPings", { enumerable: true, get: function () { return trips_1.sweepTripPings; } });
Object.defineProperty(exports, "recycleDueOrders", { enumerable: true, get: function () { return trips_1.recycleDueOrders; } });
Object.defineProperty(exports, "acceptTrip", { enumerable: true, get: function () { return trips_1.acceptTrip; } });
Object.defineProperty(exports, "declineTrip", { enumerable: true, get: function () { return trips_1.declineTrip; } });
Object.defineProperty(exports, "updateDriverLocation", { enumerable: true, get: function () { return trips_1.updateDriverLocation; } });
Object.defineProperty(exports, "advanceTripStatus", { enumerable: true, get: function () { return trips_1.advanceTripStatus; } });
Object.defineProperty(exports, "cancelTrip", { enumerable: true, get: function () { return trips_1.cancelTrip; } });
Object.defineProperty(exports, "submitBid", { enumerable: true, get: function () { return trips_1.submitBid; } });
Object.defineProperty(exports, "rejectBid", { enumerable: true, get: function () { return trips_1.rejectBid; } });
Object.defineProperty(exports, "acceptBid", { enumerable: true, get: function () { return trips_1.acceptBid; } });
Object.defineProperty(exports, "increaseTripFare", { enumerable: true, get: function () { return trips_1.increaseTripFare; } });
Object.defineProperty(exports, "verifyDeliveryPin", { enumerable: true, get: function () { return trips_1.verifyDeliveryPin; } });
Object.defineProperty(exports, "onTripChatMessage", { enumerable: true, get: function () { return trips_1.onTripChatMessage; } });
var driverStatus_1 = require("./driverStatus");
Object.defineProperty(exports, "goOnline", { enumerable: true, get: function () { return driverStatus_1.goOnline; } });
Object.defineProperty(exports, "goOffline", { enumerable: true, get: function () { return driverStatus_1.goOffline; } });
var driverStreak_1 = require("./driverStreak");
Object.defineProperty(exports, "onTripCompleted", { enumerable: true, get: function () { return driverStreak_1.onTripCompleted; } });
Object.defineProperty(exports, "onTripCancelled", { enumerable: true, get: function () { return driverStreak_1.onTripCancelled; } });
Object.defineProperty(exports, "scheduledResetStreaks", { enumerable: true, get: function () { return driverStreak_1.scheduledResetStreaks; } });
var payments_1 = require("./payments");
Object.defineProperty(exports, "initializePayment", { enumerable: true, get: function () { return payments_1.initializePayment; } });
Object.defineProperty(exports, "verifyPayment", { enumerable: true, get: function () { return payments_1.verifyPayment; } });
Object.defineProperty(exports, "paystackWebhook", { enumerable: true, get: function () { return payments_1.paystackWebhook; } });
var payouts_1 = require("./payouts");
Object.defineProperty(exports, "paystackBanks", { enumerable: true, get: function () { return payouts_1.paystackBanks; } });
Object.defineProperty(exports, "resolveBankAccount", { enumerable: true, get: function () { return payouts_1.resolveBankAccount; } });
Object.defineProperty(exports, "processWalletWithdrawal", { enumerable: true, get: function () { return payouts_1.processWalletWithdrawal; } });
Object.defineProperty(exports, "settleTransfer", { enumerable: true, get: function () { return payouts_1.settleTransfer; } });
var peerPayments_1 = require("./peerPayments");
Object.defineProperty(exports, "transferWalletFunds", { enumerable: true, get: function () { return peerPayments_1.transferWalletFunds; } });
Object.defineProperty(exports, "requestSplitPayment", { enumerable: true, get: function () { return peerPayments_1.requestSplitPayment; } });
Object.defineProperty(exports, "respondSplitPayment", { enumerable: true, get: function () { return peerPayments_1.respondSplitPayment; } });
// NOTE: `onSupportTicketReply` was removed. It was bound to
// `support_tickets/{ticketId}/messages`, a legacy collection nothing writes
// to any more (the app and hub both use `support_chats`), so it was dead code
// reading a collection that no longer exists. It has been replaced by
// `onAgentReplied` in supportBot.ts, which notifies the user on the real
// `support_chats` path.
var supportBot_1 = require("./supportBot");
Object.defineProperty(exports, "onSupportMessageCreated", { enumerable: true, get: function () { return supportBot_1.onSupportMessageCreated; } });
Object.defineProperty(exports, "onAgentReplied", { enumerable: true, get: function () { return supportBot_1.onAgentReplied; } });
var deleteAccount_1 = require("./deleteAccount");
Object.defineProperty(exports, "deleteAccount", { enumerable: true, get: function () { return deleteAccount_1.deleteAccount; } });
var verification_1 = require("./verification");
Object.defineProperty(exports, "reviewCustomerVerification", { enumerable: true, get: function () { return verification_1.reviewCustomerVerification; } });
Object.defineProperty(exports, "reviewDriverVerification", { enumerable: true, get: function () { return verification_1.reviewDriverVerification; } });
Object.defineProperty(exports, "onUserVerificationUpdated", { enumerable: true, get: function () { return verification_1.onUserVerificationUpdated; } });
Object.defineProperty(exports, "onDriverVerificationUpdated", { enumerable: true, get: function () { return verification_1.onDriverVerificationUpdated; } });
Object.defineProperty(exports, "onDriverVehicleVerified", { enumerable: true, get: function () { return verification_1.onDriverVehicleVerified; } });
/**
 * Callable Function: calculateFare
 *
 * Enforces Zero-Trust Architecture:
 * 1. Verifies caller authentication.
 * 2. Computes road network distance and travel duration via Google Routes API.
 * 3. Pulls active server-side region pricing rates from Firestore.
 * 4. Computes minimum fare floor, per-km/per-min rates, and multipliers.
 * 5. Generates a signed cryptographic fareToken ensuring zero client-side tampering.
 */
exports.calculateFare = (0, https_1.onCall)(async (request) => {
    var _a;
    // Zero-Trust Guard: reject unauthenticated callers. The Firebase SDK
    // attaches the verified JWT session as request.auth; absence of it means
    // the caller is not signed in and must never receive authoritative fares.
    if (!request.auth) {
        throw new https_1.HttpsError("unauthenticated", "You must sign in before calculating fares.");
    }
    const uid = request.auth.uid;
    const { pickup, dropoff, serviceType, selectedTiers, countryCode, stateOrRegion } = (_a = request.data) !== null && _a !== void 0 ? _a : {};
    if (!pickup ||
        typeof pickup.lat !== "number" ||
        typeof pickup.lng !== "number" ||
        !dropoff ||
        typeof dropoff.lat !== "number" ||
        typeof dropoff.lng !== "number") {
        throw new https_1.HttpsError("invalid-argument", "Both pickup and dropoff coordinates ({lat, lng}) are required.");
    }
    // Validate coordinate bounds to reject absurd/tampered inputs.
    const isValidCoord = (lat, lng) => Number.isFinite(lat) &&
        Number.isFinite(lng) &&
        lat >= -90 && lat <= 90 &&
        lng >= -180 && lng <= 180;
    if (!isValidCoord(pickup.lat, pickup.lng) ||
        !isValidCoord(dropoff.lat, dropoff.lng)) {
        throw new https_1.HttpsError("invalid-argument", "Coordinates are outside valid geographic bounds.");
    }
    if (!serviceType || !["ride", "send_item", "receive_item"].includes(serviceType)) {
        throw new https_1.HttpsError("invalid-argument", "Valid serviceType ('ride', 'send_item', or 'receive_item') is required.");
    }
    if (selectedTiers !== undefined &&
        (!Array.isArray(selectedTiers) ||
            selectedTiers.some((t) => typeof t !== "string" || t.trim().length === 0))) {
        throw new https_1.HttpsError("invalid-argument", "selectedTiers must be an array of non-empty tier/category ids.");
    }
    // 1. Fetch actual road-network route distance and duration
    let distanceKm = 10.0;
    let durationMins = 20.0;
    try {
        const route = await (0, routing_1.fetchRoute)(pickup.lat, pickup.lng, dropoff.lat, dropoff.lng);
        distanceKm = Math.round(route.distanceKm * 10) / 10;
        durationMins = Math.round(route.durationMins);
    }
    catch (err) {
        // Fallback: approximate crow-flies distance if external routing engine is temporarily unreachable
        const dLat = (dropoff.lat - pickup.lat) * (Math.PI / 180);
        const dLng = (dropoff.lng - pickup.lng) * (Math.PI / 180);
        const a = Math.sin(dLat / 2) * Math.sin(dLat / 2) +
            Math.cos(pickup.lat * (Math.PI / 180)) *
                Math.cos(dropoff.lat * (Math.PI / 180)) *
                Math.sin(dLng / 2) *
                Math.sin(dLng / 2);
        const c = 2 * Math.atan2(Math.sqrt(a), Math.sqrt(1 - a));
        const crowKm = 6371 * c;
        distanceKm = Math.max(1.0, Math.round(crowKm * 1.35 * 10) / 10); // 1.35 road winding factor
        durationMins = Math.max(5.0, Math.round((distanceKm / 25) * 60)); // ~25 km/h urban speed
    }
    // 2. Compute authoritative fares for requested vehicle categories or ride tiers
    // Regional scoping: countryCode/stateOrRegion are optional — resolved via
    // system_configs fallback chain (Global -> Country -> State) in pricing.ts
    const tiers = await (0, pricing_1.computeFares)({
        serviceType,
        selectedTiers,
        distanceKm,
        durationMins,
        countryCode: typeof countryCode === "string" ? countryCode : undefined,
        stateOrRegion: typeof stateOrRegion === "string" ? stateOrRegion : undefined,
    });
    // 3. Generate signed tamper-proof fare token
    const fareToken = (0, fareToken_1.generateFareToken)({
        uid,
        serviceType,
        pickup,
        dropoff,
        distanceKm,
        durationMins,
        tiers: tiers.map((t) => ({ tierId: t.tierId, fareAmount: t.fareAmount })),
        timestamp: Date.now(),
    });
    return {
        distanceKm,
        durationMins,
        tiers,
        fareToken,
    };
});
//# sourceMappingURL=index.js.map