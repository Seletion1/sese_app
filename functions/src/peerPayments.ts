import * as admin from "firebase-admin";
import { onCall, HttpsError } from "firebase-functions/v2/https";

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
const MAX_TRANSFER_KOBO = 50_000_000;

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

interface WalletTransferData {
  recipientPhone?: string;
  amountKobo?: number;
}

/**
 * Callable: moves wallet value from the caller to another SeSe user,
 * identified by their registered phone number.
 *
 * Order of operations:
 *   1. Authenticate + validate amount.
 *   2. Resolve the recipient by phone (users.phoneNumber / phoneNumberE164).
 *      No self-transfers; unknown numbers are rejected, not queued.
 *   3. In ONE transaction: re-read the sender wallet, re-check sufficiency,
 *      decrement sender, credit recipient (merge-create if absent), and write
 *      a ledger row on BOTH sides sharing one transferId.
 *
 * The transaction is the concurrency lock — two simultaneous transfers
 * cannot both pass the balance check.
 */
export const transferWalletFunds = onCall<WalletTransferData>(
  async (request) => {
    if (!request.auth) {
      throw new HttpsError("unauthenticated", "You must sign in.");
    }
    const senderId = request.auth.uid;

    const amountKobo = Math.round(Number(request.data?.amountKobo));
    if (!Number.isFinite(amountKobo) || amountKobo < MIN_TRANSFER_KOBO) {
      throw new HttpsError("invalid-argument", "Minimum transfer is ₦100.");
    }
    if (amountKobo > MAX_TRANSFER_KOBO) {
      throw new HttpsError(
        "invalid-argument",
        "Maximum transfer per request is ₦500,000."
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

    // Resolve the recipient by phone. Both stored shapes are tried because
    // older documents carry `phoneNumber` in local format.
    let recipientId = "";
    let recipientName = "";
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
    // Fallback: scan is not possible server-side at scale, so also try the
    // drivers collection — a driver without a users doc can still receive.
    if (!recipientSnap) {
      const byDriver = await db()
        .collection("drivers")
        .where("phoneNumberE164", "==", recipientPhone.startsWith("234")
          ? `+${recipientPhone}`
          : recipientPhone)
        .limit(1)
        .get();
      recipientSnap = byDriver.empty ? null : byDriver.docs[0];
    }
    if (!recipientSnap) {
      throw new HttpsError(
        "not-found",
        "No SeSe user found with that phone number."
      );
    }
    recipientId = recipientSnap.id;
    const rdata = recipientSnap.data() ?? {};
    recipientName = String(rdata.fullName ?? rdata.displayName ?? "");
    if (recipientId === senderId) {
      throw new HttpsError(
        "invalid-argument",
        "You cannot transfer to yourself."
      );
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
      tx.set(senderRef.collection("transactions").doc(transferId), {
        type: "p2p_transfer_out",
        amount: amountKobo,
        amountKobo,
        amountNaira: amountKobo / 100,
        currency: "NGN",
        transferId,
        counterpartyId: recipientId,
        createdAt,
      });
      tx.set(recipientRef.collection("transactions").doc(transferId), {
        type: "p2p_transfer_in",
        amount: amountKobo,
        amountKobo,
        amountNaira: amountKobo / 100,
        currency: "NGN",
        transferId,
        counterpartyId: senderId,
        createdAt,
      });
    });

    // Notify the recipient (best-effort; the money already moved).
    try {
      await db()
        .collection("users")
        .doc(recipientId)
        .collection("notifications")
        .add({
          title: "Wallet transfer received",
          body: `You received ₦${(amountKobo / 100).toLocaleString("en-NG", {
            minimumFractionDigits: 2,
          })} in your SeSe wallet.`,
          transferId,
          type: "p2p_transfer_in",
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
 * the actual debit is intentionally left to an explicit `settleSplitPayment`
 * call (not built here) so no money moves on intent creation.
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

    return { splitId, shareKobo, parties };
  }
);

/**
 * Callable: a co-payer accepts or declines their split share.
 *
 * Accepting records consent only — it does not move money (see the scope
 * note on `requestSplitPayment`). When every part is accepted the intent
 * flips to `ready`, which is the precondition a future settlement call
 * will require. A single decline flips the whole intent to `declined`.
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
      }
    });

    return { ok: true, accepted: accept };
  }
);
