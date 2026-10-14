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
const admin = __importStar(require("firebase-admin"));
const node_crypto_1 = require("node:crypto");
const https_1 = require("firebase-functions/v2/https");
const payouts_1 = require("./payouts");
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
    var _a, _b, _c;
    const envSecret = (_a = process.env.PAYSTACK_API_KEY) !== null && _a !== void 0 ? _a : process.env.PAYSTACK_SECRET_KEY;
    if (envSecret && envSecret.trim()) {
        return envSecret.trim();
    }
    const docPaths = [
        "system_config/remote_keys",
        "system_config/financial",
        "system_config/keys",
        "system_configs/global_default",
    ];
    for (const docPath of docPaths) {
        try {
            const snap = await db().doc(docPath).get();
            if (snap.exists) {
                const data = snap.data();
                if (data) {
                    const raw = (_c = (_b = data.paystackSecretKey) !== null && _b !== void 0 ? _b : data.paystack_secret_key) !== null && _c !== void 0 ? _c : data.secret_key;
                    if (typeof raw === "string" && raw.trim()) {
                        return raw.trim();
                    }
                }
            }
        }
        catch (e) {
            console.error(`Failed to read ${docPath} for paystackSecretKey:`, e);
        }
    }
    // No valid secret anywhere: fail fast with a machine-readable code instead
    // of calling Paystack with a dead key (which surfaces as a confusing
    // "Invalid key"). Rotate/paste the current test secret from the Paystack
    // dashboard into `functions/.env` as PAYSTACK_API_KEY and redeploy.
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
    var _a, _b, _c, _d;
    if (!request.auth) {
        throw new https_1.HttpsError("unauthenticated", "You must sign in to pay.");
    }
    const uid = request.auth.uid;
    const secret = await paystackSecret();
    const d = (_a = request.data) !== null && _a !== void 0 ? _a : {};
    const amountKobo = typeof d.amountKobo === "number" ? Math.round(d.amountKobo) : NaN;
    if (!Number.isFinite(amountKobo) || amountKobo < MIN_AMOUNT_KOBO) {
        throw new https_1.HttpsError("invalid-argument", "Minimum payment is ₦100. Enter a valid amount.");
    }
    if (amountKobo > MAX_AMOUNT_KOBO) {
        throw new https_1.HttpsError("invalid-argument", "Maximum payment per transaction is ₦500,000.");
    }
    const purpose = d.purpose === "trip_payment" ? "trip_payment" : "wallet_topup";
    const tripId = typeof d.tripId === "string" ? d.tripId.trim() : "";
    if (purpose === "trip_payment" && !tripId) {
        throw new https_1.HttpsError("invalid-argument", "tripId is required for trip payments.");
    }
    const email = (_b = request.auth.token.email) !== null && _b !== void 0 ? _b : (typeof d.email === "string" ? d.email.trim() : "");
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
        accessCode = String((_c = data["access_code"]) !== null && _c !== void 0 ? _c : "");
        authorizationUrl = String((_d = data["authorization_url"]) !== null && _d !== void 0 ? _d : "");
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
    return db().runTransaction(async (tx) => {
        var _a, _b, _c, _d, _e;
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
    if (!signature || signature !== expected) {
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
        // Return 200 anyway for unknown references so Paystack stops retrying
        // poison events; real mismatches are already logged above.
        res.status(200).send("ok");
    }
});
//# sourceMappingURL=payments.js.map