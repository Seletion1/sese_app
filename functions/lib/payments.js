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
exports.paystackWebhook = exports.verifyPayment = exports.initializePaystackTopUp = exports.initializePayment = void 0;
exports.chargePaystackCardAuthorization = chargePaystackCardAuthorization;
const admin = __importStar(require("firebase-admin"));
const node_crypto_1 = require("node:crypto");
const https_1 = require("firebase-functions/v2/https");
const payouts_1 = require("./payouts");
const transactionPin_1 = require("./transactionPin");
const accountGuard_1 = require("./accountGuard");
/**
 * Paystack Collections (inline card, bank transfer, USSD, mobile money).
 *
 * Money flow (zero-trust — the client NEVER touches amounts):
 *   1. `initializePayment` (callable): validates the caller + amount, mints a
 *      `payment_intents/{reference}` doc (PENDING), and initializes the
 *      transaction with Paystack. Returns the hosted `authorizationUrl` the
 *      app opens for the user to pay.
 *   2. User pays on Paystack's hosted checkout (test mode accepts test cards).
 *   3. `verifyPayment` (callable): verifies the reference server-side with
 *      Paystack, checks the amount/currency match the intent, then credits
 *      `wallets/{uid}` EXACTLY ONCE (idempotent) and writes the wallet
 *      transaction record.
 *   4. `paystackWebhook` (HTTPS): same settlement driven by Paystack's
 *      `charge.success` event (signature-verified). Either path settles;
 *      the second one no-ops via the idempotency guard.
 *
 * Secrets: the Paystack SECRET key lives ONLY here, read from
 * `process.env.PAYSTACK_API_KEY` (plain `.env` var, git-ignored) with a
 * fallback to `process.env.PAYSTACK_SECRET_KEY` (stale Secret Manager
 * binding from the defineSecret era — see payouts.ts).
 * The public key (`pk_test_...`) is safe to embed in the client.
 */
const db = () => admin.firestore();
const PAYSTACK_BASE = (_a = process.env.PAYSTACK_BASE_URL) !== null && _a !== void 0 ? _a : "https://api.paystack.co";
/** Floor/ceiling per payment in kobo (₦100 – ₦500,000). */
const MIN_AMOUNT_KOBO = 10000;
const MAX_AMOUNT_KOBO = 50000000;
async function paystackSecret() {
    var _a;
    const envSecret = (_a = process.env.PAYSTACK_API_KEY) !== null && _a !== void 0 ? _a : process.env.PAYSTACK_SECRET_KEY;
    if (envSecret && envSecret.trim()) {
        return envSecret.trim();
    }
    // Paystack secret key must NOT be read from client-accessible Firestore documents.
    // It is strictly populated via environment variables or Secret Manager.
    throw new https_1.HttpsError("failed-precondition", "PAYSTACK_NOT_CONFIGURED");
}
function newReference(uid) {
    const rand = Math.random().toString(36).slice(2, 10);
    return `sese_${uid.slice(0, 8)}_${Date.now().toString(36)}${rand}`;
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
async function paystackGet(path, secret) {
    var _a, _b;
    const res = await fetch(`${PAYSTACK_BASE}${path}`, {
        method: "GET",
        headers: { Authorization: `Bearer ${secret}` },
    });
    const json = (await res.json());
    if (!res.ok || json.status !== true) {
        throw new https_1.HttpsError("internal", `Paystack error: ${(_a = json.message) !== null && _a !== void 0 ? _a : `HTTP ${res.status}`}`);
    }
    return (_b = json.data) !== null && _b !== void 0 ? _b : {};
}
/**
 * Callable: starts a Paystack collection for the caller.
 * Returns `{ authorizationUrl, accessCode, reference }`.
 */
exports.initializePayment = (0, https_1.onCall)(async (request) => {
    var _a, _b, _c, _d, _e, _f, _g;
    if (!request.auth) {
        throw new https_1.HttpsError("unauthenticated", "You must sign in to pay.");
    }
    const uid = request.auth.uid;
    // ── Security gates (must run before any business logic) ───────────────
    // App Check: rejects calls from non-genuine app builds / scripts.
    (0, accountGuard_1.enforceAppCheck)(request);
    // Suspension gate: banned/suspended users cannot initiate payments even
    // when Firestore rules have not yet propagated to all SDK caches.
    await (0, accountGuard_1.requireAccountActive)(uid, "customer");
    // Transaction-PIN gate: verified server-side before initializing Paystack payment intent.
    await (0, transactionPin_1.requireValidPin)(uid, (_a = request.data) === null || _a === void 0 ? void 0 : _a.transactionPin);
    const secret = await paystackSecret();
    const d = (_b = request.data) !== null && _b !== void 0 ? _b : {};
    const amountKobo = typeof d.amountKobo === "number" ? Math.round(d.amountKobo) : NaN;
    if (!Number.isFinite(amountKobo) || amountKobo < MIN_AMOUNT_KOBO) {
        throw new https_1.HttpsError("invalid-argument", "Min payment ₦100");
    }
    if (amountKobo > MAX_AMOUNT_KOBO) {
        throw new https_1.HttpsError("invalid-argument", "Max payment ₦500,000");
    }
    const purpose = d.purpose === "trip_payment" ? "trip_payment" : "wallet_topup";
    // ── Financial Rules & Business Limits Gate ─────────────────────────
    if (purpose === "wallet_topup") {
        let maxAccountBalance = 50000;
        let maxSingleTopUp = 20000;
        let dailyTopUpFrequency = 5;
        try {
            const finDoc = await db().collection("system_configs").doc("financials").get();
            if (finDoc.exists) {
                const finData = (_c = finDoc.data()) !== null && _c !== void 0 ? _c : {};
                if (typeof finData["maxAccountBalance"] === "number") {
                    maxAccountBalance = finData["maxAccountBalance"];
                }
                if (typeof finData["maxSingleTopUp"] === "number") {
                    maxSingleTopUp = finData["maxSingleTopUp"];
                }
                if (typeof finData["dailyTopUpFrequency"] === "number") {
                    dailyTopUpFrequency = finData["dailyTopUpFrequency"];
                }
            }
        }
        catch (e) {
            console.warn(`[initializePayment] financials config read fallback: ${e}`);
        }
        // 1. Max Single Top-Up
        const maxSingleKobo = Math.round(maxSingleTopUp * 100);
        if (amountKobo > maxSingleKobo) {
            throw new https_1.HttpsError("invalid-argument", `Max top-up ₦${maxSingleTopUp.toLocaleString("en-NG")}`);
        }
        // 2. Max Account Balance Cap
        try {
            const walletDoc = await db().collection("wallets").doc(uid).get();
            if (walletDoc.exists) {
                const wData = (_d = walletDoc.data()) !== null && _d !== void 0 ? _d : {};
                const currentBalKobo = typeof wData["mainWalletBalance"] === "number"
                    ? Math.round(wData["mainWalletBalance"] * 100)
                    : (typeof wData["balance"] === "number" ? Math.round(wData["balance"]) : 0);
                const maxBalanceKobo = Math.round(maxAccountBalance * 100);
                if (currentBalKobo + amountKobo > maxBalanceKobo) {
                    throw new https_1.HttpsError("failed-precondition", `Max balance ₦${maxAccountBalance.toLocaleString("en-NG")}`);
                }
            }
        }
        catch (e) {
            if (e instanceof https_1.HttpsError)
                throw e;
            console.warn(`[initializePayment] wallet balance check warning: ${e}`);
        }
        // 3. Daily Top-Up Frequency (Max times per 24 hours)
        try {
            const oneDayAgo = new Date(Date.now() - 24 * 60 * 60 * 1000);
            const dailyTopUpsSnap = await db()
                .collection("payment_intents")
                .where("userId", "==", uid)
                .where("purpose", "==", "wallet_topup")
                .where("createdAt", ">=", oneDayAgo)
                .get();
            if (dailyTopUpsSnap.size >= dailyTopUpFrequency) {
                throw new https_1.HttpsError("resource-exhausted", "Daily limit reached");
            }
        }
        catch (e) {
            if (e instanceof https_1.HttpsError)
                throw e;
            console.warn(`[initializePayment] daily frequency check warning: ${e}`);
        }
    }
    const tripId = typeof d.tripId === "string" ? d.tripId.trim() : "";
    if (purpose === "trip_payment" && !tripId) {
        throw new https_1.HttpsError("invalid-argument", "tripId is required for trip payments.");
    }
    const email = (_e = request.auth.token.email) !== null && _e !== void 0 ? _e : (typeof d.email === "string" ? d.email.trim() : "");
    if (!email || !email.includes("@")) {
        throw new https_1.HttpsError("invalid-argument", "A valid email is required for the receipt.");
    }
    const reference = newReference(uid);
    const intentRef = db().collection("payment_intents").doc(reference);
    await intentRef.set({
        reference,
        userId: uid,
        email,
        amountKobo,
        currency: "NGN",
        purpose,
        tripId: tripId || null,
        status: "INITIALIZED",
        paystackAccessCode: null,
        paystackReference: null,
        createdAt: admin.firestore.FieldValue.serverTimestamp(),
        updatedAt: admin.firestore.FieldValue.serverTimestamp(),
    });
    let accessCode = "";
    let authorizationUrl = "";
    try {
        const data = await paystackPost("/transaction/initialize", {
            email,
            amount: amountKobo,
            currency: "NGN",
            reference,
            metadata: {
                userId: uid,
                amount: amountKobo,
                transactionType: "wallet_topup",
                purpose,
            },
        }, secret);
        accessCode = String((_f = data["access_code"]) !== null && _f !== void 0 ? _f : "");
        authorizationUrl = String((_g = data["authorization_url"]) !== null && _g !== void 0 ? _g : "");
        if (!authorizationUrl) {
            throw new https_1.HttpsError("internal", "Paystack returned no checkout URL.");
        }
        await intentRef.update({
            status: "PENDING",
            paystackAccessCode: accessCode,
            updatedAt: admin.firestore.FieldValue.serverTimestamp(),
        });
    }
    catch (e) {
        await intentRef.update({
            status: "FAILED",
            failureReason: e instanceof Error ? e.message : String(e),
            updatedAt: admin.firestore.FieldValue.serverTimestamp(),
        });
        throw e;
    }
    return { authorizationUrl, accessCode, reference };
});
/** Alias export for initializePayment */
exports.initializePaystackTopUp = exports.initializePayment;
/**
 * Settles a PENDING intent after a successful Paystack verification.
 * Idempotent: concurrent callers (verify callable + webhook) settle once —
 * the Firestore transaction bails when the intent is already SUCCEEDED.
 * Returns `{ settled: boolean, creditedKobo: number }`.
 */
async function settleIntent(reference, verifiedAmountKobo) {
    const intentRef = db().collection("payment_intents").doc(reference);
    const ledgerRef = db().collection("wallet_ledger").doc(reference);
    return db().runTransaction(async (tx) => {
        var _a, _b, _c, _d, _e;
        // ── Idempotency Check (wallet_ledger) ──────────────────────────────
        const ledgerSnap = await tx.get(ledgerRef);
        if (ledgerSnap.exists) {
            console.log(`[payments] Duplicate webhook / settlement processing blocked for ledger: ${reference}`);
            return { settled: false, creditedKobo: 0 };
        }
        const snap = await tx.get(intentRef);
        if (!snap.exists) {
            throw new https_1.HttpsError("not-found", "Payment reference not found.");
        }
        const intent = snap.data();
        if (intent["status"] === "SUCCEEDED") {
            return { settled: false, creditedKobo: 0 };
        }
        if (intent["status"] !== "PENDING" && intent["status"] !== "INITIALIZED") {
            throw new https_1.HttpsError("failed-precondition", "This payment is no longer payable.");
        }
        const expected = Number((_a = intent["amountKobo"]) !== null && _a !== void 0 ? _a : 0);
        if (verifiedAmountKobo !== expected) {
            throw new https_1.HttpsError("data-loss", "Paid amount does not match the payment request.");
        }
        const uid = String((_b = intent["userId"]) !== null && _b !== void 0 ? _b : "");
        if (!uid) {
            throw new https_1.HttpsError("data-loss", "Payment intent has no owner.");
        }
        const walletRef = db().collection("wallets").doc(uid);
        // ── Automatic split-debt recovery ──────────────────────────────────
        // Trusted split partners may settle into a negative balance (see
        // `settleSplitPayment`, tracked as `users/{uid}.splitStats.splitDebtKobo`).
        // The next self-funding repays it first: up to the outstanding debt is
        // diverted from this credit before it lands. Same-transaction reads, so
        // a racing spend cannot dodge the diversion.
        let creditKobo = verifiedAmountKobo;
        let recoveredKobo = 0;
        try {
            const userSnap = await tx.get(db().collection("users").doc(uid));
            const statsRaw = ((_d = (_c = userSnap.data()) === null || _c === void 0 ? void 0 : _c.splitStats) !== null && _d !== void 0 ? _d : {});
            const debt = typeof statsRaw.splitDebtKobo === "number" && Number.isFinite(statsRaw.splitDebtKobo)
                ? Math.max(0, Math.floor(statsRaw.splitDebtKobo))
                : 0;
            if (debt > 0) {
                recoveredKobo = Math.min(debt, verifiedAmountKobo);
                creditKobo = verifiedAmountKobo - recoveredKobo;
                tx.set(db().collection("users").doc(uid), {
                    splitStats: {
                        splitDebtKobo: admin.firestore.FieldValue.increment(-recoveredKobo),
                    },
                }, { merge: true });
            }
        }
        catch (e) {
            // Fail open toward the user: a stats-read failure must never block a
            // paid-for top-up. The debt simply waits for the next funding.
            console.warn(`verifyPayment: debt-recovery skipped for ${uid}: ${e}`);
            creditKobo = verifiedAmountKobo;
            recoveredKobo = 0;
        }
        tx.set(walletRef, {
            userId: uid,
            balance: admin.firestore.FieldValue.increment(creditKobo),
            mainWalletBalance: admin.firestore.FieldValue.increment(creditKobo / 100),
            currency: "NGN",
            updatedAt: admin.firestore.FieldValue.serverTimestamp(),
        }, { merge: true });
        const txRef = walletRef.collection("transactions").doc();
        tx.set(txRef, {
            type: intent["purpose"] === "trip_payment" ? "trip_payment" : "wallet_topup",
            role: intent["role"] || "customer",
            amountKobo: verifiedAmountKobo,
            amount: verifiedAmountKobo / 100,
            status: "success",
            currency: "NGN",
            paymentReference: reference,
            tripId: (_e = intent["tripId"]) !== null && _e !== void 0 ? _e : null,
            createdAt: admin.firestore.FieldValue.serverTimestamp(),
        });
        if (recoveredKobo > 0) {
            tx.set(walletRef.collection("transactions").doc(), {
                type: "SPLIT_DEBT_RECOVERY",
                amountKobo: -recoveredKobo,
                amount: -recoveredKobo / 100,
                status: "success",
                currency: "NGN",
                note: `Recovered ₦${(recoveredKobo / 100).toLocaleString("en-NG")} of split debt from this top-up.`,
                createdAt: admin.firestore.FieldValue.serverTimestamp(),
            });
        }
        tx.update(intentRef, {
            status: "SUCCEEDED",
            settledAt: admin.firestore.FieldValue.serverTimestamp(),
            updatedAt: admin.firestore.FieldValue.serverTimestamp(),
        });
        tx.set(ledgerRef, {
            status: "success",
            reference,
            userId: uid,
            amountKobo: verifiedAmountKobo,
            timestamp: admin.firestore.FieldValue.serverTimestamp(),
        });
        return { settled: true, creditedKobo: verifiedAmountKobo };
    });
}
/**
 * Callable: verifies the caller's payment with Paystack and credits the
 * wallet on success. Safe to call repeatedly (second call reports
 * `{ settled: false }`).
 */
exports.verifyPayment = (0, https_1.onCall)(async (request) => {
    var _a, _b, _c, _d, _e;
    if (!request.auth) {
        throw new https_1.HttpsError("unauthenticated", "You must sign in.");
    }
    // ── Security gates ────────────────────────────────────────────────────────
    (0, accountGuard_1.enforceAppCheck)(request);
    await (0, accountGuard_1.requireAccountActive)(request.auth.uid, "customer");
    const reference = String((_b = (_a = request.data) === null || _a === void 0 ? void 0 : _a.reference) !== null && _b !== void 0 ? _b : "").trim();
    if (!reference) {
        throw new https_1.HttpsError("invalid-argument", "reference is required.");
    }
    const intentSnap = await db()
        .collection("payment_intents")
        .doc(reference)
        .get();
    if (!intentSnap.exists) {
        throw new https_1.HttpsError("not-found", "Payment reference not found.");
    }
    if (intentSnap.data()["userId"] !== request.auth.uid) {
        throw new https_1.HttpsError("permission-denied", "Not your payment.");
    }
    const secret = await paystackSecret();
    const data = await paystackGet(`/transaction/verify/${encodeURIComponent(reference)}`, secret);
    if (data["status"] !== "success") {
        await intentSnap.ref.update({
            status: "FAILED",
            failureReason: `Paystack status: ${String((_c = data["status"]) !== null && _c !== void 0 ? _c : "unknown")}`,
            updatedAt: admin.firestore.FieldValue.serverTimestamp(),
        });
        throw new https_1.HttpsError("failed-precondition", "Payment was not successful. No money was taken from your wallet flow.");
    }
    if (String((_d = data["currency"]) !== null && _d !== void 0 ? _d : "NGN") !== "NGN") {
        throw new https_1.HttpsError("data-loss", "Unexpected payment currency.");
    }
    const paidKobo = Number((_e = data["amount"]) !== null && _e !== void 0 ? _e : 0);
    return settleIntent(reference, paidKobo);
});
/**
 * HTTPS webhook: `charge.success` settlement + `transfer.success` /
 * `transfer.failed` payout settlement, all driven by Paystack.
 * Verifies the `x-paystack-signature` HMAC before trusting the payload.
 * Configure the URL in the Paystack dashboard (Settings → Webhooks).
 *
 * Transfer events settle `payout_requests` rows written by
 * `processWalletWithdrawal`, via the shared idempotent `settleTransfer`.
 * This is the single HMAC-verified ingress for all Paystack events; the old
 * token-guarded `transferWebhook` callable is deleted.
 */
exports.paystackWebhook = (0, https_1.onRequest)(async (req, res) => {
    var _a, _b, _c, _d, _e, _f, _g, _h, _j, _k;
    if (req.method !== "POST") {
        res.status(405).send("Method not allowed");
        return;
    }
    let secret = "";
    try {
        secret = await paystackSecret();
    }
    catch (e) {
        console.error("paystackWebhook secret error:", e);
        res.status(500).send("Payments not configured");
        return;
    }
    const signature = String((_a = req.headers["x-paystack-signature"]) !== null && _a !== void 0 ? _a : "");
    const rawBody = (_b = req.rawBody) !== null && _b !== void 0 ? _b : Buffer.from(JSON.stringify((_c = req.body) !== null && _c !== void 0 ? _c : {}));
    const expected = (0, node_crypto_1.createHmac)("sha512", secret).update(rawBody).digest("hex");
    const sigBuf = Buffer.from(signature, "hex");
    const expBuf = Buffer.from(expected, "hex");
    if (!signature ||
        sigBuf.length === 0 ||
        sigBuf.length !== expBuf.length ||
        !(0, node_crypto_1.timingSafeEqual)(sigBuf, expBuf)) {
        res.status(401).send("Invalid signature");
        return;
    }
    const event = ((_d = req.body) !== null && _d !== void 0 ? _d : {});
    try {
        if (event.event === "charge.success" && event.data) {
            const reference = String((_e = event.data["reference"]) !== null && _e !== void 0 ? _e : "");
            const amountKobo = Number((_f = event.data["amount"]) !== null && _f !== void 0 ? _f : 0);
            if (reference && amountKobo > 0) {
                await settleIntent(reference, amountKobo);
            }
        }
        else if (event.event === "transfer.success" && event.data) {
            // `reference` is the payout requestId we set on the transfer.
            const reference = String((_g = event.data["reference"]) !== null && _g !== void 0 ? _g : "");
            if (reference) {
                await (0, payouts_1.settleTransfer)(reference, "success", "");
            }
        }
        else if (event.event === "transfer.failed" && event.data) {
            const reference = String((_h = event.data["reference"]) !== null && _h !== void 0 ? _h : "");
            const reason = String((_k = (_j = event.data["gateway_response"]) !== null && _j !== void 0 ? _j : event.data["reason"]) !== null && _k !== void 0 ? _k : "Transfer failed at the bank.");
            if (reference) {
                await (0, payouts_1.settleTransfer)(reference, "failed", reason);
            }
        }
        res.status(200).send("ok");
    }
    catch (e) {
        console.error(`paystackWebhook settlement failed: ${e}`);
        res.status(500).send("Internal settlement error");
    }
});
/**
 * Triggers an automated Paystack charge using a stored reusable card authorization code.
 * Used when a trip with card payment method transitions to IN_PROGRESS.
 */
async function chargePaystackCardAuthorization(req) {
    var _a, _b, _c, _d, _e, _f, _g, _h;
    const { uid, tripId, amountNaira } = req;
    if (!uid || amountNaira <= 0) {
        return { success: false, failureReason: "INVALID_CHARGE_PARAMETERS" };
    }
    try {
        const userSnap = await db().collection("users").doc(uid).get();
        const walletSnap = await db().collection("wallets").doc(uid).get();
        const uData = userSnap.exists ? userSnap.data() : {};
        const wData = walletSnap.exists ? walletSnap.data() : {};
        const authCode = String((_c = (_b = (_a = uData["paystackAuthorizationCode"]) !== null && _a !== void 0 ? _a : wData["paystackAuthorizationCode"]) !== null && _b !== void 0 ? _b : uData["paystackAuthCode"]) !== null && _c !== void 0 ? _c : "").trim();
        const email = String((_e = (_d = uData["email"]) !== null && _d !== void 0 ? _d : uData["emailAddress"]) !== null && _e !== void 0 ? _e : `${uid}@sese.app`).trim();
        if (!authCode) {
            return { success: false, failureReason: "NO_STORED_CARD" };
        }
        const secret = await paystackSecret();
        const reference = newReference(uid);
        const amountKobo = Math.round(amountNaira * 100);
        const data = await paystackPost("/transaction/charge_authorization", {
            authorization_code: authCode,
            email,
            amount: amountKobo,
            reference,
            currency: "NGN",
            metadata: { tripId, purpose: "automated_trip_card_charge" },
        }, secret);
        const status = String((_f = data["status"]) !== null && _f !== void 0 ? _f : "");
        if (status === "success") {
            return { success: true, reference };
        }
        return {
            success: false,
            failureReason: String((_g = data["gateway_response"]) !== null && _g !== void 0 ? _g : "CARD_CHARGE_FAILED"),
        };
    }
    catch (e) {
        console.warn(`chargePaystackCardAuthorization error for trip ${tripId}: ${e}`);
        return {
            success: false,
            failureReason: (_h = e === null || e === void 0 ? void 0 : e.message) !== null && _h !== void 0 ? _h : String(e),
        };
    }
}
//# sourceMappingURL=payments.js.map