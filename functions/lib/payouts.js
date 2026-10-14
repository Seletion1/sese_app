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
exports.processWalletWithdrawal = exports.resolveBankAccount = exports.verifyBankAccount = exports.paystackBanks = void 0;
exports.accountNameMatches = accountNameMatches;
exports.settleTransfer = settleTransfer;
const admin = __importStar(require("firebase-admin"));
const https_1 = require("firebase-functions/v2/https");
const transactionPin_1 = require("./transactionPin");
const db = () => admin.firestore();
const PAYSTACK_BASE = (_a = process.env.PAYSTACK_BASE_URL) !== null && _a !== void 0 ? _a : "https://api.paystack.co";
/** Minimum withdrawal: ₦100 (10,000 kobo). Mirrors MIN_AMOUNT_KOBO in payments.ts. */
const MIN_WITHDRAWAL_KOBO = 10000;
/** Ceiling per withdrawal: ₦500,000. Bounds blast radius of a bug or a hijack. */
const MAX_WITHDRAWAL_KOBO = 50000000;
function paystackSecret() {
    var _a;
    // NOTE: `PAYSTACK_SECRET_KEY` is still bound as a Secret Manager secret
    // on the live revisions (defineSecret era), and Cloud Run rejects a
    // plain env var that overlaps a secret binding (`Secret environment
    // variable overlaps non secret environment variable`). The plain `.env`
    // value therefore ships under `PAYSTACK_API_KEY`, which is preferred;
    // the legacy name remains as a fallback for emulators/local runs that
    // never had the stale binding. Clean up the binding (console/gcloud)
    // and this fallback can go.
    const secret = (_a = process.env.PAYSTACK_API_KEY) !== null && _a !== void 0 ? _a : process.env.PAYSTACK_SECRET_KEY;
    if (!secret) {
        throw new https_1.HttpsError("failed-precondition", "Withdrawals are not available right now. Please contact support.");
    }
    return secret;
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
/**
 * Normalises a name for comparison: uppercase, strip anything that is not a
 * letter (so "O'Brien-Adeniyi," and "OBRIEN ADENIYI" collapse together),
 * collapse whitespace.
 */
function normalizeName(raw) {
    return raw
        .toUpperCase()
        // Apostrophes are dropped with NO separator, so "O'Brien" and "OBRIEN"
        // are the same token. Hyphens become separators, because they usually join
        // two distinct name parts ("Adeniyi-Femi" ~ "ADENIYI FEMI"). Everything
        // else non-alphabetic also becomes a separator, so "Okonkwo, Adaeze" splits.
        .replace(/['’`]/g, "")
        .replace(/[^A-Z]+/g, " ")
        .trim()
        .replace(/\s+/g, " ");
}
/**
 * True when a Paystack-resolved account name plausibly belongs to the
 * registered profile name.
 *
 * Deliberately NOT exact string equality: banks reorder and expand names
 * ("ADAEZE BAKARE OKONKWO" for "Adaeze Okonkwo"), insert middle names, and
 * vary punctuation. An exact match would reject legitimate payouts.
 *
 * The rule is token-set containment: every token of the SHORTER name must
 * appear in the LONGER one. So a profile of "Adaeze Okonkwo" matches an
 * account of "ADAEZE BAKARE OKONKWO" (account is a superset), and vice versa.
 * A completely different person ("CHINEDU OBI") fails.
 *
 * Both directions are checked so that neither an empty profile name nor a
 * generic/unresolved account name can slip through.
 */
function accountNameMatches(profileName, accountName) {
    const profileTokens = dedupeTokens(profileName);
    const accountTokens = dedupeTokens(accountName);
    // Require at least two distinct name components on both sides. "JOHN" alone
    // is too weak an identity signal to authorise a money movement, and a
    // Paystack resolve that returns one token is usually a proxy/placeholder.
    if (profileTokens.length < 2 || accountTokens.length < 2)
        return false;
    const [shorter, longer] = profileTokens.length <= accountTokens.length
        ? [profileTokens, accountTokens]
        : [accountTokens, profileTokens];
    return shorter.every((t) => longer.includes(t));
}
/** Uppercased, de-punctuated, de-duplicated name components. */
function dedupeTokens(raw) {
    return Array.from(new Set(normalizeName(raw).split(" ").filter((t) => t.length > 0)));
}
/** The name on the caller's own profile, from whichever doc holds it. */
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
            // Try the next collection; a missing/denied doc is not fatal here.
        }
    }
    return "";
}
// ─── Callables ──────────────────────────────────────────────────────────────
/**
 * Callable: returns the Nigerian bank catalogue for the payout picker.
 * Cached briefly to keep the sheet snappy and to limit call volume.
 */
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
    const data = await paystackGet("/bank", paystackSecret());
    const banks = Array.isArray(data) ? data : [];
    bankCache = { at: now, banks };
    return { banks };
});
/**
 * Callable: resolves a Nigerian account number to its registered holder name.
 *
 * Read-only by design. The client shows the returned name for the user to
 * confirm, but the value is treated as UNTRUSTED input by
 * `processWalletWithdrawal`, which re-resolves server-side and never accepts a
 * client-supplied name.
 *
 * Exported as both `verifyBankAccount` and `resolveBankAccount` to support
 * both caller conventions.
 */
exports.verifyBankAccount = (0, https_1.onCall)(async (request) => {
    var _a, _b, _c, _d, _e, _f;
    if (!request.auth) {
        throw new https_1.HttpsError("unauthenticated", "You must sign in.");
    }
    const bankCode = String((_b = (_a = request.data) === null || _a === void 0 ? void 0 : _a.bankCode) !== null && _b !== void 0 ? _b : "").trim();
    const accountNumber = String((_d = (_c = request.data) === null || _c === void 0 ? void 0 : _c.accountNumber) !== null && _d !== void 0 ? _d : "").trim();
    if (!/^\d{3}$/.test(bankCode)) {
        throw new https_1.HttpsError("invalid-argument", "Select a bank first.");
    }
    if (!/^\d{10}$/.test(accountNumber)) {
        throw new https_1.HttpsError("invalid-argument", "Account number must be exactly 10 digits.");
    }
    const data = await paystackGet(`/bank/resolve?account_number=${encodeURIComponent(accountNumber)}&bank_code=${encodeURIComponent(bankCode)}`, paystackSecret());
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
 * Callable: debits the caller's wallet and transfers the money to their bank.
 *
 * Order of operations (the security-critical part):
 *   1. Authenticate the caller.
 *   2. Validate the amount against min/max and the caller's live balance.
 *   3. Re-resolve the account name server-side and check it against the
 *      registered profile name. A client cannot fake this: the name comes
 *      from Paystack, not from the request body.
 *   4. In one Firestore transaction: re-read the wallet, re-check
 *      sufficiency, decrement, and write the ledger + audit rows.
 *   5. Create the Paystack transfer recipient and initiate the transfer.
 *   6. On any failure after step 4, refund the debit.
 */
exports.processWalletWithdrawal = (0, https_1.onCall)(async (request) => {
    var _a, _b, _c, _d, _e, _f, _g, _h, _j, _k, _l;
    if (!request.auth) {
        throw new https_1.HttpsError("unauthenticated", "You must sign in.");
    }
    const uid = request.auth.uid;
    const secret = paystackSecret();
    // Transaction-PIN gate FIRST: verified server-side before the balance
    // is even re-read inside the debit transaction. Skipping the app prompt
    // buys a hostile client nothing.
    await (0, transactionPin_1.requireValidPin)(uid, (_a = request.data) === null || _a === void 0 ? void 0 : _a.transactionPin);
    // 1. Amount validation: supports both amountKobo and amount (Naira).
    // Hard ₦100 floor (10,000 kobo) / ₦500,000 ceiling.
    const rawKobo = ((_b = request.data) === null || _b === void 0 ? void 0 : _b.amountKobo) !== undefined
        ? Number(request.data.amountKobo)
        : ((_c = request.data) === null || _c === void 0 ? void 0 : _c.amount) !== undefined
            ? Number(request.data.amount) * 100
            : NaN;
    const amountKobo = Math.round(rawKobo);
    if (!Number.isFinite(amountKobo) || amountKobo < MIN_WITHDRAWAL_KOBO) {
        throw new https_1.HttpsError("invalid-argument", "Minimum withdrawal is ₦100.");
    }
    if (amountKobo > MAX_WITHDRAWAL_KOBO) {
        throw new https_1.HttpsError("invalid-argument", "Maximum withdrawal per request is ₦500,000.");
    }
    const bankCode = String((_e = (_d = request.data) === null || _d === void 0 ? void 0 : _d.bankCode) !== null && _e !== void 0 ? _e : "").trim();
    const accountNumber = String((_g = (_f = request.data) === null || _f === void 0 ? void 0 : _f.accountNumber) !== null && _g !== void 0 ? _g : "").trim();
    if (!/^\d{3}$/.test(bankCode)) {
        throw new https_1.HttpsError("invalid-argument", "Select a valid bank.");
    }
    if (!/^\d{10}$/.test(accountNumber)) {
        throw new https_1.HttpsError("invalid-argument", "Account number must be exactly 10 digits.");
    }
    // 2. Resolve the account name server-side (never trust the client's).
    const resolved = await paystackGet(`/bank/resolve?account_number=${encodeURIComponent(accountNumber)}&bank_code=${encodeURIComponent(bankCode)}`, secret);
    const accountName = String((_h = resolved["account_name"]) !== null && _h !== void 0 ? _h : "");
    if (!accountName) {
        throw new https_1.HttpsError("invalid-argument", "We could not verify that bank account. Check the number and bank.");
    }
    // 3. Identity check against the registered profile name.
    const registered = await registeredName(uid);
    if (!registered) {
        throw new https_1.HttpsError("failed-precondition", "Add your full name to your profile before withdrawing.");
    }
    if (!accountNameMatches(registered, accountName)) {
        throw new https_1.HttpsError("permission-denied", `This account is registered to a different name than your profile. `
            + `Update your profile name or use the account matching your profile.`);
    }
    // 4. Debit inside a transaction: the re-read + conditional decrement is
    //    the concurrency lock that stops two withdrawals racing the balance.
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
        if (!Number.isFinite(balanceKobo) || balanceKobo < amountKobo) {
            throw new https_1.HttpsError("failed-precondition", "Your balance is too low for this withdrawal.");
        }
        tx.update(walletRef, {
            balance: admin.firestore.FieldValue.increment(-amountKobo),
            updatedAt: admin.firestore.FieldValue.serverTimestamp(),
        });
        tx.set(ledgerRef, {
            type: "wallet_withdrawal",
            // `amount` is kobo to match every other ledger row in this collection
            // (payments.ts writes amountKobo here); the naira value is kept
            // alongside for readability.
            amount: amountKobo,
            amountKobo,
            amountNaira: amountKobo / 100,
            currency: "NGN",
            payoutRequestId: requestId,
            status: "pending",
            createdAt,
        });
        tx.set(requestRef, {
            requestId,
            userId: uid,
            driverId: uid,
            amountKobo,
            amountNaira: amountKobo / 100,
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
    // 5. Move the money. Any throw below is compensated by the refund path.
    try {
        const recipient = await paystackPost("/transferrecipient", {
            type: "nuban",
            name: accountName,
            account_number: accountNumber,
            bank_code: bankCode,
            currency: "NGN",
        }, secret);
        const recipientCode = String((_j = recipient["recipient_code"]) !== null && _j !== void 0 ? _j : "");
        if (!recipientCode) {
            throw new https_1.HttpsError("internal", "Paystack did not return a transfer recipient.");
        }
        const transfer = await paystackPost("/transfer", {
            source: "balance",
            // Paystack's `amount` is in kobo.
            amount: amountKobo,
            recipient: recipientCode,
            reason: "Sese Ride Wallet Payout",
            reference: requestId,
        }, secret);
        const transferReference = String((_k = transfer["reference"]) !== null && _k !== void 0 ? _k : "");
        const transferStatus = String((_l = transfer["status"]) !== null && _l !== void 0 ? _l : "");
        // `success` here means Paystack ACCEPTED the transfer, not that the
        // bank has paid out. The webhook settles the final state.
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
            amountKobo,
            status: settled ? "completed" : "pending",
            transferReference,
            accountName,
        };
    }
    catch (e) {
        // 6. Compensate: the debit already committed, so give the money back.
        const reason = e instanceof Error ? e.message : String(e);
        await db().runTransaction(async (tx) => {
            tx.update(walletRef, {
                balance: admin.firestore.FieldValue.increment(amountKobo),
                updatedAt: admin.firestore.FieldValue.serverTimestamp(),
            });
            tx.set(walletRef.collection("transactions").doc(`${requestId}_refund`), {
                type: "wallet_withdrawal_refund",
                amount: amountKobo,
                amountKobo,
                amountNaira: amountKobo / 100,
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
 * Settles a payout from Paystack's asynchronous transfer events.
 *
 * Idempotent: guarded on the request's current status so a retried webhook
 * cannot double-refund a failure or double-complete a success. Exported for
 * `paystackWebhook` (payments.ts), which is the single HMAC-verified ingress
 * for all Paystack events.
 */
async function settleTransfer(reference, outcome, reason) {
    const snap = await db().collection("payout_requests").doc(reference).get();
    if (!snap.exists)
        return;
    const row = snap.data();
    if (row["status"] === outcome)
        return;
    if (row["status"] === "refunded" && outcome === "success")
        return;
    const walletRef = db().collection("wallets").doc(String(row["userId"]));
    const ledgerRef = walletRef
        .collection("transactions")
        .doc(String(row["requestId"]));
    await db().runTransaction(async (tx) => {
        var _a;
        if (outcome === "success") {
            tx.update(snap.ref, {
                status: "completed",
                settledAt: admin.firestore.FieldValue.serverTimestamp(),
                updatedAt: admin.firestore.FieldValue.serverTimestamp(),
            });
            tx.update(ledgerRef, { status: "completed" });
            return;
        }
        // Failed AFTER the debit committed: refund it.
        const amountKobo = Number((_a = row["amountKobo"]) !== null && _a !== void 0 ? _a : 0);
        if (amountKobo > 0) {
            tx.update(walletRef, {
                balance: admin.firestore.FieldValue.increment(amountKobo),
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
        tx.update(snap.ref, {
            status: "refunded",
            failureReason: reason.slice(0, 500),
            settledAt: admin.firestore.FieldValue.serverTimestamp(),
            updatedAt: admin.firestore.FieldValue.serverTimestamp(),
        });
        tx.update(ledgerRef, { status: "refunded" });
    });
}
/**
 * REMOVED: `transferWebhook` used to exist here as a token-guarded callable
 * for Paystack transfer events. It is deleted because a shared-secret token
 * is strictly weaker than the HMAC signature Paystack already sends, and
 * running two ingress paths for one event source invites double-settlement
 * confusion. `paystackWebhook` (payments.ts) now handles `transfer.success`
 * and `transfer.failed` directly, verified by HMAC, calling the exported
 * `settleTransfer` above. If `firebase deploy` complains about an orphaned
 * `transferWebhook`, delete it once:
 * `firebase functions:delete transferWebhook --region us-central1 --force`.
 */
//# sourceMappingURL=payouts.js.map