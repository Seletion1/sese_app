import * as admin from "firebase-admin";

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
}

// Initialize BEFORE importing/re-exporting any module that touches the
// Admin SDK, so trigger discovery (which requires this entry point in an
// isolated worker) never observes an uninitialized default app.
admin.initializeApp();

import { onCall, HttpsError } from "firebase-functions/v2/https";
import { fetchRoute } from "./routing";
import { computeFares } from "./pricing";
import { generateFareToken } from "./fareToken";

export {
  createTrip,
  onTripCreated,
  sweepTripPings,
  recycleDueOrders,
  acceptTrip,
  declineTrip,
  updateDriverLocation,
  advanceTripStatus,
  cancelTrip,
  submitBid,
  rejectBid,
  acceptBid,
  increaseTripFare,
  verifyDeliveryPin,
  hubForceCompleteTrip,
  hubCancelRefundTrip,
  hubManualPinBypass,
  onTripChatMessage,
} from "./trips";

export { goOnline, goOffline, hubSetDriverOnlineStatus } from "./driverStatus";

export {
  onTripCompleted,
  onTripCancelled,
  scheduledResetStreaks,
} from "./driverStreak";

export {
  evaluateAndGrantStreakRewards,
  resolveDynamicStreakRewards,
  getCyclePeriodKey,
} from "./streakRewards";

export {
  initializePayment,
  initializePaystackTopUp,
  verifyPayment,
  paystackWebhook,
} from "./payments";

export {
  paystackBanks,
  resolveBankAccount,
  verifyBankAccount,
  processWalletWithdrawal,
  settleTransfer,
} from "./payouts";

export {
  lookupP2pRecipient,
  transferWalletFunds,
  requestSplitPayment,
  respondSplitPayment,
  settleSplitPayment,
  convertSeseCoins,
} from "./peerPayments";

// NOTE: `onSupportTicketReply` was removed. It was bound to
// `support_tickets/{ticketId}/messages`, a legacy collection nothing writes
// to any more (the app and hub both use `support_chats`), so it was dead code
// reading a collection that no longer exists. It has been replaced by
// `onAgentReplied` in supportBot.ts, which notifies the user on the real
// `support_chats` path.
export { onSupportMessageCreated, onAgentReplied } from "./supportBot";

export { deleteAccount } from "./deleteAccount";

// Granular targeted push broadcast engine (admin console + inbox).
export { sendTargetedBroadcast } from "./broadcast";

export {
  syncGlobalExchangeRates,
  triggerExchangeRatesSync,
} from "./exchangeRates";

// Google Maps Platform proxy: the only server holder of the web-services
// key. Clients call it for autocomplete/details/geocode/directions — the
// key never ships in client code. See googleMaps.ts for the key-delivery
// and quota-discipline notes.
export { googleMapsProxy } from "./googleMaps";

// Transaction Security PIN authority (hashed, server-verified) + gates.
// Money callables verify via `requireValidPin` — see transactionPin.ts.
export { setTransactionPin, verifyTransactionPin } from "./transactionPin";

export {
  reviewCustomerVerification,
  reviewDriverVerification,
  onUserVerificationUpdated,
  onDriverVerificationUpdated,
  onDriverVehicleVerified,
} from "./verification";

export {
  lookupAccountForOnboarding,
  sendOnboardingOtp,
  verifyOnboardingOtp,
  adminRegisterUser,
} from "./adminOnboarding";

interface CalculateFareData {
  pickup: { lat: number; lng: number };
  dropoff: { lat: number; lng: number };
  serviceType: "ride" | "send_item" | "receive_item";
  selectedTiers?: string[];
  countryCode?: string;
  stateOrRegion?: string;
}

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
export const calculateFare = onCall<CalculateFareData>(async (request) => {
  // Zero-Trust Guard: reject unauthenticated callers. The Firebase SDK
  // attaches the verified JWT session as request.auth; absence of it means
  // the caller is not signed in and must never receive authoritative fares.
  if (!request.auth) {
    throw new HttpsError(
      "unauthenticated",
      "You must sign in before calculating fares."
    );
  }
  const uid = request.auth.uid;

  const { pickup, dropoff, serviceType, selectedTiers, countryCode, stateOrRegion } = request.data ?? {};

  if (
    !pickup ||
    typeof pickup.lat !== "number" ||
    typeof pickup.lng !== "number" ||
    !dropoff ||
    typeof dropoff.lat !== "number" ||
    typeof dropoff.lng !== "number"
  ) {
    throw new HttpsError(
      "invalid-argument",
      "Both pickup and dropoff coordinates ({lat, lng}) are required."
    );
  }

  // Validate coordinate bounds to reject absurd/tampered inputs.
  const isValidCoord = (lat: number, lng: number) =>
    Number.isFinite(lat) &&
    Number.isFinite(lng) &&
    lat >= -90 && lat <= 90 &&
    lng >= -180 && lng <= 180;

  if (
    !isValidCoord(pickup.lat, pickup.lng) ||
    !isValidCoord(dropoff.lat, dropoff.lng)
  ) {
    throw new HttpsError(
      "invalid-argument",
      "Coordinates are outside valid geographic bounds."
    );
  }

  if (!serviceType || !["ride", "send_item", "receive_item"].includes(serviceType)) {
    throw new HttpsError(
      "invalid-argument",
      "Valid serviceType ('ride', 'send_item', or 'receive_item') is required."
    );
  }

  if (
    selectedTiers !== undefined &&
    (!Array.isArray(selectedTiers) ||
      selectedTiers.some((t) => typeof t !== "string" || t.trim().length === 0))
  ) {
    throw new HttpsError(
      "invalid-argument",
      "selectedTiers must be an array of non-empty tier/category ids."
    );
  }

  // 1. Fetch actual road-network route distance and duration
  let distanceKm = 10.0;
  let durationMins = 20.0;

  try {
    const route = await fetchRoute(pickup.lat, pickup.lng, dropoff.lat, dropoff.lng);
    distanceKm = Math.round(route.distanceKm * 10) / 10;
    durationMins = Math.round(route.durationMins);
  } catch (err) {
    // Fallback: approximate crow-flies distance if external routing engine is temporarily unreachable
    const dLat = (dropoff.lat - pickup.lat) * (Math.PI / 180);
    const dLng = (dropoff.lng - pickup.lng) * (Math.PI / 180);
    const a =
      Math.sin(dLat / 2) * Math.sin(dLat / 2) +
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
  const tiers = await computeFares({
    serviceType,
    selectedTiers,
    distanceKm,
    durationMins,
    countryCode: typeof countryCode === "string" ? countryCode : undefined,
    stateOrRegion: typeof stateOrRegion === "string" ? stateOrRegion : undefined,
  });

  // 3. Generate signed tamper-proof fare token
  const fareToken = generateFareToken({
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
