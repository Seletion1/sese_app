import * as admin from "firebase-admin";
import { nairaToKobo } from "./driverStreak";

const db = () => admin.firestore();

export interface StreakTier {
  completedTripsTrigger: number;
  bonusPayout: number;
}

export interface DynamicStreakRewardConfig {
  enabled: boolean;
  cycle: "daily" | "weekly" | "monthly";
  tiers: StreakTier[];
  grandCompletionCashAward: number;
  grandCompletionTargetTrips: number;
}

export interface UserRewardProgressDoc {
  userId: string;
  role: "driver" | "customer";
  cycle: "daily" | "weekly" | "monthly";
  periodKey: string;
  completedTrips: number;
  awardedMilestones: number[];
  grandAwardClaimed: boolean;
  lastTripId: string;
  updatedAt: admin.firestore.FieldValue;
}

const DEFAULT_DRIVER_REWARDS: DynamicStreakRewardConfig = {
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

const DEFAULT_CUSTOMER_REWARDS: DynamicStreakRewardConfig = {
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
export async function resolveDynamicStreakRewards(
  role: "driver" | "customer",
  countryCode: string = "NG",
  stateOrRegion: string = ""
): Promise<DynamicStreakRewardConfig> {
  const defaults = role === "driver" ? DEFAULT_DRIVER_REWARDS : DEFAULT_CUSTOMER_REWARDS;
  const fieldKey = role === "driver" ? "streakRewards" : "customerStreakRewards";

  const upperCountry = (countryCode || "NG").trim().toUpperCase();
  const cleanState = (stateOrRegion || "").trim().toUpperCase().replace(/ /g, "_");

  const docIds: string[] = [];
  if (cleanState) {
    docIds.push(`state_${upperCountry}_${cleanState}`);
  }
  docIds.push(`country_${upperCountry}`);
  docIds.push("global_default");

  for (const docId of docIds) {
    try {
      const snap = await db().collection("system_configs").doc(docId).get();
      if (snap.exists) {
        const raw = snap.data()?.[fieldKey];
        if (raw && typeof raw === "object") {
          const rawTiers = Array.isArray(raw.tiers) ? raw.tiers : defaults.tiers;
          const parsedTiers: StreakTier[] = rawTiers.map((t: any) => ({
            completedTripsTrigger: Number(t.completedTripsTrigger) || 0,
            bonusPayout: Number(t.bonusPayout) || 0,
          }));

          return {
            enabled: raw.enabled !== false,
            cycle: ["daily", "weekly", "monthly"].includes(raw.cycle) ? raw.cycle : defaults.cycle,
            tiers: parsedTiers,
            grandCompletionCashAward:
              Number(raw.grandCompletionCashAward) ?? defaults.grandCompletionCashAward,
            grandCompletionTargetTrips:
              Number(raw.grandCompletionTargetTrips) ?? defaults.grandCompletionTargetTrips,
          };
        }
      }
    } catch (e) {
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
export function getCyclePeriodKey(
  cycle: "daily" | "weekly" | "monthly",
  now: Date = new Date()
): string {
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
export async function evaluateAndGrantStreakRewards(
  userId: string,
  role: "driver" | "customer",
  tripId: string,
  countryCode: string = "NG",
  stateOrRegion: string = ""
): Promise<{
  completedTrips: number;
  awardedMilestones: number[];
  grandAwardClaimed: boolean;
  totalAwardNaira: number;
}> {
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
    const existing = progressSnap.exists ? progressSnap.data()! : {};

    const currentTrips = Number(existing.completedTrips) || 0;
    const awardedMilestones: number[] = Array.isArray(existing.awardedMilestones)
      ? [...existing.awardedMilestones]
      : [];
    let grandAwardClaimed = Boolean(existing.grandAwardClaimed);

    const newTripCount = currentTrips + 1;
    const newUnlockedTiers: StreakTier[] = [];

    // Evaluate milestone tiers
    for (const tier of cfg.tiers) {
      if (
        newTripCount >= tier.completedTripsTrigger &&
        !awardedMilestones.includes(tier.completedTripsTrigger)
      ) {
        awardedMilestones.push(tier.completedTripsTrigger);
        newUnlockedTiers.push(tier);
      }
    }

    // Evaluate grand award
    let triggerGrand = false;
    if (
      newTripCount >= cfg.grandCompletionTargetTrips &&
      !grandAwardClaimed &&
      cfg.grandCompletionCashAward > 0
    ) {
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
      const totalAwardKobo = nairaToKobo(totalAwardNaira);
      tx.set(
        walletRef,
        { balance: admin.firestore.FieldValue.increment(totalAwardKobo) },
        { merge: true }
      );

      // Append milestone transactions
      for (const tier of newUnlockedTiers) {
        const tierKobo = nairaToKobo(tier.bonusPayout);
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
        const grandKobo = nairaToKobo(cfg.grandCompletionCashAward);
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
    tx.set(
      progressRef,
      {
        userId,
        role,
        cycle: cfg.cycle,
        periodKey,
        completedTrips: newTripCount,
        awardedMilestones,
        grandAwardClaimed,
        lastTripId: tripId,
        updatedAt: admin.firestore.FieldValue.serverTimestamp(),
      },
      { merge: true }
    );

    return {
      completedTrips: newTripCount,
      awardedMilestones,
      grandAwardClaimed,
      totalAwardNaira,
    };
  });
}
