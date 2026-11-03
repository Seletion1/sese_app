"use strict";
/**
 * financialLimits.ts — Server-enforced financial limits engine.
 *
 * Enforces role-based (Customer, Driver, Hub Admin) and KYC-tiered limits for:
 *   1. Single-transaction top-up caps (Customer/Driver: max ₦20,000 | Hub Admin: max ₦50,000)
 *   2. Daily top-up frequency caps (e.g. max 5 attempts/day)
 *   3. Overall wallet balance caps (Customer/Driver: max ₦20,000 unverified / ₦50,000 verified)
 *   4. Daily P2P send limits (Customer/Driver: ₦5,000 unverified / ₦15,000 verified | Hub Admin: ₦10,000 / ₦50,000)
 *   5. Daily withdrawal limits (Customer: ₦10,000 unverified / ₦25,000 verified | Driver: ₦15,000 / ₦35,000 | Hub Admin: ₦20,000 / ₦50,000)
 *   6. Dynamic multi-currency conversion via Exchange API
 *   7. Automated daily reset at 00:00 local time (keyed by local timezone date `YYYY-MM-DD`).
 */
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
exports.scheduledDailyLimitsReset = exports.getUserFinancialLimits = exports.DEFAULT_FINANCIAL_LIMITS = void 0;
exports.getFinancialLimits = getFinancialLimits;
exports.getUserFinancialProfile = getUserFinancialProfile;
exports.getLocalDateKey = getLocalDateKey;
exports.getExchangeRates = getExchangeRates;
exports.convertToKobo = convertToKobo;
exports.formatKoboInCurrency = formatKoboInCurrency;
exports.getDailyUsage = getDailyUsage;
exports.assertTopUpAllowed = assertTopUpAllowed;
exports.assertWithdrawalAllowed = assertWithdrawalAllowed;
exports.assertP2pTransferAllowed = assertP2pTransferAllowed;
exports.recordDailyUsage = recordDailyUsage;
const admin = __importStar(require("firebase-admin"));
const https_1 = require("firebase-functions/v2/https");
const scheduler_1 = require("firebase-functions/v2/scheduler");
const accountGuard_1 = require("./accountGuard");
const db = () => admin.firestore();
exports.DEFAULT_FINANCIAL_LIMITS = {
    // Customer defaults (in Kobo, 100 Kobo = ₦1)
    customerMinTopUpKobo: 10000, // ₦100
    customerMaxSingleTopUpKobo: 2000000, // ₦20,000
    customerMaxDailyTopUpCount: 5,
    customerMaxWalletBalanceUnverifiedKobo: 2000000, // ₦20,000
    customerMaxWalletBalanceVerifiedKobo: 5000000, // ₦50,000
    customerMaxDailyP2pUnverifiedKobo: 500000, // ₦5,000
    customerMaxDailyP2pVerifiedKobo: 1500000, // ₦15,000
    customerMaxDailyWithdrawalUnverifiedKobo: 1000000, // ₦10,000
    customerMaxDailyWithdrawalVerifiedKobo: 2500000, // ₦25,000
    // Driver defaults
    driverMinTopUpKobo: 10000, // ₦100
    driverMaxSingleTopUpKobo: 2000000, // ₦20,000
    driverMaxDailyTopUpCount: 5,
    driverMaxWalletBalanceUnverifiedKobo: 2000000, // ₦20,000
    driverMaxWalletBalanceVerifiedKobo: 5000000, // ₦50,000
    driverMaxDailyP2pUnverifiedKobo: 500000, // ₦5,000
    driverMaxDailyP2pVerifiedKobo: 1500000, // ₦15,000
    driverMaxDailyWithdrawalUnverifiedKobo: 1500000, // ₦15,000
    driverMaxDailyWithdrawalVerifiedKobo: 3500000, // ₦35,000
    // Hub Admin defaults
    hubAdminMinTopUpKobo: 10000, // ₦100
    hubAdminMaxSingleTopUpKobo: 5000000, // ₦50,000
    hubAdminMaxDailyTopUpCount: 15,
    hubAdminMaxWalletBalanceKobo: 5000000, // ₦50,000
    hubAdminMaxDailyP2pKobo: 1000000, // ₦10,000
    hubAdminMaxDailyWithdrawalKobo: 2000000, // ₦20,000
    minWithdrawalKobo: 10000, // ₦100
    minP2pTransferKobo: 10000, // ₦100
};
/**
 * Reads dynamic financial limits from `/system_config/financial_limits`,
 * falling back safely to default limits.
 */
async function getFinancialLimits(tx) {
    if (!admin.apps.length)
        return exports.DEFAULT_FINANCIAL_LIMITS;
    const ref = db().collection("system_config").doc("financial_limits");
    try {
        const snap = tx ? await tx.get(ref) : await ref.get();
        if (!snap.exists)
            return exports.DEFAULT_FINANCIAL_LIMITS;
        const d = snap.data() || {};
        const toKobo = (val, fallbackNaira) => {
            const num = typeof val === "number" ? val : fallbackNaira;
            return Math.round(num * 100);
        };
        const toInt = (val, fallback) => {
            return typeof val === "number" ? Math.floor(val) : fallback;
        };
        return {
            customerMinTopUpKobo: toKobo(d.customerMinTopUp, 100),
            customerMaxSingleTopUpKobo: toKobo(d.customerMaxSingleTopUp, 20000),
            customerMaxDailyTopUpCount: toInt(d.customerMaxDailyTopUpCount, 5),
            customerMaxWalletBalanceUnverifiedKobo: toKobo(d.customerMaxWalletBalanceUnverified, 20000),
            customerMaxWalletBalanceVerifiedKobo: toKobo(d.customerMaxWalletBalanceVerified, 50000),
            customerMaxDailyP2pUnverifiedKobo: toKobo(d.customerMaxDailyP2pUnverified, 5000),
            customerMaxDailyP2pVerifiedKobo: toKobo(d.customerMaxDailyP2pVerified, 15000),
            customerMaxDailyWithdrawalUnverifiedKobo: toKobo(d.customerMaxDailyWithdrawalUnverified, 10000),
            customerMaxDailyWithdrawalVerifiedKobo: toKobo(d.customerMaxDailyWithdrawalVerified, 25000),
            driverMinTopUpKobo: toKobo(d.driverMinTopUp, 100),
            driverMaxSingleTopUpKobo: toKobo(d.driverMaxSingleTopUp, 20000),
            driverMaxDailyTopUpCount: toInt(d.driverMaxDailyTopUpCount, 5),
            driverMaxWalletBalanceUnverifiedKobo: toKobo(d.driverMaxWalletBalanceUnverified, 20000),
            driverMaxWalletBalanceVerifiedKobo: toKobo(d.driverMaxWalletBalanceVerified, 50000),
            driverMaxDailyP2pUnverifiedKobo: toKobo(d.driverMaxDailyP2pUnverified, 5000),
            driverMaxDailyP2pVerifiedKobo: toKobo(d.driverMaxDailyP2pVerified, 15000),
            driverMaxDailyWithdrawalUnverifiedKobo: toKobo(d.driverMaxDailyWithdrawalUnverified, 15000),
            driverMaxDailyWithdrawalVerifiedKobo: toKobo(d.driverMaxDailyWithdrawalVerified, 35000),
            hubAdminMinTopUpKobo: toKobo(d.hubAdminMinTopUp, 100),
            hubAdminMaxSingleTopUpKobo: toKobo(d.hubAdminMaxSingleTopUp, 50000),
            hubAdminMaxDailyTopUpCount: toInt(d.hubAdminMaxDailyTopUpCount, 15),
            hubAdminMaxWalletBalanceKobo: toKobo(d.hubAdminMaxWalletBalance, 50000),
            hubAdminMaxDailyP2pKobo: toKobo(d.hubAdminMaxDailyP2p, 10000),
            hubAdminMaxDailyWithdrawalKobo: toKobo(d.hubAdminMaxDailyWithdrawal, 20000),
            minWithdrawalKobo: toKobo(d.minWithdrawalAmount, 100),
            minP2pTransferKobo: toKobo(d.minP2pTransferAmount, 100),
        };
    }
    catch (e) {
        console.warn(`getFinancialLimits failed, using defaults: ${e}`);
        return exports.DEFAULT_FINANCIAL_LIMITS;
    }
}
/**
 * Resolves the user's role, KYC verification status, and local timezone.
 */
async function getUserFinancialProfile(uid, tx) {
    var _a, _b, _c, _d;
    const userRef = db().collection("users").doc(uid);
    const driverRef = db().collection("drivers").doc(uid);
    const [userSnap, driverSnap] = await Promise.all([
        tx ? tx.get(userRef) : userRef.get(),
        tx ? tx.get(driverRef) : driverRef.get(),
    ]);
    const userData = userSnap.exists ? userSnap.data() || {} : {};
    const driverData = driverSnap.exists ? driverSnap.data() || {} : {};
    // Check role
    const rawRole = String((_b = (_a = userData.role) !== null && _a !== void 0 ? _a : driverData.role) !== null && _b !== void 0 ? _b : "").toLowerCase();
    let role = "customer";
    if (rawRole === "admin" ||
        rawRole === "super_admin" ||
        rawRole === "operations_admin" ||
        rawRole === "hub_admin" ||
        userData.isAdmin === true) {
        role = "hub_admin";
    }
    else if (driverSnap.exists || rawRole === "driver") {
        role = "driver";
    }
    // Check KYC status
    const isUserKyc = userData.kycStatus === "verified" ||
        userData.isKycVerified === true ||
        userData.isVerified === true ||
        userData.bvnVerified === true ||
        userData.ninVerified === true;
    const isDriverKyc = driverData.isVerified === true ||
        driverData.verificationStatus === "APPROVED" ||
        driverData.verificationStatus === "verified";
    const isKycVerified = role === "driver" ? isDriverKyc : (isUserKyc || isDriverKyc);
    // Timezone (defaults to Nigerian standard time: Africa/Lagos)
    const timezone = String((_d = (_c = userData.timezone) !== null && _c !== void 0 ? _c : driverData.timezone) !== null && _d !== void 0 ? _d : "Africa/Lagos").trim();
    return { role, isKycVerified, timezone };
}
/**
 * Generates local date key `YYYY-MM-DD` in the user's local timezone.
 * Resets automatically at 00:00 midnight in that timezone.
 */
function getLocalDateKey(timezone = "Africa/Lagos") {
    try {
        const formatter = new Intl.DateTimeFormat("en-CA", {
            timeZone: timezone,
            year: "numeric",
            month: "2-digit",
            day: "2-digit",
        });
        return formatter.format(new Date()); // Outputs YYYY-MM-DD
    }
    catch (_) {
        // Fallback if timezone string is invalid
        return new Date().toISOString().slice(0, 10);
    }
}
/**
 * Exchange rate cache & multi-currency conversion.
 */
const FALLBACK_RATES = {
    NGN: 1.0,
    USD: 0.00063,
    EUR: 0.00058,
    GBP: 0.00049,
    GHS: 0.0098,
    XOF: 0.38,
    XAF: 0.38,
    KES: 0.081,
    ZAR: 0.011,
    CAD: 0.00085,
    AUD: 0.00095,
};
async function getExchangeRates(tx) {
    var _a;
    if (!admin.apps.length)
        return FALLBACK_RATES;
    const ref = db().collection("system_config").doc("exchange_rates");
    try {
        const snap = tx ? await tx.get(ref) : await ref.get();
        if (snap.exists && ((_a = snap.data()) === null || _a === void 0 ? void 0 : _a.rates)) {
            return snap.data().rates;
        }
    }
    catch (e) {
        console.warn(`getExchangeRates fallback: ${e}`);
    }
    return FALLBACK_RATES;
}
/**
 * Converts any currency amount to equivalent base Kobo (integer).
 */
async function convertToKobo(amount, currency = "NGN", tx) {
    const code = currency.toUpperCase().trim();
    if (code === "NGN")
        return Math.round(amount * 100);
    const rates = await getExchangeRates(tx);
    const rate = rates[code];
    if (!rate || rate <= 0) {
        return Math.round(amount * 100);
    }
    // Rate expresses 1 NGN in target currency units.
    // E.g. $10 USD with rate 0.00063 -> 10 / 0.00063 NGN
    const ngnAmount = amount / rate;
    return Math.round(ngnAmount * 100);
}
/**
 * Converts Kobo (integer) to formatted display string in target currency.
 */
async function formatKoboInCurrency(kobo, currency = "NGN", tx) {
    var _a;
    const ngn = kobo / 100;
    const code = currency.toUpperCase().trim();
    if (code === "NGN") {
        return `₦${ngn.toLocaleString("en-NG", { maximumFractionDigits: 0 })}`;
    }
    const rates = await getExchangeRates(tx);
    const rate = (_a = rates[code]) !== null && _a !== void 0 ? _a : 1.0;
    const foreign = ngn * rate;
    return `${code} ${foreign.toLocaleString("en-US", {
        minimumFractionDigits: foreign < 10 ? 2 : 0,
        maximumFractionDigits: 2,
    })}`;
}
/**
 * Reads daily financial usage record for the specified user and date key.
 */
async function getDailyUsage(uid, dateKey, tx) {
    var _a, _b, _c, _d;
    const ref = db()
        .collection("wallets")
        .doc(uid)
        .collection("daily_usage")
        .doc(dateKey);
    const snap = tx ? await tx.get(ref) : await ref.get();
    if (!snap.exists) {
        return {
            topUpCount: 0,
            topUpKobo: 0,
            withdrawalKobo: 0,
            p2pSendKobo: 0,
            dateKey,
        };
    }
    const d = snap.data() || {};
    return {
        topUpCount: Number((_a = d.topUpCount) !== null && _a !== void 0 ? _a : 0),
        topUpKobo: Number((_b = d.topUpKobo) !== null && _b !== void 0 ? _b : 0),
        withdrawalKobo: Number((_c = d.withdrawalKobo) !== null && _c !== void 0 ? _c : 0),
        p2pSendKobo: Number((_d = d.p2pSendKobo) !== null && _d !== void 0 ? _d : 0),
        dateKey,
    };
}
// ── Financial Assertions (Zero-Trust Gateways) ───────────────────────────────
/**
 * Asserts that a proposed top-up passes single-transaction, frequency, and
 * overall wallet balance caps.
 */
async function assertTopUpAllowed(params) {
    var _a, _b;
    const { uid, amountKobo, currency = "NGN", tx } = params;
    const limits = await getFinancialLimits(tx);
    const profile = await getUserFinancialProfile(uid, tx);
    const dateKey = getLocalDateKey(profile.timezone);
    const dailyUsage = await getDailyUsage(uid, dateKey, tx);
    const walletRef = db().collection("wallets").doc(uid);
    const walletSnap = await tx.get(walletRef);
    const currentBalanceKobo = walletSnap.exists
        ? Number((_b = (_a = walletSnap.data()) === null || _a === void 0 ? void 0 : _a.balance) !== null && _b !== void 0 ? _b : 0)
        : 0;
    // 1. Min and Single Top-up Cap
    let minKobo = limits.customerMinTopUpKobo;
    let maxSingleKobo = limits.customerMaxSingleTopUpKobo;
    let maxDailyCount = limits.customerMaxDailyTopUpCount;
    let balanceCapKobo = profile.isKycVerified
        ? limits.customerMaxWalletBalanceVerifiedKobo
        : limits.customerMaxWalletBalanceUnverifiedKobo;
    if (profile.role === "driver") {
        minKobo = limits.driverMinTopUpKobo;
        maxSingleKobo = limits.driverMaxSingleTopUpKobo;
        maxDailyCount = limits.driverMaxDailyTopUpCount;
        balanceCapKobo = profile.isKycVerified
            ? limits.driverMaxWalletBalanceVerifiedKobo
            : limits.driverMaxWalletBalanceUnverifiedKobo;
    }
    else if (profile.role === "hub_admin") {
        minKobo = limits.hubAdminMinTopUpKobo;
        maxSingleKobo = limits.hubAdminMaxSingleTopUpKobo;
        maxDailyCount = limits.hubAdminMaxDailyTopUpCount;
        balanceCapKobo = limits.hubAdminMaxWalletBalanceKobo;
    }
    if (amountKobo < minKobo) {
        const minStr = await formatKoboInCurrency(minKobo, currency, tx);
        throw new https_1.HttpsError("invalid-argument", `Minimum top-up is ${minStr}. Please enter a higher amount.`);
    }
    if (amountKobo > maxSingleKobo) {
        const maxStr = await formatKoboInCurrency(maxSingleKobo, currency, tx);
        throw new https_1.HttpsError("invalid-argument", `Single top-up limit is ${maxStr}. To deposit more, split into separate transactions or complete KYC verification.`);
    }
    // 2. Daily Frequency Cap
    if (dailyUsage.topUpCount >= maxDailyCount) {
        throw new https_1.HttpsError("resource-exhausted", `You have reached the daily limit of ${maxDailyCount} top-up attempts. Limits reset at midnight (00:00 local time).`);
    }
    // 3. Overall Wallet Balance Cap
    if (currentBalanceKobo + amountKobo > balanceCapKobo) {
        const capStr = await formatKoboInCurrency(balanceCapKobo, currency, tx);
        const currStr = await formatKoboInCurrency(currentBalanceKobo, currency, tx);
        throw new https_1.HttpsError("failed-precondition", `This top-up would exceed your maximum wallet balance limit of ${capStr} (current balance: ${currStr}).` +
            (!profile.isKycVerified
                ? " Upgrade your account verification in Profile → Verification to unlock higher balance limits."
                : ""));
    }
}
/**
 * Asserts that a proposed withdrawal passes min floor and cumulative daily caps.
 */
async function assertWithdrawalAllowed(params) {
    const { uid, amountKobo, currency = "NGN", tx } = params;
    const limits = await getFinancialLimits(tx);
    const profile = await getUserFinancialProfile(uid, tx);
    const dateKey = getLocalDateKey(profile.timezone);
    const dailyUsage = await getDailyUsage(uid, dateKey, tx);
    let maxDailyKobo = profile.isKycVerified
        ? limits.customerMaxDailyWithdrawalVerifiedKobo
        : limits.customerMaxDailyWithdrawalUnverifiedKobo;
    if (profile.role === "driver") {
        maxDailyKobo = profile.isKycVerified
            ? limits.driverMaxDailyWithdrawalVerifiedKobo
            : limits.driverMaxDailyWithdrawalUnverifiedKobo;
    }
    else if (profile.role === "hub_admin") {
        maxDailyKobo = limits.hubAdminMaxDailyWithdrawalKobo;
    }
    if (amountKobo < limits.minWithdrawalKobo) {
        const minStr = await formatKoboInCurrency(limits.minWithdrawalKobo, currency, tx);
        throw new https_1.HttpsError("invalid-argument", `Minimum withdrawal is ${minStr}.`);
    }
    if (dailyUsage.withdrawalKobo + amountKobo > maxDailyKobo) {
        const maxStr = await formatKoboInCurrency(maxDailyKobo, currency, tx);
        const remKobo = Math.max(0, maxDailyKobo - dailyUsage.withdrawalKobo);
        const remStr = await formatKoboInCurrency(remKobo, currency, tx);
        throw new https_1.HttpsError("resource-exhausted", `Withdrawal exceeds your daily limit of ${maxStr} (${remStr} remaining today). Limits reset at midnight (00:00 local time).` +
            (!profile.isKycVerified
                ? " Complete identity verification to unlock higher daily limits."
                : ""));
    }
}
/**
 * Asserts that a proposed P2P send passes min floor, sender daily limits,
 * and recipient overall wallet balance caps.
 */
async function assertP2pTransferAllowed(params) {
    var _a, _b;
    const { senderUid, recipientUid, amountKobo, currency = "NGN", tx } = params;
    const limits = await getFinancialLimits(tx);
    const senderProfile = await getUserFinancialProfile(senderUid, tx);
    const recipientProfile = await getUserFinancialProfile(recipientUid, tx);
    const dateKey = getLocalDateKey(senderProfile.timezone);
    const senderDailyUsage = await getDailyUsage(senderUid, dateKey, tx);
    let maxDailyP2pKobo = senderProfile.isKycVerified
        ? limits.customerMaxDailyP2pVerifiedKobo
        : limits.customerMaxDailyP2pUnverifiedKobo;
    if (senderProfile.role === "driver") {
        maxDailyP2pKobo = senderProfile.isKycVerified
            ? limits.driverMaxDailyP2pVerifiedKobo
            : limits.driverMaxDailyP2pUnverifiedKobo;
    }
    else if (senderProfile.role === "hub_admin") {
        maxDailyP2pKobo = limits.hubAdminMaxDailyP2pKobo;
    }
    if (amountKobo < limits.minP2pTransferKobo) {
        const minStr = await formatKoboInCurrency(limits.minP2pTransferKobo, currency, tx);
        throw new https_1.HttpsError("invalid-argument", `Minimum transfer is ${minStr}.`);
    }
    if (senderDailyUsage.p2pSendKobo + amountKobo > maxDailyP2pKobo) {
        const maxStr = await formatKoboInCurrency(maxDailyP2pKobo, currency, tx);
        const remKobo = Math.max(0, maxDailyP2pKobo - senderDailyUsage.p2pSendKobo);
        const remStr = await formatKoboInCurrency(remKobo, currency, tx);
        throw new https_1.HttpsError("resource-exhausted", `Transfer exceeds your daily P2P limit of ${maxStr} (${remStr} remaining today). Limits reset at midnight (00:00 local time).` +
            (!senderProfile.isKycVerified
                ? " Complete account verification to unlock higher P2P limits."
                : ""));
    }
    // Recipient wallet balance cap
    const recipientWalletRef = db().collection("wallets").doc(recipientUid);
    const recipientWalletSnap = await tx.get(recipientWalletRef);
    const recipientBalanceKobo = recipientWalletSnap.exists
        ? Number((_b = (_a = recipientWalletSnap.data()) === null || _a === void 0 ? void 0 : _a.balance) !== null && _b !== void 0 ? _b : 0)
        : 0;
    let recipientCapKobo = recipientProfile.isKycVerified
        ? limits.customerMaxWalletBalanceVerifiedKobo
        : limits.customerMaxWalletBalanceUnverifiedKobo;
    if (recipientProfile.role === "driver") {
        recipientCapKobo = recipientProfile.isKycVerified
            ? limits.driverMaxWalletBalanceVerifiedKobo
            : limits.driverMaxWalletBalanceUnverifiedKobo;
    }
    else if (recipientProfile.role === "hub_admin") {
        recipientCapKobo = limits.hubAdminMaxWalletBalanceKobo;
    }
    if (recipientBalanceKobo + amountKobo > recipientCapKobo) {
        throw new https_1.HttpsError("failed-precondition", "Transfer cannot be completed because it would exceed the recipient's maximum wallet balance capacity.");
    }
}
/**
 * Atomically increments daily financial usage record within an active transaction.
 */
async function recordDailyUsage(params) {
    var _a;
    const { uid, type, amountKobo, tx } = params;
    const timezone = (_a = params.timezone) !== null && _a !== void 0 ? _a : "Africa/Lagos";
    const dateKey = getLocalDateKey(timezone);
    const ref = db()
        .collection("wallets")
        .doc(uid)
        .collection("daily_usage")
        .doc(dateKey);
    const updates = {
        dateKey,
        updatedAt: admin.firestore.FieldValue.serverTimestamp(),
    };
    if (type === "topup") {
        updates.topUpCount = admin.firestore.FieldValue.increment(1);
        updates.topUpKobo = admin.firestore.FieldValue.increment(amountKobo);
    }
    else if (type === "withdrawal") {
        updates.withdrawalKobo = admin.firestore.FieldValue.increment(amountKobo);
    }
    else if (type === "p2p_send") {
        updates.p2pSendKobo = admin.firestore.FieldValue.increment(amountKobo);
    }
    tx.set(ref, updates, { merge: true });
}
/**
 * Callable: Retrieves the caller's financial limits, KYC tier, usage today,
 * and remaining limits in their wallet currency.
 */
exports.getUserFinancialLimits = (0, https_1.onCall)(async (request) => {
    var _a, _b, _c, _d;
    if (!request.auth) {
        throw new https_1.HttpsError("unauthenticated", "Authentication required.");
    }
    (0, accountGuard_1.enforceAppCheck)(request);
    await (0, accountGuard_1.requireAccountActive)(request.auth.uid, "any");
    const uid = request.auth.uid;
    const profile = await getUserFinancialProfile(uid);
    const limits = await getFinancialLimits();
    const dateKey = getLocalDateKey(profile.timezone);
    const usage = await getDailyUsage(uid, dateKey);
    const walletSnap = await db().collection("wallets").doc(uid).get();
    const currentBalanceKobo = walletSnap.exists
        ? Number((_b = (_a = walletSnap.data()) === null || _a === void 0 ? void 0 : _a.balance) !== null && _b !== void 0 ? _b : 0)
        : 0;
    const currency = String((_d = (_c = walletSnap.data()) === null || _c === void 0 ? void 0 : _c.currency) !== null && _d !== void 0 ? _d : "NGN");
    let maxSingleTopUpKobo = limits.customerMaxSingleTopUpKobo;
    let maxDailyTopUpCount = limits.customerMaxDailyTopUpCount;
    let walletBalanceCapKobo = profile.isKycVerified
        ? limits.customerMaxWalletBalanceVerifiedKobo
        : limits.customerMaxWalletBalanceUnverifiedKobo;
    let maxDailyP2pKobo = profile.isKycVerified
        ? limits.customerMaxDailyP2pVerifiedKobo
        : limits.customerMaxDailyP2pUnverifiedKobo;
    let maxDailyWithdrawalKobo = profile.isKycVerified
        ? limits.customerMaxDailyWithdrawalVerifiedKobo
        : limits.customerMaxDailyWithdrawalUnverifiedKobo;
    if (profile.role === "driver") {
        maxSingleTopUpKobo = limits.driverMaxSingleTopUpKobo;
        maxDailyTopUpCount = limits.driverMaxDailyTopUpCount;
        walletBalanceCapKobo = profile.isKycVerified
            ? limits.driverMaxWalletBalanceVerifiedKobo
            : limits.driverMaxWalletBalanceUnverifiedKobo;
        maxDailyP2pKobo = profile.isKycVerified
            ? limits.driverMaxDailyP2pVerifiedKobo
            : limits.driverMaxDailyP2pUnverifiedKobo;
        maxDailyWithdrawalKobo = profile.isKycVerified
            ? limits.driverMaxDailyWithdrawalVerifiedKobo
            : limits.driverMaxDailyWithdrawalUnverifiedKobo;
    }
    else if (profile.role === "hub_admin") {
        maxSingleTopUpKobo = limits.hubAdminMaxSingleTopUpKobo;
        maxDailyTopUpCount = limits.hubAdminMaxDailyTopUpCount;
        walletBalanceCapKobo = limits.hubAdminMaxWalletBalanceKobo;
        maxDailyP2pKobo = limits.hubAdminMaxDailyP2pKobo;
        maxDailyWithdrawalKobo = limits.hubAdminMaxDailyWithdrawalKobo;
    }
    return {
        role: profile.role,
        isKycVerified: profile.isKycVerified,
        timezone: profile.timezone,
        dateKey,
        currency,
        currentBalanceKobo,
        limits: {
            maxSingleTopUpKobo,
            maxDailyTopUpCount,
            walletBalanceCapKobo,
            maxDailyP2pKobo,
            maxDailyWithdrawalKobo,
            minTopUpKobo: limits.customerMinTopUpKobo,
            minWithdrawalKobo: limits.minWithdrawalKobo,
            minP2pTransferKobo: limits.minP2pTransferKobo,
        },
        todayUsage: {
            topUpCount: usage.topUpCount,
            topUpKobo: usage.topUpKobo,
            withdrawalKobo: usage.withdrawalKobo,
            p2pSendKobo: usage.p2pSendKobo,
        },
        remaining: {
            remainingTopUpCount: Math.max(0, maxDailyTopUpCount - usage.topUpCount),
            remainingP2pKobo: Math.max(0, maxDailyP2pKobo - usage.p2pSendKobo),
            remainingWithdrawalKobo: Math.max(0, maxDailyWithdrawalKobo - usage.withdrawalKobo),
            remainingBalanceRoomKobo: Math.max(0, walletBalanceCapKobo - currentBalanceKobo),
        },
    };
});
/**
 * Scheduled job: Runs every night at 00:00 UTC.
 * Daily limits naturally reset at 00:00 local time because daily usage records
 * are partitioned by local date `YYYY-MM-DD`. This job sweeps daily tracking
 * records older than 14 days to keep database storage optimal.
 */
exports.scheduledDailyLimitsReset = (0, scheduler_1.onSchedule)({ schedule: "0 0 * * *", timeZone: "UTC" }, async () => {
    console.log("[financialLimits] scheduledDailyLimitsReset: local reset cycle active.");
    const cutoffDate = new Date(Date.now() - 14 * 24 * 60 * 60 * 1000)
        .toISOString()
        .slice(0, 10);
    try {
        const oldUsageQuery = await db()
            .collectionGroup("daily_usage")
            .where("dateKey", "<", cutoffDate)
            .limit(500)
            .get();
        if (!oldUsageQuery.empty) {
            const batch = db().batch();
            oldUsageQuery.docs.forEach((doc) => batch.delete(doc.ref));
            await batch.commit();
            console.log(`[financialLimits] Pruned ${oldUsageQuery.size} expired daily usage records older than ${cutoffDate}.`);
        }
    }
    catch (e) {
        console.warn(`[financialLimits] scheduledDailyLimitsReset sweep note: ${e}`);
    }
});
//# sourceMappingURL=financialLimits.js.map