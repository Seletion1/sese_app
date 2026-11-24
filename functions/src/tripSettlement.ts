import * as admin from "firebase-admin";
import { onDocumentUpdated } from "firebase-functions/v2/firestore";
import { HttpsError } from "firebase-functions/v2/https";

const db = () => admin.firestore();

export function nairaToKobo(naira: number): number {
  return Math.round(naira * 100);
}

export interface FinancialMutationLog {
  tripId?: string;
  type: string;
  accountId: string;
  amountNaira: number;
  amountKobo: number;
  currency: string;
  stage?: string;
  actor?: string;
  role?: string;
  reason?: string;
  note?: string;
  timestamp: number;
  invariantsChecked?: boolean;
}

export function logFinancialMutation(log: FinancialMutationLog): void {
  console.log(`[FINANCIAL_MUTATION] ${JSON.stringify(log)}`);
}

export function persistFinancialAuditLogInTx(
  tx: admin.firestore.Transaction,
  log: FinancialMutationLog
): void {
  const docId = log.stage
    ? `${log.tripId}_${log.type}_${log.stage}`
    : `${log.tripId}_${log.type}`;
  const auditRef = db().collection("financial_audit_logs").doc(docId);
  tx.set(
    auditRef,
    {
      ...log,
      createdAt: admin.firestore.FieldValue.serverTimestamp(),
    },
    { merge: true }
  );
  logFinancialMutation(log);
}

export async function persistFinancialAuditLog(
  log: FinancialMutationLog
): Promise<void> {
  const docId = log.stage
    ? `${log.tripId}_${log.type}_${log.stage}`
    : `${log.tripId}_${log.type}`;
  await db()
    .collection("financial_audit_logs")
    .doc(docId)
    .set(
      {
        ...log,
        createdAt: admin.firestore.FieldValue.serverTimestamp(),
      },
      { merge: true }
    );
  logFinancialMutation(log);
}

export interface TripTransitionLog {
  tripId: string;
  from: string;
  to: string;
  actor: string;
  role: string;
  reason?: string;
  timestamp: number;
}

export function logTripTransition(log: TripTransitionLog): void {
  console.log(`[TRIP_TRANSITION] ${JSON.stringify(log)}`);
}

export function persistTripChangeLogInTx(
  tx: admin.firestore.Transaction,
  log: TripTransitionLog
): void {
  const auditRef = db().collection("trip_transition_logs").doc();
  tx.set(auditRef, {
    ...log,
    createdAt: admin.firestore.FieldValue.serverTimestamp(),
  });
  logTripTransition(log);
}

export async function persistTripChangeLog(
  log: TripTransitionLog
): Promise<void> {
  await db().collection("trip_transition_logs").add({
    ...log,
    createdAt: admin.firestore.FieldValue.serverTimestamp(),
  });
  logTripTransition(log);
}

export async function closeTripCalls(tripId: string, reason: string): Promise<void> {
  if (!tripId) return;
  try {
    const firestore = db();
    const [metaSnap, directSnap] = await Promise.all([
      firestore
        .collection("calls")
        .where("metadata.tripId", "==", tripId)
        .where("status", "in", ["ringing", "connecting", "connected", "idle"])
        .get(),
      firestore
        .collection("calls")
        .where("tripId", "==", tripId)
        .where("status", "in", ["ringing", "connecting", "connected", "idle"])
        .get(),
    ]);

    const batch = firestore.batch();
    const seen = new Set<string>();

    for (const doc of [...metaSnap.docs, ...directSnap.docs]) {
      if (seen.has(doc.id)) continue;
      seen.add(doc.id);
      batch.update(doc.ref, {
        status: "ended",
        endedAt: admin.firestore.FieldValue.serverTimestamp(),
        endReason: reason,
        updatedAt: admin.firestore.FieldValue.serverTimestamp(),
      });
    }

    if (seen.size > 0) {
      await batch.commit();
      console.log(`[closeTripCalls] Terminated ${seen.size} active call(s) for trip ${tripId} (${reason}).`);
    }
  } catch (e: any) {
    console.warn(`[closeTripCalls] Failed to terminate calls for trip ${tripId}: ${e?.message ?? e}`);
  }
}

export interface CancellationSettlementParams {
  tripId: string;
  cancelledBy: string;
  actorId: string;
  role: string;
  reason?: string;
  paidWaitingFee?: number;
  useCashSettlement?: boolean;
}

export interface CancellationSettlementResult {
  ok: boolean;
  alreadyCancelled?: boolean;
  status: string;
  paidWaitingFee: number;
  escrowRefunded: number;
  cashSettlementPending?: boolean;
}

/**
 * Server-authoritative trip completion settlement.
 * Computes flat platform commission, debits commission from driver Sese Credits,
 * clears driver collected debt, releases customer card escrow, and marks trip settled.
 * ZERO streaks, ZERO bonuses, ZERO cashbacks, ZERO referral earnings.
 */
export async function handleTripCompletion(
  tripId: string,
  after: admin.firestore.DocumentData
): Promise<void> {
  const driverId: string = String(after["driver"]?.["driverId"] ?? after["driverId"] ?? "");
  if (!driverId) {
    console.warn(`handleTripCompletion[${tripId}]: no driverId, skipping completion settlement`);
    return;
  }

  const fareTiers: Array<{ tierId: string; fareAmount: number }> =
    Array.isArray(after["fareTiers"]) ? after["fareTiers"] : [];
  const selectedTiers: string[] = Array.isArray(after["selectedTiers"])
    ? after["selectedTiers"]
    : [];
  const matchedTier = fareTiers.find((t) =>
    selectedTiers.includes(t.tierId)
  );

  const baseFare: number = Number(
    after["base_trip_fare"] ??
      after["baseTripFare"] ??
      after["broadcast_fare"] ??
      after["broadcastFare"] ??
      after["baseFare"] ??
      after["proposedFare"] ??
      after["fareAmount"] ??
      matchedTier?.fareAmount ??
      fareTiers[0]?.fareAmount ??
      0
  );

  const recoveredDebt: number = Number(
    after["outstanding_debt"] ??
      after["outstandingDebt"] ??
      after["recoveredDebt"] ??
      after["paymentBreakdown"]?.["outstanding_debt"] ??
      after["paymentBreakdown"]?.["recoveredDebt"] ??
      after["outstandingBalanceIncluded"] ??
      0
  );

  const paymentMethod: string = String(
    after["paymentMethod"] ?? "cash"
  ).toLowerCase();

  if (baseFare <= 0) {
    console.warn(`handleTripCompletion[${tripId}]: baseFare=0, skipping`);
    return;
  }

  // Resolve driver data
  const driverSnap = await db().collection("drivers").doc(driverId).get();
  const driverData = driverSnap.exists ? driverSnap.data()! : {};

  // Resolve platform base commission rate (default 15%)
  let baseCommissionRate = 0.15;
  try {
    const dispatchSnap = await db().collection("system_settings").doc("dispatch").get();
    if (dispatchSnap.exists) {
      const dData = dispatchSnap.data()!;
      if (typeof dData["baseCommissionRate"] === "number") {
        baseCommissionRate = dData["baseCommissionRate"];
      } else if (typeof dData["driverCommissionRate"] === "number") {
        baseCommissionRate = dData["driverCommissionRate"];
      }
    }
  } catch (e) {
    console.warn(`handleTripCompletion[${tripId}]: failed to read dispatch config: ${e}`);
  }

  const commissionAmount = Number((baseFare * baseCommissionRate).toFixed(2));
  const commissionDebitKobo = nairaToKobo(commissionAmount);

  const tripRef = db().collection("trips").doc(tripId);
  const driverWalletRef = db().collection("wallets").doc(driverId);
  const customerId = String(after["customerId"] ?? after["userId"] ?? "");
  const custWalletRef = customerId ? db().collection("wallets").doc(customerId) : null;
  const driverUserRef = db().collection("users").doc(driverId);
  const custUserRef = customerId ? db().collection("users").doc(customerId) : null;

  await db().runTransaction(async (tx) => {
    // 1. ALL READS FIRST
    const liveTripSnap = await tx.get(tripRef);
    if (!liveTripSnap.exists) {
      console.warn(`handleTripCompletion[${tripId}]: trip not found in transaction`);
      return;
    }
    const liveTrip = liveTripSnap.data()!;

    const tripStatus = String(liveTrip.status ?? "");
    if (tripStatus !== "COMPLETED") {
      console.warn(
        `handleTripCompletion[${tripId}]: status is '${tripStatus}', not 'COMPLETED'. Aborting settlement.`
      );
      return;
    }
    if (
      liveTrip.settlement?.settled === true ||
      liveTrip.settlement?.commissionSettled === true ||
      liveTrip.settlement?.cancellationSettled === true
    ) {
      console.log(`handleTripCompletion[${tripId}]: already settled or cancelled, skipping duplicate run`);
      return;
    }

    const settlementDocRef = db().collection("settlement_records").doc(`${tripId}_completed_settlement`);
    const settlementDocSnap = await tx.get(settlementDocRef);
    if (settlementDocSnap.exists) {
      console.log(`handleTripCompletion[${tripId}]: settlement record already exists, skipping duplicate run`);
      return;
    }

    const custWalletSnap = custWalletRef ? await tx.get(custWalletRef) : null;
    await tx.get(driverWalletRef);

    // 2. Platform Commission Debit from driver Sese Credits / wallet ledger
    if (commissionDebitKobo > 0) {
      tx.set(
        driverWalletRef,
        {
          balance: admin.firestore.FieldValue.increment(-commissionDebitKobo),
          mainWalletBalance: admin.firestore.FieldValue.increment(-commissionAmount),
          driverBalance: admin.firestore.FieldValue.increment(-commissionAmount),
          updatedAt: admin.firestore.FieldValue.serverTimestamp(),
        },
        { merge: true }
      );

      const driverSeqId = (driverData.sequentialId as string | undefined) || null;
      const commTxRef = driverWalletRef
        .collection("transactions")
        .doc(`${tripId}_commission`);
      tx.set(commTxRef, {
        type: "platform_commission",
        role: "driver",
        sequentialId: driverSeqId,
        userId: driverSeqId || driverId,
        uid: driverId,
        amount: -commissionDebitKobo,
        amountKobo: -commissionDebitKobo,
        amountNaira: -commissionAmount,
        tripId,
        currency: "NGN",
        note: `Platform commission fee for trip ${tripId}`,
        createdAt: admin.firestore.FieldValue.serverTimestamp(),
      });

      persistFinancialAuditLogInTx(tx, {
        tripId,
        type: "commission",
        accountId: driverId,
        amountNaira: -commissionAmount,
        amountKobo: -commissionDebitKobo,
        currency: "NGN",
        note: `Platform commission fee for trip ${tripId}`,
        timestamp: Date.now(),
        stage: "completion",
      });
    }

    // 3. Platform Debt Settlement (Driver debited if collected in cash)
    const liveCashToCollect = Number(liveTrip.cashToCollect ?? after["cashToCollect"] ?? 0);
    const liveRecoveredDebt = Number(
      liveTrip.outstanding_debt ??
      liveTrip.outstandingDebt ??
      liveTrip.recoveredDebt ??
      liveTrip.paymentBreakdown?.outstanding_debt ??
      liveTrip.paymentBreakdown?.recoveredDebt ??
      recoveredDebt
    );
    const recoveredDebtKobo = nairaToKobo(liveRecoveredDebt);
    if (recoveredDebtKobo > 0 && (paymentMethod === "cash" || liveCashToCollect > 0)) {
      tx.set(
        driverWalletRef,
        {
          balance: admin.firestore.FieldValue.increment(-recoveredDebtKobo),
          mainWalletBalance: admin.firestore.FieldValue.increment(-liveRecoveredDebt),
          updatedAt: admin.firestore.FieldValue.serverTimestamp(),
        },
        { merge: true }
      );

      const debtDebitTxRef = driverWalletRef
        .collection("transactions")
        .doc(`${tripId}_recovered_debt_debit`);
      tx.set(debtDebitTxRef, {
        type: "recovered_debt_debit",
        role: "driver",
        amount: -recoveredDebtKobo,
        amountKobo: -recoveredDebtKobo,
        amountNaira: -liveRecoveredDebt,
        tripId,
        currency: "NGN",
        note: `Platform debt collected in cash from customer on trip ${tripId}`,
        createdAt: admin.firestore.FieldValue.serverTimestamp(),
      });

      persistFinancialAuditLogInTx(tx, {
        tripId,
        type: "recovered_debt_debit",
        accountId: driverId,
        amountNaira: -liveRecoveredDebt,
        amountKobo: -recoveredDebtKobo,
        currency: "NGN",
        note: `Driver debited for platform debt collected in cash on trip ${tripId}`,
        timestamp: Date.now(),
        stage: "completion",
      });

      if (custWalletRef) {
        tx.set(
          custWalletRef,
          {
            balance: admin.firestore.FieldValue.increment(recoveredDebtKobo),
            mainWalletBalance: admin.firestore.FieldValue.increment(liveRecoveredDebt),
            updatedAt: admin.firestore.FieldValue.serverTimestamp(),
          },
          { merge: true }
        );

        const custDebtCreditTxRef = custWalletRef
          .collection("transactions")
          .doc(`${tripId}_debt_settled`);
        tx.set(custDebtCreditTxRef, {
          type: "debt_settled_cash",
          role: "customer",
          amount: recoveredDebtKobo,
          amountKobo: recoveredDebtKobo,
          amountNaira: liveRecoveredDebt,
          tripId,
          currency: "NGN",
          note: `Outstanding debt settled via cash payment to driver on trip ${tripId}`,
          createdAt: admin.firestore.FieldValue.serverTimestamp(),
        });
      }

      if (custUserRef) {
        tx.set(
          custUserRef,
          { outstandingNegativeBalance: 0 },
          { merge: true }
        );
      }
    }

    // 4. Atomically increment completedTrips
    tx.set(
      driverUserRef,
      { completedTrips: admin.firestore.FieldValue.increment(1) },
      { merge: true }
    );
    if (custUserRef) {
      tx.set(
        custUserRef,
        { completedTrips: admin.firestore.FieldValue.increment(1) },
        { merge: true }
      );
    }

    // 5. Settle Trip Wallet Escrow & Credit Driver if Card Payment
    const walletCoverage = Number(
      liveTrip.walletCoverageAmount ??
      liveTrip.paymentBreakdown?.walletCoverageAmount ??
      after["walletCoverageAmount"] ??
      0
    );
    if (walletCoverage > 0 && !liveTrip.walletSettledAt) {
      const coverageKobo = nairaToKobo(walletCoverage);
      const custWData = custWalletSnap?.exists ? custWalletSnap.data()! : {};
      const currentCustEscrow = Number(custWData["escrowBalance"] ?? walletCoverage);
      const newCustEscrow = Math.max(0, currentCustEscrow - walletCoverage);

      if (custWalletRef) {
        tx.set(
          custWalletRef,
          {
            escrowBalance: newCustEscrow,
            updatedAt: admin.firestore.FieldValue.serverTimestamp(),
          },
          { merge: true }
        );

        tx.set(custWalletRef.collection("transactions").doc(`${tripId}_payment`), {
          type: "trip_payment",
          role: "customer",
          amountNaira: -walletCoverage,
          amountKobo: -coverageKobo,
          amount: -coverageKobo,
          tripId,
          currency: "NGN",
          note: `Payment for trip ${tripId}`,
          createdAt: admin.firestore.FieldValue.serverTimestamp(),
        });

        persistFinancialAuditLogInTx(tx, {
          tripId,
          type: "wallet_settlement_customer_debit",
          accountId: customerId,
          amountNaira: -walletCoverage,
          amountKobo: -coverageKobo,
          currency: "NGN",
          note: `Customer trip payment settled for trip ${tripId}`,
          timestamp: Date.now(),
          stage: "completion",
        });
      }

      tx.set(
        driverWalletRef,
        {
          mainWalletBalance: admin.firestore.FieldValue.increment(walletCoverage),
          balance: admin.firestore.FieldValue.increment(coverageKobo),
          updatedAt: admin.firestore.FieldValue.serverTimestamp(),
        },
        { merge: true }
      );

      tx.set(driverWalletRef.collection("transactions").doc(`${tripId}_wallet_settlement`), {
        type: "trip_wallet_settlement",
        role: "driver",
        amountNaira: walletCoverage,
        amountKobo: coverageKobo,
        amount: coverageKobo,
        tripId,
        currency: "NGN",
        note: `Wallet fare portion credited for trip ${tripId}`,
        createdAt: admin.firestore.FieldValue.serverTimestamp(),
      });

      persistFinancialAuditLogInTx(tx, {
        tripId,
        type: "wallet_settlement_driver_credit",
        accountId: driverId,
        amountNaira: walletCoverage,
        amountKobo: coverageKobo,
        currency: "NGN",
        note: `Driver fare credited for trip ${tripId}`,
        timestamp: Date.now(),
        stage: "completion",
      });
    }

    // 6. Canonical Trip Settlement Metadata
    const tripUpdate: Record<string, any> = {
      "settlement.settled": true,
      "settlement.commissionRate": baseCommissionRate,
      "settlement.commissionAmount": commissionAmount,
      "settlement.commissionSettled": true,
      "settlement.commissionSettledAt": admin.firestore.FieldValue.serverTimestamp(),
      "settlement.settledAt": admin.firestore.FieldValue.serverTimestamp(),
      "settlement.walletSettled": true,
      walletSettledAt: admin.firestore.FieldValue.serverTimestamp(),
      "paymentBreakdown.walletSettled": true,
      updatedAt: admin.firestore.FieldValue.serverTimestamp(),
    };
    if (!liveTrip.completedAt && !after["completedAt"]) {
      tripUpdate["completedAt"] = admin.firestore.FieldValue.serverTimestamp();
    }
    tx.update(tripRef, tripUpdate);

    tx.set(settlementDocRef, {
      tripId,
      driverId,
      customerId,
      baseFare,
      commissionAmount,
      commissionDebitKobo,
      recoveredDebt,
      paymentMethod,
      settledAt: admin.firestore.FieldValue.serverTimestamp(),
      createdAt: admin.firestore.FieldValue.serverTimestamp(),
    });

    tx.set(
      db().collection("driver_status").doc(driverId),
      {
        activeTripId: null,
        activeTripStatus: null,
        updatedAt: admin.firestore.FieldValue.serverTimestamp(),
      },
      { merge: true }
    );

    persistTripChangeLogInTx(tx, {
      tripId,
      from: String(liveTrip.status ?? "IN_PROGRESS"),
      to: "COMPLETED",
      actor: driverId,
      role: "driver",
      reason: "trip_completed_settled",
      timestamp: Date.now(),
    });
  });

  console.log(
    `handleTripCompletion[${tripId}] driver=${driverId} fare=${baseFare} commission=${commissionAmount}`
  );

  try {
    await processTripReferralAccumulation(tripId, after);
  } catch (e) {
    console.warn(`handleTripCompletion[${tripId}]: referral accumulation warning: ${e}`);
  }
}

/**
 * 1% Referral Credit Accumulation on Completed Trips.
 * Checks if passenger or driver was referred by a valid referrerId.
 * Verifies referral is within active duration window:
 *   - standardReferralDurationDays (default 365) for regular users
 *   - adminReferralDurationDays (default 548) for Hub Admins/Staff
 * Atomically credits 1% (configured referralCommissionPercent) of base fare into referrer's seseCredits balance,
 * keyed idempotently by `${tripId}_referral_credit_${role}` so it can never credit twice.
 */
export async function processTripReferralAccumulation(
  tripId: string,
  after: admin.firestore.DocumentData
): Promise<void> {
  const baseFare = Number(
    after["base_trip_fare"] ??
      after["baseTripFare"] ??
      after["broadcast_fare"] ??
      after["broadcastFare"] ??
      after["baseFare"] ??
      after["proposedFare"] ??
      after["fareAmount"] ??
      0
  );
  if (baseFare <= 0) return;

  // 1. Fetch dispatch settings
  let referralCommissionPercent = 1.0;
  let standardReferralDurationDays = 365;
  let adminReferralDurationDays = 548;

  try {
    const dispatchSnap = await db().collection("system_settings").doc("dispatch").get();
    if (dispatchSnap.exists) {
      const dData = dispatchSnap.data()!;
      if (typeof dData["referralCommissionPercent"] === "number") {
        referralCommissionPercent = dData["referralCommissionPercent"];
      }
      if (typeof dData["standardReferralDurationDays"] === "number") {
        standardReferralDurationDays = dData["standardReferralDurationDays"];
      }
      if (typeof dData["adminReferralDurationDays"] === "number") {
        adminReferralDurationDays = dData["adminReferralDurationDays"];
      }
    }
  } catch (e) {
    console.warn(`processTripReferralAccumulation[${tripId}]: failed to read dispatch config: ${e}`);
  }

  if (referralCommissionPercent <= 0) return;

  const creditAmountNaira = Number(((baseFare * referralCommissionPercent) / 100).toFixed(2));
  const creditAmountKobo = nairaToKobo(creditAmountNaira);
  if (creditAmountNaira <= 0 || creditAmountKobo <= 0) return;

  const customerId = String(after["customerId"] ?? after["userId"] ?? "");
  const driverId = String(after["driver"]?.["driverId"] ?? after["driverId"] ?? "");

  const actors = [
    { refereeId: customerId, collection: "users", role: "customer" },
    { refereeId: driverId, collection: "drivers", role: "driver" },
  ];

  for (const { refereeId, collection, role } of actors) {
    if (!refereeId) continue;

    try {
      let refereeSnap = await db().collection(collection).doc(refereeId).get();
      if (!refereeSnap.exists) {
        const altCollection = collection === "users" ? "drivers" : "users";
        refereeSnap = await db().collection(altCollection).doc(refereeId).get();
      }
      if (!refereeSnap.exists) continue;

      const refereeData = refereeSnap.data()!;
      const rawReferredBy = String(
        refereeData.referredBy ??
          refereeData.referrerId ??
          refereeData.referred_by_code ??
          ""
      ).trim();
      if (!rawReferredBy) continue;

      let referrerId = "";
      const codeSnap = await db().collection("referral_codes").doc(rawReferredBy.toUpperCase()).get();
      if (codeSnap.exists) {
        referrerId = String(codeSnap.data()?.referrerId ?? "").trim();
      }
      if (!referrerId) {
        referrerId = rawReferredBy;
      }

      if (!referrerId || referrerId === refereeId) continue;

      let referrerSnap = await db().collection("users").doc(referrerId).get();
      let referrerColl = "users";
      if (!referrerSnap.exists) {
        referrerSnap = await db().collection("drivers").doc(referrerId).get();
        referrerColl = "drivers";
      }
      if (!referrerSnap.exists) continue;

      const referrerData = referrerSnap.data()!;

      const referrerRoleStr = String(referrerData.role ?? "").toLowerCase();
      const isHubAdminOrStaff =
        ["admin", "hub_admin", "operations_admin", "hub_staff", "super_admin", "dispatch_operations"].includes(referrerRoleStr) ||
        referrerData.isHubStaff === true ||
        referrerData.isAdmin === true;

      const maxDays = isHubAdminOrStaff ? adminReferralDurationDays : standardReferralDurationDays;

      let refereeSignupMs = Date.now();
      const rawSignup = refereeData.referralSignupAt ?? refereeData.createdAt;
      if (rawSignup) {
        if (typeof rawSignup.toMillis === "function") {
          refereeSignupMs = rawSignup.toMillis();
        } else if (typeof rawSignup === "number") {
          refereeSignupMs = rawSignup;
        } else if (rawSignup instanceof Date) {
          refereeSignupMs = rawSignup.getTime();
        }
      }

      const ageInDays = (Date.now() - refereeSignupMs) / (1000 * 60 * 60 * 24);
      if (ageInDays > maxDays) {
        console.log(`processTripReferralAccumulation[${tripId}]: referral from ${refereeId} to ${referrerId} expired (${ageInDays.toFixed(1)} days > ${maxDays} days)`);
        continue;
      }

      const txId = `${tripId}_referral_credit_${role}`;
      const referrerWalletRef = db().collection("wallets").doc(referrerId);
      const txRef = referrerWalletRef.collection("transactions").doc(txId);

      await db().runTransaction(async (tx) => {
        const txSnap = await tx.get(txRef);
        if (txSnap.exists) {
          console.log(`processTripReferralAccumulation[${tripId}]: tx ${txId} already processed, skipping`);
          return;
        }

        const isDriverReferrer = referrerColl === "drivers" || String(referrerData.role ?? "").toLowerCase() === "driver";
        const walletUpdate: Record<string, any> = {
          seseCredits: admin.firestore.FieldValue.increment(creditAmountNaira),
          balance: admin.firestore.FieldValue.increment(creditAmountKobo),
          mainWalletBalance: admin.firestore.FieldValue.increment(creditAmountNaira),
          updatedAt: admin.firestore.FieldValue.serverTimestamp(),
        };
        if (isDriverReferrer) {
          walletUpdate["driverBalance"] = admin.firestore.FieldValue.increment(creditAmountNaira);
        } else {
          walletUpdate["customerBalance"] = admin.firestore.FieldValue.increment(creditAmountNaira);
        }
        tx.set(referrerWalletRef, walletUpdate, { merge: true });

        tx.set(txRef, {
          type: "referral_credit",
          role: isDriverReferrer ? "driver" : "customer",
          amount: creditAmountKobo,
          amountKobo: creditAmountKobo,
          amountNaira: creditAmountNaira,
          tripId,
          refereeId,
          currency: "NGN",
          note: `${referralCommissionPercent}% Referral credit earned from completed trip ${tripId}`,
          createdAt: admin.firestore.FieldValue.serverTimestamp(),
        });

        const profileRef = db().collection(referrerColl).doc(referrerId);
        tx.set(
          profileRef,
          {
            seseCredits: admin.firestore.FieldValue.increment(creditAmountNaira),
            totalReferralCreditsEarned: admin.firestore.FieldValue.increment(creditAmountNaira),
            updatedAt: admin.firestore.FieldValue.serverTimestamp(),
          },
          { merge: true }
        );

        persistFinancialAuditLogInTx(tx, {
          tripId,
          type: "referral_credit",
          accountId: referrerId,
          amountNaira: creditAmountNaira,
          amountKobo: creditAmountKobo,
          currency: "NGN",
          note: `${referralCommissionPercent}% Referral credit earned from completed trip ${tripId}`,
          timestamp: Date.now(),
          stage: "completion",
        });
      });

      console.log(`processTripReferralAccumulation[${tripId}] credited ${creditAmountNaira} NGN to referrer ${referrerId}`);
    } catch (err) {
      console.warn(`processTripReferralAccumulation[${tripId}] error for ${refereeId}:`, err);
    }
  }
}

/**
 * Server-authoritative cancellation settlement.
 * Releases escrow holds, settles waiting fees, and marks cancellation.
 */
export async function handleTripCancellationSettlement(
  params: CancellationSettlementParams
): Promise<CancellationSettlementResult> {
  const { tripId, cancelledBy, actorId, role, reason, paidWaitingFee, useCashSettlement } = params;
  const tripRef = db().collection("trips").doc(tripId);

  return await db().runTransaction(async (tx) => {
    // 1. ALL READS FIRST
    const tripSnap = await tx.get(tripRef);
    if (!tripSnap.exists) {
      throw new HttpsError("not-found", `Trip ${tripId} not found.`);
    }
    const trip = tripSnap.data()!;
    const currentStatus = String(trip.status ?? "");

    if (
      currentStatus === "COMPLETED" ||
      trip.settlement?.commissionSettled === true ||
      (trip.settlement?.settled === true && !trip.settlement?.cancellationSettled)
    ) {
      throw new HttpsError("failed-precondition", "Cannot cancel an already completed or settled trip.");
    }

    if (
      (currentStatus === "CANCELLED" ||
       currentStatus === "CANCELLED_BY_CUSTOMER" ||
       currentStatus === "CANCELLED_BY_DRIVER" ||
       currentStatus === "CANCELLED_WAITING_CASH_SETTLEMENT") &&
      trip.settlement?.cancellationSettled === true
    ) {
      return {
        ok: true,
        alreadyCancelled: true,
        status: currentStatus,
        paidWaitingFee: Number(trip.paidWaitingFee ?? 0),
        escrowRefunded: 0,
        cashSettlementPending: currentStatus === "CANCELLED_WAITING_CASH_SETTLEMENT",
      };
    }

    const customerId = String(trip.customerId ?? trip.userId ?? "");
    const driverId = String(trip.driver?.driverId ?? trip.driverId ?? "");
    const custWalletRef = customerId ? db().collection("wallets").doc(customerId) : null;
    const driverWalletRef = driverId ? db().collection("wallets").doc(driverId) : null;
    const custUserRef = customerId ? db().collection("users").doc(customerId) : null;

    const custWalletSnap = custWalletRef ? await tx.get(custWalletRef) : null;
    if (driverWalletRef) await tx.get(driverWalletRef);
    const custUserSnap = custUserRef ? await tx.get(custUserRef) : null;

    // 2. FINANCIAL CALCULATIONS & INVARIANT CHECKS
    const walletCoverage = Number(
      trip.walletCoverageAmount ??
      trip.paymentBreakdown?.walletCoverageAmount ??
      0
    );
    const isEscrowLocked = trip.escrowLocked !== false && !trip.escrowRefundedAt;
    const currentCustEscrow = Number(custWalletSnap?.data()?.escrowBalance ?? walletCoverage);
    const refundAmount = (isEscrowLocked && walletCoverage > 0) ? walletCoverage : 0;
    const newCustEscrow = Math.max(0, currentCustEscrow - refundAmount);

    const waitingFee = Math.max(0, Number(paidWaitingFee ?? 0));
    const isCashWaiting = useCashSettlement === true && waitingFee > 0;
    const targetStatus = isCashWaiting
      ? "CANCELLED_WAITING_CASH_SETTLEMENT"
      : "CANCELLED";

    // 3. ATOMIC WRITES
    // Waiting Fee Settlement (if not cash)
    if (waitingFee > 0 && !isCashWaiting && custWalletRef && driverWalletRef) {
      const feeKobo = nairaToKobo(waitingFee);
      const wData = custWalletSnap?.exists ? custWalletSnap.data()! : {};
      const uData = custUserSnap?.exists ? custUserSnap.data()! : {};
      const currentBalance = typeof wData.mainWalletBalance === "number"
        ? wData.mainWalletBalance
        : (typeof wData.balance === "number" ? wData.balance / 100 : 0);
      const isTrustedCustomer = Number(uData.completedTripCount ?? 0) >= 5;

      if (currentBalance < waitingFee && !isTrustedCustomer) {
        throw new HttpsError(
          "failed-precondition",
          `INSUFFICIENT_FUNDS: Your wallet balance (₦${currentBalance}) is insufficient for the ₦${waitingFee} paid waiting fee.`
        );
      }

      if (currentBalance >= waitingFee) {
        tx.set(
          custWalletRef,
          {
            mainWalletBalance: admin.firestore.FieldValue.increment(-waitingFee),
            balance: admin.firestore.FieldValue.increment(-feeKobo),
            updatedAt: admin.firestore.FieldValue.serverTimestamp(),
          },
          { merge: true }
        );
        tx.set(
          custWalletRef.collection("transactions").doc(`${tripId}_waiting_fee_paid`),
          {
            type: "waiting_fee_paid",
            role: "customer",
            amountNaira: -waitingFee,
            amountKobo: -feeKobo,
            amount: -feeKobo,
            tripId,
            currency: "NGN",
            note: `Paid waiting fee for trip ${tripId}`,
            createdAt: admin.firestore.FieldValue.serverTimestamp(),
          }
        );
      } else {
        const shortage = waitingFee - Math.max(0, currentBalance);
        if (custUserRef) {
          tx.set(
            custUserRef,
            { outstandingNegativeBalance: admin.firestore.FieldValue.increment(shortage) },
            { merge: true }
          );
        }
        if (currentBalance > 0) {
          tx.set(
            custWalletRef,
            {
              mainWalletBalance: 0,
              balance: 0,
              updatedAt: admin.firestore.FieldValue.serverTimestamp(),
            },
            { merge: true }
          );
          tx.set(
            custWalletRef.collection("transactions").doc(`${tripId}_waiting_fee_paid`),
            {
              type: "waiting_fee_paid",
              role: "customer",
              amountNaira: -currentBalance,
              amountKobo: -nairaToKobo(currentBalance),
              amount: -nairaToKobo(currentBalance),
              tripId,
              currency: "NGN",
              note: `Partial waiting fee paid for trip ${tripId}`,
              createdAt: admin.firestore.FieldValue.serverTimestamp(),
            }
          );
        }
      }

      tx.set(
        driverWalletRef,
        {
          mainWalletBalance: admin.firestore.FieldValue.increment(waitingFee),
          balance: admin.firestore.FieldValue.increment(feeKobo),
          updatedAt: admin.firestore.FieldValue.serverTimestamp(),
        },
        { merge: true }
      );
      tx.set(
        driverWalletRef.collection("transactions").doc(`${tripId}_waiting_fee_credited`),
        {
          type: "waiting_fee_credited",
          role: "driver",
          amountNaira: waitingFee,
          amountKobo: feeKobo,
          amount: feeKobo,
          tripId,
          currency: "NGN",
          note: `Paid waiting fee credited for trip ${tripId}`,
          createdAt: admin.firestore.FieldValue.serverTimestamp(),
        }
      );

      persistFinancialAuditLogInTx(tx, {
        tripId,
        type: "waiting_fee_paid",
        accountId: customerId,
        amountNaira: -waitingFee,
        amountKobo: -feeKobo,
        currency: "NGN",
        actor: actorId,
        role,
        reason,
        timestamp: Date.now(),
        stage: "cancellation",
      });
      persistFinancialAuditLogInTx(tx, {
        tripId,
        type: "waiting_fee_credited",
        accountId: driverId,
        amountNaira: waitingFee,
        amountKobo: feeKobo,
        currency: "NGN",
        actor: actorId,
        role,
        reason,
        timestamp: Date.now(),
        stage: "cancellation",
      });
    }

    // Escrow refund execution
    if (refundAmount > 0 && custWalletRef) {
      const coverageKobo = nairaToKobo(refundAmount);
      tx.set(
        custWalletRef,
        {
          mainWalletBalance: admin.firestore.FieldValue.increment(refundAmount),
          balance: admin.firestore.FieldValue.increment(coverageKobo),
          escrowBalance: newCustEscrow,
          updatedAt: admin.firestore.FieldValue.serverTimestamp(),
        },
        { merge: true }
      );
      tx.set(
        custWalletRef.collection("transactions").doc(`${tripId}_escrow_refund`),
        {
          type: "trip_escrow_refund",
          role: "customer",
          amountNaira: refundAmount,
          amountKobo: coverageKobo,
          amount: coverageKobo,
          tripId,
          currency: "NGN",
          note: `Escrow hold released for cancelled trip ${tripId}`,
          createdAt: admin.firestore.FieldValue.serverTimestamp(),
        }
      );
      persistFinancialAuditLogInTx(tx, {
        tripId,
        type: "escrow_refund",
        accountId: customerId,
        amountNaira: refundAmount,
        amountKobo: coverageKobo,
        currency: "NGN",
        actor: actorId,
        role,
        reason,
        timestamp: Date.now(),
        stage: "cancellation",
      });
    }

    // Update trip document
    const tripUpdates: Record<string, any> = {
      status: targetStatus,
      cancellationSource: cancelledBy,
      cancellationReason: reason,
      escrowLocked: false,
      escrowRefundedAt: admin.firestore.FieldValue.serverTimestamp(),
      "settlement.cancellationSettled": true,
      "settlement.settled": true,
      "settlement.settledAt": admin.firestore.FieldValue.serverTimestamp(),
      paidWaitingFee: waitingFee,
      pendingCashFee: isCashWaiting ? waitingFee : 0,
      pingDriverId: null,
      pingDriverIds: [],
      pingExpiresAt: null,
      tierExpiresAt: null,
      statusHistory: admin.firestore.FieldValue.arrayUnion({
        from: currentStatus,
        to: targetStatus,
        actor: actorId,
        role,
        reason,
        timestamp: Date.now(),
      }),
      updatedAt: admin.firestore.FieldValue.serverTimestamp(),
    };

    if (driverId) {
      tx.set(
        db().collection("driver_status").doc(driverId),
        {
          activeTripId: null,
          activeTripStatus: null,
          updatedAt: admin.firestore.FieldValue.serverTimestamp(),
        },
        { merge: true }
      );
    }

    tx.update(tripRef, tripUpdates);

    persistTripChangeLogInTx(tx, {
      tripId,
      from: currentStatus,
      to: targetStatus,
      actor: actorId,
      role,
      reason,
      timestamp: Date.now(),
    });

    return {
      ok: true,
      status: targetStatus,
      paidWaitingFee: waitingFee,
      escrowRefunded: refundAmount,
      cashSettlementPending: isCashWaiting,
    };
  });
}

/**
 * Firestore trigger: fires when a trip transitions to COMPLETED.
 */
export const onTripCompleted = onDocumentUpdated(
  "trips/{tripId}",
  async (event) => {
    const before = event.data?.before?.data();
    const after = event.data?.after?.data();
    if (!before || !after) return;

    if (before["status"] === "COMPLETED" || after["status"] !== "COMPLETED") {
      return;
    }

    const tripId = event.params.tripId;
    await Promise.all([
      handleTripCompletion(tripId, after),
      closeTripCalls(tripId, "trip_completed"),
    ]);
  }
);

/**
 * Firestore trigger: fires when a trip transitions to CANCELLED.
 */
export const onTripCancelled = onDocumentUpdated(
  "trips/{tripId}",
  async (event) => {
    const before = event.data?.before?.data();
    const after = event.data?.after?.data();
    if (!before || !after) return;

    if (before["status"] === "CANCELLED" || after["status"] !== "CANCELLED") {
      return;
    }

    const tripId = event.params.tripId;
    closeTripCalls(tripId, "trip_cancelled").catch((e: any) =>
      console.warn(`[onTripCancelled] closeTripCalls error for ${tripId}:`, e)
    );
  }
);
