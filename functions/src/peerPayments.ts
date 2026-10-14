import * as admin from "firebase-admin";
import { onCall, HttpsError } from "firebase-functions/v2/https";
import { requireValidPin } from "./transactionPin";

/**
 * P2P wallet-to-wallet transfers + split-payment intents.
 *
 * Two features, one file, because both move wallet value between users
 * without touching Paystack — no secret, no external call, just Firestore
 * transactions under the same unit discipline as everything else.
 *
 * UNIT: `wallets/{uid}.balance` is KOBO (integer minor units). Every amount
 * in this file is kobo on the wire and in storage; the naira rendering
 * happens client-side. See `driverStreak.nairaToKobo` and the decision log.
 */

const db = () => admin.firestore();

/** Floor per transfer: ₦100. Mirrors the Paystack withdrawal floor. */
const MIN_TRANSFER_KOBO = 10_000;

/** Ceiling per transfer: ₦500,000. Bounds blast radius. */

function newTransferId(prefix: string, uid: string): string {
  const rand = Math.random().toString(36).slice(2, 10);
  return `${prefix}_${uid.slice(0, 8)}_${Date.now().toString(36)}${rand}`;
}

/** Digits only, for phone matching across formats (+234... vs 080...). */
function digitsOnly(raw: string): string {
  return raw.replace(/\D/g, "");
}

/**
 * Normalises a Nigerian phone to E.164-ish digits for comparison:
 * `0803...` → `234803...`, `+234803...` → `234803...`.
 */
function normalizePhone(raw: string): string {
  const d = digitsOnly(raw);
  if (d.startsWith("234") && d.length === 13) return d;
  if (d.startsWith("0") && d.length === 11) return `234${d.slice(1)}`;
  return d;
}

/**
 * Trust tiers for split payments: below this many SETTLED splits a partner
 * must pre-fund their share (wallet balance ≥ share). At or above it the
 * account may settle into a negative balance, with the shortfall tracked
 * as recoverable debt (`splitStats.splitDebtKobo`).
 */
const SPLIT_TRUST_THRESHOLD = 3;

interface SplitStats {
  completedSplits: number;
  splitDebtKobo: number;
}

function readSplitStats(data: admin.firestore.DocumentData | undefined): SplitStats {
  const raw = (data?.splitStats ?? {}) as Record<string, unknown>;
  const completedSplits = typeof raw.completedSplits === "number" && Number.isFinite(raw.completedSplits)
    ? Math.max(0, Math.floor(raw.completedSplits))
    : 0;
  const splitDebtKobo = typeof raw.splitDebtKobo === "number" && Number.isFinite(raw.splitDebtKobo)
    ? Math.max(0, Math.floor(raw.splitDebtKobo))
    : 0;
  return { completedSplits, splitDebtKobo };
}

/**
 * Zero-trust co-payer eligibility: the account must exist, not be
 * suspended, carry a phone identity, and be KYC-verified (hub-approved
 * customer OR approved/active driver). Ghost, suspended, phone-less, or
 * unverified accounts can never hold a split share.
 *
 * Checked at invite time (fail fast) AND re-checked at settlement (status
 * may have changed in between). Throws user-safe `HttpsError`s.
 */
async function assertSplitEligible(uid: string, phone: string): Promise<void> {
  const userSnap = await db().collection("users").doc(uid).get();
  if (!userSnap.exists) {
    throw new HttpsError(
      "not-found",
      `No SeSe user found with number ${phone}.`
    );
  }
  const u = userSnap.data() ?? {};
  if (u.isSuspended === true) {
    throw new HttpsError(
      "failed-precondition",
      `The account for ${phone} is suspended and cannot split fares.`
    );
  }
  const hasPhone =
    String(u.phoneNumberE164 ?? u.phoneNumber ?? "").trim().length > 0;
  if (!hasPhone) {
    throw new HttpsError(
      "failed-precondition",
      `The account for ${phone} has no verified phone number.`
    );
  }
  const customerVerified =
    u.customerVerificationStatus === "verified" ||
    u.isVerifiedCustomer === true;
  let driverVerified = false;
  if (!customerVerified) {
    try {
      const dSnap = await db().collection("drivers").doc(uid).get();
      if (dSnap.exists) {
        const dd = dSnap.data() ?? {};
        const st = String(
          dd.verificationStatus ?? dd.status ?? ""
        ).toLowerCase();
        driverVerified =
          st === "verified" ||
          st === "approved" ||
          st === "active_verified" ||
          dd.isVerified === true ||
          dd.isProfileVerified === true;
      }
    } catch {
      // Treat lookup failure as unverified (fail closed).
    }
  }
  if (!customerVerified && !driverVerified) {
    throw new HttpsError(
      "failed-precondition",
      `The account for ${phone} is not KYC-verified yet and cannot split fares.`
    );
  }
}

interface WalletTransferData {
  recipientPhone?: string;
  amountKobo?: number;
  /** 4-digit transaction PIN, verified server-side before any movement. */
  transactionPin?: string;
}

interface WalletRules {
  minDriverTrips: number;
  maxP2pLimitNaira: number;
  adminOverrideEnabled: boolean;
}

async function getWalletRules(): Promise<WalletRules> {
  let minDriverTrips = 3;
  let maxP2pLimitNaira = 20000;
  let adminOverrideEnabled = true;

  try {
    const snap = await db().collection("system_config").doc("wallet_rules").get();
    if (snap.exists && snap.data()) {
      const data = snap.data()!;
      if (typeof data.minDriverTrips === "number") minDriverTrips = data.minDriverTrips;
      if (typeof data.min_driver_trips === "number") minDriverTrips = data.min_driver_trips;
      if (typeof data.maxP2pLimit === "number") maxP2pLimitNaira = data.maxP2pLimit;
      if (typeof data.max_p2p_limit === "number") maxP2pLimitNaira = data.max_p2p_limit;
      if (typeof data.adminOverrideEnabled === "boolean") adminOverrideEnabled = data.adminOverrideEnabled;
    }
  } catch {
    // Fall back to defaults
  }
  return { minDriverTrips, maxP2pLimitNaira, adminOverrideEnabled };
}

/**
 * Callable: live phone lookup fetching recipient's Name & Account Type (Driver/Customer)
 * and evaluating P2P eligibility guards.
 */
export const lookupP2pRecipient = onCall(async (request) => {
  if (!request.auth) {
    throw new HttpsError("unauthenticated", "You must sign in.");
  }
  const senderId = request.auth.uid;
  const recipientPhone = normalizePhone(String(request.data?.recipientPhone ?? ""));
  if (recipientPhone.length < 10) {
    throw new HttpsError("invalid-argument", "Enter a valid recipient phone number.");
  }

  let recipientId = "";
  let recipientName = "";
  let accountType: "Driver" | "Customer" = "Customer";
  let completedTrips = 0;

  // Search users collection first
  const byE164 = await db()
    .collection("users")
    .where("phoneNumberE164", "==", recipientPhone.startsWith("234") ? `+${recipientPhone}` : recipientPhone)
    .limit(1)
    .get();
  let recipientSnap = byE164.empty ? null : byE164.docs[0];
  let isFromDriversCol = false;

  if (!recipientSnap) {
    const byLocal = await db()
      .collection("users")
      .where("phoneNumber", "==", String(request.data?.recipientPhone ?? "").trim())
      .limit(1)
      .get();
    recipientSnap = byLocal.empty ? null : byLocal.docs[0];
  }

  if (!recipientSnap) {
    const byDriver = await db()
      .collection("drivers")
      .where("phoneNumberE164", "==", recipientPhone.startsWith("234") ? `+${recipientPhone}` : recipientPhone)
      .limit(1)
      .get();
    recipientSnap = byDriver.empty ? null : byDriver.docs[0];
    if (recipientSnap) isFromDriversCol = true;
  }

  if (!recipientSnap) {
    throw new HttpsError("not-found", "No SeSe user found with that phone number.");
  }

  recipientId = recipientSnap.id;
  if (recipientId === senderId) {
    throw new HttpsError("invalid-argument", "You cannot transfer to yourself.");
  }

  const rdata = recipientSnap.data() ?? {};
  recipientName = String(rdata.fullName ?? rdata.displayName ?? rdata.name ?? "SeSe User");
  const rawRole = String(rdata.role ?? "").toLowerCase();
  if (isFromDriversCol || rawRole === "driver") {
    accountType = "Driver";
    completedTrips = Number(rdata.completedTrips ?? rdata.completed_trips ?? 0);
  }

  // Check sender admin status
  let isSenderAdmin = false;
  try {
    const senderStaffSnap = await db().collection("hub_staff").doc(senderId).get();
    if (senderStaffSnap.exists && senderStaffSnap.data()?.active !== false) {
      isSenderAdmin = true;
    }
  } catch {
    // Ignore error
  }

  const rules = await getWalletRules();
  let canReceive = true;
  let tripsRemaining = 0;
  let reason = "";

  if (accountType === "Driver") {
    if (isSenderAdmin && rules.adminOverrideEnabled) {
      canReceive = true;
    } else if (completedTrips < rules.minDriverTrips) {
      canReceive = false;
      tripsRemaining = rules.minDriverTrips - completedTrips;
      reason = `This driver cannot receive transfers yet (${tripsRemaining} trip(s) remaining).`;
    }
  }

  return {
    recipientId,
    recipientName,
    accountType,
    completedTrips,
    minDriverTrips: rules.minDriverTrips,
    maxP2pLimitNaira: rules.maxP2pLimitNaira,
    canReceive,
    tripsRemaining,
    reason,
  };
});

/**
 * Callable: moves wallet value from the caller to another SeSe user,
 * identified by their registered phone number.
 */
export const transferWalletFunds = onCall<WalletTransferData>(
  async (request) => {
    if (!request.auth) {
      throw new HttpsError("unauthenticated", "You must sign in.");
    }
    const senderId = request.auth.uid;

    // Transaction-PIN gate FIRST: no verified PIN, no money movement. A
    // hostile client cannot skip the prompt — verification is server-side,
    // before any balance or recipient state is even read (no oracle).
    await requireValidPin(senderId, request.data?.transactionPin);

    const amountKobo = Math.round(Number(request.data?.amountKobo));
    if (!Number.isFinite(amountKobo) || amountKobo < MIN_TRANSFER_KOBO) {
      throw new HttpsError("invalid-argument", "Minimum transfer is ₦100.");
    }

    const rules = await getWalletRules();
    const maxKobo = rules.maxP2pLimitNaira * 100;
    if (amountKobo > maxKobo) {
      throw new HttpsError(
        "invalid-argument",
        `Maximum transfer limit is ₦${rules.maxP2pLimitNaira.toLocaleString("en-NG")}.`
      );
    }

    const recipientPhone = normalizePhone(
      String(request.data?.recipientPhone ?? "")
    );
    if (recipientPhone.length < 10) {
      throw new HttpsError(
        "invalid-argument",
        "Enter the recipient's registered phone number."
      );
    }

    // Resolve the recipient
    let recipientId = "";
    let recipientName = "";
    let accountType: "Driver" | "Customer" = "Customer";
    let completedTrips = 0;
    let isFromDriverCol = false;

    const byE164 = await db()
      .collection("users")
      .where("phoneNumberE164", "==", recipientPhone.startsWith("234")
        ? `+${recipientPhone}`
        : recipientPhone)
      .limit(1)
      .get();
    let recipientSnap = byE164.empty ? null : byE164.docs[0];

    if (!recipientSnap) {
      const byLocal = await db()
        .collection("users")
        .where("phoneNumber", "==", String(request.data?.recipientPhone ?? "").trim())
        .limit(1)
        .get();
      recipientSnap = byLocal.empty ? null : byLocal.docs[0];
    }

    if (!recipientSnap) {
      const byDriver = await db()
        .collection("drivers")
        .where("phoneNumberE164", "==", recipientPhone.startsWith("234")
          ? `+${recipientPhone}`
          : recipientPhone)
        .limit(1)
        .get();
      recipientSnap = byDriver.empty ? null : byDriver.docs[0];
      if (recipientSnap) isFromDriverCol = true;
    }

    if (!recipientSnap) {
      throw new HttpsError(
        "not-found",
        "No SeSe user found with that phone number."
      );
    }

    recipientId = recipientSnap.id;
    const rdata = recipientSnap.data() ?? {};
    recipientName = String(rdata.fullName ?? rdata.displayName ?? rdata.name ?? "SeSe User");
    const rawRole = String(rdata.role ?? "").toLowerCase();
    if (isFromDriverCol || rawRole === "driver") {
      accountType = "Driver";
      completedTrips = Number(rdata.completedTrips ?? rdata.completed_trips ?? 0);
    }

    if (recipientId === senderId) {
      throw new HttpsError(
        "invalid-argument",
        "You cannot transfer to yourself."
      );
    }

    // Check sender admin status
    let isSenderAdmin = false;
    try {
      const senderStaffSnap = await db().collection("hub_staff").doc(senderId).get();
      if (senderStaffSnap.exists && senderStaffSnap.data()?.active !== false) {
        isSenderAdmin = true;
      }
    } catch {
      // Ignore error
    }

    // Eligibility check for Driver recipient
    if (accountType === "Driver") {
      if (!isSenderAdmin || !rules.adminOverrideEnabled) {
        if (completedTrips < rules.minDriverTrips) {
          const remaining = rules.minDriverTrips - completedTrips;
          throw new HttpsError(
            "failed-precondition",
            `This driver cannot receive transfers yet (${remaining} trip(s) remaining).`
          );
        }
      }
    }

    // Get sender name for notification
    let senderName = "A SeSe user";
    try {
      const senderUserSnap = await db().collection("users").doc(senderId).get();
      if (senderUserSnap.exists) {
        senderName = String(senderUserSnap.data()?.fullName ?? senderUserSnap.data()?.displayName ?? "A SeSe user");
      }
    } catch {
      // Ignore error
    }

    const transferId = newTransferId("p2p", senderId);
    const createdAt = admin.firestore.FieldValue.serverTimestamp();
    const senderRef = db().collection("wallets").doc(senderId);
    const recipientRef = db().collection("wallets").doc(recipientId);

    await db().runTransaction(async (tx) => {
      const senderSnap = await tx.get(senderRef);
      if (!senderSnap.exists) {
        throw new HttpsError(
          "failed-precondition",
          "No wallet found for this account."
        );
      }
      const balanceKobo = Number(senderSnap.data()!["balance"] ?? 0);
      if (!Number.isFinite(balanceKobo) || balanceKobo < amountKobo) {
        throw new HttpsError(
          "failed-precondition",
          "Your balance is too low for this transfer."
        );
      }

      tx.update(senderRef, {
        balance: admin.firestore.FieldValue.increment(-amountKobo),
        updatedAt: admin.firestore.FieldValue.serverTimestamp(),
      });
      tx.set(
        recipientRef,
        {
          userId: recipientId,
          balance: admin.firestore.FieldValue.increment(amountKobo),
          currency: "NGN",
          updatedAt: admin.firestore.FieldValue.serverTimestamp(),
        },
        { merge: true }
      );

      // User wallet transaction logs
      tx.set(senderRef.collection("transactions").doc(transferId), {
        type: "P2P_TRANSFER_SENT",
        amount: amountKobo,
        amountKobo,
        amountNaira: amountKobo / 100,
        currency: "NGN",
        transferId,
        counterpartyId: recipientId,
        counterpartyName: recipientName,
        createdAt,
      });
      tx.set(recipientRef.collection("transactions").doc(transferId), {
        type: "P2P_TRANSFER_RECEIVED",
        amount: amountKobo,
        amountKobo,
        amountNaira: amountKobo / 100,
        currency: "NGN",
        transferId,
        counterpartyId: senderId,
        counterpartyName: senderName,
        createdAt,
      });

      // Global wallet_transactions ledger audit rows
      tx.set(db().collection("wallet_transactions").doc(`${transferId}_sent`), {
        transferId,
        userId: senderId,
        counterpartyId: recipientId,
        type: "P2P_TRANSFER_SENT",
        amountKobo,
        amountNaira: amountKobo / 100,
        createdAt,
      });
      tx.set(db().collection("wallet_transactions").doc(`${transferId}_recv`), {
        transferId,
        userId: recipientId,
        counterpartyId: senderId,
        type: "P2P_TRANSFER_RECEIVED",
        amountKobo,
        amountNaira: amountKobo / 100,
        createdAt,
      });
    });

    // Notify the recipient
    const formattedAmount = (amountKobo / 100).toLocaleString("en-NG", {
      minimumFractionDigits: 2,
    });
    try {
      await db()
        .collection("users")
        .doc(recipientId)
        .collection("notifications")
        .add({
          title: "Wallet transfer received",
          body: `You received ₦${formattedAmount} from ${senderName}!`,
          transferId,
          type: "P2P_TRANSFER_RECEIVED",
          createdAt: admin.firestore.FieldValue.serverTimestamp(),
        });
    } catch (e) {
      console.warn(`transferWalletFunds: notify failed: ${e}`);
    }

    return { transferId, amountKobo, recipientName };
  }
);

// ─── Split payments ─────────────────────────────────────────────────────────

interface RequestSplitData {
  tripId?: string;
  copayerPhones?: string[];
}

interface RespondSplitData {
  splitId?: string;
  accept?: boolean;
}

/**
 * Callable: the trip customer invites co-payers to split the fare equally.
 *
 * Creates a `split_payments/{splitId}` intent with one `parts/{uid}` row per
 * co-payer (resolved by phone like P2P) plus the requester's own share, and
 * writes an in-app authorization prompt to each co-payer's notifications.
 * Nothing moves yet — money moves only when every party accepts, via
 * `respondSplitPayment` + a final settlement both sides can audit.
 *
 * Scope note: this is the REQUEST side. Charging a co-payer's wallet at
 * settle time reuses the same transactional pattern as `transferWalletFunds`;
 * the actual debit happens in the explicit `settleSplitPayment` call below,
 * so no money moves on intent creation.
 */
export const requestSplitPayment = onCall<RequestSplitData>(
  async (request) => {
    if (!request.auth) {
      throw new HttpsError("unauthenticated", "You must sign in.");
    }
    const requesterId = request.auth.uid;
    const tripId = String(request.data?.tripId ?? "").trim();
    if (!tripId) {
      throw new HttpsError("invalid-argument", "tripId is required.");
    }
    const phones = Array.isArray(request.data?.copayerPhones)
      ? (request.data?.copayerPhones as unknown[]).map(String)
      : [];
    const cleanPhones = [...new Set(phones.map((p) => p.trim()).filter(Boolean))];
    if (cleanPhones.length === 0 || cleanPhones.length > 5) {
      throw new HttpsError(
        "invalid-argument",
        "Invite between 1 and 5 co-payers."
      );
    }

    const tripSnap = await db().collection("trips").doc(tripId).get();
    if (!tripSnap.exists) throw new HttpsError("not-found", "Trip not found.");
    const trip = tripSnap.data()!;
    if (trip.customerId !== requesterId) {
      throw new HttpsError(
        "permission-denied",
        "Only the trip customer can split this fare."
      );
    }
    const fareKobo = Math.round(Number(trip.fareAmount ?? trip.proposedFare ?? 0) * 100);
    // fareAmount is stored in NAIRA on trips; convert once, here.
    if (!Number.isFinite(fareKobo) || fareKobo <= 0) {
      throw new HttpsError(
        "failed-precondition",
        "This trip has no settled fare to split yet."
      );
    }

    // Resolve every co-payer by phone before writing anything.
    const copayers: Array<{ uid: string; name: string; phone: string }> = [];
    for (const phone of cleanPhones) {
      const norm = normalizePhone(phone);
      const byE164 = await db()
        .collection("users")
        .where("phoneNumberE164", "==", norm.startsWith("234") ? `+${norm}` : norm)
        .limit(1)
        .get();
      const snap = byE164.empty ? null : byE164.docs[0];
      if (!snap || snap.id === requesterId) {
        throw new HttpsError(
          "not-found",
          `No SeSe user found with number ${phone}.`
        );
      }
      // Zero-trust gate at invite time: suspended / phone-less /
      // unverified accounts are rejected before any intent row exists.
      await assertSplitEligible(snap.id, phone);
      const d = snap.data() ?? {};
      copayers.push({
        uid: snap.id,
        name: String(d.fullName ?? d.displayName ?? ""),
        phone,
      });
    }

    const parties = copayers.length + 1;
    const shareKobo = Math.floor(fareKobo / parties);
    const remainderKobo = fareKobo - shareKobo * parties;
    // The requester absorbs the rounding remainder (at most a few kobo),
    // so the parts always sum exactly to the fare.
    if (shareKobo * parties + remainderKobo !== fareKobo) {
      throw new HttpsError(
        "data-loss",
        "Split shares do not sum to the trip fare. Please try again."
      );
    }
    const splitId = newTransferId("split", requesterId);
    const createdAt = admin.firestore.FieldValue.serverTimestamp();
    const splitRef = db().collection("split_payments").doc(splitId);

    const batch = db().batch();
    batch.set(splitRef, {
      splitId,
      tripId,
      requesterId,
      fareKobo,
      shareKobo,
      requesterExtraKobo: remainderKobo,
      status: "pending",
      createdAt,
      updatedAt: createdAt,
    });
    batch.set(splitRef.collection("parts").doc(requesterId), {
      userId: requesterId,
      shareKobo: shareKobo + remainderKobo,
      status: "accepted",
      respondedAt: createdAt,
    });
    for (const c of copayers) {
      batch.set(splitRef.collection("parts").doc(c.uid), {
        userId: c.uid,
        name: c.name,
        phone: c.phone,
        shareKobo,
        status: "pending",
      });
      batch.set(
        db().collection("users").doc(c.uid).collection("notifications").doc(),
        {
          title: "Split payment request",
          body: `You were invited to split a ₦${(fareKobo / 100).toLocaleString("en-NG")} fare — your share is ₦${(shareKobo / 100).toLocaleString("en-NG")}.`,
          splitId,
          tripId,
          type: "split_payment_request",
          createdAt: admin.firestore.FieldValue.serverTimestamp(),
        }
      );
    }
    await batch.commit();

    // Authenticated push alongside the in-app prompt: co-payers get a
    // high-priority FCM nudge to their personal topic. Best-effort — the
    // in-app `split_payment_request` row above is the reliable channel, so
    // a messaging failure never fails the invite.
    for (const c of copayers) {
      try {
        await admin.messaging().send({
          topic: `user_${c.uid}`,
          notification: {
            title: "Split payment request",
            body: `You were invited to split a ₦${(fareKobo / 100).toLocaleString("en-NG")} fare — your share is ₦${(shareKobo / 100).toLocaleString("en-NG")}. Open SeSe to accept or decline.`,
          },
          data: {
            type: "split_payment_request",
            splitId,
            tripId,
          },
        });
      } catch (e) {
        console.warn(`requestSplitPayment: FCM failed for ${c.uid}: ${e}`);
      }
    }

    return { splitId, shareKobo, parties };
  }
);

/**
 * Callable: a co-payer accepts or declines their split share.
 *
 * Accepting records consent only — it does not move money (see the scope
 * note on `requestSplitPayment`). When every part is accepted the intent
 * flips to `ready`, which is the precondition `settleSplitPayment`
 * requires. A single decline flips the whole intent to `declined`, and the
 * requester retains 100% fare liability through the normal trip settlement.
 *
 * Consent is authenticated (the callable uid must own the part row) and
 * server-timestamped (`respondedAt`), which is the consent log — no split
 * can proceed without every row carrying `accepted` with a server stamp.
 */
export const respondSplitPayment = onCall<RespondSplitData>(
  async (request) => {
    if (!request.auth) {
      throw new HttpsError("unauthenticated", "You must sign in.");
    }
    const uid = request.auth.uid;
    const splitId = String(request.data?.splitId ?? "").trim();
    if (!splitId) {
      throw new HttpsError("invalid-argument", "splitId is required.");
    }
    const accept = request.data?.accept === true;

    const splitRef = db().collection("split_payments").doc(splitId);
    const partRef = splitRef.collection("parts").doc(uid);
    let becameReady = false;

    await db().runTransaction(async (tx) => {
      const splitSnap = await tx.get(splitRef);
      if (!splitSnap.exists) {
        throw new HttpsError("not-found", "Split request not found.");
      }
      if (splitSnap.data()!.status !== "pending") {
        throw new HttpsError(
          "failed-precondition",
          "This split request is no longer pending."
        );
      }
      const partSnap = await tx.get(partRef);
      if (!partSnap.exists) {
        throw new HttpsError(
          "permission-denied",
          "You were not invited to this split."
        );
      }
      if (partSnap.data()!.status !== "pending") {
        throw new HttpsError(
          "failed-precondition",
          "You already responded to this split."
        );
      }

      if (!accept) {
        tx.update(partRef, {
          status: "declined",
          respondedAt: admin.firestore.FieldValue.serverTimestamp(),
        });
        tx.update(splitRef, {
          status: "declined",
          updatedAt: admin.firestore.FieldValue.serverTimestamp(),
        });
        return;
      }

      tx.update(partRef, {
        status: "accepted",
        respondedAt: admin.firestore.FieldValue.serverTimestamp(),
      });

      const partsSnap = await tx.get(splitRef.collection("parts"));
      const allAccepted = partsSnap.docs.every(
        (d) => d.id === uid || d.data().status === "accepted"
      );
      if (allAccepted) {
        tx.update(splitRef, {
          status: "ready",
          updatedAt: admin.firestore.FieldValue.serverTimestamp(),
        });
        becameReady = true;
      }
    });

    return { ok: true, accepted: accept, ready: becameReady };
  }
);

/**
 * Callable: atomically settle a fully-accepted split.
 *
 * Preconditions (all server-verified, never trusted from the client):
 * - The intent exists and `status == "ready"` — i.e. every part row
 *   carries an authenticated, server-stamped `accepted`. Anything else
 *   (pending/declined/settled) is rejected; a decline anywhere means the
 *   requester retains 100% liability through normal trip settlement.
 * - Every co-payer re-passes [assertSplitEligible] (invite-time status may
 *   have lapsed: suspension, de-verification, phone removal).
 * - Tiered trust per co-payer from `users/{uid}.splitStats.completedSplits`:
 *   fewer than [SPLIT_TRUST_THRESHOLD] settled splits → the live wallet
 *   balance must cover the share (`failed-precondition` otherwise, naming
 *   the shortfall). At/above the threshold the share may drive the balance
 *   negative, with the below-zero portion tracked as
 *   `splitStats.splitDebtKobo` for automatic recovery on later fundings.
 *
 * Execution is ONE `runTransaction`: all co-payer debits, the requester
 * credit, every ledger row, the trust-counter bumps, and the
 * `settled` flip commit together — no race can half-settle, double-settle
 * (idempotent early return on `settled`), or tamper a balance mid-flight.
 * Units are kobo throughout, matching `wallets/{uid}.balance`.
 */
export const settleSplitPayment = onCall(async (request) => {
  if (!request.auth) {
    throw new HttpsError("unauthenticated", "You must sign in.");
  }
  const callerId = request.auth.uid;
  const splitId = String(request.data?.splitId ?? "").trim();
  if (!splitId) {
    throw new HttpsError("invalid-argument", "splitId is required.");
  }

  // Execution authorization: the triggering participant authorizes the
  // settlement run with their transaction PIN. Co-payer debits were already
  // authorized by their individual accepts; this PIN covers the execution.
  // Verified before any wallet state is read (no oracle).
  await requireValidPin(callerId, request.data?.transactionPin);

  const splitRef = db().collection("split_payments").doc(splitId);
  const splitSnap = await splitRef.get();
  if (!splitSnap.exists) {
    throw new HttpsError("not-found", "Split request not found.");
  }
  const split = splitSnap.data()!;
  if (split.status === "settled") {
    return { settled: true, alreadySettled: true };
  }
  if (split.status !== "ready") {
    throw new HttpsError(
      "failed-precondition",
      split.status === "declined"
        ? "This split was declined. The trip customer retains the full fare."
        : "All co-payers must accept before this split can settle."
    );
  }
  const requesterId = String(split.requesterId ?? "");
  if (!requesterId) {
    throw new HttpsError("data-loss", "Split intent has no requester.");
  }
  if (callerId !== requesterId) {
    // Any accepted party may trigger settlement, but the intent belongs to
    // the requester — anyone else is a confused-deputy risk, not a helper.
    const partsProbe = await splitRef.collection("parts").doc(callerId).get();
    if (!partsProbe.exists) {
      throw new HttpsError(
        "permission-denied",
        "Only split participants can settle this split."
      );
    }
  }

  const partsSnap = await splitRef.collection("parts").get();
  const parts = partsSnap.docs.map((d) => ({
    uid: d.id,
    ...(d.data() ?? {}),
  }));
  if (parts.length === 0) {
    throw new HttpsError("data-loss", "Split intent has no shares.");
  }
  for (const p of parts) {
    if ((p as Record<string, unknown>).status !== "accepted") {
      throw new HttpsError(
        "failed-precondition",
        "All co-payers must accept before this split can settle."
      );
    }
  }
  const copayers = parts.filter((p) => p.uid !== requesterId);
  if (copayers.length === 0) {
    throw new HttpsError(
      "failed-precondition",
      "There are no co-payer shares to settle."
    );
  }

  // Re-verify eligibility for every co-payer (fail fast, before the tx).
  for (const c of copayers) {
    const phone = String(
      (c as Record<string, unknown>).phone ?? "this number"
    );
    await assertSplitEligible(c.uid, phone);
  }

  const createdAt = admin.firestore.FieldValue.serverTimestamp();
  let creditedKobo = 0;

  await db().runTransaction(async (tx) => {
    const freshSplit = await tx.get(splitRef);
    if (!freshSplit.exists) {
      throw new HttpsError("not-found", "Split request not found.");
    }
    if (freshSplit.data()!.status === "settled") return; // idempotent
    if (freshSplit.data()!.status !== "ready") {
      throw new HttpsError(
        "failed-precondition",
        "All co-payers must accept before this split can settle."
      );
    }

    let totalKobo = 0;
    for (const c of copayers) {
      const share = Math.floor(
        Number((c as Record<string, unknown>).shareKobo ?? NaN)
      );
      if (!Number.isFinite(share) || share <= 0) {
        throw new HttpsError("data-loss", "Split intent has a corrupt share.");
      }
      const walletRef = db().collection("wallets").doc(c.uid);
      const userRef = db().collection("users").doc(c.uid);
      const [walletSnap, userSnap] = await Promise.all([
        tx.get(walletRef),
        tx.get(userRef),
      ]);
      const balance = walletSnap.exists
        ? Number(walletSnap.data()!["balance"] ?? 0)
        : 0;
      if (!Number.isFinite(balance)) {
        throw new HttpsError("data-loss", "Wallet balance is corrupt.");
      }
      const stats = readSplitStats(
        userSnap.exists ? userSnap.data() : undefined
      );
      const trusted = stats.completedSplits >= SPLIT_TRUST_THRESHOLD;
      if (!trusted && balance < share) {
        throw new HttpsError(
          "failed-precondition",
          `A co-payer's wallet is too low (₦${(Math.max(0, balance) / 100).toLocaleString("en-NG")} available, ₦${(share / 100).toLocaleString("en-NG")} needed). First ${SPLIT_TRUST_THRESHOLD} splits must be pre-funded.`
        );
      }
      // Trusted shortfall below zero becomes recoverable debt.
      const debtIncrease = trusted
        ? Math.max(0, share - Math.max(0, balance))
        : 0;

      if (walletSnap.exists) {
        tx.update(walletRef, {
          balance: admin.firestore.FieldValue.increment(-share),
          updatedAt: createdAt,
        });
      } else {
        // Trusted-only path (untrusted missing wallets fail the guard
        // above): mint the wallet already carrying the negative balance.
        tx.set(walletRef, {
          userId: c.uid,
          balance: -share,
          currency: "NGN",
          updatedAt: createdAt,
        });
      }
      tx.set(walletRef.collection("transactions").doc(splitId), {
        type: "SPLIT_FARE_DEBIT",
        amount: -share,
        amountKobo: -share,
        amountNaira: -share / 100,
        currency: "NGN",
        splitId,
        tripId: String(split.tripId ?? ""),
        counterpartyId: requesterId,
        createdAt,
      });
      tx.set(
        userRef,
        {
          splitStats: {
            completedSplits: stats.completedSplits + 1,
            splitDebtKobo: stats.splitDebtKobo + debtIncrease,
          },
        },
        { merge: true }
      );
      tx.set(db().collection("wallet_transactions").doc(`${splitId}_${c.uid}`), {
        splitId,
        tripId: String(split.tripId ?? ""),
        userId: c.uid,
        counterpartyId: requesterId,
        type: "SPLIT_FARE_DEBIT",
        amountKobo: share,
        amountNaira: share / 100,
        createdAt,
      });
      totalKobo += share;
    }

    // Co-payer shares reimburse the requester, who remains liable for the
    // full driver fare through normal trip settlement.
    const requesterWallet = db().collection("wallets").doc(requesterId);
    const requesterUser = db().collection("users").doc(requesterId);
    const [reqWalletSnap, reqUserSnap] = await Promise.all([
      tx.get(requesterWallet),
      tx.get(requesterUser),
    ]);
    if (reqWalletSnap.exists) {
      tx.update(requesterWallet, {
        balance: admin.firestore.FieldValue.increment(totalKobo),
        updatedAt: createdAt,
      });
    } else {
      tx.set(requesterWallet, {
        userId: requesterId,
        balance: totalKobo,
        currency: "NGN",
        updatedAt: createdAt,
      });
    }
    const reqStats = readSplitStats(
      reqUserSnap.exists ? reqUserSnap.data() : undefined
    );
    tx.set(
      requesterUser,
      {
        splitStats: {
          completedSplits: reqStats.completedSplits + 1,
          splitDebtKobo: reqStats.splitDebtKobo,
        },
      },
      { merge: true }
    );
    tx.set(requesterWallet.collection("transactions").doc(splitId), {
      type: "SPLIT_FARE_CREDIT",
      amount: totalKobo,
      amountKobo: totalKobo,
      amountNaira: totalKobo / 100,
      currency: "NGN",
      splitId,
      tripId: String(split.tripId ?? ""),
      createdAt,
    });

    for (const c of copayers) {
      tx.update(splitRef.collection("parts").doc(c.uid), {
        status: "settled",
        settledAt: createdAt,
      });
    }
    tx.update(splitRef, {
      status: "settled",
      settledKobo: totalKobo,
      settledAt: createdAt,
      updatedAt: createdAt,
    });
    creditedKobo = totalKobo;
  });

  return { settled: true, splitId, creditedKobo };
});

// ─── SeSe Coin conversion ────────────────────────────────────────────────────

/**
 * Callable: move the caller's entire `seseCoinBalance` into their
 * `mainWalletBalance` (withdrawable cash), subject to a configurable minimum.
 *
 * Guards:
 *  - Minimum convertible balance (`system_configs/financials.minConvertibleBonus`,
 *    defaulting to ₦50) prevents trickle conversions and reduces ledger noise.
 *  - A single Firestore transaction reads and debits `seseCoinBalance` and
 *    credits `mainWalletBalance` atomically. Two simultaneous calls cannot
 *    both pass the minimum check.
 *
 * Units: `seseCoinBalance` is stored in NAIRA (1 coin = ₦1) because it is a
 * bonus tier, never a kobo-precision value. The credit to `mainWalletBalance`
 * is also NAIRA. `balance` (the legacy kobo mirror) is NOT updated here —
 * the withdrawal path reads `mainWalletBalance` directly.
 *
 * Returns: `{ converted: <naira amount moved> }`.
 */
export const convertSeseCoins = onCall(async (request) => {
  if (!request.auth) {
    throw new HttpsError("unauthenticated", "You must sign in.");
  }
  const uid = request.auth.uid;

  // Read the admin-configured minimum from system_configs. Treat missing/bad
  // values as ₦50 so an unconfigured backend never blocks legitimate conversions.
  let minConvertible = 5000;
  try {
    const snap = await db().collection("system_configs").doc("financials").get();
    const raw = snap.data()?.minConvertibleBonus;
    if (typeof raw === "number" && Number.isFinite(raw) && raw > 0) {
      minConvertible = raw;
    }
  } catch {
    // Fall through to default.
  }

  const walletRef = db().collection("wallets").doc(uid);
  const ledgerRef = walletRef.collection("transactions").doc();

  let converted = 0;

  await db().runTransaction(async (tx) => {
    const walletSnap = await tx.get(walletRef);
    if (!walletSnap.exists) {
      throw new HttpsError("not-found", "Wallet not found.");
    }
    const data = walletSnap.data() ?? {};
    const coinBalance = typeof data["seseCoinBalance"] === "number"
      ? data["seseCoinBalance"] as number
      : 0;

    if (coinBalance < minConvertible) {
      throw new HttpsError(
        "failed-precondition",
        `You need at least ₦${minConvertible.toLocaleString("en-NG")} in SeSe Coins to convert. ` +
        `Your current balance is ₦${coinBalance.toLocaleString("en-NG")}.`
      );
    }

    converted = coinBalance;

    tx.update(walletRef, {
      seseCoinBalance: 0,
      mainWalletBalance: admin.firestore.FieldValue.increment(converted),
      updatedAt: admin.firestore.FieldValue.serverTimestamp(),
    });

    tx.set(ledgerRef, {
      userId: uid,
      type: "sese_coin_conversion",
      amountNaira: converted,
      note: `Converted ₦${converted.toLocaleString("en-NG")} in SeSe Coins to wallet cash.`,
      createdAt: admin.firestore.FieldValue.serverTimestamp(),
    });
  });

  return { converted };
});
