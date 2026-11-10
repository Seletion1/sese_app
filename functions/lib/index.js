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
exports.sendTargetedBroadcast = exports.deleteAccount = exports.onAgentReplied = exports.onSupportMessageCreated = exports.settleTransfer = exports.processWalletWithdrawal = exports.verifyBankAccount = exports.resolveBankAccount = exports.paystackBanks = exports.paystackWebhook = exports.verifyPayment = exports.initializePaystackTopUp = exports.initializePayment = exports.getCyclePeriodKey = exports.resolveDynamicStreakRewards = exports.evaluateAndGrantStreakRewards = exports.backfillDriverTripHistory = exports.onTripWrittenForDriverHistory = exports.scheduledResetStreaks = exports.onTripCancelled = exports.onTripCompleted = exports.getZegoToken = exports.hubSetDriverOnlineStatus = exports.goOffline = exports.goOnline = exports.submitCancellationFeedback = exports.submitTripRating = exports.onTripChatMessage = exports.hubManualPinBypass = exports.hubCancelRefundTrip = exports.hubForceCompleteTrip = exports.recordDropoffArrival = exports.skipDeliveryPin = exports.verifyDeliveryPin = exports.retryTripDispatch = exports.reassignTrip = exports.keepSearchingTrip = exports.increaseTripFare = exports.acceptBid = exports.rejectBid = exports.submitBid = exports.confirmCashCancellation = exports.cancelTrip = exports.advanceTripStatus = exports.updateDriverLocation = exports.declineTrip = exports.acceptTrip = exports.sweepTripPings = exports.onTripCreated = exports.createTrip = void 0;
exports.calculateFare = exports.registerVehicle = exports.updateProfile = exports.registerUser = exports.checkIdentifierAvailability = exports.verifyEmailOtp = exports.sendEmailOtp = exports.sendTransactionalEmail = exports.adminRegisterUser = exports.verifyOnboardingOtp = exports.sendOnboardingOtp = exports.lookupAccountForOnboarding = exports.onDriverCreated = exports.onUserCreated = exports.onDriverVehicleVerified = exports.onDriverVerificationUpdated = exports.onUserVerificationUpdated = exports.reviewDriverVerification = exports.reviewCustomerVerification = exports.verifyTransactionPin = exports.setTransactionPin = exports.googleMapsProxy = void 0;
const admin = __importStar(require("firebase-admin"));
// DEPLOYMENT CREDENTIAL-PROBE GUARD.
// `admin.initializeApp()` calls google-auth-library, which probes the GCE
// metadata server to detect the project ID when credentials come from
// `gcloud auth application-default login` (stored in
// ~/.config/gcloud/application_default_credentials.json). In that case
// GOOGLE_APPLICATION_CREDENTIALS is NOT set, so the old guard on that var
// never fired — the CLI's 10-second trigger-discovery worker then hung on
// every deploy.
//
// Correct sentinel: GCP runtime environment variables.
//   K_SERVICE     — always set by Cloud Run (2nd-gen Cloud Functions).
//   FUNCTION_NAME — always set by 1st-gen Cloud Functions.
// Neither is present in the Firebase CLI's local trigger-discovery subprocess,
// so suppressing the probe here is safe and has zero effect on cold starts.
if (!process.env.K_SERVICE && !process.env.FUNCTION_NAME) {
    process.env.METADATA_SERVER_DETECTION = "none";
    process.env.CLOUD_SDK_METADATA_SERVER_DISABLE = "true";
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
Object.defineProperty(exports, "acceptTrip", { enumerable: true, get: function () { return trips_1.acceptTrip; } });
Object.defineProperty(exports, "declineTrip", { enumerable: true, get: function () { return trips_1.declineTrip; } });
Object.defineProperty(exports, "updateDriverLocation", { enumerable: true, get: function () { return trips_1.updateDriverLocation; } });
Object.defineProperty(exports, "advanceTripStatus", { enumerable: true, get: function () { return trips_1.advanceTripStatus; } });
Object.defineProperty(exports, "cancelTrip", { enumerable: true, get: function () { return trips_1.cancelTrip; } });
Object.defineProperty(exports, "confirmCashCancellation", { enumerable: true, get: function () { return trips_1.confirmCashCancellation; } });
Object.defineProperty(exports, "submitBid", { enumerable: true, get: function () { return trips_1.submitBid; } });
Object.defineProperty(exports, "rejectBid", { enumerable: true, get: function () { return trips_1.rejectBid; } });
Object.defineProperty(exports, "acceptBid", { enumerable: true, get: function () { return trips_1.acceptBid; } });
Object.defineProperty(exports, "increaseTripFare", { enumerable: true, get: function () { return trips_1.increaseTripFare; } });
Object.defineProperty(exports, "keepSearchingTrip", { enumerable: true, get: function () { return trips_1.keepSearchingTrip; } });
Object.defineProperty(exports, "reassignTrip", { enumerable: true, get: function () { return trips_1.reassignTrip; } });
Object.defineProperty(exports, "retryTripDispatch", { enumerable: true, get: function () { return trips_1.retryTripDispatch; } });
Object.defineProperty(exports, "verifyDeliveryPin", { enumerable: true, get: function () { return trips_1.verifyDeliveryPin; } });
Object.defineProperty(exports, "skipDeliveryPin", { enumerable: true, get: function () { return trips_1.skipDeliveryPin; } });
Object.defineProperty(exports, "recordDropoffArrival", { enumerable: true, get: function () { return trips_1.recordDropoffArrival; } });
Object.defineProperty(exports, "hubForceCompleteTrip", { enumerable: true, get: function () { return trips_1.hubForceCompleteTrip; } });
Object.defineProperty(exports, "hubCancelRefundTrip", { enumerable: true, get: function () { return trips_1.hubCancelRefundTrip; } });
Object.defineProperty(exports, "hubManualPinBypass", { enumerable: true, get: function () { return trips_1.hubManualPinBypass; } });
Object.defineProperty(exports, "onTripChatMessage", { enumerable: true, get: function () { return trips_1.onTripChatMessage; } });
Object.defineProperty(exports, "submitTripRating", { enumerable: true, get: function () { return trips_1.submitTripRating; } });
Object.defineProperty(exports, "submitCancellationFeedback", { enumerable: true, get: function () { return trips_1.submitCancellationFeedback; } });
var driverStatus_1 = require("./driverStatus");
Object.defineProperty(exports, "goOnline", { enumerable: true, get: function () { return driverStatus_1.goOnline; } });
Object.defineProperty(exports, "goOffline", { enumerable: true, get: function () { return driverStatus_1.goOffline; } });
Object.defineProperty(exports, "hubSetDriverOnlineStatus", { enumerable: true, get: function () { return driverStatus_1.hubSetDriverOnlineStatus; } });
var callTokens_1 = require("./callTokens");
Object.defineProperty(exports, "getZegoToken", { enumerable: true, get: function () { return callTokens_1.getZegoToken; } });
var driverStreak_1 = require("./driverStreak");
Object.defineProperty(exports, "onTripCompleted", { enumerable: true, get: function () { return driverStreak_1.onTripCompleted; } });
Object.defineProperty(exports, "onTripCancelled", { enumerable: true, get: function () { return driverStreak_1.onTripCancelled; } });
Object.defineProperty(exports, "scheduledResetStreaks", { enumerable: true, get: function () { return driverStreak_1.scheduledResetStreaks; } });
var driverTripHistory_1 = require("./driverTripHistory");
Object.defineProperty(exports, "onTripWrittenForDriverHistory", { enumerable: true, get: function () { return driverTripHistory_1.onTripWrittenForDriverHistory; } });
Object.defineProperty(exports, "backfillDriverTripHistory", { enumerable: true, get: function () { return driverTripHistory_1.backfillDriverTripHistory; } });
var streakRewards_1 = require("./streakRewards");
Object.defineProperty(exports, "evaluateAndGrantStreakRewards", { enumerable: true, get: function () { return streakRewards_1.evaluateAndGrantStreakRewards; } });
Object.defineProperty(exports, "resolveDynamicStreakRewards", { enumerable: true, get: function () { return streakRewards_1.resolveDynamicStreakRewards; } });
Object.defineProperty(exports, "getCyclePeriodKey", { enumerable: true, get: function () { return streakRewards_1.getCyclePeriodKey; } });
var payments_1 = require("./payments");
Object.defineProperty(exports, "initializePayment", { enumerable: true, get: function () { return payments_1.initializePayment; } });
Object.defineProperty(exports, "initializePaystackTopUp", { enumerable: true, get: function () { return payments_1.initializePaystackTopUp; } });
Object.defineProperty(exports, "verifyPayment", { enumerable: true, get: function () { return payments_1.verifyPayment; } });
Object.defineProperty(exports, "paystackWebhook", { enumerable: true, get: function () { return payments_1.paystackWebhook; } });
var payouts_1 = require("./payouts");
Object.defineProperty(exports, "paystackBanks", { enumerable: true, get: function () { return payouts_1.paystackBanks; } });
Object.defineProperty(exports, "resolveBankAccount", { enumerable: true, get: function () { return payouts_1.resolveBankAccount; } });
Object.defineProperty(exports, "verifyBankAccount", { enumerable: true, get: function () { return payouts_1.verifyBankAccount; } });
Object.defineProperty(exports, "processWalletWithdrawal", { enumerable: true, get: function () { return payouts_1.processWalletWithdrawal; } });
Object.defineProperty(exports, "settleTransfer", { enumerable: true, get: function () { return payouts_1.settleTransfer; } });
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
// Granular targeted push broadcast engine (admin console + inbox).
var broadcast_1 = require("./broadcast");
Object.defineProperty(exports, "sendTargetedBroadcast", { enumerable: true, get: function () { return broadcast_1.sendTargetedBroadcast; } });
// Google Maps Platform proxy: the only server holder of the web-services
// key. Clients call it for autocomplete/details/geocode/directions — the
// key never ships in client code. See googleMaps.ts for the key-delivery
// and quota-discipline notes.
var googleMaps_1 = require("./googleMaps");
Object.defineProperty(exports, "googleMapsProxy", { enumerable: true, get: function () { return googleMaps_1.googleMapsProxy; } });
// Transaction Security PIN authority (hashed, server-verified) + gates.
// Money callables verify via `requireValidPin` — see transactionPin.ts.
var transactionPin_1 = require("./transactionPin");
Object.defineProperty(exports, "setTransactionPin", { enumerable: true, get: function () { return transactionPin_1.setTransactionPin; } });
Object.defineProperty(exports, "verifyTransactionPin", { enumerable: true, get: function () { return transactionPin_1.verifyTransactionPin; } });
var verification_1 = require("./verification");
Object.defineProperty(exports, "reviewCustomerVerification", { enumerable: true, get: function () { return verification_1.reviewCustomerVerification; } });
Object.defineProperty(exports, "reviewDriverVerification", { enumerable: true, get: function () { return verification_1.reviewDriverVerification; } });
Object.defineProperty(exports, "onUserVerificationUpdated", { enumerable: true, get: function () { return verification_1.onUserVerificationUpdated; } });
Object.defineProperty(exports, "onDriverVerificationUpdated", { enumerable: true, get: function () { return verification_1.onDriverVerificationUpdated; } });
Object.defineProperty(exports, "onDriverVehicleVerified", { enumerable: true, get: function () { return verification_1.onDriverVehicleVerified; } });
Object.defineProperty(exports, "onUserCreated", { enumerable: true, get: function () { return verification_1.onUserCreated; } });
Object.defineProperty(exports, "onDriverCreated", { enumerable: true, get: function () { return verification_1.onDriverCreated; } });
var adminOnboarding_1 = require("./adminOnboarding");
Object.defineProperty(exports, "lookupAccountForOnboarding", { enumerable: true, get: function () { return adminOnboarding_1.lookupAccountForOnboarding; } });
Object.defineProperty(exports, "sendOnboardingOtp", { enumerable: true, get: function () { return adminOnboarding_1.sendOnboardingOtp; } });
Object.defineProperty(exports, "verifyOnboardingOtp", { enumerable: true, get: function () { return adminOnboarding_1.verifyOnboardingOtp; } });
Object.defineProperty(exports, "adminRegisterUser", { enumerable: true, get: function () { return adminOnboarding_1.adminRegisterUser; } });
var email_1 = require("./email");
Object.defineProperty(exports, "sendTransactionalEmail", { enumerable: true, get: function () { return email_1.sendTransactionalEmail; } });
Object.defineProperty(exports, "sendEmailOtp", { enumerable: true, get: function () { return email_1.sendEmailOtp; } });
Object.defineProperty(exports, "verifyEmailOtp", { enumerable: true, get: function () { return email_1.verifyEmailOtp; } });
var uniqueIdentifiers_1 = require("./uniqueIdentifiers");
Object.defineProperty(exports, "checkIdentifierAvailability", { enumerable: true, get: function () { return uniqueIdentifiers_1.checkIdentifierAvailability; } });
Object.defineProperty(exports, "registerUser", { enumerable: true, get: function () { return uniqueIdentifiers_1.registerUser; } });
Object.defineProperty(exports, "updateProfile", { enumerable: true, get: function () { return uniqueIdentifiers_1.updateProfile; } });
Object.defineProperty(exports, "registerVehicle", { enumerable: true, get: function () { return uniqueIdentifiers_1.registerVehicle; } });
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