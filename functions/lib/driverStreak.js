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
exports.breakDriverStreak = breakDriverStreak;
const admin = __importStar(require("firebase-admin"));
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
// ─── Cloud Function: onTripCompleted ─────────────────────────────────────────
/**
 * Firestore trigger: fires when a trip document transitions to COMPLETED.
 * Computes streak-aware commission, credits refunds/bonuses, persists state.
 */
exports.onTripCompleted = (0, firestore_1.onDocumentUpdated)("trips/{tripId}", async (event) => {
    var _a, _b, _c, _d, _e, _f, _g, _h, _j, _k, _l, _m, _o, _p, _q, _r, _s, _t;
    const before = (_b = (_a = event.data) === null || _a === void 0 ? void 0 : _a.before) === null || _b === void 0 ? void 0 : _b.data();
    const after = (_d = (_c = event.data) === null || _c === void 0 ? void 0 : _c.after) === null || _d === void 0 ? void 0 : _d.data();
    if (!before || !after)
        return;
    // Only react to the COMPLETED transition
    if (before["status"] === "COMPLETED" || after["status"] !== "COMPLETED") {
        return;
    }
    const tripId = event.params.tripId;
    const driverId = (_e = after["driver"]) === null || _e === void 0 ? void 0 : _e["driverId"];
    if (!driverId) {
        console.warn(`onTripCompleted[${tripId}]: no driverId, skipping streak`);
        return;
    }
    // Determine fare amount from the trip doc
    // fareTiers is an array [{tierId, fareAmount}]; we take the first selected tier.
    const fareTiers = Array.isArray(after["fareTiers"]) ? after["fareTiers"] : [];
    const selectedTiers = Array.isArray(after["selectedTiers"])
        ? after["selectedTiers"]
        : [];
    const matchedTier = fareTiers.find((t) => selectedTiers.includes(t.tierId));
    const fareAmount = (_h = (_f = matchedTier === null || matchedTier === void 0 ? void 0 : matchedTier.fareAmount) !== null && _f !== void 0 ? _f : (_g = fareTiers[0]) === null || _g === void 0 ? void 0 : _g.fareAmount) !== null && _h !== void 0 ? _h : 0;
    if (fareAmount <= 0) {
        console.warn(`onTripCompleted[${tripId}]: fareAmount=0, skipping`);
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
    // Build the Firestore write batch
    const batch = db().batch();
    // 1. Persist updated streak state (both history keys for compat)
    const streakRef = db().collection("driver_streaks").doc(driverId);
    batch.set(streakRef, streakToMap(result.newState, driverId), { merge: true });
    // 2. Annotate the trip with the settled commission details
    const tripRef = db().collection("trips").doc(tripId);
    batch.update(tripRef, {
        "settlement.commissionRate": result.commissionRate,
        "settlement.commissionAmount": result.commissionAmount,
        "settlement.cashBackAmount": result.cashBackAmount,
        "settlement.cashBonusAmount": result.cashBonusAmount,
        "settlement.streakLevel": streak.currentLevel,
        "settlement.streakStep": streak.currentStep,
        "settlement.settledAt": admin.firestore.FieldValue.serverTimestamp(),
    });
    // 3. Credit cash-back / bonus to driver wallet (Level 2 & 3)
    //
    // UNIT: `wallets/{uid}.balance` is KOBO (integer minor units) — the same
    // unit `payments.ts` credits top-ups in and the same unit the app reads
    // via `PaymentService.walletBalanceKoboStream`. The streak math above is
    // in NAIRA (it is derived from the naira fare), so it MUST be converted
    // before touching the wallet. Crediting raw naira here made the balance
    // 100x too small and silently mixed units in one field.
    const walletCreditNaira = result.cashBackAmount + result.cashBonusAmount;
    const walletCreditKobo = nairaToKobo(walletCreditNaira);
    if (walletCreditKobo > 0) {
        const walletRef = db().collection("wallets").doc(driverId);
        batch.set(walletRef, { balance: admin.firestore.FieldValue.increment(walletCreditKobo) }, { merge: true });
        // Wallet transaction record
        const txRef = walletRef.collection("transactions").doc();
        const txType = result.cashBonusAmount > 0
            ? "streak_level3_bonus"
            : "streak_level2_cashback";
        batch.set(txRef, {
            type: txType,
            amount: walletCreditKobo,
            amountKobo: walletCreditKobo,
            amountNaira: walletCreditNaira,
            tripId,
            streakLevel: streak.currentLevel,
            streakStep: streak.currentStep,
            createdAt: admin.firestore.FieldValue.serverTimestamp(),
        });
    }
    // 4. Grand Award: credit extra wallet payout + set celebration flag on trip
    if (result.grandAwardTriggered && cfg.completionCashAward > 0) {
        const grandAwardKobo = nairaToKobo(cfg.completionCashAward);
        const walletRef = db().collection("wallets").doc(driverId);
        batch.set(walletRef, { balance: admin.firestore.FieldValue.increment(grandAwardKobo) }, { merge: true });
        const awardTxRef = walletRef.collection("transactions").doc();
        batch.set(awardTxRef, {
            type: "streak_grand_award",
            amount: grandAwardKobo,
            amountKobo: grandAwardKobo,
            amountNaira: cfg.completionCashAward,
            tripId,
            createdAt: admin.firestore.FieldValue.serverTimestamp(),
        });
        // Flag the trip so the driver app shows the celebration modal
        batch.update(tripRef, {
            "settlement.grandAwardTriggered": true,
            "settlement.grandAwardAmount": cfg.completionCashAward,
        });
    }
    await batch.commit();
    // 5. Automated Residual Referral Commission Split Engine
    try {
        const customerId = String((_k = (_j = after["customerId"]) !== null && _j !== void 0 ? _j : after["userId"]) !== null && _k !== void 0 ? _k : "");
        const driverName = String((_m = (_l = driverData["fullName"]) !== null && _l !== void 0 ? _l : driverData["displayName"]) !== null && _m !== void 0 ? _m : "Driver");
        const refSplits = await processReferralCommissions(tripId, customerId, driverId, driverName, fareAmount);
        await db().collection("trips").doc(tripId).update({
            "settlement.platformFeeNaira": refSplits.platformFeeNaira,
            "settlement.driverReferrerCutNaira": refSplits.driverReferrerCutNaira,
            "settlement.customerReferrerCutNaira": refSplits.customerReferrerCutNaira,
            "settlement.netPlatformProfitNaira": refSplits.netPlatformProfitNaira,
            "settlement.netDriverPayoutNaira": refSplits.netDriverPayoutNaira,
        });
    }
    catch (e) {
        console.warn(`onTripCompleted[${tripId}]: referral commission processing warning: ${e}`);
    }
    // 6. Dynamic Streak & Reward Overrides Evaluation (Driver & Customer)
    try {
        await (0, streakRewards_1.evaluateAndGrantStreakRewards)(driverId, "driver", tripId, countryCode, stateOrRegion);
    }
    catch (e) {
        console.warn(`onTripCompleted[${tripId}]: driver streak reward evaluation warning: ${e}`);
    }
    try {
        const customerId = String((_p = (_o = after["customerId"]) !== null && _o !== void 0 ? _o : after["userId"]) !== null && _p !== void 0 ? _p : "");
        if (customerId) {
            const custSnap = await db().collection("users").doc(customerId).get();
            const custData = custSnap.exists ? custSnap.data() : {};
            const custCountry = String((_r = (_q = custData["countryCode"]) !== null && _q !== void 0 ? _q : countryCode) !== null && _r !== void 0 ? _r : "NG");
            const custState = String((_t = (_s = custData["stateOrRegion"]) !== null && _s !== void 0 ? _s : stateOrRegion) !== null && _t !== void 0 ? _t : "");
            await (0, streakRewards_1.evaluateAndGrantStreakRewards)(customerId, "customer", tripId, custCountry, custState);
        }
    }
    catch (e) {
        console.warn(`onTripCompleted[${tripId}]: customer streak reward evaluation warning: ${e}`);
    }
    console.log(`onTripCompleted[${tripId}] driver=${driverId} ` +
        `L${streak.currentLevel}S${streak.currentStep} ` +
        `fare=${fareAmount} commission=${result.commissionAmount} ` +
        `cashBack=${result.cashBackAmount} bonus=${result.cashBonusAmount} ` +
        `grandAward=${result.grandAwardTriggered}`);
});
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
                userReferralCommissionRate = d.userReferralCommissionRate;
            if (typeof d.agentReferralCommissionRate === "number")
                agentReferralCommissionRate = d.agentReferralCommissionRate;
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
        }
    }
    catch (_a) {
        // Fall back to defaults
    }
    return { platformBaseCommissionRate, driverReferrerRate, customerReferrerRate };
}
async function processReferralCommissions(tripId, customerId, driverId, driverName, totalFareNaira) {
    var _a, _b, _c, _d, _e, _f, _g, _h, _j, _k, _l, _m;
    const finCfg = await getBackendFinancialConfig();
    const settings = await getReferralSettings();
    const platformFeeNaira = totalFareNaira * (settings.platformBaseCommissionRate / 100);
    let driverReferrerCutNaira = 0;
    let customerReferrerCutNaira = 0;
    const nowMs = Date.now();
    const now = admin.firestore.FieldValue.serverTimestamp();
    // Helper: Process referral credit to seseCoinBalance + auto-sweep check
    const creditReferrerCoins = async (referrerId, refereeId, refereeName, signupTimestamp, type) => {
        var _a, _b, _c, _d, _e;
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
        // Determine referrer role & commission rates
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
        const rate = isAgentOrStaff ? finCfg.agentReferralCommissionRate : finCfg.userReferralCommissionRate;
        const maxDays = isAgentOrStaff ? finCfg.agentReferralDurationDays : finCfg.standardReferralDurationDays;
        if (ageDays > maxDays)
            return 0; // Eligibility window expired
        const cutNaira = totalFareNaira * rate;
        if (cutNaira <= 0)
            return 0;
        const wRef = db().collection("wallets").doc(targetUid);
        const txRef = wRef.collection("transactions").doc();
        const auditRef = db().collection("wallet_transactions").doc();
        const earnRef = db().collection("referral_earnings").doc();
        const note = `+₦${cutNaira.toFixed(2)} referral bonus received from ${refereeName || 'Referred User'} for Order #${tripId}`;
        await db().runTransaction(async (tx) => {
            var _a;
            const wSnap = await tx.get(wRef);
            const wData = wSnap.exists ? ((_a = wSnap.data()) !== null && _a !== void 0 ? _a : {}) : {};
            const currentCoins = typeof wData.seseCoinBalance === "number" ? wData.seseCoinBalance : 0;
            const newCoins = currentCoins + cutNaira;
            // Auto-Sweep check
            if (newCoins >= finCfg.maxBonusThreshold) {
                tx.set(wRef, {
                    seseCoinBalance: 0,
                    mainWalletBalance: admin.firestore.FieldValue.increment(newCoins),
                    updatedAt: now,
                }, { merge: true });
                tx.set(txRef, {
                    type: "sese_coin_auto_sweep",
                    amountNaira: newCoins,
                    note: `Auto-swept ₦${newCoins.toFixed(2)} in SeSe Coins to withdrawable wallet cash.`,
                    createdAt: now,
                });
            }
            else {
                tx.set(wRef, {
                    seseCoinBalance: admin.firestore.FieldValue.increment(cutNaira),
                    updatedAt: now,
                }, { merge: true });
                tx.set(txRef, {
                    type: type === "driver" ? "REFERRAL_COMMISSION_DRIVER" : "REFERRAL_COMMISSION_CUSTOMER",
                    amountNaira: cutNaira,
                    note,
                    tripId,
                    refereeId,
                    createdAt: now,
                });
            }
            tx.set(auditRef, {
                type: type === "driver" ? "REFERRAL_COMMISSION_DRIVER" : "REFERRAL_COMMISSION_CUSTOMER",
                userId: targetUid,
                refereeId,
                tripId,
                amountNaira: cutNaira,
                createdAt: now,
            });
            tx.set(earnRef, {
                referrerId: targetUid,
                refereeId,
                amount: cutNaira,
                orderId: tripId,
                type: `${type}_commission`,
                createdAt: now,
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
                const referrerId = String((_c = (_b = (_a = dData.referredBy) !== null && _a !== void 0 ? _a : dData.referred_by_code) !== null && _b !== void 0 ? _b : dData.referrerId) !== null && _c !== void 0 ? _c : "");
                if (referrerId && referrerId !== driverId) {
                    const refereeName = String((_e = (_d = dData.fullName) !== null && _d !== void 0 ? _d : driverName) !== null && _e !== void 0 ? _e : "Driver");
                    const signupTs = (_f = dData.referralSignupAt) !== null && _f !== void 0 ? _f : dData.createdAt;
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
                const referrerId = String((_j = (_h = (_g = cData.referredBy) !== null && _g !== void 0 ? _g : cData.referred_by_code) !== null && _h !== void 0 ? _h : cData.referrerId) !== null && _j !== void 0 ? _j : "");
                if (referrerId && referrerId !== customerId) {
                    const refereeName = String((_l = (_k = cData.fullName) !== null && _k !== void 0 ? _k : cData.displayName) !== null && _l !== void 0 ? _l : "Customer");
                    const signupTs = (_m = cData.referralSignupAt) !== null && _m !== void 0 ? _m : cData.createdAt;
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
    var _a, _b, _c, _d, _e, _f;
    const before = (_b = (_a = event.data) === null || _a === void 0 ? void 0 : _a.before) === null || _b === void 0 ? void 0 : _b.data();
    const after = (_d = (_c = event.data) === null || _c === void 0 ? void 0 : _c.after) === null || _d === void 0 ? void 0 : _d.data();
    if (!before || !after)
        return;
    // Only react to CANCELLED transition
    if (before["status"] === "CANCELLED" || after["status"] !== "CANCELLED") {
        return;
    }
    const cancellationSource = after["cancellationSource"] || "unknown";
    // Customer cancel and driver no-show are streak-protected
    if (cancellationSource === "customer" ||
        cancellationSource === "driver_no_show") {
        return;
    }
    // All other cases (driver_before_arrival, ping_expired, etc.) break the streak
    const driverId = (_f = (_e = after["driver"]) === null || _e === void 0 ? void 0 : _e["driverId"]) !== null && _f !== void 0 ? _f : after["pingDriverId"];
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