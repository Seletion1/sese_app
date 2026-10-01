import * as admin from "firebase-admin";
import { onCall, HttpsError } from "firebase-functions/v2/https";

const db = () => admin.firestore();

const ACTIVE_TRIP_STATUSES = [
  "SEARCHING_DRIVER",
  "WAITING_FOR_ACCEPTANCE",
  "MARKETPLACE_OPEN",
  "DRIVER_ACCEPTED",
  "DRIVER_ARRIVING",
  "DRIVER_ARRIVED",
  "IN_PROGRESS",
];

/**
 * Secure Account Deletion Pipeline:
 *
 * 1. Hard Security & Financial Guardrails:
 *    - Rejects if `walletBalance > 0`
 *    - Rejects if `pendingPayouts == true`
 *    - Rejects if user has active ongoing rides/deliveries
 *
 * 2. Execution:
 *    - Soft-deletes user/driver document with 30-day regulatory archival
 *    - Revokes active session tokens
 */
export const deleteAccount = onCall(async (request) => {
  if (!request.auth) {
    throw new HttpsError(
      "unauthenticated",
      "You must be authenticated to request account deletion."
    );
  }

  const uid = request.auth.uid;

  // 0. Zero-trust re-authentication enforcement. The client collects the
  // password / Google credential and re-authenticates, which refreshes
  // `auth_time` on the ID token. The server trusts ONLY that timestamp —
  // never a client-sent "I re-authenticated" flag — and requires a fresh
  // sign-in within the last 10 minutes. Without this, a stolen (but still
  // valid) session could delete the account with no fresh proof of identity.
  const authTimeSec = Number(request.auth.token.auth_time ?? 0);
  const ageSec = Date.now() / 1000 - authTimeSec;
  if (!Number.isFinite(ageSec) || ageSec < 0 || ageSec > 10 * 60) {
    throw new HttpsError(
      "unauthenticated",
      "Please sign in again to confirm account deletion."
    );
  }

  // 1. Guardrail: Check Wallet balance & pending payouts
  const walletDoc = await db().collection("wallets").doc(uid).get();
  if (walletDoc.exists) {
    const data = walletDoc.data() || {};
    const balance = Number(data.balance || 0);
    if (balance > 0) {
      throw new HttpsError(
        "failed-precondition",
        `Account deletion blocked: You have an active wallet balance of ₦${(
          balance / 100
        ).toFixed(2)}. Please withdraw or exhaust your balance before deleting your account.`
      );
    }

    if (data.pendingPayouts === true || data.hasPendingPayout === true) {
      throw new HttpsError(
        "failed-precondition",
        "Account deletion blocked: You have pending payouts in progress. Please wait for them to settle before deleting your account."
      );
    }
  }

  // 2. Guardrail: Check pending driver payouts
  const pendingPayoutsSnap = await db()
    .collection("driver_payouts")
    .where("driverId", "==", uid)
    .where("status", "==", "pending")
    .limit(1)
    .get();

  if (!pendingPayoutsSnap.empty) {
    throw new HttpsError(
      "failed-precondition",
      "Account deletion blocked: You have a pending payout request awaiting processing."
    );
  }

  // 3. Guardrail: Check active customer rides/deliveries
  const activeCustomerTrips = await db()
    .collection("trips")
    .where("customerId", "==", uid)
    .where("status", "in", ACTIVE_TRIP_STATUSES)
    .limit(1)
    .get();

  if (!activeCustomerTrips.empty) {
    throw new HttpsError(
      "failed-precondition",
      "Account deletion blocked: You have an active trip or delivery in progress."
    );
  }

  // 4. Guardrail: Check active driver rides/deliveries.
  // The assignee lives nested at `driver.driverId` — a top-level
  // `driverId` filter never matches trip documents.
  const activeDriverTrips = await db()
    .collection("trips")
    .where("driver.driverId", "==", uid)
    .where("status", "in", ACTIVE_TRIP_STATUSES)
    .limit(1)
    .get();

  if (!activeDriverTrips.empty) {
    throw new HttpsError(
      "failed-precondition",
      "Account deletion blocked: You have an active trip in progress as a driver."
    );
  }

  // 5. Execution Pipeline: Soft-delete with 30-day archival
  const now = new Date();
  const purgeDate = new Date(now.getTime() + 30 * 24 * 60 * 60 * 1000);
  const deletionData = {
    status: "deleted",
    isDeleted: true,
    deletedAt: admin.firestore.FieldValue.serverTimestamp(),
    scheduledPurgeAt: purgeDate.toISOString(),
    isActive: false,
    canGoOnline: false,
  };

  const batch = db().batch();
  const userRef = db().collection("users").doc(uid);
  const driverRef = db().collection("drivers").doc(uid);

  batch.set(userRef, deletionData, { merge: true });
  batch.set(driverRef, deletionData, { merge: true });

  await batch.commit();

  // 6. Revoke active session tokens
  try {
    await admin.auth().revokeRefreshTokens(uid);
  } catch (err) {
    console.error("Failed to revoke refresh tokens for:", uid, err);
  }

  return {
    success: true,
    message: "Account marked as deleted and scheduled for 30-day regulatory archival.",
  };
});
