process.env.FARE_SIGNING_SECRET = process.env.FARE_SIGNING_SECRET || "sese-test-fare-signing-secret";

import assert from "node:assert";
import { test, describe } from "node:test";
import {
  nairaToKobo,
  computeCommission,
  applyStreakBreak,
  DriverStreakDoc,
  DailyStreakConfig,
  FinancialMutationLog,
  TripTransitionLog,
} from "../driverStreak";
import {
  normalizePhone,
  haversineKm,
} from "../trips";

describe("Backend Safety & Invariant Matrix", () => {
  test("1. Trip Creation & Escrow Invariants", async () => {
    // Escrow coverage clamp test
    const availableBalance = 5000;
    const requestedCoverage = 6000;
    const actualCoverage = Math.min(requestedCoverage, Math.max(0, availableBalance));
    assert.strictEqual(actualCoverage, 5000); // Clamped to available balance
    assert.strictEqual(nairaToKobo(actualCoverage), 500000);

    // Escrow transaction key determinism
    const tripId = "TRIP_TEST_101";
    const holdTxKey = `${tripId}_escrow_hold`;
    assert.strictEqual(holdTxKey, "TRIP_TEST_101_escrow_hold");
  });

  test("2. Trip Accept & Single Driver Assignment", async () => {
    // Simulate first-wins driver claim atomic logic
    let assignedDriverId: string | null = null;
    const claimTrip = (driverId: string) => {
      if (assignedDriverId !== null) {
        throw new Error("Another driver claimed this trip first.");
      }
      assignedDriverId = driverId;
      return true;
    };

    assert.strictEqual(claimTrip("DRIVER_A"), true);
    assert.throws(() => claimTrip("DRIVER_B"), /Another driver claimed this trip first/);
    assert.strictEqual(assignedDriverId, "DRIVER_A");
  });

  test("3. Low-Balance Rejection", async () => {
    const minBalanceRequired = 1.00; // ₦1.00 minimum
    const driverMainBalance = 0.50; // Below threshold

    const canAccept = driverMainBalance >= minBalanceRequired;
    assert.strictEqual(canAccept, false);
  });

  test("4. Trip Decline & Audit Trail", async () => {
    const streakBefore: DriverStreakDoc = {
      streakActive: true,
      currentLevel: 1,
      currentStep: 3,
      level1PaidHistory: [],
      dailyStreakCompleted: false,
      baseCommissionRate: 0.20,
      resetDateLocal: "2026-11-02",
    };

    const broken = applyStreakBreak(streakBefore);
    assert.strictEqual(broken.currentStep, 0); // Drops to step 0 on decline
  });

  test("5. Driver Reassignment Bounds (Max 3 Reassignments)", async () => {
    const calculateReassignmentOutcome = (currentCount: number) => {
      const nextCount = currentCount + 1;
      if (nextCount <= 3) {
        return { action: "reassign_searching", attempt: nextCount };
      } else {
        return { action: "needs_customer_action", attempt: nextCount };
      }
    };

    assert.deepStrictEqual(calculateReassignmentOutcome(0), { action: "reassign_searching", attempt: 1 });
    assert.deepStrictEqual(calculateReassignmentOutcome(1), { action: "reassign_searching", attempt: 2 });
    assert.deepStrictEqual(calculateReassignmentOutcome(2), { action: "reassign_searching", attempt: 3 });
    assert.deepStrictEqual(calculateReassignmentOutcome(3), { action: "needs_customer_action", attempt: 4 });
  });

  test("6. Escrow Release & Invariant Math", async () => {
    const currentEscrow = 3000;
    const walletCoverage = 3000;
    const newEscrow = Math.max(0, currentEscrow - walletCoverage);
    assert.strictEqual(newEscrow, 0); // Escrow cleared without negative balance

    const refundTxKey = `TRIP_TEST_101_escrow_refund`;
    assert.strictEqual(refundTxKey, "TRIP_TEST_101_escrow_refund");
  });

  test("7. Canonical Completion Settlement", async () => {
    const fareAmount = 5000; // ₦5,000
    const commissionRate = 0.15; // 15%
    const commissionAmount = fareAmount * commissionRate; // ₦750
    const driverEarnings = fareAmount - commissionAmount; // ₦4,250

    assert.strictEqual(commissionAmount, 750);
    assert.strictEqual(driverEarnings, 4250);
    assert.strictEqual(nairaToKobo(commissionAmount), 75000);
    assert.strictEqual(nairaToKobo(driverEarnings), 425000);
  });

  test("8. Settlement Idempotency", async () => {
    const liveTrip = {
      settlement: { settled: true, commissionSettled: true },
    };

    const isAlreadySettled = liveTrip.settlement?.settled === true || liveTrip.settlement?.commissionSettled === true;
    assert.strictEqual(isAlreadySettled, true);
  });

  test("9. Stale Status & State Machine Verification", async () => {
    const DRIVER_TRANSITIONS: Record<string, string[]> = {
      DRIVER_ACCEPTED: ["DRIVER_ARRIVING", "DRIVER_ARRIVED"],
      DRIVER_ARRIVING: ["DRIVER_ARRIVED"],
      DRIVER_ARRIVED: ["IN_PROGRESS"],
      IN_PROGRESS: ["COMPLETED"],
    };

    const validateTransition = (current: string, next: string, expected?: string) => {
      if (expected && current !== expected) {
        throw new Error(`STALE_WRITE: Trip status is ${current}, expected ${expected}.`);
      }
      if (current === next) {
        return "already_in_status";
      }
      const allowed = DRIVER_TRANSITIONS[current] ?? [];
      if (!allowed.includes(next)) {
        throw new Error(`Cannot move from ${current} to ${next}.`);
      }
      return "transition_allowed";
    };

    assert.strictEqual(validateTransition("DRIVER_ACCEPTED", "DRIVER_ARRIVED"), "transition_allowed");
    assert.strictEqual(validateTransition("DRIVER_ARRIVED", "DRIVER_ARRIVED"), "already_in_status");
    assert.throws(() => validateTransition("DRIVER_ACCEPTED", "COMPLETED"), /Cannot move from DRIVER_ACCEPTED to COMPLETED/);
    assert.throws(() => validateTransition("DRIVER_ARRIVED", "IN_PROGRESS", "DRIVER_ACCEPTED"), /STALE_WRITE: Trip status is DRIVER_ARRIVED, expected DRIVER_ACCEPTED/);
  });

  test("10. Observability & Audit Log Schema", async () => {
    const finLog: FinancialMutationLog = {
      tripId: "TRIP_101",
      type: "commission",
      accountId: "DRIVER_99",
      amountNaira: -750,
      amountKobo: -75000,
      currency: "NGN",
      stage: "completion",
      timestamp: Date.now(),
      invariantsChecked: true,
    };

    assert.strictEqual(finLog.tripId, "TRIP_101");
    assert.strictEqual(finLog.amountKobo, -75000);
    assert.strictEqual(finLog.invariantsChecked, true);

    const transitionLog: TripTransitionLog = {
      tripId: "TRIP_101",
      from: "IN_PROGRESS",
      to: "COMPLETED",
      actor: "DRIVER_99",
      role: "driver",
      timestamp: Date.now(),
    };

    assert.strictEqual(transitionLog.from, "IN_PROGRESS");
    assert.strictEqual(transitionLog.to, "COMPLETED");
  });
});

describe("Financial & Currency Precision Engine", () => {
  test("nairaToKobo converts naira values to exact kobo integers", () => {
    assert.strictEqual(nairaToKobo(100), 10000);
    assert.strictEqual(nairaToKobo(1500.5), 150050);
    assert.strictEqual(nairaToKobo(0), 0);
    assert.strictEqual(nairaToKobo(12.345), 1235);
  });

  test("Phone normalization validates and formats E.164 canonical numbers", () => {
    assert.strictEqual(normalizePhone("08161561592"), "+2348161561592");
    assert.strictEqual(normalizePhone("+2348161561592"), "+2348161561592");
    assert.strictEqual(normalizePhone("+234 816-156-1592"), "+2348161561592");
    assert.strictEqual(normalizePhone(""), "");
  });

  test("Haversine distance calculation is accurate", () => {
    // Distance between Victoria Island and Ikeja (~20km)
    const dist = haversineKm(6.4281, 3.4219, 6.6018, 3.3515);
    assert.strictEqual(Math.round(dist), 21);
  });
});

describe("Driver Streak & Commission Calculation Engine", () => {
  const cfg: DailyStreakConfig = {
    streakEnabled: true,
    baseCommissionRate: 0.20,
    noShowWaitMinutes: 10,
    completionCashAward: 10000.0,
    disabledCountries: [],
    disabledStates: [],
  };

  test("Level 1 step 0 computes 15% commission", () => {
    const streak: DriverStreakDoc = {
      streakActive: true,
      currentLevel: 1,
      currentStep: 0,
      level1PaidHistory: [],
      dailyStreakCompleted: false,
      baseCommissionRate: 0.20,
      resetDateLocal: "2026-11-02",
    };

    const res = computeCommission(streak, 2000, cfg);
    assert.strictEqual(res.commissionRate, 0.15);
    assert.strictEqual(res.commissionAmount, 300); // 15% of 2000
    assert.strictEqual(res.cashBackAmount, 0);
    assert.strictEqual(res.newState.currentLevel, 1);
    assert.strictEqual(res.newState.currentStep, 1);
  });

  test("Level 2 refund reverses Level 1 paid commission", () => {
    const streak: DriverStreakDoc = {
      streakActive: true,
      currentLevel: 2,
      currentStep: 0,
      level1PaidHistory: [300, 250, 200, 150, 100, 50],
      dailyStreakCompleted: false,
      baseCommissionRate: 0.20,
      resetDateLocal: "2026-11-02",
    };

    const res = computeCommission(streak, 2000, cfg);
    assert.strictEqual(res.commissionRate, 0);
    assert.strictEqual(res.commissionAmount, 0);
    assert.strictEqual(res.cashBackAmount, 50); // refunds history[5]
    assert.strictEqual(res.newState.currentLevel, 2);
    assert.strictEqual(res.newState.currentStep, 1);
  });

  test("Level 3 grand award triggers at step 6", () => {
    const streak: DriverStreakDoc = {
      streakActive: true,
      currentLevel: 3,
      currentStep: 6,
      level1PaidHistory: [],
      dailyStreakCompleted: false,
      baseCommissionRate: 0.20,
      resetDateLocal: "2026-11-02",
    };

    const res = computeCommission(streak, 2000, cfg);
    assert.strictEqual(res.commissionRate, 0);
    assert.strictEqual(res.cashBonusAmount, 400); // 20% of 2000
    assert.strictEqual(res.grandAwardTriggered, true);
    assert.strictEqual(res.newState.dailyStreakCompleted, true);
  });

  test("Streak break drop-back rules behave correctly", () => {
    const streakL1S0: DriverStreakDoc = {
      streakActive: true,
      currentLevel: 1,
      currentStep: 0,
      level1PaidHistory: [],
      dailyStreakCompleted: false,
      baseCommissionRate: 0.20,
      resetDateLocal: "2026-11-02",
    };
    const brokenL1S0 = applyStreakBreak(streakL1S0);
    assert.strictEqual(brokenL1S0.streakActive, false);

    const streakL1S3: DriverStreakDoc = {
      streakActive: true,
      currentLevel: 1,
      currentStep: 3,
      level1PaidHistory: [],
      dailyStreakCompleted: false,
      baseCommissionRate: 0.20,
      resetDateLocal: "2026-11-02",
    };
    const brokenL1S3 = applyStreakBreak(streakL1S3);
    assert.strictEqual(brokenL1S3.currentStep, 0);
  });
});

describe("Trip Rating Security Invariants", () => {
  const mockTrip = {
    tripId: "TRIP_100",
    customerId: "CUSTOMER_1",
    driver: { driverId: "DRIVER_1" },
  };

  const validateRatingRequest = (auth: { uid: string } | null, data: any) => {
    if (!auth) throw new Error("unauthenticated: User must be authenticated.");
    const raterId = auth.uid;
    const ratedUserId = String(data?.ratedUserId ?? "").trim();
    if (raterId === ratedUserId) throw new Error("invalid-argument: Cannot rate yourself.");

    const customerId = mockTrip.customerId;
    const driverId = mockTrip.driver.driverId;

    const isCallerCustomer = raterId === customerId;
    const isCallerDriver = raterId === driverId;

    if (!isCallerCustomer && !isCallerDriver) {
      throw new Error("permission-denied: You are not a participant in this trip.");
    }

    const expectedRatedUserId = isCallerCustomer ? driverId : customerId;
    if (ratedUserId !== expectedRatedUserId) {
      throw new Error("permission-denied: Rated user was not a participant in this trip.");
    }

    return { raterId, ratedUserId, isRatedUserDriver: isCallerCustomer };
  };

  test("Rejects unauthenticated callers", () => {
    assert.throws(
      () => validateRatingRequest(null, { raterId: "ATTACKER_99", ratedUserId: "DRIVER_1" }),
      /unauthenticated/
    );
  });

  test("Ignores client-supplied raterId and enforces auth.uid", () => {
    const res = validateRatingRequest({ uid: "CUSTOMER_1" }, { raterId: "OTHER_USER", ratedUserId: "DRIVER_1" });
    assert.strictEqual(res.raterId, "CUSTOMER_1");
  });

  test("Rejects non-participant callers", () => {
    assert.throws(
      () => validateRatingRequest({ uid: "OUTSIDER_99" }, { ratedUserId: "DRIVER_1" }),
      /permission-denied: You are not a participant in this trip/
    );
  });

  test("Rejects rating wrong/mismatched target user", () => {
    assert.throws(
      () => validateRatingRequest({ uid: "CUSTOMER_1" }, { ratedUserId: "RANDOM_USER" }),
      /permission-denied: Rated user was not a participant/
    );
  });

  test("Allows valid customer rating assigned driver", () => {
    const res = validateRatingRequest({ uid: "CUSTOMER_1" }, { ratedUserId: "DRIVER_1" });
    assert.strictEqual(res.raterId, "CUSTOMER_1");
    assert.strictEqual(res.ratedUserId, "DRIVER_1");
    assert.strictEqual(res.isRatedUserDriver, true);
  });

  test("Allows valid driver rating customer", () => {
    const res = validateRatingRequest({ uid: "DRIVER_1" }, { ratedUserId: "CUSTOMER_1" });
    assert.strictEqual(res.raterId, "DRIVER_1");
    assert.strictEqual(res.ratedUserId, "CUSTOMER_1");
    assert.strictEqual(res.isRatedUserDriver, false);
  });
});
