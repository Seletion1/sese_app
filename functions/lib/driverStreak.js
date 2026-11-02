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
exports.scheduledResetStreaks = exports.onTripCancelled = exports.onTripCompleted = exports.L3_BONUS_RATES = exports.L1_RATES = void 0;
exports.nairaToKobo = nairaToKobo;
exports.resolveDriverTimeZone = resolveDriverTimeZone;
exports.localDateString = localDateString;
exports.isStreakEnabledForRegion = isStreakEnabledForRegion;
exports.computeCommission = computeCommission;
exports.applyStreakBreak = applyStreakBreak;
exports.logFinancialMutation = logFinancialMutation;
exports.persistFinancialAuditLogInTx = persistFinancialAuditLogInTx;
exports.persistFinancialAuditLog = persistFinancialAuditLog;
exports.logTripTransition = logTripTransition;
exports.persistTripChangeLogInTx = persistTripChangeLogInTx;
exports.persistTripChangeLog = persistTripChangeLog;
exports.handleTripCompletion = handleTripCompletion;
exports.handleTripCancellationSettlement = handleTripCancellationSettlement;
exports.breakDriverStreak = breakDriverStreak;
const admin = __importStar(require("firebase-admin"));
const https_1 = require("firebase-functions/v2/https");
const firestore_1 = require("firebase-functions/v2/firestore");
const scheduler_1 = require("firebase-functions/v2/scheduler");
const streakRewards_1 = require("./streakRewards");
/**
 * Dynamic Driver Daily Commission Tiering & Streak Gamification Engine
 *
 * 3-Level Mechanics (local-midnight reset per driver timezone —
 * hourly `scheduledResetStreaks` cron + lazy reset on trip events):
 *
 * LEVEL 1 — Step-Down Commission Discount
 *   Step 0: 15% | Step 1: 12.5% | Step 2: 10% | Step 3: 7.5%
 *   Step 4: 5%  | Step 5: 2.5%  | Step 6: 0%  → triggers Level 2
 *
 * LEVEL 2 — 0% Fee + Level 1 Cash-Back Recovery (reverse order)
 *   Step 0: refund L1.step5 (2.5% paid) | Step 1: refund L1.step4 (5%)
 *   Step 2: refund L1.step3 (7.5%)       | Step 3: refund L1.step2 (10%)
 *   Step 4: refund L1.step1 (12.5%)      | Step 5: refund L1.step0 (15%)
 *   → All 6 refunds done triggers Level 3
 *
 * LEVEL 3 — 0% Fee + Cash Bonus % of Current Trip Fare
 *   Step 0: 2.5% | Step 1: 5% | Step 2: 7.5% | Step 3: 10%
 *   Step 4: 12.5%| Step 5: 15%| Step 6: 20%  → Grand Award trigger
 *
 * BREAK TRIGGERS (streak drops/resets):
 *   - declineTrip (or ping expiry counted as decline)
 *   - Driver manual cancel BEFORE reaching DRIVER_ARRIVED status
 *
 * DROP-BACK RULES:
 *   L1 Step 0    → off-streak (flat base commission)
 *   L1 Step 1-6  → L1 Step 0 (15%)
 *   L2 Step 0    → L1 Step 0 (15%)
 *   L2 Step 1-5  → L2 Step 0
 *
 * STREAK PROTECTION (no penalty):
 *   - Customer cancels at any point
 *   - Driver at DRIVER_ARRIVED + waited ≥ noShowWaitMinutes + customer no-show
 */
const db = () => admin.firestore();
/**
 * NAIRA -> KOBO (integer minor units).
 *
 * The streak engine computes commission/cash-back in naira because it derives
 * them from the naira fare, but `wallets/{uid}.balance` is denominated in
 * kobo (see `payments.ts` and `PaymentService.walletBalanceKoboStream`).
 * Every naira amount must pass through here before it reaches the wallet.
 *
 * Rounded because a wallet balance must stay an exact integer; sub-kobo dust
 * from the rate ladder is dropped rather than carried as a float.
 */
function nairaToKobo(naira) {
    if (!Number.isFinite(naira))
        return 0;
    return Math.round(naira * 100);
}
// ─── Commission Rate Tables ─────────────────────────────────────────────────
/** Level 1 commission rates indexed by step (0-6). */
exports.L1_RATES = [0.15, 0.125, 0.10, 0.075, 0.05, 0.025, 0.0];
/** Level 3 bonus rates (added to driver wallet) indexed by step (0-6). */
exports.L3_BONUS_RATES = [0.025, 0.05, 0.075, 0.10, 0.125, 0.15, 0.20];
/** Country → IANA timezone for local-midnight reset computation. */
const COUNTRY_TIMEZONES = {
    NG: "Africa/Lagos",
    GH: "Africa/Accra",
    KE: "Africa/Nairobi",
    ZA: "Africa/Johannesburg",
    US: "America/New_York",
    GB: "Europe/London",
    CA: "America/Toronto",
};
/** Resolves the driver's IANA timezone (explicit doc field wins). */
function resolveDriverTimeZone(driverData) {
    var _a, _b;
    const explicit = driverData["timezone"];
    if (typeof explicit === "string" && explicit.trim())
        return explicit.trim();
    const country = String((_a = driverData["countryCode"]) !== null && _a !== void 0 ? _a : "NG").toUpperCase();
    return (_b = COUNTRY_TIMEZONES[country]) !== null && _b !== void 0 ? _b : "Africa/Lagos";
}
/** Local calendar date (YYYY-MM-DD) for `nowMs` in `timeZone`. */
function localDateString(timeZone, nowMs) {
    try {
        return new Intl.DateTimeFormat("en-CA", {
            timeZone,
            year: "numeric",
            month: "2-digit",
            day: "2-digit",
        }).format(new Date(nowMs));
    }
    catch (_a) {
        return new Date(nowMs).toISOString().slice(0, 10);
    }
}
async function resolveStreakConfig(countryCode, stateOrRegion) {
    const defaults = {
        streakEnabled: true,
        baseCommissionRate: 0.20,
        noShowWaitMinutes: 10,
        completionCashAward: 10000.0,
        disabledCountries: [],
        disabledStates: [],
    };
    // Walk the config hierarchy: state → country → global_default
    const docIds = [
        `state_${countryCode}_${stateOrRegion.toUpperCase().replace(/ /g, "_")}`,
        `country_${countryCode}`,
        "global_default",
    ];
    for (const docId of docIds) {
        const snap = await db().collection("system_configs").doc(docId).get();
        if (snap.exists) {
            const data = snap.data();
            const raw = data["dailyStreakConfig"];
            if (raw && typeof raw === "object") {
                return Object.assign(Object.assign({}, defaults), raw);
            }
        }
    }
    return defaults;
}
function isStreakEnabledForRegion(cfg, countryCode, stateOrRegion) {
    if (!cfg.streakEnabled)
        return false;
    if (cfg.disabledCountries.includes(countryCode.toUpperCase()))
        return false;
    const stateKey = `${countryCode.toUpperCase()}_${stateOrRegion
        .toUpperCase()
        .replace(/ /g, "_")}`;
    if (cfg.disabledStates.includes(stateKey))
        return false;
    return true;
}
const FRESH_STREAK = (baseRate, active, resetDateLocal = "") => ({
    streakActive: active,
    currentLevel: 1,
    currentStep: 0,
    level1PaidHistory: [],
    dailyStreakCompleted: false,
    baseCommissionRate: baseRate,
    resetDateLocal,
});
function readPaidHistory(d) {
    // Canonical key is `level1PaidHistory`; the spec alias
    // `level1PaidCommissionHistory` is accepted on read and mirrored on write.
    const raw = Array.isArray(d["level1PaidHistory"])
        ? d["level1PaidHistory"]
        : d["level1PaidCommissionHistory"];
    return Array.isArray(raw) ? raw : [];
}
async function getDriverStreak(driverId) {
    var _a, _b, _c, _d, _e, _f;
    const snap = await db().collection("driver_streaks").doc(driverId).get();
    if (!snap.exists) {
        return FRESH_STREAK(0.20, true);
    }
    const d = snap.data();
    return {
        streakActive: (_a = d["streakActive"]) !== null && _a !== void 0 ? _a : true,
        currentLevel: (_b = d["currentLevel"]) !== null && _b !== void 0 ? _b : 1,
        currentStep: (_c = d["currentStep"]) !== null && _c !== void 0 ? _c : 0,
        level1PaidHistory: readPaidHistory(d),
        dailyStreakCompleted: (_d = d["dailyStreakCompleted"]) !== null && _d !== void 0 ? _d : false,
        baseCommissionRate: (_e = d["baseCommissionRate"]) !== null && _e !== void 0 ? _e : 0.20,
        resetDateLocal: (_f = d["resetDateLocal"]) !== null && _f !== void 0 ? _f : "",
    };
}
/**
 * Serialises a streak state for Firestore. Both history keys are written
 * so readers using either the canonical or the spec alias stay in sync.
 */
function streakToMap(streak, driverId) {
    return Object.assign(Object.assign({}, streak), { driverId, level1PaidCommissionHistory: [...streak.level1PaidHistory], updatedAt: admin.firestore.FieldValue.serverTimestamp() });
}
/**
 * Lazy local-midnight reset: if the stored `resetDateLocal` differs from
 * the driver's *today*, the day has rolled over locally and the streak
 * restarts at Level 1, Step 0 (preserving region enable + base rate).
 */
function applyLocalResetIfStale(streak, timeZone, now) {
    const today = localDateString(timeZone, now);
    if (streak.resetDateLocal === today)
        return streak;
    return Object.assign({}, FRESH_STREAK(streak.baseCommissionRate, streak.streakActive, today));
}
function computeCommission(streak, fareAmount, cfg) {
    var _a, _b;
    // If streak disabled or already completed today → flat rate, no changes
    if (!streak.streakActive || streak.dailyStreakCompleted) {
        const fee = fareAmount * cfg.baseCommissionRate;
        return {
            commissionRate: cfg.baseCommissionRate,
            commissionAmount: fee,
            cashBackAmount: 0,
            cashBonusAmount: 0,
            grandAwardTriggered: false,
            newState: streak,
        };
    }
    const level = streak.currentLevel;
    const step = streak.currentStep;
    let commissionRate = 0;
    let commissionAmount = 0;
    let cashBackAmount = 0;
    let cashBonusAmount = 0;
    let grandAwardTriggered = false;
    let newLevel = level;
    let newStep = step;
    let newHistory = [...streak.level1PaidHistory];
    let dailyCompleted = false;
    if (level === 1) {
        commissionRate = (_a = exports.L1_RATES[step]) !== null && _a !== void 0 ? _a : 0;
        commissionAmount = fareAmount * commissionRate;
        // Record this payment in history (only for steps 0-5 that will be refunded)
        if (step < 6) {
            newHistory = [...streak.level1PaidHistory];
            newHistory[step] = commissionAmount;
        }
        if (step === 6) {
            // 0% fee — advance to Level 2
            newLevel = 2;
            newStep = 0;
        }
        else {
            newStep = step + 1;
        }
    }
    else if (level === 2) {
        // 0% commission at Level 2
        commissionRate = 0;
        commissionAmount = 0;
        // Refund from Level 1 history in reverse: step0→history[5], step1→history[4]...
        const refundIndex = 5 - step;
        cashBackAmount =
            refundIndex >= 0 && refundIndex < streak.level1PaidHistory.length
                ? streak.level1PaidHistory[refundIndex]
                : 0;
        if (step === 5) {
            // Last refund — advance to Level 3
            newLevel = 3;
            newStep = 0;
        }
        else {
            newStep = step + 1;
        }
    }
    else {
        // Level 3 — 0% commission + cash bonus
        commissionRate = 0;
        commissionAmount = 0;
        const bonusRate = (_b = exports.L3_BONUS_RATES[step]) !== null && _b !== void 0 ? _b : 0;
        cashBonusAmount = fareAmount * bonusRate;
        if (step === 6) {
            // Grand award! Full cycle complete.
            grandAwardTriggered = true;
            dailyCompleted = true;
            newStep = step; // freeze at step 6 (won't advance further)
        }
        else {
            newStep = step + 1;
        }
    }
    const newState = {
        streakActive: streak.streakActive,
        currentLevel: newLevel,
        currentStep: newStep,
        level1PaidHistory: newHistory,
        dailyStreakCompleted: dailyCompleted,
        baseCommissionRate: streak.baseCommissionRate,
        resetDateLocal: streak.resetDateLocal,
    };
    return {
        commissionRate,
        commissionAmount,
        cashBackAmount,
        cashBonusAmount,
        grandAwardTriggered,
        newState,
    };
}
// ─── Streak break logic ──────────────────────────────────────────────────────
/**
 * Applies the streak drop-back rules and returns the broken state.
 *
 * Break rules:
 *   L1 Step 0:    → reset to off-streak (flat base rate, streakActive = false
 *                   until next completed trip restores it)
 *   L1 Step 1-6:  → L1 Step 0
 *   L2 Step 0:    → L1 Step 0
 *   L2 Step 1-5:  → L2 Step 0
 *   L3 (any):     → L1 Step 0  (can't break from L3 per spec — but safe guard)
 */
function applyStreakBreak(streak) {
    const { currentLevel: level, currentStep: step } = streak;
    if (level === 1) {
        if (step === 0) {
            // Was at the very start — drop fully off-streak (flat rate)
            return Object.assign(Object.assign({}, streak), { streakActive: false, currentLevel: 1, currentStep: 0 });
        }
        // Steps 1-6: drop back to L1 Step 0
        return Object.assign(Object.assign({}, streak), { currentLevel: 1, currentStep: 0 });
    }
    if (level === 2) {
        if (step === 0) {
            // Bounce all the way back to L1 Step 0
            return Object.assign(Object.assign({}, streak), { currentLevel: 1, currentStep: 0 });
        }
        // Steps 1-5: reset to L2 Step 0
        return Object.assign(Object.assign({}, streak), { currentLevel: 2, currentStep: 0 });
    }
    // Level 3 — guard: drop to L1 Step 0
    return Object.assign(Object.assign({}, streak), { currentLevel: 1, currentStep: 0 });
}
function logFinancialMutation(log) {
    console.log(`[FINANCIAL_MUTATION] ${JSON.stringify(log)}`);
}
function persistFinancialAuditLogInTx(tx, log) {
    const docId = log.stage
        ? `${log.tripId}_${log.type}_${log.stage}`
        : `${log.tripId}_${log.type}`;
    const logRef = db().collection("financial_audit_logs").doc(docId);
    tx.set(logRef, Object.assign(Object.assign({}, log), { id: docId, invariantsChecked: true, createdAt: admin.firestore.FieldValue.serverTimestamp(), serverTimestampMs: Date.now() }), { merge: true });
    logFinancialMutation(log);
}
async function persistFinancialAuditLog(log) {
    const docId = log.stage
        ? `${log.tripId}_${log.type}_${log.stage}`
        : `${log.tripId}_${log.type}`;
    const logRef = db().collection("financial_audit_logs").doc(docId);
    try {
        await logRef.set(Object.assign(Object.assign({}, log), { id: docId, invariantsChecked: true, createdAt: admin.firestore.FieldValue.serverTimestamp(), serverTimestampMs: Date.now() }), { merge: true });
    }
    catch (e) {
        console.warn(`persistFinancialAuditLog[${docId}] failed: ${e}`);
    }
    logFinancialMutation(log);
}
function logTripTransition(log) {
    console.log(`[TRIP_TRANSITION] ${JSON.stringify(log)}`);
}
function persistTripChangeLogInTx(tx, log) {
    const safeTimestamp = log.timestamp || Date.now();
    const docId = `${log.tripId}_${log.from}_to_${log.to}_${safeTimestamp}`;
    const logRef = db().collection("trip_change_logs").doc(docId);
    tx.set(logRef, Object.assign(Object.assign({}, log), { id: docId, createdAt: admin.firestore.FieldValue.serverTimestamp() }), { merge: true });
    logTripTransition(log);
}
async function persistTripChangeLog(log) {
    const safeTimestamp = log.timestamp || Date.now();
    const docId = `${log.tripId}_${log.from}_to_${log.to}_${safeTimestamp}`;
    const logRef = db().collection("trip_change_logs").doc(docId);
    try {
        await logRef.set(Object.assign(Object.assign({}, log), { id: docId, createdAt: admin.firestore.FieldValue.serverTimestamp() }), { merge: true });
    }
    catch (e) {
        console.warn(`persistTripChangeLog[${docId}] failed: ${e}`);
    }
    logTripTransition(log);
}
// ─── Cloud Function & Core Settlement: onTripCompleted / handleTripCompletion ──
/**
 * Core trip settlement processor: executes synchronously on trip completion or
 * as an idempotent trigger fallback.
 * Computes streak-aware commission, deducts platform commission from driver wallet ledger,
 * credits bonuses/refunds, updates trip settlement, and handles wallet escrow settlement.
 */
async function handleTripCompletion(tripId, after) {
    var _a, _b, _c, _d, _e, _f, _g, _h, _j, _k, _l, _m, _o, _p, _q, _r, _s, _t, _u, _v, _w;
    const driverId = String((_c = (_b = (_a = after["driver"]) === null || _a === void 0 ? void 0 : _a["driverId"]) !== null && _b !== void 0 ? _b : after["driverId"]) !== null && _c !== void 0 ? _c : "");
    if (!driverId) {
        console.warn(`handleTripCompletion[${tripId}]: no driverId, skipping streak`);
        return;
    }
    // Determine fare amount from the trip doc (prioritize top-level fareAmount/proposedFare/finalFare)
    const fareTiers = Array.isArray(after["fareTiers"]) ? after["fareTiers"] : [];
    const selectedTiers = Array.isArray(after["selectedTiers"])
        ? after["selectedTiers"]
        : [];
    const matchedTier = fareTiers.find((t) => selectedTiers.includes(t.tierId));
    const fareAmount = Number((_j = (_g = (_f = (_e = (_d = after["fareAmount"]) !== null && _d !== void 0 ? _d : after["proposedFare"]) !== null && _e !== void 0 ? _e : after["finalFare"]) !== null && _f !== void 0 ? _f : matchedTier === null || matchedTier === void 0 ? void 0 : matchedTier.fareAmount) !== null && _g !== void 0 ? _g : (_h = fareTiers[0]) === null || _h === void 0 ? void 0 : _h.fareAmount) !== null && _j !== void 0 ? _j : 0);
    if (fareAmount <= 0) {
        console.warn(`handleTripCompletion[${tripId}]: fareAmount=0, skipping`);
        return;
    }
    // Resolve region from driver doc
    const driverSnap = await db().collection("drivers").doc(driverId).get();
    const driverData = driverSnap.exists ? driverSnap.data() : {};
    const countryCode = driverData["countryCode"] || "NG";
    const stateOrRegion = driverData["stateOrRegion"] || "";
    const cfg = await resolveStreakConfig(countryCode, stateOrRegion);
    const streakEnabled = isStreakEnabledForRegion(cfg, countryCode, stateOrRegion);
    // Read current streak state (or initialise fresh)
    let streak = await getDriverStreak(driverId);
    const driverTimeZone = resolveDriverTimeZone(driverData);
    // Lazy local-midnight reset: a stale `resetDateLocal` means the
    // driver's day has rolled over since the last event.
    streak = applyLocalResetIfStale(streak, driverTimeZone, Date.now());
    // If streak was off (broke) and a new trip completes, re-enter at L1 Step 0
    if (!streak.streakActive && streakEnabled) {
        streak = Object.assign(Object.assign({}, streak), { streakActive: true });
    }
    // Sync the regional enable flag
    streak = Object.assign(Object.assign({}, streak), { streakActive: streakEnabled ? streak.streakActive : false, baseCommissionRate: cfg.baseCommissionRate });
    const result = computeCommission(streak, fareAmount, cfg);
    const tripRef = db().collection("trips").doc(tripId);
    const driverWalletRef = db().collection("wallets").doc(driverId);
    const streakRef = db().collection("driver_streaks").doc(driverId);
    const customerId = String((_l = (_k = after["customerId"]) !== null && _k !== void 0 ? _k : after["userId"]) !== null && _l !== void 0 ? _l : "");
    const custWalletRef = customerId ? db().collection("wallets").doc(customerId) : null;
    const driverUserRef = db().collection("users").doc(driverId);
    const custUserRef = customerId ? db().collection("users").doc(customerId) : null;
    // ── Step 1: Canonical Atomic Settlement Transaction ───────────────────────
    let shouldProceedWithReferralsAndRewards = false;
    await db().runTransaction(async (tx) => {
        var _a, _b, _c, _d, _e, _f, _g, _h;
        // STRICT ORDERING: All reads executed first
        const liveTripSnap = await tx.get(tripRef);
        if (!liveTripSnap.exists) {
            console.warn(`handleTripCompletion[${tripId}]: trip not found in transaction`);
            return;
        }
        const liveTrip = liveTripSnap.data();
        // Idempotency check: if commission or full settlement is already complete, abort safely
        if (((_a = liveTrip.settlement) === null || _a === void 0 ? void 0 : _a.settled) === true ||
            ((_b = liveTrip.settlement) === null || _b === void 0 ? void 0 : _b.commissionSettled) === true) {
            console.log(`handleTripCompletion[${tripId}]: already settled, skipping duplicate run`);
            return;
        }
        const custWalletSnap = custWalletRef ? await tx.get(custWalletRef) : null;
        await tx.get(driverWalletRef);
        shouldProceedWithReferralsAndRewards = true;
        // 1. Streak State
        tx.set(streakRef, streakToMap(result.newState, driverId), { merge: true });
        // 2. Platform Commission Debit from driver wallet ledger & trip annotation
        const commissionDebitNaira = result.commissionAmount;
        const commissionDebitKobo = nairaToKobo(commissionDebitNaira);
        if (commissionDebitKobo > 0) {
            tx.set(driverWalletRef, {
                balance: admin.firestore.FieldValue.increment(-commissionDebitKobo),
                mainWalletBalance: admin.firestore.FieldValue.increment(-commissionDebitNaira),
                updatedAt: admin.firestore.FieldValue.serverTimestamp(),
            }, { merge: true });
            const commTxRef = driverWalletRef
                .collection("transactions")
                .doc(`${tripId}_commission`);
            tx.set(commTxRef, {
                type: "platform_commission",
                amount: -commissionDebitKobo,
                amountKobo: -commissionDebitKobo,
                amountNaira: -commissionDebitNaira,
                tripId,
                currency: "NGN",
                note: `Platform commission fee for trip ${tripId}`,
                createdAt: admin.firestore.FieldValue.serverTimestamp(),
            });
            persistFinancialAuditLogInTx(tx, {
                tripId,
                type: "commission",
                accountId: driverId,
                amountNaira: -commissionDebitNaira,
                amountKobo: -commissionDebitKobo,
                currency: "NGN",
                note: `Platform commission fee for trip ${tripId}`,
                timestamp: Date.now(),
                stage: "completion",
            });
        }
        // 3. Credit cash-back / bonus to driver wallet (Level 2 & 3)
        const walletCreditNaira = result.cashBackAmount + result.cashBonusAmount;
        const walletCreditKobo = nairaToKobo(walletCreditNaira);
        if (walletCreditKobo > 0) {
            tx.set(driverWalletRef, {
                balance: admin.firestore.FieldValue.increment(walletCreditKobo),
                mainWalletBalance: admin.firestore.FieldValue.increment(walletCreditNaira),
                updatedAt: admin.firestore.FieldValue.serverTimestamp(),
            }, { merge: true });
            // Wallet transaction record
            const txRef = driverWalletRef.collection("transactions").doc(`${tripId}_bonus`);
            const txType = result.cashBonusAmount > 0
                ? "streak_level3_bonus"
                : "streak_level2_cashback";
            tx.set(txRef, {
                type: txType,
                amount: walletCreditKobo,
                amountKobo: walletCreditKobo,
                amountNaira: walletCreditNaira,
                tripId,
                streakLevel: streak.currentLevel,
                streakStep: streak.currentStep,
                createdAt: admin.firestore.FieldValue.serverTimestamp(),
            });
            persistFinancialAuditLogInTx(tx, {
                tripId,
                type: "payout_bonus",
                accountId: driverId,
                amountNaira: walletCreditNaira,
                amountKobo: walletCreditKobo,
                currency: "NGN",
                note: `Streak bonus/cashback for trip ${tripId}`,
                timestamp: Date.now(),
                stage: "completion",
            });
        }
        // 4. Grand Award: credit extra wallet payout + set celebration flag on trip
        if (result.grandAwardTriggered && cfg.completionCashAward > 0) {
            const grandAwardKobo = nairaToKobo(cfg.completionCashAward);
            tx.set(driverWalletRef, {
                balance: admin.firestore.FieldValue.increment(grandAwardKobo),
                mainWalletBalance: admin.firestore.FieldValue.increment(cfg.completionCashAward),
                updatedAt: admin.firestore.FieldValue.serverTimestamp(),
            }, { merge: true });
            const awardTxRef = driverWalletRef.collection("transactions").doc(`${tripId}_grand_award`);
            tx.set(awardTxRef, {
                type: "streak_grand_award",
                amount: grandAwardKobo,
                amountKobo: grandAwardKobo,
                amountNaira: cfg.completionCashAward,
                tripId,
                createdAt: admin.firestore.FieldValue.serverTimestamp(),
            });
            persistFinancialAuditLogInTx(tx, {
                tripId,
                type: "grand_award",
                accountId: driverId,
                amountNaira: cfg.completionCashAward,
                amountKobo: grandAwardKobo,
                currency: "NGN",
                note: `Grand award payout for trip ${tripId}`,
                timestamp: Date.now(),
                stage: "completion",
            });
        }
        // 5. Atomically increment completedTrips counter for both driver and customer
        tx.set(driverUserRef, { completedTrips: admin.firestore.FieldValue.increment(1) }, { merge: true });
        if (custUserRef) {
            tx.set(custUserRef, { completedTrips: admin.firestore.FieldValue.increment(1) }, { merge: true });
        }
        // 6. Settle Trip Wallet Escrow & Credit Driver Virtual Wallet
        const walletCoverage = Number((_f = (_e = (_c = liveTrip.walletCoverageAmount) !== null && _c !== void 0 ? _c : (_d = liveTrip.paymentBreakdown) === null || _d === void 0 ? void 0 : _d.walletCoverageAmount) !== null && _e !== void 0 ? _e : after["walletCoverageAmount"]) !== null && _f !== void 0 ? _f : 0);
        if (walletCoverage > 0 && !liveTrip.walletSettledAt) {
            const coverageKobo = nairaToKobo(walletCoverage);
            const custWData = (custWalletSnap === null || custWalletSnap === void 0 ? void 0 : custWalletSnap.exists) ? custWalletSnap.data() : {};
            const currentCustEscrow = Number((_g = custWData["escrowBalance"]) !== null && _g !== void 0 ? _g : walletCoverage);
            const newCustEscrow = Math.max(0, currentCustEscrow - walletCoverage);
            // Finalize debit on customer's wallet (deduct from main balance, clear escrow safely)
            if (custWalletRef) {
                tx.set(custWalletRef, {
                    mainWalletBalance: admin.firestore.FieldValue.increment(-walletCoverage),
                    balance: admin.firestore.FieldValue.increment(-coverageKobo),
                    escrowBalance: newCustEscrow,
                    updatedAt: admin.firestore.FieldValue.serverTimestamp(),
                }, { merge: true });
                tx.set(custWalletRef.collection("transactions").doc(`${tripId}_payment`), {
                    type: "trip_payment",
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
            // Credit the wallet portion to the driver's virtual wallet upon trip completion
            tx.set(driverWalletRef, {
                mainWalletBalance: admin.firestore.FieldValue.increment(walletCoverage),
                balance: admin.firestore.FieldValue.increment(coverageKobo),
                updatedAt: admin.firestore.FieldValue.serverTimestamp(),
            }, { merge: true });
            tx.set(driverWalletRef.collection("transactions").doc(`${tripId}_wallet_settlement`), {
                type: "trip_wallet_settlement",
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
        // 7. Canonical Trip Settlement Metadata
        const tripUpdate = {
            "settlement.settled": true,
            "settlement.commissionRate": result.commissionRate,
            "settlement.commissionAmount": result.commissionAmount,
            "settlement.commissionSettled": true,
            "settlement.commissionSettledAt": admin.firestore.FieldValue.serverTimestamp(),
            "settlement.cashBackAmount": result.cashBackAmount,
            "settlement.cashBonusAmount": result.cashBonusAmount,
            "settlement.streakLevel": streak.currentLevel,
            "settlement.streakStep": streak.currentStep,
            "settlement.settledAt": admin.firestore.FieldValue.serverTimestamp(),
            "settlement.walletSettled": true,
            walletSettledAt: admin.firestore.FieldValue.serverTimestamp(),
            "paymentBreakdown.walletSettled": true,
            updatedAt: admin.firestore.FieldValue.serverTimestamp(),
        };
        if (result.grandAwardTriggered && cfg.completionCashAward > 0) {
            tripUpdate["settlement.grandAwardTriggered"] = true;
            tripUpdate["settlement.grandAwardAmount"] = cfg.completionCashAward;
        }
        if (!liveTrip.completedAt && !after["completedAt"]) {
            tripUpdate["completedAt"] = admin.firestore.FieldValue.serverTimestamp();
        }
        tx.update(tripRef, tripUpdate);
        persistTripChangeLogInTx(tx, {
            tripId,
            from: String((_h = liveTrip.status) !== null && _h !== void 0 ? _h : "IN_PROGRESS"),
            to: "COMPLETED",
            actor: driverId,
            role: "driver",
            reason: "trip_completed_settled",
            timestamp: Date.now(),
        });
    });
    if (!shouldProceedWithReferralsAndRewards) {
        return;
    }
    // 5. Automated Residual Referral Commission Split Engine (Idempotent)
    try {
        const customerId = String((_o = (_m = after["customerId"]) !== null && _m !== void 0 ? _m : after["userId"]) !== null && _o !== void 0 ? _o : "");
        const driverName = String((_q = (_p = driverData["fullName"]) !== null && _p !== void 0 ? _p : driverData["displayName"]) !== null && _q !== void 0 ? _q : "Driver");
        const refSplits = await processReferralCommissions(tripId, customerId, driverId, driverName, fareAmount);
        await db().collection("trips").doc(tripId).update({
            "settlement.platformFeeNaira": refSplits.platformFeeNaira,
            "settlement.driverReferrerCutNaira": refSplits.driverReferrerCutNaira,
            "settlement.customerReferrerCutNaira": refSplits.customerReferrerCutNaira,
            "settlement.netPlatformProfitNaira": refSplits.netPlatformProfitNaira,
            "settlement.netDriverPayoutNaira": refSplits.netDriverPayoutNaira,
            "settlement.referralsSettled": true,
            updatedAt: admin.firestore.FieldValue.serverTimestamp(),
        });
    }
    catch (e) {
        console.warn(`handleTripCompletion[${tripId}]: referral commission processing warning: ${e}`);
    }
    // 6. Dynamic Streak & Reward Overrides Evaluation (Driver & Customer)
    try {
        await (0, streakRewards_1.evaluateAndGrantStreakRewards)(driverId, "driver", tripId, countryCode, stateOrRegion);
    }
    catch (e) {
        console.warn(`handleTripCompletion[${tripId}]: driver streak reward evaluation warning: ${e}`);
    }
    try {
        const customerId = String((_s = (_r = after["customerId"]) !== null && _r !== void 0 ? _r : after["userId"]) !== null && _s !== void 0 ? _s : "");
        if (customerId) {
            const custSnap = await db().collection("users").doc(customerId).get();
            const custData = custSnap.exists ? custSnap.data() : {};
            const custCountry = String((_u = (_t = custData["countryCode"]) !== null && _t !== void 0 ? _t : countryCode) !== null && _u !== void 0 ? _u : "NG");
            const custState = String((_w = (_v = custData["stateOrRegion"]) !== null && _v !== void 0 ? _v : stateOrRegion) !== null && _w !== void 0 ? _w : "");
            await (0, streakRewards_1.evaluateAndGrantStreakRewards)(customerId, "customer", tripId, custCountry, custState);
        }
    }
    catch (e) {
        console.warn(`handleTripCompletion[${tripId}]: customer streak reward evaluation warning: ${e}`);
    }
    console.log(`handleTripCompletion[${tripId}] driver=${driverId} ` +
        `L${streak.currentLevel}S${streak.currentStep} ` +
        `fare=${fareAmount} commission=${result.commissionAmount} ` +
        `cashBack=${result.cashBackAmount} bonus=${result.cashBonusAmount} ` +
        `grandAward=${result.grandAwardTriggered}`);
}
/**
 * Firestore trigger: fires when a trip document transitions to COMPLETED.
 * Idempotently executes trip completion settlement.
 */
exports.onTripCompleted = (0, firestore_1.onDocumentUpdated)("trips/{tripId}", async (event) => {
    var _a, _b, _c, _d;
    const before = (_b = (_a = event.data) === null || _a === void 0 ? void 0 : _a.before) === null || _b === void 0 ? void 0 : _b.data();
    const after = (_d = (_c = event.data) === null || _c === void 0 ? void 0 : _c.after) === null || _d === void 0 ? void 0 : _d.data();
    if (!before || !after)
        return;
    // Only react to the COMPLETED transition
    if (before["status"] === "COMPLETED" || after["status"] !== "COMPLETED") {
        return;
    }
    const tripId = event.params.tripId;
    await handleTripCompletion(tripId, after);
});
/**
 * Canonical trip cancellation settlement processor: executes atomically
 * within a single Firestore transaction.
 *
 * Guaranteed idempotency:
 * - Checks if cancellation settlement already executed
 * - Safely refunds locked wallet escrow to customer (clamping to >= 0)
 * - Settles paid waiting fee (if applicable) either via atomic wallet debit/credit
 *   or marks for cash settlement
 * - Records permanent financial audit logs with unique deterministic doc IDs
 * - Updates trip status to CANCELLED or CANCELLED_WAITING_CASH_SETTLEMENT
 */
async function handleTripCancellationSettlement(params) {
    const { tripId, cancelledBy, actorId, role, reason, paidWaitingFee, useCashSettlement } = params;
    const tripRef = db().collection("trips").doc(tripId);
    return await db().runTransaction(async (tx) => {
        var _a, _b, _c, _d, _e, _f, _g, _h, _j, _k, _l, _m, _o, _p;
        // 1. ALL READS FIRST (Firestore transaction invariant)
        const tripSnap = await tx.get(tripRef);
        if (!tripSnap.exists) {
            throw new https_1.HttpsError("not-found", `Trip ${tripId} not found.`);
        }
        const trip = tripSnap.data();
        const currentStatus = String((_a = trip.status) !== null && _a !== void 0 ? _a : "");
        // Terminal completion guard
        if (currentStatus === "COMPLETED") {
            throw new https_1.HttpsError("failed-precondition", "Cannot cancel an already completed trip.");
        }
        // Idempotency check: if already cancelled and settled, return safely
        if ((currentStatus === "CANCELLED" ||
            currentStatus === "CANCELLED_BY_CUSTOMER" ||
            currentStatus === "CANCELLED_BY_DRIVER") &&
            ((_b = trip.settlement) === null || _b === void 0 ? void 0 : _b.cancellationSettled) === true) {
            return {
                ok: true,
                alreadyCancelled: true,
                status: currentStatus,
                paidWaitingFee: Number((_c = trip.paidWaitingFee) !== null && _c !== void 0 ? _c : 0),
                escrowRefunded: 0,
            };
        }
        const customerId = String((_e = (_d = trip.customerId) !== null && _d !== void 0 ? _d : trip.userId) !== null && _e !== void 0 ? _e : "");
        const driverId = String((_h = (_g = (_f = trip.driver) === null || _f === void 0 ? void 0 : _f.driverId) !== null && _g !== void 0 ? _g : trip.driverId) !== null && _h !== void 0 ? _h : "");
        const custWalletRef = customerId ? db().collection("wallets").doc(customerId) : null;
        const driverWalletRef = driverId ? db().collection("wallets").doc(driverId) : null;
        const custUserRef = customerId ? db().collection("users").doc(customerId) : null;
        const custWalletSnap = custWalletRef ? await tx.get(custWalletRef) : null;
        if (driverWalletRef)
            await tx.get(driverWalletRef);
        const custUserSnap = custUserRef ? await tx.get(custUserRef) : null;
        // 2. FINANCIAL CALCULATIONS & INVARIANT CHECKS
        const walletCoverage = Number((_l = (_j = trip.walletCoverageAmount) !== null && _j !== void 0 ? _j : (_k = trip.paymentBreakdown) === null || _k === void 0 ? void 0 : _k.walletCoverageAmount) !== null && _l !== void 0 ? _l : 0);
        const isEscrowLocked = trip.escrowLocked !== false && !trip.escrowRefundedAt;
        const currentCustEscrow = Number((_o = (_m = custWalletSnap === null || custWalletSnap === void 0 ? void 0 : custWalletSnap.data()) === null || _m === void 0 ? void 0 : _m.escrowBalance) !== null && _o !== void 0 ? _o : walletCoverage);
        const refundAmount = (isEscrowLocked && walletCoverage > 0) ? walletCoverage : 0;
        const newCustEscrow = Math.max(0, currentCustEscrow - refundAmount); // Invariant: no negative escrow
        const waitingFee = Math.max(0, Number(paidWaitingFee !== null && paidWaitingFee !== void 0 ? paidWaitingFee : 0));
        const isCashWaiting = useCashSettlement === true && waitingFee > 0;
        const targetStatus = isCashWaiting
            ? "CANCELLED_WAITING_CASH_SETTLEMENT"
            : "CANCELLED";
        // 3. ATOMIC WRITES
        // Waiting Fee Settlement (if not cash)
        if (waitingFee > 0 && !isCashWaiting && custWalletRef && driverWalletRef) {
            const feeKobo = nairaToKobo(waitingFee);
            const wData = (custWalletSnap === null || custWalletSnap === void 0 ? void 0 : custWalletSnap.exists) ? custWalletSnap.data() : {};
            const uData = (custUserSnap === null || custUserSnap === void 0 ? void 0 : custUserSnap.exists) ? custUserSnap.data() : {};
            const currentBalance = typeof wData.mainWalletBalance === "number"
                ? wData.mainWalletBalance
                : (typeof wData.balance === "number" ? wData.balance / 100 : 0);
            const isTrustedCustomer = Number((_p = uData.completedTripCount) !== null && _p !== void 0 ? _p : 0) >= 5;
            if (currentBalance < waitingFee && !isTrustedCustomer) {
                throw new https_1.HttpsError("failed-precondition", `INSUFFICIENT_FUNDS: Your wallet balance (₦${currentBalance}) is insufficient for the ₦${waitingFee} paid waiting fee.`);
            }
            if (currentBalance >= waitingFee) {
                tx.set(custWalletRef, {
                    mainWalletBalance: admin.firestore.FieldValue.increment(-waitingFee),
                    balance: admin.firestore.FieldValue.increment(-feeKobo),
                    updatedAt: admin.firestore.FieldValue.serverTimestamp(),
                }, { merge: true });
                tx.set(custWalletRef.collection("transactions").doc(`${tripId}_waiting_fee_paid`), {
                    type: "waiting_fee_paid",
                    amountNaira: -waitingFee,
                    amountKobo: -feeKobo,
                    amount: -feeKobo,
                    tripId,
                    currency: "NGN",
                    note: `Paid waiting fee for trip ${tripId}`,
                    createdAt: admin.firestore.FieldValue.serverTimestamp(),
                });
            }
            else {
                // Trusted customer negative balance
                const shortage = waitingFee - Math.max(0, currentBalance);
                if (custUserRef) {
                    tx.set(custUserRef, { outstandingNegativeBalance: admin.firestore.FieldValue.increment(shortage) }, { merge: true });
                }
                if (currentBalance > 0) {
                    tx.set(custWalletRef, {
                        mainWalletBalance: 0,
                        balance: 0,
                        updatedAt: admin.firestore.FieldValue.serverTimestamp(),
                    }, { merge: true });
                    tx.set(custWalletRef.collection("transactions").doc(`${tripId}_waiting_fee_paid`), {
                        type: "waiting_fee_paid",
                        amountNaira: -currentBalance,
                        amountKobo: -nairaToKobo(currentBalance),
                        amount: -nairaToKobo(currentBalance),
                        tripId,
                        currency: "NGN",
                        note: `Partial waiting fee paid for trip ${tripId} (remainder ₦${shortage} added to debt)`,
                        createdAt: admin.firestore.FieldValue.serverTimestamp(),
                    });
                }
            }
            // Credit driver wallet
            tx.set(driverWalletRef, {
                mainWalletBalance: admin.firestore.FieldValue.increment(waitingFee),
                balance: admin.firestore.FieldValue.increment(feeKobo),
                updatedAt: admin.firestore.FieldValue.serverTimestamp(),
            }, { merge: true });
            tx.set(driverWalletRef.collection("transactions").doc(`${tripId}_waiting_fee_credited`), {
                type: "waiting_fee_credited",
                amountNaira: waitingFee,
                amountKobo: feeKobo,
                amount: feeKobo,
                tripId,
                currency: "NGN",
                note: `Paid waiting fee credited for trip ${tripId}`,
                createdAt: admin.firestore.FieldValue.serverTimestamp(),
            });
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
            tx.set(custWalletRef, {
                escrowBalance: newCustEscrow,
                updatedAt: admin.firestore.FieldValue.serverTimestamp(),
            }, { merge: true });
            tx.set(custWalletRef.collection("transactions").doc(`${tripId}_escrow_refund`), {
                type: "trip_escrow_refund",
                amountNaira: refundAmount,
                amountKobo: coverageKobo,
                amount: coverageKobo,
                tripId,
                currency: "NGN",
                note: `Escrow hold released for cancelled trip ${tripId}`,
                createdAt: admin.firestore.FieldValue.serverTimestamp(),
            });
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
        const now = Date.now();
        const tripUpdates = {
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
                timestamp: now,
            }),
            updatedAt: admin.firestore.FieldValue.serverTimestamp(),
        };
        tx.update(tripRef, tripUpdates);
        persistTripChangeLogInTx(tx, {
            tripId,
            from: currentStatus,
            to: targetStatus,
            actor: actorId,
            role,
            reason,
            timestamp: now,
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
function normalizeRateFraction(val, fallback) {
    if (typeof val !== "number" || isNaN(val))
        return fallback;
    return val > 1 ? val / 100 : val;
}
async function getBackendFinancialConfig() {
    let userReferralCommissionRate = 0.01;
    let agentReferralCommissionRate = 0.02;
    let standardReferralDurationDays = 365;
    let agentReferralDurationDays = 547;
    let maxBonusThreshold = 10000.0;
    try {
        const snap = await db().collection("system_configs").doc("financials").get();
        if (snap.exists && snap.data()) {
            const d = snap.data();
            if (typeof d.userReferralCommissionRate === "number")
                userReferralCommissionRate = normalizeRateFraction(d.userReferralCommissionRate, 0.01);
            if (typeof d.agentReferralCommissionRate === "number")
                agentReferralCommissionRate = normalizeRateFraction(d.agentReferralCommissionRate, 0.02);
            if (typeof d.standardReferralDurationDays === "number")
                standardReferralDurationDays = d.standardReferralDurationDays;
            if (typeof d.agentReferralDurationDays === "number")
                agentReferralDurationDays = d.agentReferralDurationDays;
            if (typeof d.maxBonusThreshold === "number")
                maxBonusThreshold = d.maxBonusThreshold;
        }
    }
    catch (_a) {
        // Fall back to defaults
    }
    return {
        userReferralCommissionRate,
        agentReferralCommissionRate,
        standardReferralDurationDays,
        agentReferralDurationDays,
        maxBonusThreshold,
    };
}
async function getReferralSettings() {
    let platformBaseCommissionRate = 20.0;
    let driverReferrerRate = 5.0;
    let customerReferrerRate = 5.0;
    let userReferralCommissionRate;
    let agentReferralCommissionRate;
    let standardReferralDurationDays;
    let agentReferralDurationDays;
    try {
        const snap = await db().collection("system_config").doc("referral_settings").get();
        if (snap.exists && snap.data()) {
            const d = snap.data();
            if (typeof d.platformBaseCommissionRate === "number")
                platformBaseCommissionRate = d.platformBaseCommissionRate;
            if (typeof d.driverReferrerRate === "number")
                driverReferrerRate = d.driverReferrerRate;
            if (typeof d.customerReferrerRate === "number")
                customerReferrerRate = d.customerReferrerRate;
            if (typeof d.userReferralCommissionRate === "number")
                userReferralCommissionRate = d.userReferralCommissionRate;
            if (typeof d.agentReferralCommissionRate === "number")
                agentReferralCommissionRate = d.agentReferralCommissionRate;
            if (typeof d.standardReferralDurationDays === "number")
                standardReferralDurationDays = d.standardReferralDurationDays;
            if (typeof d.agentReferralDurationDays === "number")
                agentReferralDurationDays = d.agentReferralDurationDays;
        }
    }
    catch (_a) {
        // Fall back to defaults
    }
    return {
        platformBaseCommissionRate,
        driverReferrerRate,
        customerReferrerRate,
        userReferralCommissionRate,
        agentReferralCommissionRate,
        standardReferralDurationDays,
        agentReferralDurationDays,
    };
}
async function processReferralCommissions(tripId, customerId, driverId, driverName, totalFareNaira) {
    var _a, _b, _c, _d, _e, _f, _g, _h, _j, _k, _l, _m, _o, _p, _q, _r, _s, _t, _u, _v;
    const tripSnap = await db().collection("trips").doc(tripId).get();
    if (tripSnap.exists && ((_b = (_a = tripSnap.data()) === null || _a === void 0 ? void 0 : _a.settlement) === null || _b === void 0 ? void 0 : _b.referralsSettled) === true) {
        console.log(`processReferralCommissions[${tripId}]: referrals already settled, skipping`);
        const s = (_c = tripSnap.data().settlement) !== null && _c !== void 0 ? _c : {};
        return {
            platformFeeNaira: Number((_d = s.platformFeeNaira) !== null && _d !== void 0 ? _d : 0),
            driverReferrerCutNaira: Number((_e = s.driverReferrerCutNaira) !== null && _e !== void 0 ? _e : 0),
            customerReferrerCutNaira: Number((_f = s.customerReferrerCutNaira) !== null && _f !== void 0 ? _f : 0),
            netPlatformProfitNaira: Number((_g = s.netPlatformProfitNaira) !== null && _g !== void 0 ? _g : 0),
            netDriverPayoutNaira: Number((_h = s.netDriverPayoutNaira) !== null && _h !== void 0 ? _h : 0),
        };
    }
    const finCfg = await getBackendFinancialConfig();
    const settings = await getReferralSettings();
    const platformFeeNaira = totalFareNaira * (settings.platformBaseCommissionRate / 100);
    let driverReferrerCutNaira = 0;
    let customerReferrerCutNaira = 0;
    const nowMs = Date.now();
    const now = admin.firestore.FieldValue.serverTimestamp();
    // Helper: Process referral credit to seseCoinBalance + auto-sweep check
    const creditReferrerCoins = async (referrerId, refereeId, refereeName, signupTimestamp, type) => {
        var _a, _b, _c, _d, _e, _f, _g, _h, _j, _k, _l, _m, _o;
        let signupMs = nowMs;
        if (signupTimestamp) {
            try {
                signupMs = typeof signupTimestamp.toMillis === "function"
                    ? signupTimestamp.toMillis()
                    : new Date(String(signupTimestamp)).getTime();
            }
            catch (_) { }
        }
        const ageDays = (nowMs - signupMs) / (1000 * 60 * 60 * 24);
        let targetUid = referrerId;
        if (referrerId && referrerId.length < 20) {
            try {
                const codeSnap = await db().collection("referral_codes").doc(referrerId.toUpperCase()).get();
                if (codeSnap.exists) {
                    targetUid = String((_b = (_a = codeSnap.data()) === null || _a === void 0 ? void 0 : _a.referrerId) !== null && _b !== void 0 ? _b : referrerId);
                }
                else {
                    const uQuery = await db().collection("users").where("referralCode", "==", referrerId.toUpperCase()).limit(1).get();
                    if (!uQuery.empty) {
                        targetUid = uQuery.docs[0].id;
                    }
                }
            }
            catch (_) { }
        }
        // Determine referrer role & commission rates from Hub master settings
        let isAgentOrStaff = false;
        try {
            const refUserSnap = await db().collection("users").doc(targetUid).get();
            if (refUserSnap.exists) {
                const role = String((_d = (_c = refUserSnap.data()) === null || _c === void 0 ? void 0 : _c.role) !== null && _d !== void 0 ? _d : "");
                if (role === "agent" || role === "staff" || ((_e = refUserSnap.data()) === null || _e === void 0 ? void 0 : _e.isAgent) === true) {
                    isAgentOrStaff = true;
                }
            }
        }
        catch (_) { }
        // Dynamic Rate Selection from Hub Settings:
        // 1. Agent/Staff rate: agentReferralCommissionRate (default ~2%)
        // 2. Specific driver/customer rate from system_config/referral_settings or financials (default ~5%)
        let rate = 0.05;
        if (isAgentOrStaff) {
            rate = normalizeRateFraction((_f = settings.agentReferralCommissionRate) !== null && _f !== void 0 ? _f : finCfg.agentReferralCommissionRate, 0.02);
        }
        else if (type === "driver") {
            rate = normalizeRateFraction((_h = (_g = settings.driverReferrerRate) !== null && _g !== void 0 ? _g : settings.userReferralCommissionRate) !== null && _h !== void 0 ? _h : finCfg.userReferralCommissionRate, 0.05);
        }
        else {
            rate = normalizeRateFraction((_k = (_j = settings.customerReferrerRate) !== null && _j !== void 0 ? _j : settings.userReferralCommissionRate) !== null && _k !== void 0 ? _k : finCfg.userReferralCommissionRate, 0.05);
        }
        const maxDays = isAgentOrStaff
            ? ((_l = settings.agentReferralDurationDays) !== null && _l !== void 0 ? _l : finCfg.agentReferralDurationDays)
            : ((_m = settings.standardReferralDurationDays) !== null && _m !== void 0 ? _m : finCfg.standardReferralDurationDays);
        if (ageDays > maxDays)
            return 0; // Eligibility window expired
        const cutNaira = totalFareNaira * rate;
        if (cutNaira <= 0)
            return 0;
        // First qualifying trip check on referee document
        const refereeColl = type === "driver" ? "drivers" : "users";
        const refereeRef = db().collection(refereeColl).doc(refereeId);
        let isFirstTrip = false;
        try {
            const refSnap = await refereeRef.get();
            if (refSnap.exists && !((_o = refSnap.data()) === null || _o === void 0 ? void 0 : _o.hasCompletedFirstTrip)) {
                isFirstTrip = true;
            }
        }
        catch (_) { }
        const txDocId = `${tripId}_ref_${type}_${refereeId}`;
        const wRef = db().collection("wallets").doc(targetUid);
        const txRef = wRef.collection("transactions").doc(txDocId);
        const auditRef = db().collection("wallet_transactions").doc(txDocId);
        const earnRef = db().collection("referral_earnings").doc(txDocId);
        const tripTag = isFirstTrip ? " (First Qualifying Trip)" : "";
        const note = `+₦${cutNaira.toFixed(2)} referral bonus received from ${refereeName || 'Referred User'} for Order #${tripId}${tripTag}`;
        await db().runTransaction(async (tx) => {
            var _a;
            // Idempotency check: if transaction already committed for this trip & referee, skip
            const existingTx = await tx.get(txRef);
            if (existingTx.exists) {
                console.log(`creditReferrerCoins[${tripId}]: already credited for ${txDocId}, skipping`);
                return;
            }
            // Mark referee doc with first qualifying trip milestone
            if (isFirstTrip) {
                tx.set(refereeRef, {
                    hasCompletedFirstTrip: true,
                    firstQualifyingTripId: tripId,
                    firstQualifyingTripAt: now,
                }, { merge: true });
            }
            const wSnap = await tx.get(wRef);
            const wData = wSnap.exists ? ((_a = wSnap.data()) !== null && _a !== void 0 ? _a : {}) : {};
            const currentCoins = typeof wData.seseCoinBalance === "number" ? wData.seseCoinBalance : 0;
            const newCoins = currentCoins + cutNaira;
            // Auto-Sweep check
            if (newCoins >= finCfg.maxBonusThreshold) {
                const newCoinsKobo = nairaToKobo(newCoins);
                tx.set(wRef, {
                    seseCoinBalance: 0,
                    mainWalletBalance: admin.firestore.FieldValue.increment(newCoins),
                    balance: admin.firestore.FieldValue.increment(newCoinsKobo),
                    updatedAt: now,
                }, { merge: true });
                tx.set(txRef, {
                    type: "sese_coin_auto_sweep",
                    amountNaira: newCoins,
                    amountKobo: newCoinsKobo,
                    amount: newCoinsKobo,
                    tripId,
                    refereeId,
                    note: `Auto-swept ₦${newCoins.toFixed(2)} in SeSe Coins to withdrawable wallet cash.`,
                    createdAt: now,
                });
            }
            else {
                const cutKobo = nairaToKobo(cutNaira);
                tx.set(wRef, {
                    seseCoinBalance: admin.firestore.FieldValue.increment(cutNaira),
                    updatedAt: now,
                }, { merge: true });
                tx.set(txRef, {
                    type: type === "driver" ? "REFERRAL_COMMISSION_DRIVER" : "REFERRAL_COMMISSION_CUSTOMER",
                    amountNaira: cutNaira,
                    amountKobo: cutKobo,
                    amount: cutKobo,
                    note,
                    tripId,
                    refereeId,
                    isFirstTrip,
                    createdAt: now,
                });
            }
            tx.set(auditRef, {
                type: type === "driver" ? "REFERRAL_COMMISSION_DRIVER" : "REFERRAL_COMMISSION_CUSTOMER",
                userId: targetUid,
                refereeId,
                tripId,
                amountNaira: cutNaira,
                amountKobo: nairaToKobo(cutNaira),
                amount: nairaToKobo(cutNaira),
                isFirstTrip,
                createdAt: now,
            });
            tx.set(earnRef, {
                referrerId: targetUid,
                refereeId,
                amount: cutNaira,
                orderId: tripId,
                type: `${type}_commission`,
                isFirstTrip,
                createdAt: now,
            });
            persistFinancialAuditLogInTx(tx, {
                tripId,
                type: "referral_credit",
                accountId: targetUid,
                amountNaira: cutNaira,
                amountKobo: nairaToKobo(cutNaira),
                currency: "NGN",
                note,
                stage: `${type}_${refereeId}`,
                timestamp: nowMs,
                invariantsChecked: true,
            });
        });
        return cutNaira;
    };
    // 1. Driver Referrer Check
    if (driverId) {
        try {
            const driverSnap = await db().collection("drivers").doc(driverId).get();
            if (driverSnap.exists) {
                const dData = driverSnap.data();
                const referrerId = String((_l = (_k = (_j = dData.referredBy) !== null && _j !== void 0 ? _j : dData.referred_by_code) !== null && _k !== void 0 ? _k : dData.referrerId) !== null && _l !== void 0 ? _l : "");
                if (referrerId && referrerId !== driverId) {
                    const refereeName = String((_o = (_m = dData.fullName) !== null && _m !== void 0 ? _m : driverName) !== null && _o !== void 0 ? _o : "Driver");
                    const signupTs = (_p = dData.referralSignupAt) !== null && _p !== void 0 ? _p : dData.createdAt;
                    driverReferrerCutNaira = await creditReferrerCoins(referrerId, driverId, refereeName, signupTs, "driver");
                }
            }
        }
        catch (e) {
            console.warn(`processReferralCommissions driver check failed: ${e}`);
        }
    }
    // 2. Customer Referrer Check
    if (customerId) {
        try {
            const customerSnap = await db().collection("users").doc(customerId).get();
            if (customerSnap.exists) {
                const cData = customerSnap.data();
                const referrerId = String((_s = (_r = (_q = cData.referredBy) !== null && _q !== void 0 ? _q : cData.referred_by_code) !== null && _r !== void 0 ? _r : cData.referrerId) !== null && _s !== void 0 ? _s : "");
                if (referrerId && referrerId !== customerId) {
                    const refereeName = String((_u = (_t = cData.fullName) !== null && _t !== void 0 ? _t : cData.displayName) !== null && _u !== void 0 ? _u : "Customer");
                    const signupTs = (_v = cData.referralSignupAt) !== null && _v !== void 0 ? _v : cData.createdAt;
                    customerReferrerCutNaira = await creditReferrerCoins(referrerId, customerId, refereeName, signupTs, "customer");
                }
            }
        }
        catch (e) {
            console.warn(`processReferralCommissions customer check failed: ${e}`);
        }
    }
    const netPlatformProfitNaira = platformFeeNaira - (driverReferrerCutNaira + customerReferrerCutNaira);
    const netDriverPayoutNaira = totalFareNaira - platformFeeNaira;
    return {
        platformFeeNaira,
        driverReferrerCutNaira,
        customerReferrerCutNaira,
        netPlatformProfitNaira,
        netDriverPayoutNaira,
    };
}
// ─── Shared streak-break writer ─────────────────────────────────────────────
/**
 * Breaks a driver's streak from a non-CANCELLED path (explicit decline,
 * ignored ping expiry). Applies the lazy local-midnight reset first so a
 * stale streak from yesterday is never "broken" — it is reset instead.
 * Completed-today streaks are left untouched. Returns the persisted state,
 * or null when no write was needed.
 */
async function breakDriverStreak(driverId, reason) {
    const driverSnap = await db().collection("drivers").doc(driverId).get();
    const driverData = driverSnap.exists ? driverSnap.data() : {};
    const timeZone = resolveDriverTimeZone(driverData);
    let streak = await getDriverStreak(driverId);
    streak = applyLocalResetIfStale(streak, timeZone, Date.now());
    if (streak.dailyStreakCompleted)
        return null;
    const brokenState = applyStreakBreak(streak);
    const doc = streakToMap(brokenState, driverId);
    await db().collection("driver_streaks").doc(driverId).set(doc, { merge: true });
    console.log(`breakDriverStreak: driver=${driverId} reason=${reason} ` +
        `L${streak.currentLevel}S${streak.currentStep} → ` +
        `L${brokenState.currentLevel}S${brokenState.currentStep}`);
    return brokenState;
}
// ─── Cloud Function: onTripCancelled ────────────────────────────────────────
/**
 * Firestore trigger: fires when a trip transitions to CANCELLED.
 * Applies streak break rules based on cancellationSource:
 *   - "driver_before_arrival" → streak breaks
 *   - "customer"              → streak protected (no change)
 *   - "driver_no_show"        → streak protected (no change, no earning)
 * NOTE: explicit declines ("driver_declined") and ignored pings
 * ("ping_expired") never transition to CANCELLED — they break the streak
 * directly via breakDriverStreak() in declineTrip / sweepTripPings.
 */
exports.onTripCancelled = (0, firestore_1.onDocumentUpdated)("trips/{tripId}", async (event) => {
    var _a, _b, _c, _d, _e, _f, _g, _h, _j, _k, _l, _m;
    const before = (_b = (_a = event.data) === null || _a === void 0 ? void 0 : _a.before) === null || _b === void 0 ? void 0 : _b.data();
    const after = (_d = (_c = event.data) === null || _c === void 0 ? void 0 : _c.after) === null || _d === void 0 ? void 0 : _d.data();
    if (!before || !after)
        return;
    // Only react to CANCELLED transition
    if (before["status"] === "CANCELLED" || after["status"] !== "CANCELLED") {
        return;
    }
    // Release active escrow if not already released (transactionally & idempotently)
    const walletCoverage = Number((_g = (_e = after["walletCoverageAmount"]) !== null && _e !== void 0 ? _e : (_f = after["paymentBreakdown"]) === null || _f === void 0 ? void 0 : _f["walletCoverageAmount"]) !== null && _g !== void 0 ? _g : 0);
    if (walletCoverage > 0 && after["escrowLocked"] === true && !after["escrowRefundedAt"]) {
        const customerId = String((_h = after["customerId"]) !== null && _h !== void 0 ? _h : "");
        if (customerId) {
            try {
                const custWalletRef = db().collection("wallets").doc(customerId);
                const coverageKobo = nairaToKobo(walletCoverage);
                const tripRef = (_k = (_j = event.data) === null || _j === void 0 ? void 0 : _j.after) === null || _k === void 0 ? void 0 : _k.ref;
                if (!tripRef)
                    return;
                await db().runTransaction(async (tx) => {
                    var _a, _b;
                    const snap = await tx.get(tripRef);
                    if (!snap.exists)
                        return;
                    const t = snap.data();
                    if (t["escrowRefundedAt"] || t["escrowLocked"] === false)
                        return;
                    const wSnap = await tx.get(custWalletRef);
                    const currentEscrow = wSnap.exists ? Number((_b = (_a = wSnap.data()) === null || _a === void 0 ? void 0 : _a.escrowBalance) !== null && _b !== void 0 ? _b : walletCoverage) : walletCoverage;
                    const newEscrow = Math.max(0, currentEscrow - walletCoverage);
                    tx.set(custWalletRef, {
                        escrowBalance: newEscrow,
                        updatedAt: admin.firestore.FieldValue.serverTimestamp(),
                    }, { merge: true });
                    const refundTxRef = custWalletRef.collection("transactions").doc(`${event.params.tripId}_escrow_refund`);
                    tx.set(refundTxRef, {
                        type: "trip_escrow_refund",
                        amountNaira: walletCoverage,
                        amountKobo: coverageKobo,
                        amount: coverageKobo,
                        tripId: event.params.tripId,
                        currency: "NGN",
                        note: `Escrow hold released for cancelled trip ${event.params.tripId}`,
                        createdAt: admin.firestore.FieldValue.serverTimestamp(),
                    });
                    tx.update(tripRef, {
                        escrowLocked: false,
                        escrowRefundedAt: admin.firestore.FieldValue.serverTimestamp(),
                        "paymentBreakdown.escrowLocked": false,
                        "paymentBreakdown.escrowRefunded": true,
                        updatedAt: admin.firestore.FieldValue.serverTimestamp(),
                    });
                    persistFinancialAuditLogInTx(tx, {
                        tripId: event.params.tripId,
                        type: "trip_escrow_refund",
                        accountId: customerId,
                        amountNaira: walletCoverage,
                        amountKobo: coverageKobo,
                        currency: "NGN",
                        note: `Escrow hold released for cancelled trip ${event.params.tripId}`,
                        timestamp: Date.now(),
                        stage: "trigger_cancellation",
                        invariantsChecked: true,
                    });
                });
            }
            catch (e) {
                console.warn(`onTripCancelled[${event.params.tripId}]: escrow release warning: ${e}`);
            }
        }
    }
    const cancellationSource = after["cancellationSource"] || "unknown";
    // Customer cancel and driver no-show are streak-protected
    if (cancellationSource === "customer" ||
        cancellationSource === "driver_no_show") {
        return;
    }
    // All other cases (driver_before_arrival, ping_expired, etc.) break the streak
    const driverId = (_m = (_l = after["driver"]) === null || _l === void 0 ? void 0 : _l["driverId"]) !== null && _m !== void 0 ? _m : after["pingDriverId"];
    if (!driverId)
        return;
    const driverSnap = await db().collection("drivers").doc(driverId).get();
    const driverData = driverSnap.exists ? driverSnap.data() : {};
    const timeZone = resolveDriverTimeZone(driverData);
    let streak = await getDriverStreak(driverId);
    streak = applyLocalResetIfStale(streak, timeZone, Date.now());
    if (streak.dailyStreakCompleted)
        return; // already done for today
    const brokenState = applyStreakBreak(streak);
    await db()
        .collection("driver_streaks")
        .doc(driverId)
        .set(streakToMap(brokenState, driverId), { merge: true });
    console.log(`onTripCancelled: streak broken for driver=${driverId} ` +
        `source=${cancellationSource} ` +
        `L${streak.currentLevel}S${streak.currentStep} → ` +
        `L${brokenState.currentLevel}S${brokenState.currentStep}`);
});
// ─── Cloud Function: scheduledResetStreaks ────────────────────────────────────
/**
 * Local-midnight reset sweeper — runs hourly and resets every driver whose
 * stored `resetDateLocal` differs from *today in their own timezone*.
 * (Trip events also apply the same lazy reset, so the cron is a backstop
 * for idle drivers.) Processes in pages of 500.
 */
exports.scheduledResetStreaks = (0, scheduler_1.onSchedule)({ schedule: "0 * * * *", timeZone: "UTC" }, async () => {
    var _a, _b;
    console.log("scheduledResetStreaks: local-midnight sweep starting...");
    const now = Date.now();
    let totalReset = 0;
    let lastDoc;
    // Cache driver timezones within this run (driverId → timeZone).
    const tzCache = new Map();
    async function timeZoneFor(driverId) {
        const cached = tzCache.get(driverId);
        if (cached)
            return cached;
        try {
            const snap = await db().collection("drivers").doc(driverId).get();
            const tz = resolveDriverTimeZone(snap.exists ? snap.data() : {});
            tzCache.set(driverId, tz);
            return tz;
        }
        catch (_a) {
            return "Africa/Lagos";
        }
    }
    // eslint-disable-next-line no-constant-condition
    while (true) {
        let query = db()
            .collection("driver_streaks")
            .orderBy(admin.firestore.FieldPath.documentId())
            .limit(500);
        if (lastDoc) {
            query = query.startAfter(lastDoc);
        }
        const snap = await query.get();
        if (snap.empty)
            break;
        const batch = db().batch();
        let batchCount = 0;
        for (const doc of snap.docs) {
            const data = doc.data();
            const driverId = data["driverId"] || doc.id;
            const tz = await timeZoneFor(driverId);
            const today = localDateString(tz, now);
            if (data["resetDateLocal"] === today)
                continue;
            batch.set(doc.ref, {
                driverId,
                currentLevel: 1,
                currentStep: 0,
                level1PaidHistory: [],
                level1PaidCommissionHistory: [],
                dailyStreakCompleted: false,
                // Preserve streakActive and baseCommissionRate from config
                streakActive: (_a = data["streakActive"]) !== null && _a !== void 0 ? _a : true,
                baseCommissionRate: (_b = data["baseCommissionRate"]) !== null && _b !== void 0 ? _b : 0.20,
                resetDateLocal: today,
                updatedAt: admin.firestore.FieldValue.serverTimestamp(),
            }, { merge: true });
            batchCount++;
        }
        if (batchCount > 0)
            await batch.commit();
        totalReset += batchCount;
        lastDoc = snap.docs[snap.docs.length - 1];
        if (snap.size < 500)
            break;
    }
    console.log(`scheduledResetStreaks: local-midnight sweep complete. ` +
        `${totalReset} driver streak documents reset.`);
});
//# sourceMappingURL=driverStreak.js.map