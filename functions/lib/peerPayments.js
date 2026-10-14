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
exports.convertSeseCoins = exports.settleSplitPayment = exports.respondSplitPayment = exports.requestSplitPayment = exports.transferWalletFunds = exports.lookupP2pRecipient = void 0;
const admin = __importStar(require("firebase-admin"));
const https_1 = require("firebase-functions/v2/https");
const transactionPin_1 = require("./transactionPin");
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
 * Trust tiers for split payments: below this many SETTLED splits a partner
 * must pre-fund their share (wallet balance ≥ share). At or above it the
 * account may settle into a negative balance, with the shortfall tracked
 * as recoverable debt (`splitStats.splitDebtKobo`).
 */
const SPLIT_TRUST_THRESHOLD = 3;
function readSplitStats(data) {
    var _a;
    const raw = ((_a = data === null || data === void 0 ? void 0 : data.splitStats) !== null && _a !== void 0 ? _a : {});
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
async function assertSplitEligible(uid, phone) {
    var _a, _b, _c, _d, _e, _f;
    const userSnap = await db().collection("users").doc(uid).get();
    if (!userSnap.exists) {
        throw new https_1.HttpsError("not-found", `No SeSe user found with number ${phone}.`);
    }
    const u = (_a = userSnap.data()) !== null && _a !== void 0 ? _a : {};
    if (u.isSuspended === true) {
        throw new https_1.HttpsError("failed-precondition", `The account for ${phone} is suspended and cannot split fares.`);
    }
    const hasPhone = String((_c = (_b = u.phoneNumberE164) !== null && _b !== void 0 ? _b : u.phoneNumber) !== null && _c !== void 0 ? _c : "").trim().length > 0;
    if (!hasPhone) {
        throw new https_1.HttpsError("failed-precondition", `The account for ${phone} has no verified phone number.`);
    }
    const customerVerified = u.customerVerificationStatus === "verified" ||
        u.isVerifiedCustomer === true;
    let driverVerified = false;
    if (!customerVerified) {
        try {
            const dSnap = await db().collection("drivers").doc(uid).get();
            if (dSnap.exists) {
                const dd = (_d = dSnap.data()) !== null && _d !== void 0 ? _d : {};
                const st = String((_f = (_e = dd.verificationStatus) !== null && _e !== void 0 ? _e : dd.status) !== null && _f !== void 0 ? _f : "").toLowerCase();
                driverVerified =
                    st === "verified" ||
                        st === "approved" ||
                        st === "active_verified" ||
                        dd.isVerified === true ||
                        dd.isProfileVerified === true;
            }
        }
        catch (_g) {
            // Treat lookup failure as unverified (fail closed).
        }
    }
    if (!customerVerified && !driverVerified) {
        throw new https_1.HttpsError("failed-precondition", `The account for ${phone} is not KYC-verified yet and cannot split fares.`);
    }
}
async function getWalletRules() {
    let minDriverTrips = 3;
    let maxP2pLimitNaira = 20000;
    let adminOverrideEnabled = true;
    try {
        const snap = await db().collection("system_config").doc("wallet_rules").get();
        if (snap.exists && snap.data()) {
            const data = snap.data();
            if (typeof data.minDriverTrips === "number")
                minDriverTrips = data.minDriverTrips;
            if (typeof data.min_driver_trips === "number")
                minDriverTrips = data.min_driver_trips;
            if (typeof data.maxP2pLimit === "number")
                maxP2pLimitNaira = data.maxP2pLimit;
            if (typeof data.max_p2p_limit === "number")
                maxP2pLimitNaira = data.max_p2p_limit;
            if (typeof data.adminOverrideEnabled === "boolean")
                adminOverrideEnabled = data.adminOverrideEnabled;
        }
    }
    catch (_a) {
        // Fall back to defaults
    }
    return { minDriverTrips, maxP2pLimitNaira, adminOverrideEnabled };
}
/**
 * Callable: live phone lookup fetching recipient's Name & Account Type (Driver/Customer)
 * and evaluating P2P eligibility guards.
 */
exports.lookupP2pRecipient = (0, https_1.onCall)(async (request) => {
    var _a, _b, _c, _d, _e, _f, _g, _h, _j, _k, _l, _m;
    if (!request.auth) {
        throw new https_1.HttpsError("unauthenticated", "You must sign in.");
    }
    const senderId = request.auth.uid;
    const recipientPhone = normalizePhone(String((_b = (_a = request.data) === null || _a === void 0 ? void 0 : _a.recipientPhone) !== null && _b !== void 0 ? _b : ""));
    if (recipientPhone.length < 10) {
        throw new https_1.HttpsError("invalid-argument", "Enter a valid recipient phone number.");
    }
    let recipientId = "";
    let recipientName = "";
    let accountType = "Customer";
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
            .where("phoneNumber", "==", String((_d = (_c = request.data) === null || _c === void 0 ? void 0 : _c.recipientPhone) !== null && _d !== void 0 ? _d : "").trim())
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
        if (recipientSnap)
            isFromDriversCol = true;
    }
    if (!recipientSnap) {
        throw new https_1.HttpsError("not-found", "No SeSe user found with that phone number.");
    }
    recipientId = recipientSnap.id;
    if (recipientId === senderId) {
        throw new https_1.HttpsError("invalid-argument", "You cannot transfer to yourself.");
    }
    const rdata = (_e = recipientSnap.data()) !== null && _e !== void 0 ? _e : {};
    recipientName = String((_h = (_g = (_f = rdata.fullName) !== null && _f !== void 0 ? _f : rdata.displayName) !== null && _g !== void 0 ? _g : rdata.name) !== null && _h !== void 0 ? _h : "SeSe User");
    const rawRole = String((_j = rdata.role) !== null && _j !== void 0 ? _j : "").toLowerCase();
    if (isFromDriversCol || rawRole === "driver") {
        accountType = "Driver";
        completedTrips = Number((_l = (_k = rdata.completedTrips) !== null && _k !== void 0 ? _k : rdata.completed_trips) !== null && _l !== void 0 ? _l : 0);
    }
    // Check sender admin status
    let isSenderAdmin = false;
    try {
        const senderStaffSnap = await db().collection("hub_staff").doc(senderId).get();
        if (senderStaffSnap.exists && ((_m = senderStaffSnap.data()) === null || _m === void 0 ? void 0 : _m.active) !== false) {
            isSenderAdmin = true;
        }
    }
    catch (_o) {
        // Ignore error
    }
    const rules = await getWalletRules();
    let canReceive = true;
    let tripsRemaining = 0;
    let reason = "";
    if (accountType === "Driver") {
        if (isSenderAdmin && rules.adminOverrideEnabled) {
            canReceive = true;
        }
        else if (completedTrips < rules.minDriverTrips) {
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
exports.transferWalletFunds = (0, https_1.onCall)(async (request) => {
    var _a, _b, _c, _d, _e, _f, _g, _h, _j, _k, _l, _m, _o, _p, _q, _r, _s, _t;
    if (!request.auth) {
        throw new https_1.HttpsError("unauthenticated", "You must sign in.");
    }
    const senderId = request.auth.uid;
    // Transaction-PIN gate FIRST: no verified PIN, no money movement. A
    // hostile client cannot skip the prompt — verification is server-side,
    // before any balance or recipient state is even read (no oracle).
    await (0, transactionPin_1.requireValidPin)(senderId, (_a = request.data) === null || _a === void 0 ? void 0 : _a.transactionPin);
    const amountKobo = Math.round(Number((_b = request.data) === null || _b === void 0 ? void 0 : _b.amountKobo));
    if (!Number.isFinite(amountKobo) || amountKobo < MIN_TRANSFER_KOBO) {
        throw new https_1.HttpsError("invalid-argument", "Minimum transfer is ₦100.");
    }
    const rules = await getWalletRules();
    const maxKobo = rules.maxP2pLimitNaira * 100;
    if (amountKobo > maxKobo) {
        throw new https_1.HttpsError("invalid-argument", `Maximum transfer limit is ₦${rules.maxP2pLimitNaira.toLocaleString("en-NG")}.`);
    }
    const recipientPhone = normalizePhone(String((_d = (_c = request.data) === null || _c === void 0 ? void 0 : _c.recipientPhone) !== null && _d !== void 0 ? _d : ""));
    if (recipientPhone.length < 10) {
        throw new https_1.HttpsError("invalid-argument", "Enter the recipient's registered phone number.");
    }
    // Resolve the recipient
    let recipientId = "";
    let recipientName = "";
    let accountType = "Customer";
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
            .where("phoneNumber", "==", String((_f = (_e = request.data) === null || _e === void 0 ? void 0 : _e.recipientPhone) !== null && _f !== void 0 ? _f : "").trim())
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
        if (recipientSnap)
            isFromDriverCol = true;
    }
    if (!recipientSnap) {
        throw new https_1.HttpsError("not-found", "No SeSe user found with that phone number.");
    }
    recipientId = recipientSnap.id;
    const rdata = (_g = recipientSnap.data()) !== null && _g !== void 0 ? _g : {};
    recipientName = String((_k = (_j = (_h = rdata.fullName) !== null && _h !== void 0 ? _h : rdata.displayName) !== null && _j !== void 0 ? _j : rdata.name) !== null && _k !== void 0 ? _k : "SeSe User");
    const rawRole = String((_l = rdata.role) !== null && _l !== void 0 ? _l : "").toLowerCase();
    if (isFromDriverCol || rawRole === "driver") {
        accountType = "Driver";
        completedTrips = Number((_o = (_m = rdata.completedTrips) !== null && _m !== void 0 ? _m : rdata.completed_trips) !== null && _o !== void 0 ? _o : 0);
    }
    if (recipientId === senderId) {
        throw new https_1.HttpsError("invalid-argument", "You cannot transfer to yourself.");
    }
    // Check sender admin status
    let isSenderAdmin = false;
    try {
        const senderStaffSnap = await db().collection("hub_staff").doc(senderId).get();
        if (senderStaffSnap.exists && ((_p = senderStaffSnap.data()) === null || _p === void 0 ? void 0 : _p.active) !== false) {
            isSenderAdmin = true;
        }
    }
    catch (_u) {
        // Ignore error
    }
    // Eligibility check for Driver recipient
    if (accountType === "Driver") {
        if (!isSenderAdmin || !rules.adminOverrideEnabled) {
            if (completedTrips < rules.minDriverTrips) {
                const remaining = rules.minDriverTrips - completedTrips;
                throw new https_1.HttpsError("failed-precondition", `This driver cannot receive transfers yet (${remaining} trip(s) remaining).`);
            }
        }
    }
    // Get sender name for notification
    let senderName = "A SeSe user";
    try {
        const senderUserSnap = await db().collection("users").doc(senderId).get();
        if (senderUserSnap.exists) {
            senderName = String((_t = (_r = (_q = senderUserSnap.data()) === null || _q === void 0 ? void 0 : _q.fullName) !== null && _r !== void 0 ? _r : (_s = senderUserSnap.data()) === null || _s === void 0 ? void 0 : _s.displayName) !== null && _t !== void 0 ? _t : "A SeSe user");
        }
    }
    catch (_v) {
        // Ignore error
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
 * the actual debit happens in the explicit `settleSplitPayment` call below,
 * so no money moves on intent creation.
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
        // Zero-trust gate at invite time: suspended / phone-less /
        // unverified accounts are rejected before any intent row exists.
        await assertSplitEligible(snap.id, phone);
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
    if (shareKobo * parties + remainderKobo !== fareKobo) {
        throw new https_1.HttpsError("data-loss", "Split shares do not sum to the trip fare. Please try again.");
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
        }
        catch (e) {
            console.warn(`requestSplitPayment: FCM failed for ${c.uid}: ${e}`);
        }
    }
    return { splitId, shareKobo, parties };
});
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
    let becameReady = false;
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
            becameReady = true;
        }
    });
    return { ok: true, accepted: accept, ready: becameReady };
});
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
exports.settleSplitPayment = (0, https_1.onCall)(async (request) => {
    var _a, _b, _c, _d, _e;
    if (!request.auth) {
        throw new https_1.HttpsError("unauthenticated", "You must sign in.");
    }
    const callerId = request.auth.uid;
    const splitId = String((_b = (_a = request.data) === null || _a === void 0 ? void 0 : _a.splitId) !== null && _b !== void 0 ? _b : "").trim();
    if (!splitId) {
        throw new https_1.HttpsError("invalid-argument", "splitId is required.");
    }
    // Execution authorization: the triggering participant authorizes the
    // settlement run with their transaction PIN. Co-payer debits were already
    // authorized by their individual accepts; this PIN covers the execution.
    // Verified before any wallet state is read (no oracle).
    await (0, transactionPin_1.requireValidPin)(callerId, (_c = request.data) === null || _c === void 0 ? void 0 : _c.transactionPin);
    const splitRef = db().collection("split_payments").doc(splitId);
    const splitSnap = await splitRef.get();
    if (!splitSnap.exists) {
        throw new https_1.HttpsError("not-found", "Split request not found.");
    }
    const split = splitSnap.data();
    if (split.status === "settled") {
        return { settled: true, alreadySettled: true };
    }
    if (split.status !== "ready") {
        throw new https_1.HttpsError("failed-precondition", split.status === "declined"
            ? "This split was declined. The trip customer retains the full fare."
            : "All co-payers must accept before this split can settle.");
    }
    const requesterId = String((_d = split.requesterId) !== null && _d !== void 0 ? _d : "");
    if (!requesterId) {
        throw new https_1.HttpsError("data-loss", "Split intent has no requester.");
    }
    if (callerId !== requesterId) {
        // Any accepted party may trigger settlement, but the intent belongs to
        // the requester — anyone else is a confused-deputy risk, not a helper.
        const partsProbe = await splitRef.collection("parts").doc(callerId).get();
        if (!partsProbe.exists) {
            throw new https_1.HttpsError("permission-denied", "Only split participants can settle this split.");
        }
    }
    const partsSnap = await splitRef.collection("parts").get();
    const parts = partsSnap.docs.map((d) => {
        var _a;
        return (Object.assign({ uid: d.id }, ((_a = d.data()) !== null && _a !== void 0 ? _a : {})));
    });
    if (parts.length === 0) {
        throw new https_1.HttpsError("data-loss", "Split intent has no shares.");
    }
    for (const p of parts) {
        if (p.status !== "accepted") {
            throw new https_1.HttpsError("failed-precondition", "All co-payers must accept before this split can settle.");
        }
    }
    const copayers = parts.filter((p) => p.uid !== requesterId);
    if (copayers.length === 0) {
        throw new https_1.HttpsError("failed-precondition", "There are no co-payer shares to settle.");
    }
    // Re-verify eligibility for every co-payer (fail fast, before the tx).
    for (const c of copayers) {
        const phone = String((_e = c.phone) !== null && _e !== void 0 ? _e : "this number");
        await assertSplitEligible(c.uid, phone);
    }
    const createdAt = admin.firestore.FieldValue.serverTimestamp();
    let creditedKobo = 0;
    await db().runTransaction(async (tx) => {
        var _a, _b, _c, _d, _e;
        const freshSplit = await tx.get(splitRef);
        if (!freshSplit.exists) {
            throw new https_1.HttpsError("not-found", "Split request not found.");
        }
        if (freshSplit.data().status === "settled")
            return; // idempotent
        if (freshSplit.data().status !== "ready") {
            throw new https_1.HttpsError("failed-precondition", "All co-payers must accept before this split can settle.");
        }
        let totalKobo = 0;
        for (const c of copayers) {
            const share = Math.floor(Number((_a = c.shareKobo) !== null && _a !== void 0 ? _a : NaN));
            if (!Number.isFinite(share) || share <= 0) {
                throw new https_1.HttpsError("data-loss", "Split intent has a corrupt share.");
            }
            const walletRef = db().collection("wallets").doc(c.uid);
            const userRef = db().collection("users").doc(c.uid);
            const [walletSnap, userSnap] = await Promise.all([
                tx.get(walletRef),
                tx.get(userRef),
            ]);
            const balance = walletSnap.exists
                ? Number((_b = walletSnap.data()["balance"]) !== null && _b !== void 0 ? _b : 0)
                : 0;
            if (!Number.isFinite(balance)) {
                throw new https_1.HttpsError("data-loss", "Wallet balance is corrupt.");
            }
            const stats = readSplitStats(userSnap.exists ? userSnap.data() : undefined);
            const trusted = stats.completedSplits >= SPLIT_TRUST_THRESHOLD;
            if (!trusted && balance < share) {
                throw new https_1.HttpsError("failed-precondition", `A co-payer's wallet is too low (₦${(Math.max(0, balance) / 100).toLocaleString("en-NG")} available, ₦${(share / 100).toLocaleString("en-NG")} needed). First ${SPLIT_TRUST_THRESHOLD} splits must be pre-funded.`);
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
            }
            else {
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
                tripId: String((_c = split.tripId) !== null && _c !== void 0 ? _c : ""),
                counterpartyId: requesterId,
                createdAt,
            });
            tx.set(userRef, {
                splitStats: {
                    completedSplits: stats.completedSplits + 1,
                    splitDebtKobo: stats.splitDebtKobo + debtIncrease,
                },
            }, { merge: true });
            tx.set(db().collection("wallet_transactions").doc(`${splitId}_${c.uid}`), {
                splitId,
                tripId: String((_d = split.tripId) !== null && _d !== void 0 ? _d : ""),
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
        }
        else {
            tx.set(requesterWallet, {
                userId: requesterId,
                balance: totalKobo,
                currency: "NGN",
                updatedAt: createdAt,
            });
        }
        const reqStats = readSplitStats(reqUserSnap.exists ? reqUserSnap.data() : undefined);
        tx.set(requesterUser, {
            splitStats: {
                completedSplits: reqStats.completedSplits + 1,
                splitDebtKobo: reqStats.splitDebtKobo,
            },
        }, { merge: true });
        tx.set(requesterWallet.collection("transactions").doc(splitId), {
            type: "SPLIT_FARE_CREDIT",
            amount: totalKobo,
            amountKobo: totalKobo,
            amountNaira: totalKobo / 100,
            currency: "NGN",
            splitId,
            tripId: String((_e = split.tripId) !== null && _e !== void 0 ? _e : ""),
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
exports.convertSeseCoins = (0, https_1.onCall)(async (request) => {
    var _a;
    if (!request.auth) {
        throw new https_1.HttpsError("unauthenticated", "You must sign in.");
    }
    const uid = request.auth.uid;
    // Read the admin-configured minimum from system_configs. Treat missing/bad
    // values as ₦50 so an unconfigured backend never blocks legitimate conversions.
    let minConvertible = 5000;
    try {
        const snap = await db().collection("system_configs").doc("financials").get();
        const raw = (_a = snap.data()) === null || _a === void 0 ? void 0 : _a.minConvertibleBonus;
        if (typeof raw === "number" && Number.isFinite(raw) && raw > 0) {
            minConvertible = raw;
        }
    }
    catch (_b) {
        // Fall through to default.
    }
    const walletRef = db().collection("wallets").doc(uid);
    const ledgerRef = walletRef.collection("transactions").doc();
    let converted = 0;
    await db().runTransaction(async (tx) => {
        var _a;
        const walletSnap = await tx.get(walletRef);
        if (!walletSnap.exists) {
            throw new https_1.HttpsError("not-found", "Wallet not found.");
        }
        const data = (_a = walletSnap.data()) !== null && _a !== void 0 ? _a : {};
        const coinBalance = typeof data["seseCoinBalance"] === "number"
            ? data["seseCoinBalance"]
            : 0;
        if (coinBalance < minConvertible) {
            throw new https_1.HttpsError("failed-precondition", `You need at least ₦${minConvertible.toLocaleString("en-NG")} in SeSe Coins to convert. ` +
                `Your current balance is ₦${coinBalance.toLocaleString("en-NG")}.`);
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
//# sourceMappingURL=peerPayments.js.map