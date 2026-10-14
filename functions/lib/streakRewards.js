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
exports.resolveDynamicStreakRewards = resolveDynamicStreakRewards;
exports.getCyclePeriodKey = getCyclePeriodKey;
exports.evaluateAndGrantStreakRewards = evaluateAndGrantStreakRewards;
const admin = __importStar(require("firebase-admin"));
const driverStreak_1 = require("./driverStreak");
const db = () => admin.firestore();
const DEFAULT_DRIVER_REWARDS = {
    enabled: true,
    cycle: "daily",
    tiers: [
        { completedTripsTrigger: 5, bonusPayout: 1000.0 },
        { completedTripsTrigger: 10, bonusPayout: 2500.0 },
        { completedTripsTrigger: 20, bonusPayout: 6000.0 },
    ],
    grandCompletionCashAward: 15000.0,
    grandCompletionTargetTrips: 30,
};
const DEFAULT_CUSTOMER_REWARDS = {
    enabled: true,
    cycle: "weekly",
    tiers: [
        { completedTripsTrigger: 5, bonusPayout: 500.0 },
        { completedTripsTrigger: 10, bonusPayout: 1200.0 },
        { completedTripsTrigger: 20, bonusPayout: 3000.0 },
    ],
    grandCompletionCashAward: 5000.0,
    grandCompletionTargetTrips: 25,
};
/**
 * Resolves regional Dynamic Streak & Reward Overrides hierarchically:
 * 1. State override: `state_${countryCode}_${stateOrRegion}`
 * 2. Country rule: `country_${countryCode}`
 * 3. Global default: `global_default`
 */
async function resolveDynamicStreakRewards(role, countryCode = "NG", stateOrRegion = "") {
    var _a, _b, _c;
    const defaults = role === "driver" ? DEFAULT_DRIVER_REWARDS : DEFAULT_CUSTOMER_REWARDS;
    const fieldKey = role === "driver" ? "streakRewards" : "customerStreakRewards";
    const upperCountry = (countryCode || "NG").trim().toUpperCase();
    const cleanState = (stateOrRegion || "").trim().toUpperCase().replace(/ /g, "_");
    const docIds = [];
    if (cleanState) {
        docIds.push(`state_${upperCountry}_${cleanState}`);
    }
    docIds.push(`country_${upperCountry}`);
    docIds.push("global_default");
    for (const docId of docIds) {
        try {
            const snap = await db().collection("system_configs").doc(docId).get();
            if (snap.exists) {
                const raw = (_a = snap.data()) === null || _a === void 0 ? void 0 : _a[fieldKey];
                if (raw && typeof raw === "object") {
                    const rawTiers = Array.isArray(raw.tiers) ? raw.tiers : defaults.tiers;
                    const parsedTiers = rawTiers.map((t) => ({
                        completedTripsTrigger: Number(t.completedTripsTrigger) || 0,
                        bonusPayout: Number(t.bonusPayout) || 0,
                    }));
                    return {
                        enabled: raw.enabled !== false,
                        cycle: ["daily", "weekly", "monthly"].includes(raw.cycle) ? raw.cycle : defaults.cycle,
                        tiers: parsedTiers,
                        grandCompletionCashAward: (_b = Number(raw.grandCompletionCashAward)) !== null && _b !== void 0 ? _b : defaults.grandCompletionCashAward,
                        grandCompletionTargetTrips: (_c = Number(raw.grandCompletionTargetTrips)) !== null && _c !== void 0 ? _c : defaults.grandCompletionTargetTrips,
                    };
                }
            }
        }
        catch (e) {
            console.warn(`resolveDynamicStreakRewards[${docId}]: lookup error: ${e}`);
        }
    }
    return defaults;
}
/**
 * Generates cycle period key based on cycle ('daily' | 'weekly' | 'monthly').
 * - daily: YYYY-MM-DD
 * - monthly: YYYY-MM
 * - weekly: YYYY-Www (ISO 8601 week)
 */
function getCyclePeriodKey(cycle, now = new Date()) {
    const yyyy = now.getUTCFullYear();
    const mm = String(now.getUTCMonth() + 1).padStart(2, "0");
    const dd = String(now.getUTCDate()).padStart(2, "0");
    if (cycle === "daily") {
        return `${yyyy}-${mm}-${dd}`;
    }
    if (cycle === "monthly") {
        return `${yyyy}-${mm}`;
    }
    // ISO 8601 week calculation
    const target = new Date(Date.UTC(now.getUTCFullYear(), now.getUTCMonth(), now.getUTCDate()));
    const dayNr = (target.getUTCDay() + 6) % 7;
    target.setUTCDate(target.getUTCDate() - dayNr + 3);
    const firstThursday = target.valueOf();
    target.setUTCMonth(0, 1);
    if (target.getUTCDay() !== 4) {
        target.setUTCMonth(0, 1 + (((4 - target.getUTCDay()) + 7) % 7));
    }
    const weekNumber = 1 + Math.ceil((firstThursday - target.valueOf()) / 604800000);
    return `${yyyy}-W${String(weekNumber).padStart(2, "0")}`;
}
/**
 * Evaluates trip completion against the dynamic streak & reward thresholds.
 * Increments the user's cycle trip count, unlocks milestone cash bonuses,
 * grants grand completion payouts when achieved, and credits the user's wallet in kobo.
 */
async function evaluateAndGrantStreakRewards(userId, role, tripId, countryCode = "NG", stateOrRegion = "") {
    if (!userId) {
        return { completedTrips: 0, awardedMilestones: [], grandAwardClaimed: false, totalAwardNaira: 0 };
    }
    const cfg = await resolveDynamicStreakRewards(role, countryCode, stateOrRegion);
    if (!cfg.enabled) {
        return { completedTrips: 0, awardedMilestones: [], grandAwardClaimed: false, totalAwardNaira: 0 };
    }
    const periodKey = getCyclePeriodKey(cfg.cycle);
    const docId = `${role}_${userId}_${periodKey}`;
    const progressRef = db().collection("user_reward_progress").doc(docId);
    const walletRef = db().collection("wallets").doc(userId);
    return await db().runTransaction(async (tx) => {
        const progressSnap = await tx.get(progressRef);
        const existing = progressSnap.exists ? progressSnap.data() : {};
        const currentTrips = Number(existing.completedTrips) || 0;
        const awardedMilestones = Array.isArray(existing.awardedMilestones)
            ? [...existing.awardedMilestones]
            : [];
        let grandAwardClaimed = Boolean(existing.grandAwardClaimed);
        const newTripCount = currentTrips + 1;
        const newUnlockedTiers = [];
        // Evaluate milestone tiers
        for (const tier of cfg.tiers) {
            if (newTripCount >= tier.completedTripsTrigger &&
                !awardedMilestones.includes(tier.completedTripsTrigger)) {
                awardedMilestones.push(tier.completedTripsTrigger);
                newUnlockedTiers.push(tier);
            }
        }
        // Evaluate grand award
        let triggerGrand = false;
        if (newTripCount >= cfg.grandCompletionTargetTrips &&
            !grandAwardClaimed &&
            cfg.grandCompletionCashAward > 0) {
            grandAwardClaimed = true;
            triggerGrand = true;
        }
        let totalAwardNaira = 0;
        for (const tier of newUnlockedTiers) {
            totalAwardNaira += tier.bonusPayout;
        }
        if (triggerGrand) {
            totalAwardNaira += cfg.grandCompletionCashAward;
        }
        if (totalAwardNaira > 0) {
            const totalAwardKobo = (0, driverStreak_1.nairaToKobo)(totalAwardNaira);
            tx.set(walletRef, { balance: admin.firestore.FieldValue.increment(totalAwardKobo) }, { merge: true });
            // Append milestone transactions
            for (const tier of newUnlockedTiers) {
                const tierKobo = (0, driverStreak_1.nairaToKobo)(tier.bonusPayout);
                const txDocRef = walletRef.collection("transactions").doc();
                tx.set(txDocRef, {
                    type: `${role}_streak_milestone_bonus`,
                    amount: tierKobo,
                    amountKobo: tierKobo,
                    amountNaira: tier.bonusPayout,
                    milestoneTrips: tier.completedTripsTrigger,
                    role,
                    cycle: cfg.cycle,
                    periodKey,
                    tripId,
                    createdAt: admin.firestore.FieldValue.serverTimestamp(),
                });
            }
            // Append grand award transaction
            if (triggerGrand) {
                const grandKobo = (0, driverStreak_1.nairaToKobo)(cfg.grandCompletionCashAward);
                const grandTxDocRef = walletRef.collection("transactions").doc();
                tx.set(grandTxDocRef, {
                    type: `${role}_streak_grand_award`,
                    amount: grandKobo,
                    amountKobo: grandKobo,
                    amountNaira: cfg.grandCompletionCashAward,
                    targetTrips: cfg.grandCompletionTargetTrips,
                    role,
                    cycle: cfg.cycle,
                    periodKey,
                    tripId,
                    createdAt: admin.firestore.FieldValue.serverTimestamp(),
                });
            }
        }
        // Persist progress state
        tx.set(progressRef, {
            userId,
            role,
            cycle: cfg.cycle,
            periodKey,
            completedTrips: newTripCount,
            awardedMilestones,
            grandAwardClaimed,
            lastTripId: tripId,
            updatedAt: admin.firestore.FieldValue.serverTimestamp(),
        }, { merge: true });
        return {
            completedTrips: newTripCount,
            awardedMilestones,
            grandAwardClaimed,
            totalAwardNaira,
        };
    });
}
//# sourceMappingURL=streakRewards.js.map