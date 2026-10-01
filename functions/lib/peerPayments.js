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
exports.respondSplitPayment = exports.requestSplitPayment = exports.transferWalletFunds = void 0;
const admin = __importStar(require("firebase-admin"));
const https_1 = require("firebase-functions/v2/https");
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
const MIN_TRANSFER_KOBO = 10000;
/** Ceiling per transfer: ₦500,000. Bounds blast radius. */
const MAX_TRANSFER_KOBO = 50000000;
function newTransferId(prefix, uid) {
    const rand = Math.random().toString(36).slice(2, 10);
    return `${prefix}_${uid.slice(0, 8)}_${Date.now().toString(36)}${rand}`;
}
/** Digits only, for phone matching across formats (+234... vs 080...). */
function digitsOnly(raw) {
    return raw.replace(/\D/g, "");
}
/**
 * Normalises a Nigerian phone to E.164-ish digits for comparison:
 * `0803...` → `234803...`, `+234803...` → `234803...`.
 */
function normalizePhone(raw) {
    const d = digitsOnly(raw);
    if (d.startsWith("234") && d.length === 13)
        return d;
    if (d.startsWith("0") && d.length === 11)
        return `234${d.slice(1)}`;
    return d;
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
exports.transferWalletFunds = (0, https_1.onCall)(async (request) => {
    var _a, _b, _c, _d, _e, _f, _g, _h;
    if (!request.auth) {
        throw new https_1.HttpsError("unauthenticated", "You must sign in.");
    }
    const senderId = request.auth.uid;
    const amountKobo = Math.round(Number((_a = request.data) === null || _a === void 0 ? void 0 : _a.amountKobo));
    if (!Number.isFinite(amountKobo) || amountKobo < MIN_TRANSFER_KOBO) {
        throw new https_1.HttpsError("invalid-argument", "Minimum transfer is ₦100.");
    }
    if (amountKobo > MAX_TRANSFER_KOBO) {
        throw new https_1.HttpsError("invalid-argument", "Maximum transfer per request is ₦500,000.");
    }
    const recipientPhone = normalizePhone(String((_c = (_b = request.data) === null || _b === void 0 ? void 0 : _b.recipientPhone) !== null && _c !== void 0 ? _c : ""));
    if (recipientPhone.length < 10) {
        throw new https_1.HttpsError("invalid-argument", "Enter the recipient's registered phone number.");
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
            .where("phoneNumber", "==", String((_e = (_d = request.data) === null || _d === void 0 ? void 0 : _d.recipientPhone) !== null && _e !== void 0 ? _e : "").trim())
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
        throw new https_1.HttpsError("not-found", "No SeSe user found with that phone number.");
    }
    recipientId = recipientSnap.id;
    const rdata = (_f = recipientSnap.data()) !== null && _f !== void 0 ? _f : {};
    recipientName = String((_h = (_g = rdata.fullName) !== null && _g !== void 0 ? _g : rdata.displayName) !== null && _h !== void 0 ? _h : "");
    if (recipientId === senderId) {
        throw new https_1.HttpsError("invalid-argument", "You cannot transfer to yourself.");
    }
    const transferId = newTransferId("p2p", senderId);
    const createdAt = admin.firestore.FieldValue.serverTimestamp();
    const senderRef = db().collection("wallets").doc(senderId);
    const recipientRef = db().collection("wallets").doc(recipientId);
    await db().runTransaction(async (tx) => {
        var _a;
        const senderSnap = await tx.get(senderRef);
        if (!senderSnap.exists) {
            throw new https_1.HttpsError("failed-precondition", "No wallet found for this account.");
        }
        const balanceKobo = Number((_a = senderSnap.data()["balance"]) !== null && _a !== void 0 ? _a : 0);
        if (!Number.isFinite(balanceKobo) || balanceKobo < amountKobo) {
            throw new https_1.HttpsError("failed-precondition", "Your balance is too low for this transfer.");
        }
        tx.update(senderRef, {
            balance: admin.firestore.FieldValue.increment(-amountKobo),
            updatedAt: admin.firestore.FieldValue.serverTimestamp(),
        });
        tx.set(recipientRef, {
            userId: recipientId,
            balance: admin.firestore.FieldValue.increment(amountKobo),
            currency: "NGN",
            updatedAt: admin.firestore.FieldValue.serverTimestamp(),
        }, { merge: true });
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
    }
    catch (e) {
        console.warn(`transferWalletFunds: notify failed: ${e}`);
    }
    return { transferId, amountKobo, recipientName };
});
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
exports.requestSplitPayment = (0, https_1.onCall)(async (request) => {
    var _a, _b, _c, _d, _e, _f, _g, _h, _j;
    if (!request.auth) {
        throw new https_1.HttpsError("unauthenticated", "You must sign in.");
    }
    const requesterId = request.auth.uid;
    const tripId = String((_b = (_a = request.data) === null || _a === void 0 ? void 0 : _a.tripId) !== null && _b !== void 0 ? _b : "").trim();
    if (!tripId) {
        throw new https_1.HttpsError("invalid-argument", "tripId is required.");
    }
    const phones = Array.isArray((_c = request.data) === null || _c === void 0 ? void 0 : _c.copayerPhones)
        ? ((_d = request.data) === null || _d === void 0 ? void 0 : _d.copayerPhones).map(String)
        : [];
    const cleanPhones = [...new Set(phones.map((p) => p.trim()).filter(Boolean))];
    if (cleanPhones.length === 0 || cleanPhones.length > 5) {
        throw new https_1.HttpsError("invalid-argument", "Invite between 1 and 5 co-payers.");
    }
    const tripSnap = await db().collection("trips").doc(tripId).get();
    if (!tripSnap.exists)
        throw new https_1.HttpsError("not-found", "Trip not found.");
    const trip = tripSnap.data();
    if (trip.customerId !== requesterId) {
        throw new https_1.HttpsError("permission-denied", "Only the trip customer can split this fare.");
    }
    const fareKobo = Math.round(Number((_f = (_e = trip.fareAmount) !== null && _e !== void 0 ? _e : trip.proposedFare) !== null && _f !== void 0 ? _f : 0) * 100);
    // fareAmount is stored in NAIRA on trips; convert once, here.
    if (!Number.isFinite(fareKobo) || fareKobo <= 0) {
        throw new https_1.HttpsError("failed-precondition", "This trip has no settled fare to split yet.");
    }
    // Resolve every co-payer by phone before writing anything.
    const copayers = [];
    for (const phone of cleanPhones) {
        const norm = normalizePhone(phone);
        const byE164 = await db()
            .collection("users")
            .where("phoneNumberE164", "==", norm.startsWith("234") ? `+${norm}` : norm)
            .limit(1)
            .get();
        const snap = byE164.empty ? null : byE164.docs[0];
        if (!snap || snap.id === requesterId) {
            throw new https_1.HttpsError("not-found", `No SeSe user found with number ${phone}.`);
        }
        const d = (_g = snap.data()) !== null && _g !== void 0 ? _g : {};
        copayers.push({
            uid: snap.id,
            name: String((_j = (_h = d.fullName) !== null && _h !== void 0 ? _h : d.displayName) !== null && _j !== void 0 ? _j : ""),
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
        batch.set(db().collection("users").doc(c.uid).collection("notifications").doc(), {
            title: "Split payment request",
            body: `You were invited to split a ₦${(fareKobo / 100).toLocaleString("en-NG")} fare — your share is ₦${(shareKobo / 100).toLocaleString("en-NG")}.`,
            splitId,
            tripId,
            type: "split_payment_request",
            createdAt: admin.firestore.FieldValue.serverTimestamp(),
        });
    }
    await batch.commit();
    return { splitId, shareKobo, parties };
});
/**
 * Callable: a co-payer accepts or declines their split share.
 *
 * Accepting records consent only — it does not move money (see the scope
 * note on `requestSplitPayment`). When every part is accepted the intent
 * flips to `ready`, which is the precondition a future settlement call
 * will require. A single decline flips the whole intent to `declined`.
 */
exports.respondSplitPayment = (0, https_1.onCall)(async (request) => {
    var _a, _b, _c;
    if (!request.auth) {
        throw new https_1.HttpsError("unauthenticated", "You must sign in.");
    }
    const uid = request.auth.uid;
    const splitId = String((_b = (_a = request.data) === null || _a === void 0 ? void 0 : _a.splitId) !== null && _b !== void 0 ? _b : "").trim();
    if (!splitId) {
        throw new https_1.HttpsError("invalid-argument", "splitId is required.");
    }
    const accept = ((_c = request.data) === null || _c === void 0 ? void 0 : _c.accept) === true;
    const splitRef = db().collection("split_payments").doc(splitId);
    const partRef = splitRef.collection("parts").doc(uid);
    await db().runTransaction(async (tx) => {
        const splitSnap = await tx.get(splitRef);
        if (!splitSnap.exists) {
            throw new https_1.HttpsError("not-found", "Split request not found.");
        }
        if (splitSnap.data().status !== "pending") {
            throw new https_1.HttpsError("failed-precondition", "This split request is no longer pending.");
        }
        const partSnap = await tx.get(partRef);
        if (!partSnap.exists) {
            throw new https_1.HttpsError("permission-denied", "You were not invited to this split.");
        }
        if (partSnap.data().status !== "pending") {
            throw new https_1.HttpsError("failed-precondition", "You already responded to this split.");
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
        const allAccepted = partsSnap.docs.every((d) => d.id === uid || d.data().status === "accepted");
        if (allAccepted) {
            tx.update(splitRef, {
                status: "ready",
                updatedAt: admin.firestore.FieldValue.serverTimestamp(),
            });
        }
    });
    return { ok: true, accepted: accept };
});
//# sourceMappingURL=peerPayments.js.map