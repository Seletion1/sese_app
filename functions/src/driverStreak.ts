import * as admin from "firebase-admin";
import { onDocumentUpdated } from "firebase-functions/v2/firestore";
import { onSchedule } from "firebase-functions/v2/scheduler";
import { evaluateAndGrantStreakRewards } from "./streakRewards";

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
export function nairaToKobo(naira: number): number {
  if (!Number.isFinite(naira)) return 0;
  return Math.round(naira * 100);
}

// ─── Commission Rate Tables ─────────────────────────────────────────────────

/** Level 1 commission rates indexed by step (0-6). */
export const L1_RATES = [0.15, 0.125, 0.10, 0.075, 0.05, 0.025, 0.0];

/** Level 3 bonus rates (added to driver wallet) indexed by step (0-6). */
export const L3_BONUS_RATES = [0.025, 0.05, 0.075, 0.10, 0.125, 0.15, 0.20];

/** Country → IANA timezone for local-midnight reset computation. */
const COUNTRY_TIMEZONES: Record<string, string> = {
  NG: "Africa/Lagos",
  GH: "Africa/Accra",
  KE: "Africa/Nairobi",
  ZA: "Africa/Johannesburg",
  US: "America/New_York",
  GB: "Europe/London",
  CA: "America/Toronto",
};

/** Resolves the driver's IANA timezone (explicit doc field wins). */
export function resolveDriverTimeZone(
  driverData: admin.firestore.DocumentData | Record<string, unknown>
): string {
  const explicit = (driverData as Record<string, unknown>)["timezone"];
  if (typeof explicit === "string" && explicit.trim()) return explicit.trim();
  const country = String(
    (driverData as Record<string, unknown>)["countryCode"] ?? "NG"
  ).toUpperCase();
  return COUNTRY_TIMEZONES[country] ?? "Africa/Lagos";
}

/** Local calendar date (YYYY-MM-DD) for `nowMs` in `timeZone`. */
export function localDateString(timeZone: string, nowMs: number): string {
  try {
    return new Intl.DateTimeFormat("en-CA", {
      timeZone,
      year: "numeric",
      month: "2-digit",
      day: "2-digit",
    }).format(new Date(nowMs));
  } catch {
    return new Date(nowMs).toISOString().slice(0, 10);
  }
}

// ─── Config helpers ──────────────────────────────────────────────────────────

interface DailyStreakConfig {
  streakEnabled: boolean;
  baseCommissionRate: number;
  noShowWaitMinutes: number;
  completionCashAward: number;
  disabledCountries: string[];
  disabledStates: string[];
}

async function resolveStreakConfig(
  countryCode: string,
  stateOrRegion: string
): Promise<DailyStreakConfig> {
  const defaults: DailyStreakConfig = {
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
      const data = snap.data()!;
      const raw = data["dailyStreakConfig"];
      if (raw && typeof raw === "object") {
        return { ...defaults, ...raw } as DailyStreakConfig;
      }
    }
  }
  return defaults;
}

export function isStreakEnabledForRegion(
  cfg: DailyStreakConfig,
  countryCode: string,
  stateOrRegion: string
): boolean {
  if (!cfg.streakEnabled) return false;
  if (cfg.disabledCountries.includes(countryCode.toUpperCase())) return false;
  const stateKey = `${countryCode.toUpperCase()}_${stateOrRegion
    .toUpperCase()
    .replace(/ /g, "_")}`;
  if (cfg.disabledStates.includes(stateKey)) return false;
  return true;
}

// ─── Driver streak state helpers ──────────────────────────────────────────────

interface DriverStreakDoc {
  streakActive: boolean;
  currentLevel: number;   // 1, 2, or 3
  currentStep: number;    // 0-based
  level1PaidHistory: number[];  // monetary amounts paid in each L1 step
  dailyStreakCompleted: boolean;
  baseCommissionRate: number;
  /** Local calendar date (YYYY-MM-DD) of the last midnight reset. */
  resetDateLocal: string;
}

const FRESH_STREAK = (
  baseRate: number,
  active: boolean,
  resetDateLocal = ""
): DriverStreakDoc => ({
  streakActive: active,
  currentLevel: 1,
  currentStep: 0,
  level1PaidHistory: [],
  dailyStreakCompleted: false,
  baseCommissionRate: baseRate,
  resetDateLocal,
});

function readPaidHistory(d: admin.firestore.DocumentData): number[] {
  // Canonical key is `level1PaidHistory`; the spec alias
  // `level1PaidCommissionHistory` is accepted on read and mirrored on write.
  const raw = Array.isArray(d["level1PaidHistory"])
    ? d["level1PaidHistory"]
    : d["level1PaidCommissionHistory"];
  return Array.isArray(raw) ? (raw as number[]) : [];
}

async function getDriverStreak(driverId: string): Promise<DriverStreakDoc> {
  const snap = await db().collection("driver_streaks").doc(driverId).get();
  if (!snap.exists) {
    return FRESH_STREAK(0.20, true);
  }
  const d = snap.data()!;
  return {
    streakActive: (d["streakActive"] as boolean) ?? true,
    currentLevel: (d["currentLevel"] as number) ?? 1,
    currentStep: (d["currentStep"] as number) ?? 0,
    level1PaidHistory: readPaidHistory(d),
    dailyStreakCompleted: (d["dailyStreakCompleted"] as boolean) ?? false,
    baseCommissionRate: (d["baseCommissionRate"] as number) ?? 0.20,
    resetDateLocal: (d["resetDateLocal"] as string) ?? "",
  };
}

/**
 * Serialises a streak state for Firestore. Both history keys are written
 * so readers using either the canonical or the spec alias stay in sync.
 */
function streakToMap(streak: DriverStreakDoc, driverId: string) {
  return {
    ...streak,
    driverId,
    level1PaidCommissionHistory: [...streak.level1PaidHistory],
    updatedAt: admin.firestore.FieldValue.serverTimestamp(),
  };
}

/**
 * Lazy local-midnight reset: if the stored `resetDateLocal` differs from
 * the driver's *today*, the day has rolled over locally and the streak
 * restarts at Level 1, Step 0 (preserving region enable + base rate).
 */
function applyLocalResetIfStale(
  streak: DriverStreakDoc,
  timeZone: string,
  now: number
): DriverStreakDoc {
  const today = localDateString(timeZone, now);
  if (streak.resetDateLocal === today) return streak;
  return {
    ...FRESH_STREAK(streak.baseCommissionRate, streak.streakActive, today),
  };
}

// ─── Commission calculation ──────────────────────────────────────────────────

interface CommissionResult {
  commissionRate: number;       // fraction charged from driver (0-1)
  commissionAmount: number;     // monetary fee deducted from earnings
  cashBackAmount: number;       // cash refunded to driver wallet (Level 2)
  cashBonusAmount: number;      // cash added to driver wallet (Level 3)
  grandAwardTriggered: boolean; // true when L3 Step 6 completes
  newState: DriverStreakDoc;    // updated streak state to persist
}

export function computeCommission(
  streak: DriverStreakDoc,
  fareAmount: number,
  cfg: DailyStreakConfig
): CommissionResult {
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
    commissionRate = L1_RATES[step] ?? 0;
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
    } else {
      newStep = step + 1;
    }
  } else if (level === 2) {
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
    } else {
      newStep = step + 1;
    }
  } else {
    // Level 3 — 0% commission + cash bonus
    commissionRate = 0;
    commissionAmount = 0;
    const bonusRate = L3_BONUS_RATES[step] ?? 0;
    cashBonusAmount = fareAmount * bonusRate;
    if (step === 6) {
      // Grand award! Full cycle complete.
      grandAwardTriggered = true;
      dailyCompleted = true;
      newStep = step; // freeze at step 6 (won't advance further)
    } else {
      newStep = step + 1;
    }
  }

  const newState: DriverStreakDoc = {
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
export function applyStreakBreak(streak: DriverStreakDoc): DriverStreakDoc {
  const { currentLevel: level, currentStep: step } = streak;

  if (level === 1) {
    if (step === 0) {
      // Was at the very start — drop fully off-streak (flat rate)
      return { ...streak, streakActive: false, currentLevel: 1, currentStep: 0 };
    }
    // Steps 1-6: drop back to L1 Step 0
    return { ...streak, currentLevel: 1, currentStep: 0 };
  }

  if (level === 2) {
    if (step === 0) {
      // Bounce all the way back to L1 Step 0
      return { ...streak, currentLevel: 1, currentStep: 0 };
    }
    // Steps 1-5: reset to L2 Step 0
    return { ...streak, currentLevel: 2, currentStep: 0 };
  }

  // Level 3 — guard: drop to L1 Step 0
  return { ...streak, currentLevel: 1, currentStep: 0 };
}

// ─── Cloud Function & Core Settlement: onTripCompleted / handleTripCompletion ──

/**
 * Core trip settlement processor: executes synchronously on trip completion or
 * as an idempotent trigger fallback.
 * Computes streak-aware commission, deducts platform commission from driver wallet ledger,
 * credits bonuses/refunds, updates trip settlement, and handles wallet escrow settlement.
 */
export async function handleTripCompletion(
  tripId: string,
  after: admin.firestore.DocumentData
): Promise<void> {
  const driverId: string = String(after["driver"]?.["driverId"] ?? after["driverId"] ?? "");
  if (!driverId) {
    console.warn(`handleTripCompletion[${tripId}]: no driverId, skipping streak`);
    return;
  }

  // Determine fare amount from the trip doc (prioritize top-level fareAmount/proposedFare/finalFare)
  const fareTiers: Array<{ tierId: string; fareAmount: number }> =
    Array.isArray(after["fareTiers"]) ? after["fareTiers"] : [];
  const selectedTiers: string[] = Array.isArray(after["selectedTiers"])
    ? after["selectedTiers"]
    : [];
  const matchedTier = fareTiers.find((t) =>
    selectedTiers.includes(t.tierId)
  );
  const fareAmount: number = Number(
    after["fareAmount"] ??
      after["proposedFare"] ??
      after["finalFare"] ??
      matchedTier?.fareAmount ??
      fareTiers[0]?.fareAmount ??
      0
  );

  if (fareAmount <= 0) {
    console.warn(`handleTripCompletion[${tripId}]: fareAmount=0, skipping`);
    return;
  }

  // Resolve region from driver doc
  const driverSnap = await db().collection("drivers").doc(driverId).get();
  const driverData = driverSnap.exists ? driverSnap.data()! : {};
  const countryCode: string =
    (driverData["countryCode"] as string) || "NG";
  const stateOrRegion: string =
    (driverData["stateOrRegion"] as string) || "";

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
    streak = { ...streak, streakActive: true };
  }
  // Sync the regional enable flag
  streak = {
    ...streak,
    streakActive: streakEnabled ? streak.streakActive : false,
    baseCommissionRate: cfg.baseCommissionRate,
  };

  const result = computeCommission(streak, fareAmount, cfg);

  const isCommissionAlreadySettled = after["settlement"]?.["commissionSettled"] === true;

  if (!isCommissionAlreadySettled) {
    // Build the Firestore write batch
    const batch = db().batch();

    // 1. Persist updated streak state (both history keys for compat)
    const streakRef = db().collection("driver_streaks").doc(driverId);
    batch.set(streakRef, streakToMap(result.newState, driverId), { merge: true });

    // 2. Deduct platform commission fee from driver wallet ledger & annotate trip
    const commissionDebitNaira = result.commissionAmount;
    const commissionDebitKobo = nairaToKobo(commissionDebitNaira);

    if (commissionDebitKobo > 0) {
      const driverWalletRef = db().collection("wallets").doc(driverId);
      batch.set(
        driverWalletRef,
        {
          balance: admin.firestore.FieldValue.increment(-commissionDebitKobo),
          mainWalletBalance: admin.firestore.FieldValue.increment(-commissionDebitNaira),
        },
        { merge: true }
      );

      const commTxRef = driverWalletRef
        .collection("transactions")
        .doc(`${tripId}_commission`);
      batch.set(commTxRef, {
        type: "platform_commission",
        amount: -commissionDebitKobo,
        amountKobo: -commissionDebitKobo,
        amountNaira: -commissionDebitNaira,
        tripId,
        currency: "NGN",
        note: `Platform commission fee for trip ${tripId}`,
        createdAt: admin.firestore.FieldValue.serverTimestamp(),
      });
    }

    const tripRef = db().collection("trips").doc(tripId);
    const tripUpdate: Record<string, any> = {
      "settlement.commissionRate": result.commissionRate,
      "settlement.commissionAmount": result.commissionAmount,
      "settlement.commissionSettled": true,
      "settlement.commissionSettledAt": admin.firestore.FieldValue.serverTimestamp(),
      "settlement.cashBackAmount": result.cashBackAmount,
      "settlement.cashBonusAmount": result.cashBonusAmount,
      "settlement.streakLevel": streak.currentLevel,
      "settlement.streakStep": streak.currentStep,
      "settlement.settledAt": admin.firestore.FieldValue.serverTimestamp(),
    };
    if (!after["completedAt"]) {
      tripUpdate["completedAt"] = admin.firestore.FieldValue.serverTimestamp();
    }
    batch.update(tripRef, tripUpdate);

    // 3. Credit cash-back / bonus to driver wallet (Level 2 & 3)
    const walletCreditNaira = result.cashBackAmount + result.cashBonusAmount;
    const walletCreditKobo = nairaToKobo(walletCreditNaira);
    if (walletCreditKobo > 0) {
      const walletRef = db().collection("wallets").doc(driverId);
      batch.set(
        walletRef,
        {
          balance: admin.firestore.FieldValue.increment(walletCreditKobo),
          mainWalletBalance: admin.firestore.FieldValue.increment(walletCreditNaira),
        },
        { merge: true }
      );
      // Wallet transaction record
      const txRef = walletRef.collection("transactions").doc(`${tripId}_bonus`);
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
      batch.set(
        walletRef,
        {
          balance: admin.firestore.FieldValue.increment(grandAwardKobo),
          mainWalletBalance: admin.firestore.FieldValue.increment(cfg.completionCashAward),
        },
        { merge: true }
      );
      const awardTxRef = walletRef.collection("transactions").doc(`${tripId}_grand_award`);
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

    // 4a-post. Atomically increment completedTrips counter for both driver and customer
    const custIdForTrips = String(after["customerId"] ?? after["userId"] ?? "");
    try {
      const driverUserRef = db().collection("users").doc(driverId);
      await driverUserRef.set(
        { completedTrips: admin.firestore.FieldValue.increment(1) },
        { merge: true }
      );
      if (custIdForTrips) {
        const custUserRef = db().collection("users").doc(custIdForTrips);
        await custUserRef.set(
          { completedTrips: admin.firestore.FieldValue.increment(1) },
          { merge: true }
        );
      }
    } catch (e) {
      console.warn(`handleTripCompletion[${tripId}]: completedTrips increment warning: ${e}`);
    }
  }

  // 4b. Settle Trip Wallet Escrow & Credit Driver Virtual Wallet
  try {
    const walletCoverage = Number(
      after["walletCoverageAmount"] ??
      after["paymentBreakdown"]?.["walletCoverageAmount"] ??
      0
    );
    if (walletCoverage > 0 && !after["walletSettledAt"]) {
      const customerId = String(after["customerId"] ?? after["userId"] ?? "");
      const coverageKobo = nairaToKobo(walletCoverage);

      // 1. Finalize debit on customer's wallet (deduct from main balance, clear escrow)
      if (customerId) {
        const custWalletRef = db().collection("wallets").doc(customerId);
        await custWalletRef.set({
          mainWalletBalance: admin.firestore.FieldValue.increment(-walletCoverage),
          balance: admin.firestore.FieldValue.increment(-coverageKobo),
          escrowBalance: admin.firestore.FieldValue.increment(-walletCoverage),
        }, { merge: true });

        await custWalletRef.collection("transactions").doc(`${tripId}_payment`).set({
          type: "trip_payment",
          amountNaira: -walletCoverage,
          amountKobo: -coverageKobo,
          amount: -coverageKobo,
          tripId,
          currency: "NGN",
          note: `Payment for trip ${tripId}`,
          createdAt: admin.firestore.FieldValue.serverTimestamp(),
        });
      }

      // 2. Credit the wallet portion to the driver's virtual wallet upon trip completion
      const driverWalletRef = db().collection("wallets").doc(driverId);
      await driverWalletRef.set({
        mainWalletBalance: admin.firestore.FieldValue.increment(walletCoverage),
        balance: admin.firestore.FieldValue.increment(coverageKobo),
      }, { merge: true });

      await driverWalletRef.collection("transactions").doc(`${tripId}_wallet_settlement`).set({
        type: "trip_wallet_settlement",
        amountNaira: walletCoverage,
        amountKobo: coverageKobo,
        amount: coverageKobo,
        tripId,
        currency: "NGN",
        note: `Wallet fare portion credited for trip ${tripId}`,
        createdAt: admin.firestore.FieldValue.serverTimestamp(),
      });

      await db().collection("trips").doc(tripId).update({
        walletSettledAt: admin.firestore.FieldValue.serverTimestamp(),
        "paymentBreakdown.walletSettled": true,
      });
    }
  } catch (e) {
    console.warn(`handleTripCompletion[${tripId}]: wallet escrow settlement warning: ${e}`);
  }

  // 5. Automated Residual Referral Commission Split Engine
  try {
    const customerId = String(after["customerId"] ?? after["userId"] ?? "");
    const driverName = String(driverData["fullName"] ?? driverData["displayName"] ?? "Driver");
    const refSplits = await processReferralCommissions(
      tripId,
      customerId,
      driverId,
      driverName,
      fareAmount
    );

    await db().collection("trips").doc(tripId).update({
      "settlement.platformFeeNaira": refSplits.platformFeeNaira,
      "settlement.driverReferrerCutNaira": refSplits.driverReferrerCutNaira,
      "settlement.customerReferrerCutNaira": refSplits.customerReferrerCutNaira,
      "settlement.netPlatformProfitNaira": refSplits.netPlatformProfitNaira,
      "settlement.netDriverPayoutNaira": refSplits.netDriverPayoutNaira,
    });
  } catch (e) {
    console.warn(`handleTripCompletion[${tripId}]: referral commission processing warning: ${e}`);
  }

  // 6. Dynamic Streak & Reward Overrides Evaluation (Driver & Customer)
  try {
    await evaluateAndGrantStreakRewards(
      driverId,
      "driver",
      tripId,
      countryCode,
      stateOrRegion
    );
  } catch (e) {
    console.warn(`handleTripCompletion[${tripId}]: driver streak reward evaluation warning: ${e}`);
  }

  try {
    const customerId = String(after["customerId"] ?? after["userId"] ?? "");
    if (customerId) {
      const custSnap = await db().collection("users").doc(customerId).get();
      const custData = custSnap.exists ? custSnap.data()! : {};
      const custCountry = String(custData["countryCode"] ?? countryCode ?? "NG");
      const custState = String(custData["stateOrRegion"] ?? stateOrRegion ?? "");
      await evaluateAndGrantStreakRewards(
        customerId,
        "customer",
        tripId,
        custCountry,
        custState
      );
    }
  } catch (e) {
    console.warn(`handleTripCompletion[${tripId}]: customer streak reward evaluation warning: ${e}`);
  }

  console.log(
    `handleTripCompletion[${tripId}] driver=${driverId} ` +
    `L${streak.currentLevel}S${streak.currentStep} ` +
    `fare=${fareAmount} commission=${result.commissionAmount} ` +
    `cashBack=${result.cashBackAmount} bonus=${result.cashBonusAmount} ` +
    `grandAward=${result.grandAwardTriggered}`
  );
}

/**
 * Firestore trigger: fires when a trip document transitions to COMPLETED.
 * Idempotently executes trip completion settlement.
 */
export const onTripCompleted = onDocumentUpdated(
  "trips/{tripId}",
  async (event) => {
    const before = event.data?.before?.data();
    const after = event.data?.after?.data();
    if (!before || !after) return;

    // Only react to the COMPLETED transition
    if (before["status"] === "COMPLETED" || after["status"] !== "COMPLETED") {
      return;
    }

    const tripId = event.params.tripId;
    await handleTripCompletion(tripId, after);
  }
);

interface ReferralSettings {
  platformBaseCommissionRate: number;
  driverReferrerRate: number;
  customerReferrerRate: number;
  userReferralCommissionRate?: number;
  agentReferralCommissionRate?: number;
  standardReferralDurationDays?: number;
  agentReferralDurationDays?: number;
}

interface FinancialConfigBackend {
  userReferralCommissionRate: number;
  agentReferralCommissionRate: number;
  standardReferralDurationDays: number;
  agentReferralDurationDays: number;
  maxBonusThreshold: number;
}

function normalizeRateFraction(val: unknown, fallback: number): number {
  if (typeof val !== "number" || isNaN(val)) return fallback;
  return val > 1 ? val / 100 : val;
}

async function getBackendFinancialConfig(): Promise<FinancialConfigBackend> {
  let userReferralCommissionRate = 0.01;
  let agentReferralCommissionRate = 0.02;
  let standardReferralDurationDays = 365;
  let agentReferralDurationDays = 547;
  let maxBonusThreshold = 10000.0;

  try {
    const snap = await db().collection("system_configs").doc("financials").get();
    if (snap.exists && snap.data()) {
      const d = snap.data()!;
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
  } catch {
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

async function getReferralSettings(): Promise<ReferralSettings> {
  let platformBaseCommissionRate = 20.0;
  let driverReferrerRate = 5.0;
  let customerReferrerRate = 5.0;
  let userReferralCommissionRate: number | undefined;
  let agentReferralCommissionRate: number | undefined;
  let standardReferralDurationDays: number | undefined;
  let agentReferralDurationDays: number | undefined;

  try {
    const snap = await db().collection("system_config").doc("referral_settings").get();
    if (snap.exists && snap.data()) {
      const d = snap.data()!;
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
  } catch {
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

async function processReferralCommissions(
  tripId: string,
  customerId: string,
  driverId: string,
  driverName: string,
  totalFareNaira: number
): Promise<{
  platformFeeNaira: number;
  driverReferrerCutNaira: number;
  customerReferrerCutNaira: number;
  netPlatformProfitNaira: number;
  netDriverPayoutNaira: number;
}> {
  const finCfg = await getBackendFinancialConfig();
  const settings = await getReferralSettings();
  const platformFeeNaira = totalFareNaira * (settings.platformBaseCommissionRate / 100);

  let driverReferrerCutNaira = 0;
  let customerReferrerCutNaira = 0;

  const nowMs = Date.now();
  const now = admin.firestore.FieldValue.serverTimestamp();

  // Helper: Process referral credit to seseCoinBalance + auto-sweep check
  const creditReferrerCoins = async (
    referrerId: string,
    refereeId: string,
    refereeName: string,
    signupTimestamp: unknown,
    type: "customer" | "driver"
  ): Promise<number> => {
    let signupMs = nowMs;
    if (signupTimestamp) {
      try {
        signupMs = typeof (signupTimestamp as { toMillis?: () => number }).toMillis === "function"
          ? (signupTimestamp as { toMillis: () => number }).toMillis()
          : new Date(String(signupTimestamp)).getTime();
      } catch (_) {}
    }

    const ageDays = (nowMs - signupMs) / (1000 * 60 * 60 * 24);

    let targetUid = referrerId;
    if (referrerId && referrerId.length < 20) {
      try {
        const codeSnap = await db().collection("referral_codes").doc(referrerId.toUpperCase()).get();
        if (codeSnap.exists) {
          targetUid = String(codeSnap.data()?.referrerId ?? referrerId);
        } else {
          const uQuery = await db().collection("users").where("referralCode", "==", referrerId.toUpperCase()).limit(1).get();
          if (!uQuery.empty) {
            targetUid = uQuery.docs[0].id;
          }
        }
      } catch (_) {}
    }

    // Determine referrer role & commission rates from Hub master settings
    let isAgentOrStaff = false;
    try {
      const refUserSnap = await db().collection("users").doc(targetUid).get();
      if (refUserSnap.exists) {
        const role = String(refUserSnap.data()?.role ?? "");
        if (role === "agent" || role === "staff" || refUserSnap.data()?.isAgent === true) {
          isAgentOrStaff = true;
        }
      }
    } catch (_) {}

    // Dynamic Rate Selection from Hub Settings:
    // 1. Agent/Staff rate: agentReferralCommissionRate (default ~2%)
    // 2. Specific driver/customer rate from system_config/referral_settings or financials (default ~5%)
    let rate = 0.05;
    if (isAgentOrStaff) {
      rate = normalizeRateFraction(
        settings.agentReferralCommissionRate ?? finCfg.agentReferralCommissionRate,
        0.02
      );
    } else if (type === "driver") {
      rate = normalizeRateFraction(
        settings.driverReferrerRate ?? settings.userReferralCommissionRate ?? finCfg.userReferralCommissionRate,
        0.05
      );
    } else {
      rate = normalizeRateFraction(
        settings.customerReferrerRate ?? settings.userReferralCommissionRate ?? finCfg.userReferralCommissionRate,
        0.05
      );
    }

    const maxDays = isAgentOrStaff
      ? (settings.agentReferralDurationDays ?? finCfg.agentReferralDurationDays)
      : (settings.standardReferralDurationDays ?? finCfg.standardReferralDurationDays);

    if (ageDays > maxDays) return 0; // Eligibility window expired

    const cutNaira = totalFareNaira * rate;
    if (cutNaira <= 0) return 0;

    // First qualifying trip check on referee document
    const refereeColl = type === "driver" ? "drivers" : "users";
    const refereeRef = db().collection(refereeColl).doc(refereeId);
    let isFirstTrip = false;
    try {
      const refSnap = await refereeRef.get();
      if (refSnap.exists && !refSnap.data()?.hasCompletedFirstTrip) {
        isFirstTrip = true;
      }
    } catch (_) {}

    const wRef = db().collection("wallets").doc(targetUid);
    const txRef = wRef.collection("transactions").doc();
    const auditRef = db().collection("wallet_transactions").doc();
    const earnRef = db().collection("referral_earnings").doc();

    const tripTag = isFirstTrip ? " (First Qualifying Trip)" : "";
    const note = `+₦${cutNaira.toFixed(2)} referral bonus received from ${refereeName || 'Referred User'} for Order #${tripId}${tripTag}`;

    await db().runTransaction(async (tx) => {
      // Mark referee doc with first qualifying trip milestone
      if (isFirstTrip) {
        tx.set(
          refereeRef,
          {
            hasCompletedFirstTrip: true,
            firstQualifyingTripId: tripId,
            firstQualifyingTripAt: now,
          },
          { merge: true }
        );
      }

      const wSnap = await tx.get(wRef);
      const wData = wSnap.exists ? (wSnap.data() ?? {}) : {};
      const currentCoins = typeof wData.seseCoinBalance === "number" ? wData.seseCoinBalance : 0;
      const newCoins = currentCoins + cutNaira;

      // Auto-Sweep check
      if (newCoins >= finCfg.maxBonusThreshold) {
        tx.set(
          wRef,
          {
            seseCoinBalance: 0,
            mainWalletBalance: admin.firestore.FieldValue.increment(newCoins),
            updatedAt: now,
          },
          { merge: true }
        );

        tx.set(txRef, {
          type: "sese_coin_auto_sweep",
          amountNaira: newCoins,
          note: `Auto-swept ₦${newCoins.toFixed(2)} in SeSe Coins to withdrawable wallet cash.`,
          createdAt: now,
        });
      } else {
        tx.set(
          wRef,
          {
            seseCoinBalance: admin.firestore.FieldValue.increment(cutNaira),
            updatedAt: now,
          },
          { merge: true }
        );

        tx.set(txRef, {
          type: type === "driver" ? "REFERRAL_COMMISSION_DRIVER" : "REFERRAL_COMMISSION_CUSTOMER",
          amountNaira: cutNaira,
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
    });

    return cutNaira;
  };

  // 1. Driver Referrer Check
  if (driverId) {
    try {
      const driverSnap = await db().collection("drivers").doc(driverId).get();
      if (driverSnap.exists) {
        const dData = driverSnap.data()!;
        const referrerId = String(dData.referredBy ?? dData.referred_by_code ?? dData.referrerId ?? "");
        if (referrerId && referrerId !== driverId) {
          const refereeName = String(dData.fullName ?? driverName ?? "Driver");
          const signupTs = dData.referralSignupAt ?? dData.createdAt;
          driverReferrerCutNaira = await creditReferrerCoins(referrerId, driverId, refereeName, signupTs, "driver");
        }
      }
    } catch (e) {
      console.warn(`processReferralCommissions driver check failed: ${e}`);
    }
  }

  // 2. Customer Referrer Check
  if (customerId) {
    try {
      const customerSnap = await db().collection("users").doc(customerId).get();
      if (customerSnap.exists) {
        const cData = customerSnap.data()!;
        const referrerId = String(cData.referredBy ?? cData.referred_by_code ?? cData.referrerId ?? "");
        if (referrerId && referrerId !== customerId) {
          const refereeName = String(cData.fullName ?? cData.displayName ?? "Customer");
          const signupTs = cData.referralSignupAt ?? cData.createdAt;
          customerReferrerCutNaira = await creditReferrerCoins(referrerId, customerId, refereeName, signupTs, "customer");
        }
      }
    } catch (e) {
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
export async function breakDriverStreak(
  driverId: string,
  reason: string
): Promise<DriverStreakDoc | null> {
  const driverSnap = await db().collection("drivers").doc(driverId).get();
  const driverData = driverSnap.exists ? driverSnap.data()! : {};
  const timeZone = resolveDriverTimeZone(driverData);

  let streak = await getDriverStreak(driverId);
  streak = applyLocalResetIfStale(streak, timeZone, Date.now());
  if (streak.dailyStreakCompleted) return null;

  const brokenState = applyStreakBreak(streak);
  const doc = streakToMap(brokenState, driverId);
  await db().collection("driver_streaks").doc(driverId).set(doc, { merge: true });

  console.log(
    `breakDriverStreak: driver=${driverId} reason=${reason} ` +
    `L${streak.currentLevel}S${streak.currentStep} → ` +
    `L${brokenState.currentLevel}S${brokenState.currentStep}`
  );
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
export const onTripCancelled = onDocumentUpdated(
  "trips/{tripId}",
  async (event) => {
    const before = event.data?.before?.data();
    const after = event.data?.after?.data();
    if (!before || !after) return;

    // Only react to CANCELLED transition
    if (before["status"] === "CANCELLED" || after["status"] !== "CANCELLED") {
      return;
    }

    // Release active escrow if not already released
    const walletCoverage = Number(
      after["walletCoverageAmount"] ??
      after["paymentBreakdown"]?.["walletCoverageAmount"] ??
      0
    );
    if (walletCoverage > 0 && after["escrowLocked"] === true && !after["escrowRefundedAt"]) {
      const customerId = String(after["customerId"] ?? "");
      if (customerId) {
        try {
          const custWalletRef = db().collection("wallets").doc(customerId);
          const coverageKobo = nairaToKobo(walletCoverage);
          await custWalletRef.set({
            escrowBalance: admin.firestore.FieldValue.increment(-walletCoverage),
          }, { merge: true });

          await custWalletRef.collection("transactions").add({
            type: "trip_escrow_refund",
            amountNaira: walletCoverage,
            amountKobo: coverageKobo,
            amount: coverageKobo,
            tripId: event.params.tripId,
            currency: "NGN",
            note: `Escrow hold released for cancelled trip ${event.params.tripId}`,
            createdAt: admin.firestore.FieldValue.serverTimestamp(),
          });

          await event.data?.after?.ref.update({
            escrowLocked: false,
            escrowRefundedAt: admin.firestore.FieldValue.serverTimestamp(),
            "paymentBreakdown.escrowLocked": false,
            "paymentBreakdown.escrowRefunded": true,
          });
        } catch (e) {
          console.warn(`onTripCancelled[${event.params.tripId}]: escrow release warning: ${e}`);
        }
      }
    }

    const cancellationSource: string =
      (after["cancellationSource"] as string) || "unknown";

    // Customer cancel and driver no-show are streak-protected
    if (
      cancellationSource === "customer" ||
      cancellationSource === "driver_no_show"
    ) {
      return;
    }

    // All other cases (driver_before_arrival, ping_expired, etc.) break the streak
    const driverId: string =
      after["driver"]?.["driverId"] ?? after["pingDriverId"];
    if (!driverId) return;

    const driverSnap = await db().collection("drivers").doc(driverId).get();
    const driverData = driverSnap.exists ? driverSnap.data()! : {};
    const timeZone = resolveDriverTimeZone(driverData);

    let streak = await getDriverStreak(driverId);
    streak = applyLocalResetIfStale(streak, timeZone, Date.now());
    if (streak.dailyStreakCompleted) return; // already done for today

    const brokenState = applyStreakBreak(streak);

    await db()
      .collection("driver_streaks")
      .doc(driverId)
      .set(streakToMap(brokenState, driverId), { merge: true });

    console.log(
      `onTripCancelled: streak broken for driver=${driverId} ` +
      `source=${cancellationSource} ` +
      `L${streak.currentLevel}S${streak.currentStep} → ` +
      `L${brokenState.currentLevel}S${brokenState.currentStep}`
    );
  }
);

// ─── Cloud Function: scheduledResetStreaks ────────────────────────────────────

/**
 * Local-midnight reset sweeper — runs hourly and resets every driver whose
 * stored `resetDateLocal` differs from *today in their own timezone*.
 * (Trip events also apply the same lazy reset, so the cron is a backstop
 * for idle drivers.) Processes in pages of 500.
 */
export const scheduledResetStreaks = onSchedule(
  { schedule: "0 * * * *", timeZone: "UTC" },
  async () => {
    console.log("scheduledResetStreaks: local-midnight sweep starting...");
    const now = Date.now();
    let totalReset = 0;
    let lastDoc: admin.firestore.DocumentSnapshot | undefined;

    // Cache driver timezones within this run (driverId → timeZone).
    const tzCache = new Map<string, string>();
    async function timeZoneFor(driverId: string): Promise<string> {
      const cached = tzCache.get(driverId);
      if (cached) return cached;
      try {
        const snap = await db().collection("drivers").doc(driverId).get();
        const tz = resolveDriverTimeZone(snap.exists ? snap.data()! : {});
        tzCache.set(driverId, tz);
        return tz;
      } catch {
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
      if (snap.empty) break;

      const batch = db().batch();
      let batchCount = 0;
      for (const doc of snap.docs) {
        const data = doc.data();
        const driverId = (data["driverId"] as string) || doc.id;
        const tz = await timeZoneFor(driverId);
        const today = localDateString(tz, now);
        if ((data["resetDateLocal"] as string) === today) continue;
        batch.set(
          doc.ref,
          {
            driverId,
            currentLevel: 1,
            currentStep: 0,
            level1PaidHistory: [],
            level1PaidCommissionHistory: [],
            dailyStreakCompleted: false,
            // Preserve streakActive and baseCommissionRate from config
            streakActive: data["streakActive"] ?? true,
            baseCommissionRate: data["baseCommissionRate"] ?? 0.20,
            resetDateLocal: today,
            updatedAt: admin.firestore.FieldValue.serverTimestamp(),
          },
          { merge: true }
        );
        batchCount++;
      }
      if (batchCount > 0) await batch.commit();
      totalReset += batchCount;
      lastDoc = snap.docs[snap.docs.length - 1];

      if (snap.size < 500) break;
    }

    console.log(
      `scheduledResetStreaks: local-midnight sweep complete. ` +
      `${totalReset} driver streak documents reset.`
    );
  }
);
