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
var _a;
Object.defineProperty(exports, "__esModule", { value: true });
exports.approveAllWeeklyPayouts = exports.approveWeeklyPayout = exports.processWalletWithdrawal = exports.resolveBankAccount = exports.verifyBankAccount = exports.paystackBanks = exports.APPROVED_BANK_CODES = exports.INSTANT_WITHDRAWAL_FEE_KOBO = void 0;
exports.accountNameMatches = accountNameMatches;
exports.settleTransfer = settleTransfer;
const admin = __importStar(require("firebase-admin"));
const https_1 = require("firebase-functions/v2/https");
const transactionPin_1 = require("./transactionPin");
const accountGuard_1 = require("./accountGuard");
const verification_1 = require("./verification");
const db = () => admin.firestore();
const PAYSTACK_BASE = (_a = process.env.PAYSTACK_BASE_URL) !== null && _a !== void 0 ? _a : "https://api.paystack.co";
/** Flat ad-hoc instant withdrawal fee: ₦100 (10,000 kobo). */
exports.INSTANT_WITHDRAWAL_FEE_KOBO = 10000;
/** Restricted set of 11 approved financial institutions. */
exports.APPROVED_BANK_CODES = new Set([
    "044", // Access Bank
    "011", // First Bank of Nigeria
    "058", // Guaranty Trust Bank (GTB)
    "50211", // Kuda Bank
    "50515", // Moniepoint MFB
    "999992", // OPay
    "999991", // PalmPay
    "221", // Stanbic IBTC Bank
    "033", // United Bank for Africa (UBA)
    "035", // Wema Bank
    "057", // Zenith Bank
]);
async function paystackSecret() {
    var _a, _b;
    const secret = (_a = process.env.PAYSTACK_API_KEY) !== null && _a !== void 0 ? _a : process.env.PAYSTACK_SECRET_KEY;
    if (secret && secret.trim()) {
        return secret.trim();
    }
    try {
        const secDoc = await db().collection("system_config").doc("paystack_secrets").get();
        if (secDoc.exists && ((_b = secDoc.data()) === null || _b === void 0 ? void 0 : _b.secretKey)) {
            return String(secDoc.data().secretKey).trim();
        }
    }
    catch (_) { }
    throw new https_1.HttpsError("failed-precondition", "Withdrawals are not available right now. Please contact support.");
}
async function paystackGet(path, secret) {
    var _a;
    const res = await fetch(`${PAYSTACK_BASE}${path}`, {
        method: "GET",
        headers: { Authorization: `Bearer ${secret}` },
    });
    const json = (await res.json());
    if (!res.ok || json.status !== true) {
        throw new https_1.HttpsError("internal", `Paystack error: ${(_a = json.message) !== null && _a !== void 0 ? _a : `HTTP ${res.status}`}`);
    }
    const data = json.data;
    return data && typeof data === "object" ? data : {};
}
async function paystackPost(path, body, secret) {
    var _a, _b;
    const res = await fetch(`${PAYSTACK_BASE}${path}`, {
        method: "POST",
        headers: {
            Authorization: `Bearer ${secret}`,
            "Content-Type": "application/json",
        },
        body: JSON.stringify(body),
    });
    const json = (await res.json());
    if (!res.ok || json.status !== true) {
        throw new https_1.HttpsError("internal", `Paystack error: ${(_a = json.message) !== null && _a !== void 0 ? _a : `HTTP ${res.status}`}`);
    }
    return (_b = json.data) !== null && _b !== void 0 ? _b : {};
}
function newRequestId(uid) {
    const rand = Math.random().toString(36).slice(2, 10);
    return `pay_${uid.slice(0, 8)}_${Date.now().toString(36)}${rand}`;
}
// ─── Account-holder name matching ───────────────────────────────────────────
function normalizeName(raw) {
    return raw
        .toUpperCase()
        .replace(/['’`]/g, "")
        .replace(/[^A-Z]+/g, " ")
        .trim()
        .replace(/\s+/g, " ");
}
function accountNameMatches(profileName, accountName) {
    const profileTokens = dedupeTokens(profileName);
    const accountTokens = dedupeTokens(accountName);
    if (profileTokens.length < 2 || accountTokens.length < 2)
        return false;
    const [shorter, longer] = profileTokens.length <= accountTokens.length
        ? [profileTokens, accountTokens]
        : [accountTokens, profileTokens];
    return shorter.every((t) => longer.includes(t));
}
function dedupeTokens(raw) {
    return Array.from(new Set(normalizeName(raw).split(" ").filter((t) => t.length > 0)));
}
async function registeredName(uid) {
    var _a, _b, _c, _d;
    for (const collection of ["users", "drivers"]) {
        try {
            const snap = await db().collection(collection).doc(uid).get();
            if (!snap.exists)
                continue;
            const d = snap.data();
            const direct = `${(_a = d["fullName"]) !== null && _a !== void 0 ? _a : ""} ${(_b = d["displayName"]) !== null && _b !== void 0 ? _b : ""}`.trim();
            if (direct)
                return direct;
            const composed = `${(_c = d["firstName"]) !== null && _c !== void 0 ? _c : ""} ${(_d = d["lastName"]) !== null && _d !== void 0 ? _d : ""}`.trim();
            if (composed)
                return composed;
        }
        catch (_) {
            // Ignore
        }
    }
    return "";
}
// ─── Callables ──────────────────────────────────────────────────────────────
let bankCache = null;
const BANK_CACHE_TTL_MS = 10 * 60 * 1000;
exports.paystackBanks = (0, https_1.onCall)(async (request) => {
    if (!request.auth) {
        throw new https_1.HttpsError("unauthenticated", "You must sign in.");
    }
    const now = Date.now();
    if (bankCache && now - bankCache.at < BANK_CACHE_TTL_MS) {
        return { banks: bankCache.banks };
    }
    const secret = await paystackSecret();
    const data = await paystackGet("/bank", secret);
    const rawBanks = Array.isArray(data) ? data : [];
    // Restrict returned banks strictly to approved 11 banks
    const banks = rawBanks.filter((b) => { var _a; return exports.APPROVED_BANK_CODES.has(String((_a = b["code"]) !== null && _a !== void 0 ? _a : "")); });
    bankCache = { at: now, banks };
    return { banks };
});
exports.verifyBankAccount = (0, https_1.onCall)(async (request) => {
    var _a, _b, _c, _d, _e, _f;
    if (!request.auth) {
        throw new https_1.HttpsError("unauthenticated", "You must sign in.");
    }
    const bankCode = String((_b = (_a = request.data) === null || _a === void 0 ? void 0 : _a.bankCode) !== null && _b !== void 0 ? _b : "").trim();
    const accountNumber = String((_d = (_c = request.data) === null || _c === void 0 ? void 0 : _c.accountNumber) !== null && _d !== void 0 ? _d : "").trim();
    if (!exports.APPROVED_BANK_CODES.has(bankCode)) {
        throw new https_1.HttpsError("invalid-argument", "Select an approved bank.");
    }
    if (!/^\d{10}$/.test(accountNumber)) {
        throw new https_1.HttpsError("invalid-argument", "Account number must be exactly 10 digits.");
    }
    const secret = await paystackSecret();
    const data = await paystackGet(`/bank/resolve?account_number=${encodeURIComponent(accountNumber)}&bank_code=${encodeURIComponent(bankCode)}`, secret);
    const accountName = String((_e = data["account_name"]) !== null && _e !== void 0 ? _e : "");
    const bankName = String((_f = data["bank_name"]) !== null && _f !== void 0 ? _f : "");
    return {
        account_name: accountName,
        accountName,
        bankName,
        accountNumber,
    };
});
exports.resolveBankAccount = exports.verifyBankAccount;
/**
 * Callable: Instant Ad-Hoc Self-Service Withdrawal
 * Automatically deducts flat ₦100 fee (10,000 kobo).
 */
exports.processWalletWithdrawal = (0, https_1.onCall)(async (request) => {
    var _a, _b, _c, _d, _e, _f, _g, _h, _j, _k, _l, _m, _o, _p;
    if (!request.auth) {
        throw new https_1.HttpsError("unauthenticated", "You must sign in.");
    }
    const uid = request.auth.uid;
    (0, accountGuard_1.enforceAppCheck)(request);
    await (0, accountGuard_1.requireAccountActive)(uid, "customer");
    const secret = await paystackSecret();
    await (0, transactionPin_1.requireValidPin)(uid, (_a = request.data) === null || _a === void 0 ? void 0 : _a.transactionPin);
    const rawKobo = ((_b = request.data) === null || _b === void 0 ? void 0 : _b.amountKobo) !== undefined
        ? Number(request.data.amountKobo)
        : ((_c = request.data) === null || _c === void 0 ? void 0 : _c.amount) !== undefined
            ? Number(request.data.amount) * 100
            : NaN;
    const requestedAmountKobo = Math.round(rawKobo);
    const feeKobo = exports.INSTANT_WITHDRAWAL_FEE_KOBO; // ₦100 flat fee
    if (!Number.isFinite(requestedAmountKobo) || requestedAmountKobo <= feeKobo) {
        throw new https_1.HttpsError("invalid-argument", "Withdrawal amount must be greater than the ₦100 withdrawal fee.");
    }
    const netAmountKobo = requestedAmountKobo - feeKobo;
    // Daily Limit Cap (₦20,000)
    let maxDailyWithdrawal = 20000;
    try {
        const finDoc = await db().collection("system_configs").doc("financials").get();
        if (finDoc.exists) {
            const finData = (_d = finDoc.data()) !== null && _d !== void 0 ? _d : {};
            if (typeof finData["maxDailyWithdrawal"] === "number") {
                maxDailyWithdrawal = finData["maxDailyWithdrawal"];
            }
        }
    }
    catch (e) {
        console.warn(`[processWalletWithdrawal] financials config read fallback: ${e}`);
    }
    const maxDailyKobo = Math.round(maxDailyWithdrawal * 100);
    if (requestedAmountKobo > maxDailyKobo) {
        throw new https_1.HttpsError("invalid-argument", `Max withdrawal ₦${maxDailyWithdrawal.toLocaleString("en-NG")}`);
    }
    try {
        const oneDayAgo = new Date(Date.now() - 24 * 60 * 60 * 1000);
        const recentPayoutsSnap = await db()
            .collection("payout_requests")
            .where("userId", "==", uid)
            .where("createdAt", ">=", oneDayAgo)
            .get();
        let dailyTotalKobo = 0;
        for (const pDoc of recentPayoutsSnap.docs) {
            const pData = pDoc.data();
            if (pData["status"] !== "failed" && pData["status"] !== "refunded") {
                dailyTotalKobo += Number((_f = (_e = pData["requestedAmountKobo"]) !== null && _e !== void 0 ? _e : pData["amountKobo"]) !== null && _f !== void 0 ? _f : 0);
            }
        }
        if (dailyTotalKobo + requestedAmountKobo > maxDailyKobo) {
            throw new https_1.HttpsError("failed-precondition", "Daily limit reached");
        }
    }
    catch (e) {
        if (e instanceof https_1.HttpsError)
            throw e;
        console.warn(`[processWalletWithdrawal] daily withdrawal sum warning: ${e}`);
    }
    const bankCode = String((_h = (_g = request.data) === null || _g === void 0 ? void 0 : _g.bankCode) !== null && _h !== void 0 ? _h : "").trim();
    const accountNumber = String((_k = (_j = request.data) === null || _j === void 0 ? void 0 : _j.accountNumber) !== null && _k !== void 0 ? _k : "").trim();
    if (!exports.APPROVED_BANK_CODES.has(bankCode)) {
        throw new https_1.HttpsError("invalid-argument", "Select an approved bank.");
    }
    if (!/^\d{10}$/.test(accountNumber)) {
        throw new https_1.HttpsError("invalid-argument", "10-digit account required");
    }
    const resolved = await paystackGet(`/bank/resolve?account_number=${encodeURIComponent(accountNumber)}&bank_code=${encodeURIComponent(bankCode)}`, secret);
    const accountName = String((_l = resolved["account_name"]) !== null && _l !== void 0 ? _l : "");
    if (!accountName) {
        throw new https_1.HttpsError("invalid-argument", "Account not found");
    }
    const registered = await registeredName(uid);
    if (!registered) {
        throw new https_1.HttpsError("failed-precondition", "Add your full name to your profile before withdrawing.");
    }
    if (!accountNameMatches(registered, accountName)) {
        throw new https_1.HttpsError("permission-denied", `Name mismatch: account must match ${registered}`);
    }
    const requestId = newRequestId(uid);
    const walletRef = db().collection("wallets").doc(uid);
    const requestRef = db().collection("payout_requests").doc(requestId);
    const ledgerRef = walletRef.collection("transactions").doc(requestId);
    const createdAt = admin.firestore.FieldValue.serverTimestamp();
    await db().runTransaction(async (tx) => {
        var _a, _b;
        const walletSnap = await tx.get(walletRef);
        if (!walletSnap.exists) {
            throw new https_1.HttpsError("failed-precondition", "No wallet found for this account.");
        }
        const balanceKobo = Number((_a = walletSnap.data()["balance"]) !== null && _a !== void 0 ? _a : 0);
        if (!Number.isFinite(balanceKobo) || balanceKobo < requestedAmountKobo) {
            throw new https_1.HttpsError("failed-precondition", "Insufficient balance");
        }
        tx.update(walletRef, {
            balance: admin.firestore.FieldValue.increment(-requestedAmountKobo),
            mainWalletBalance: admin.firestore.FieldValue.increment(-requestedAmountKobo / 100),
            updatedAt: admin.firestore.FieldValue.serverTimestamp(),
        });
        tx.set(ledgerRef, {
            type: "wallet_withdrawal",
            amount: requestedAmountKobo,
            requestedAmountKobo,
            feeKobo,
            netAmountKobo,
            amountKobo: requestedAmountKobo,
            amountNaira: requestedAmountKobo / 100,
            currency: "NGN",
            payoutRequestId: requestId,
            status: "pending",
            createdAt,
        });
        tx.set(requestRef, {
            requestId,
            userId: uid,
            driverId: uid,
            payoutType: "instant_adhoc",
            requestedAmountKobo,
            feeKobo,
            netAmountKobo,
            amountKobo: netAmountKobo,
            amountNaira: netAmountKobo / 100,
            currency: "NGN",
            bankCode,
            accountNumber,
            accountName,
            registeredName: registered,
            bankName: String((_b = resolved["bank_name"]) !== null && _b !== void 0 ? _b : ""),
            status: "pending",
            paystackRecipientCode: null,
            paystackTransferReference: null,
            failureReason: null,
            createdAt,
            updatedAt: createdAt,
        });
    });
    try {
        const recipient = await paystackPost("/transferrecipient", {
            type: "nuban",
            name: accountName,
            account_number: accountNumber,
            bank_code: bankCode,
            currency: "NGN",
        }, secret);
        const recipientCode = String((_m = recipient["recipient_code"]) !== null && _m !== void 0 ? _m : "");
        if (!recipientCode) {
            throw new https_1.HttpsError("internal", "Paystack did not return a transfer recipient.");
        }
        const transfer = await paystackPost("/transfer", {
            source: "balance",
            amount: netAmountKobo, // Transfer net amount after ₦100 fee
            recipient: recipientCode,
            reason: "Sese Ride Wallet Payout",
            reference: requestId,
        }, secret);
        const transferReference = String((_o = transfer["reference"]) !== null && _o !== void 0 ? _o : "");
        const transferStatus = String((_p = transfer["status"]) !== null && _p !== void 0 ? _p : "");
        const settled = transferStatus === "success";
        await requestRef.update({
            paystackRecipientCode: recipientCode,
            paystackTransferReference: transferReference,
            status: settled ? "completed" : "pending",
            submittedAt: admin.firestore.FieldValue.serverTimestamp(),
            updatedAt: admin.firestore.FieldValue.serverTimestamp(),
        });
        await ledgerRef.update({
            status: settled ? "completed" : "pending",
            paystackTransferReference: transferReference,
        });
        return {
            requestId,
            amountKobo: requestedAmountKobo,
            feeKobo,
            netAmountKobo,
            status: settled ? "completed" : "pending",
            transferReference,
            accountName,
        };
    }
    catch (e) {
        const reason = e instanceof Error ? e.message : String(e);
        const isNetworkTimeout = reason.toLowerCase().includes("timeout") ||
            reason.includes("ETIMEDOUT") ||
            reason.includes("ECONNRESET") ||
            reason.includes("504") ||
            reason.includes("ENOTFOUND");
        if (isNetworkTimeout) {
            console.warn(`[payouts] Network timeout for requestId ${requestId}. Holding debit for reconciliation.`);
            await requestRef.update({
                status: "pending_verification",
                failureReason: `Network timeout connecting to Paystack: ${reason.slice(0, 400)}`,
                updatedAt: admin.firestore.FieldValue.serverTimestamp(),
            });
            await db().collection("failed_payouts_dlq").doc(requestId).set({
                requestId,
                userId: uid,
                amountKobo: requestedAmountKobo,
                reason,
                status: "NEEDS_RECONCILIATION",
                createdAt: admin.firestore.FieldValue.serverTimestamp(),
            });
            throw new https_1.HttpsError("unavailable", "Transfer request timed out with our payment provider. Your balance is safely held while we verify delivery status.");
        }
        await db().runTransaction(async (tx) => {
            tx.update(walletRef, {
                balance: admin.firestore.FieldValue.increment(requestedAmountKobo),
                mainWalletBalance: admin.firestore.FieldValue.increment(requestedAmountKobo / 100),
                updatedAt: admin.firestore.FieldValue.serverTimestamp(),
            });
            tx.set(walletRef.collection("transactions").doc(`${requestId}_refund`), {
                type: "wallet_withdrawal_refund",
                amount: requestedAmountKobo,
                amountKobo: requestedAmountKobo,
                amountNaira: requestedAmountKobo / 100,
                currency: "NGN",
                payoutRequestId: requestId,
                status: "completed",
                reason,
                createdAt: admin.firestore.FieldValue.serverTimestamp(),
            });
            tx.update(requestRef, {
                status: "failed",
                failureReason: reason.slice(0, 500),
                updatedAt: admin.firestore.FieldValue.serverTimestamp(),
            });
            tx.update(ledgerRef, { status: "failed" });
        });
        throw e;
    }
});
/**
 * Callable: Hub Admin Weekly Fee-Free Payout Approval
 * Debits full remaining user balance and transfers 100% full amount to bank (0 fee).
 */
exports.approveWeeklyPayout = (0, https_1.onCall)(async (request) => {
    var _a, _b, _c, _d, _e, _f, _g, _h, _j, _k, _l, _m, _o;
    if (!request.auth) {
        throw new https_1.HttpsError("unauthenticated", "You must sign in.");
    }
    const token = ((_a = request.auth.token) !== null && _a !== void 0 ? _a : {});
    const callerEmail = String((_c = (_b = request.auth.token) === null || _b === void 0 ? void 0 : _b.email) !== null && _c !== void 0 ? _c : "").trim();
    await (0, verification_1.assertHubStaffOrAdmin)(request.auth.uid, callerEmail, token);
    const targetUid = String((_e = (_d = request.data) === null || _d === void 0 ? void 0 : _d.userId) !== null && _e !== void 0 ? _e : "").trim();
    if (!targetUid) {
        throw new https_1.HttpsError("invalid-argument", "Target userId is required.");
    }
    const secret = await paystackSecret();
    // 1. Resolve user payout bank profile
    const profileSnap = await db().collection("payout_profiles").doc(targetUid).get();
    if (!profileSnap.exists) {
        throw new https_1.HttpsError("failed-precondition", "User has not configured bank details.");
    }
    const profile = profileSnap.data();
    const bankCode = String((_f = profile["bankCode"]) !== null && _f !== void 0 ? _f : "").trim();
    const accountNumber = String((_g = profile["accountNumber"]) !== null && _g !== void 0 ? _g : "").trim();
    const accountName = String((_h = profile["accountName"]) !== null && _h !== void 0 ? _h : "").trim();
    const bankName = String((_j = profile["bankName"]) !== null && _j !== void 0 ? _j : "").trim();
    if (!exports.APPROVED_BANK_CODES.has(bankCode)) {
        throw new https_1.HttpsError("invalid-argument", "User bank is not in approved list.");
    }
    if (!/^\d{10}$/.test(accountNumber) || !accountName) {
        throw new https_1.HttpsError("invalid-argument", "Invalid or unverified bank account details.");
    }
    // 2. Resolve wallet balance
    const walletRef = db().collection("wallets").doc(targetUid);
    const walletSnap = await walletRef.get();
    if (!walletSnap.exists) {
        throw new https_1.HttpsError("failed-precondition", "No wallet found for this account.");
    }
    const balanceKobo = Number((_k = walletSnap.data()["balance"]) !== null && _k !== void 0 ? _k : 0);
    if (!Number.isFinite(balanceKobo) || balanceKobo <= 0) {
        throw new https_1.HttpsError("failed-precondition", "Wallet balance must be greater than 0.");
    }
    const requestId = newRequestId(targetUid);
    const requestRef = db().collection("payout_requests").doc(requestId);
    const ledgerRef = walletRef.collection("transactions").doc(requestId);
    const createdAt = admin.firestore.FieldValue.serverTimestamp();
    const adminUid = request.auth.uid;
    const feeKobo = 0;
    const netAmountKobo = balanceKobo;
    await db().runTransaction(async (tx) => {
        var _a;
        const freshWallet = await tx.get(walletRef);
        const walletData = freshWallet.data() || {};
        const freshBal = Number((_a = walletData["balance"]) !== null && _a !== void 0 ? _a : 0);
        if (!Number.isFinite(freshBal) || freshBal < balanceKobo) {
            throw new https_1.HttpsError("failed-precondition", "Wallet balance changed during processing.");
        }
        tx.update(walletRef, {
            balance: admin.firestore.FieldValue.increment(-balanceKobo),
            mainWalletBalance: admin.firestore.FieldValue.increment(-balanceKobo / 100),
            updatedAt: admin.firestore.FieldValue.serverTimestamp(),
        });
        tx.set(ledgerRef, {
            type: "weekly_payout",
            amount: balanceKobo,
            amountKobo: balanceKobo,
            amountNaira: balanceKobo / 100,
            feeKobo,
            currency: "NGN",
            payoutRequestId: requestId,
            status: "pending",
            createdAt,
        });
        tx.set(requestRef, {
            requestId,
            userId: targetUid,
            driverId: targetUid,
            payoutType: "weekly_payout",
            requestedAmountKobo: balanceKobo,
            feeKobo,
            netAmountKobo,
            amountKobo: balanceKobo,
            amountNaira: balanceKobo / 100,
            currency: "NGN",
            bankCode,
            accountNumber,
            accountName,
            bankName,
            status: "pending",
            approvedByAdmin: adminUid,
            paystackRecipientCode: null,
            paystackTransferReference: null,
            failureReason: null,
            createdAt,
            updatedAt: createdAt,
        });
    });
    try {
        const recipient = await paystackPost("/transferrecipient", {
            type: "nuban",
            name: accountName,
            account_number: accountNumber,
            bank_code: bankCode,
            currency: "NGN",
        }, secret);
        const recipientCode = String((_l = recipient["recipient_code"]) !== null && _l !== void 0 ? _l : "");
        if (!recipientCode) {
            throw new https_1.HttpsError("internal", "Paystack returned no recipient code.");
        }
        const transfer = await paystackPost("/transfer", {
            source: "balance",
            amount: netAmountKobo,
            recipient: recipientCode,
            reason: "Sese Weekly Payout",
            reference: requestId,
        }, secret);
        const transferReference = String((_m = transfer["reference"]) !== null && _m !== void 0 ? _m : "");
        const transferStatus = String((_o = transfer["status"]) !== null && _o !== void 0 ? _o : "");
        const settled = transferStatus === "success";
        await requestRef.update({
            paystackRecipientCode: recipientCode,
            paystackTransferReference: transferReference,
            status: settled ? "completed" : "pending",
            submittedAt: admin.firestore.FieldValue.serverTimestamp(),
            updatedAt: admin.firestore.FieldValue.serverTimestamp(),
        });
        await ledgerRef.update({
            status: settled ? "completed" : "pending",
            paystackTransferReference: transferReference,
        });
        return {
            requestId,
            amountKobo: balanceKobo,
            status: settled ? "completed" : "pending",
            transferReference,
            accountName,
        };
    }
    catch (e) {
        const reason = e instanceof Error ? e.message : String(e);
        await db().runTransaction(async (tx) => {
            tx.update(walletRef, {
                balance: admin.firestore.FieldValue.increment(balanceKobo),
                mainWalletBalance: admin.firestore.FieldValue.increment(balanceKobo / 100),
                updatedAt: admin.firestore.FieldValue.serverTimestamp(),
            });
            tx.set(walletRef.collection("transactions").doc(`${requestId}_refund`), {
                type: "weekly_payout_refund",
                amount: balanceKobo,
                amountKobo: balanceKobo,
                amountNaira: balanceKobo / 100,
                currency: "NGN",
                payoutRequestId: requestId,
                status: "completed",
                reason,
                createdAt: admin.firestore.FieldValue.serverTimestamp(),
            });
            tx.update(requestRef, {
                status: "failed",
                failureReason: reason.slice(0, 500),
                updatedAt: admin.firestore.FieldValue.serverTimestamp(),
            });
            tx.update(ledgerRef, { status: "failed" });
        });
        throw e;
    }
});
/**
 * Callable: Bulk Weekly Payout Approval for all eligible users in queue.
 */
exports.approveAllWeeklyPayouts = (0, https_1.onCall)(async (request) => {
    var _a, _b, _c, _d, _e, _f, _g, _h, _j, _k, _l;
    if (!request.auth) {
        throw new https_1.HttpsError("unauthenticated", "You must sign in.");
    }
    const token = ((_a = request.auth.token) !== null && _a !== void 0 ? _a : {});
    const callerEmail = String((_c = (_b = request.auth.token) === null || _b === void 0 ? void 0 : _b.email) !== null && _c !== void 0 ? _c : "").trim();
    await (0, verification_1.assertHubStaffOrAdmin)(request.auth.uid, callerEmail, token);
    // Fetch financial config for minPayoutThreshold
    let minPayoutThreshold = 20000;
    try {
        const finDoc = await db().collection("system_configs").doc("financials").get();
        const finData = finDoc.data() || {};
        if (finDoc.exists && typeof finData["minPayoutThreshold"] === "number") {
            minPayoutThreshold = finData["minPayoutThreshold"];
        }
    }
    catch (_) { }
    const minKobo = Math.round(minPayoutThreshold * 100);
    // Query eligible wallets
    const walletsSnap = await db()
        .collection("wallets")
        .where("balance", ">=", minKobo)
        .get();
    const results = [];
    for (const wDoc of walletsSnap.docs) {
        const targetUid = wDoc.id;
        try {
            const profileSnap = await db().collection("payout_profiles").doc(targetUid).get();
            if (!profileSnap.exists) {
                results.push({ userId: targetUid, success: false, error: "No bank details" });
                continue;
            }
            const profile = profileSnap.data();
            const bankCode = String((_d = profile["bankCode"]) !== null && _d !== void 0 ? _d : "").trim();
            if (!exports.APPROVED_BANK_CODES.has(bankCode)) {
                results.push({ userId: targetUid, success: false, error: "Bank not approved" });
                continue;
            }
            // Invoke approveWeeklyPayout logic internally
            const secret = await paystackSecret();
            const balanceKobo = Number((_e = wDoc.data()["balance"]) !== null && _e !== void 0 ? _e : 0);
            const accountNumber = String((_f = profile["accountNumber"]) !== null && _f !== void 0 ? _f : "").trim();
            const accountName = String((_g = profile["accountName"]) !== null && _g !== void 0 ? _g : "").trim();
            const bankName = String((_h = profile["bankName"]) !== null && _h !== void 0 ? _h : "").trim();
            const requestId = newRequestId(targetUid);
            const requestRef = db().collection("payout_requests").doc(requestId);
            const walletRef = db().collection("wallets").doc(targetUid);
            const ledgerRef = walletRef.collection("transactions").doc(requestId);
            const createdAt = admin.firestore.FieldValue.serverTimestamp();
            const adminUid = request.auth.uid;
            await db().runTransaction(async (tx) => {
                tx.update(walletRef, {
                    balance: admin.firestore.FieldValue.increment(-balanceKobo),
                    mainWalletBalance: admin.firestore.FieldValue.increment(-balanceKobo / 100),
                    updatedAt: admin.firestore.FieldValue.serverTimestamp(),
                });
                tx.set(ledgerRef, {
                    type: "weekly_payout",
                    amount: balanceKobo,
                    amountKobo: balanceKobo,
                    amountNaira: balanceKobo / 100,
                    feeKobo: 0,
                    currency: "NGN",
                    payoutRequestId: requestId,
                    status: "pending",
                    createdAt,
                });
                tx.set(requestRef, {
                    requestId,
                    userId: targetUid,
                    driverId: targetUid,
                    payoutType: "weekly_payout",
                    requestedAmountKobo: balanceKobo,
                    feeKobo: 0,
                    netAmountKobo: balanceKobo,
                    amountKobo: balanceKobo,
                    amountNaira: balanceKobo / 100,
                    currency: "NGN",
                    bankCode,
                    accountNumber,
                    accountName,
                    bankName,
                    status: "pending",
                    approvedByAdmin: adminUid,
                    paystackRecipientCode: null,
                    paystackTransferReference: null,
                    failureReason: null,
                    createdAt,
                    updatedAt: createdAt,
                });
            });
            const recipient = await paystackPost("/transferrecipient", {
                type: "nuban",
                name: accountName,
                account_number: accountNumber,
                bank_code: bankCode,
                currency: "NGN",
            }, secret);
            const recipientCode = String((_j = recipient["recipient_code"]) !== null && _j !== void 0 ? _j : "");
            const transfer = await paystackPost("/transfer", {
                source: "balance",
                amount: balanceKobo,
                recipient: recipientCode,
                reason: "Sese Weekly Payout Batch",
                reference: requestId,
            }, secret);
            const transferReference = String((_k = transfer["reference"]) !== null && _k !== void 0 ? _k : "");
            const settled = String((_l = transfer["status"]) !== null && _l !== void 0 ? _l : "") === "success";
            await requestRef.update({
                paystackRecipientCode: recipientCode,
                paystackTransferReference: transferReference,
                status: settled ? "completed" : "pending",
                submittedAt: admin.firestore.FieldValue.serverTimestamp(),
                updatedAt: admin.firestore.FieldValue.serverTimestamp(),
            });
            await ledgerRef.update({
                status: settled ? "completed" : "pending",
                paystackTransferReference: transferReference,
            });
            results.push({ userId: targetUid, success: true });
        }
        catch (err) {
            const errMsg = err instanceof Error ? err.message : String(err);
            results.push({ userId: targetUid, success: false, error: errMsg });
        }
    }
    return { processed: results.length, details: results };
});
async function settleTransfer(reference, outcome, reason) {
    const payoutRef = db().collection("payout_requests").doc(reference);
    const payoutLedgerRef = db().collection("wallet_ledger").doc(`payout_${reference}_${outcome}`);
    await db().runTransaction(async (tx) => {
        var _a, _b, _c, _d, _e;
        const ledgerSnap = await tx.get(payoutLedgerRef);
        if (ledgerSnap.exists) {
            console.log(`[payouts] Duplicate webhook processing blocked for payout ledger: payout_${reference}_${outcome}`);
            return;
        }
        const snap = await tx.get(payoutRef);
        if (!snap.exists)
            return;
        const row = snap.data();
        const currentStatus = String((_a = row["status"]) !== null && _a !== void 0 ? _a : "");
        if (currentStatus === outcome || currentStatus === "completed")
            return;
        if (currentStatus === "refunded" && outcome === "success") {
            console.error(`[payouts] CRITICAL: Payout ${reference} succeeded on Paystack but had already been marked refunded!`);
            const alertRef = db().collection("failed_payouts_dlq").doc(`${reference}_double_payout_alert`);
            tx.set(alertRef, {
                type: "DOUBLE_PAYOUT_DETECTED",
                severity: "CRITICAL",
                reference,
                userId: row["userId"],
                amountKobo: row["amountKobo"],
                createdAt: admin.firestore.FieldValue.serverTimestamp(),
            });
            return;
        }
        const userId = String((_b = row["userId"]) !== null && _b !== void 0 ? _b : "");
        const requestId = String((_c = row["requestId"]) !== null && _c !== void 0 ? _c : "");
        const walletRef = db().collection("wallets").doc(userId);
        const ledgerRef = walletRef.collection("transactions").doc(requestId);
        await tx.get(walletRef);
        if (outcome === "success") {
            tx.update(payoutRef, {
                status: "completed",
                settledAt: admin.firestore.FieldValue.serverTimestamp(),
                updatedAt: admin.firestore.FieldValue.serverTimestamp(),
            });
            tx.update(ledgerRef, { status: "completed" });
            tx.set(payoutLedgerRef, {
                status: "completed",
                reference,
                timestamp: admin.firestore.FieldValue.serverTimestamp(),
            });
            return;
        }
        // Failed AFTER the debit committed: refund it.
        const amountKobo = Number((_e = (_d = row["requestedAmountKobo"]) !== null && _d !== void 0 ? _d : row["amountKobo"]) !== null && _e !== void 0 ? _e : 0);
        if (amountKobo > 0) {
            tx.update(walletRef, {
                balance: admin.firestore.FieldValue.increment(amountKobo),
                mainWalletBalance: admin.firestore.FieldValue.increment(amountKobo / 100),
                updatedAt: admin.firestore.FieldValue.serverTimestamp(),
            });
            tx.set(walletRef.collection("transactions").doc(`${reference}_refund`), {
                type: "wallet_withdrawal_refund",
                amount: amountKobo,
                amountKobo,
                amountNaira: amountKobo / 100,
                currency: "NGN",
                payoutRequestId: reference,
                status: "completed",
                reason,
                createdAt: admin.firestore.FieldValue.serverTimestamp(),
            });
        }
        tx.update(payoutRef, {
            status: "refunded",
            failureReason: reason.slice(0, 500),
            settledAt: admin.firestore.FieldValue.serverTimestamp(),
            updatedAt: admin.firestore.FieldValue.serverTimestamp(),
        });
        tx.update(ledgerRef, { status: "refunded" });
        tx.set(payoutLedgerRef, {
            status: "refunded",
            reference,
            reason: reason.slice(0, 500),
            timestamp: admin.firestore.FieldValue.serverTimestamp(),
        });
    });
}
//# sourceMappingURL=payouts.js.map