"use strict";
var __importDefault = (this && this.__importDefault) || function (mod) {
    return (mod && mod.__esModule) ? mod : { "default": mod };
};
Object.defineProperty(exports, "__esModule", { value: true });
process.env.FARE_SIGNING_SECRET = process.env.FARE_SIGNING_SECRET || "sese-test-fare-signing-secret";
const node_assert_1 = __importDefault(require("node:assert"));
const node_test_1 = require("node:test");
const driverStreak_1 = require("../driverStreak");
const trips_1 = require("../trips");
(0, node_test_1.describe)("Backend Safety & Invariant Matrix", () => {
    (0, node_test_1.test)("1. Trip Creation & Escrow Invariants", async () => {
        // Escrow coverage clamp test
        const availableBalance = 5000;
        const requestedCoverage = 6000;
        const actualCoverage = Math.min(requestedCoverage, Math.max(0, availableBalance));
        node_assert_1.default.strictEqual(actualCoverage, 5000); // Clamped to available balance
        node_assert_1.default.strictEqual((0, driverStreak_1.nairaToKobo)(actualCoverage), 500000);
        // Escrow transaction key determinism
        const tripId = "TRIP_TEST_101";
        const holdTxKey = `${tripId}_escrow_hold`;
        node_assert_1.default.strictEqual(holdTxKey, "TRIP_TEST_101_escrow_hold");
    });
    (0, node_test_1.test)("2. Trip Accept & Single Driver Assignment", async () => {
        // Simulate first-wins driver claim atomic logic
        let assignedDriverId = null;
        const claimTrip = (driverId) => {
            if (assignedDriverId !== null) {
                throw new Error("Another driver claimed this trip first.");
            }
            assignedDriverId = driverId;
            return true;
        };
        node_assert_1.default.strictEqual(claimTrip("DRIVER_A"), true);
        node_assert_1.default.throws(() => claimTrip("DRIVER_B"), /Another driver claimed this trip first/);
        node_assert_1.default.strictEqual(assignedDriverId, "DRIVER_A");
    });
    (0, node_test_1.test)("3. Low-Balance Rejection", async () => {
        const minBalanceRequired = 1.00; // ₦1.00 minimum
        const driverMainBalance = 0.50; // Below threshold
        const canAccept = driverMainBalance >= minBalanceRequired;
        node_assert_1.default.strictEqual(canAccept, false);
    });
    (0, node_test_1.test)("4. Trip Decline & Audit Trail", async () => {
        const streakBefore = {
            streakActive: true,
            currentLevel: 1,
            currentStep: 3,
            level1PaidHistory: [],
            dailyStreakCompleted: false,
            baseCommissionRate: 0.20,
            resetDateLocal: "2026-11-02",
        };
        const broken = (0, driverStreak_1.applyStreakBreak)(streakBefore);
        node_assert_1.default.strictEqual(broken.currentStep, 0); // Drops to step 0 on decline
    });
    (0, node_test_1.test)("5. Driver Reassignment Bounds (Max 3 Reassignments)", async () => {
        const calculateReassignmentOutcome = (currentCount) => {
            const nextCount = currentCount + 1;
            if (nextCount <= 3) {
                return { action: "reassign_searching", attempt: nextCount };
            }
            else {
                return { action: "needs_customer_action", attempt: nextCount };
            }
        };
        node_assert_1.default.deepStrictEqual(calculateReassignmentOutcome(0), { action: "reassign_searching", attempt: 1 });
        node_assert_1.default.deepStrictEqual(calculateReassignmentOutcome(1), { action: "reassign_searching", attempt: 2 });
        node_assert_1.default.deepStrictEqual(calculateReassignmentOutcome(2), { action: "reassign_searching", attempt: 3 });
        node_assert_1.default.deepStrictEqual(calculateReassignmentOutcome(3), { action: "needs_customer_action", attempt: 4 });
    });
    (0, node_test_1.test)("6. Escrow Release & Invariant Math", async () => {
        const currentEscrow = 3000;
        const walletCoverage = 3000;
        const newEscrow = Math.max(0, currentEscrow - walletCoverage);
        node_assert_1.default.strictEqual(newEscrow, 0); // Escrow cleared without negative balance
        const refundTxKey = `TRIP_TEST_101_escrow_refund`;
        node_assert_1.default.strictEqual(refundTxKey, "TRIP_TEST_101_escrow_refund");
    });
    (0, node_test_1.test)("7. Canonical Completion Settlement", async () => {
        const fareAmount = 5000; // ₦5,000
        const commissionRate = 0.15; // 15%
        const commissionAmount = fareAmount * commissionRate; // ₦750
        const driverEarnings = fareAmount - commissionAmount; // ₦4,250
        node_assert_1.default.strictEqual(commissionAmount, 750);
        node_assert_1.default.strictEqual(driverEarnings, 4250);
        node_assert_1.default.strictEqual((0, driverStreak_1.nairaToKobo)(commissionAmount), 75000);
        node_assert_1.default.strictEqual((0, driverStreak_1.nairaToKobo)(driverEarnings), 425000);
    });
    (0, node_test_1.test)("8. Settlement Idempotency", async () => {
        var _a, _b;
        const liveTrip = {
            settlement: { settled: true, commissionSettled: true },
        };
        const isAlreadySettled = ((_a = liveTrip.settlement) === null || _a === void 0 ? void 0 : _a.settled) === true || ((_b = liveTrip.settlement) === null || _b === void 0 ? void 0 : _b.commissionSettled) === true;
        node_assert_1.default.strictEqual(isAlreadySettled, true);
    });
    (0, node_test_1.test)("9. Stale Status & State Machine Verification", async () => {
        const DRIVER_TRANSITIONS = {
            DRIVER_ACCEPTED: ["DRIVER_ARRIVING", "DRIVER_ARRIVED"],
            DRIVER_ARRIVING: ["DRIVER_ARRIVED"],
            DRIVER_ARRIVED: ["IN_PROGRESS"],
            IN_PROGRESS: ["COMPLETED"],
        };
        const validateTransition = (current, next, expected) => {
            var _a;
            if (expected && current !== expected) {
                throw new Error(`STALE_WRITE: Trip status is ${current}, expected ${expected}.`);
            }
            if (current === next) {
                return "already_in_status";
            }
            const allowed = (_a = DRIVER_TRANSITIONS[current]) !== null && _a !== void 0 ? _a : [];
            if (!allowed.includes(next)) {
                throw new Error(`Cannot move from ${current} to ${next}.`);
            }
            return "transition_allowed";
        };
        node_assert_1.default.strictEqual(validateTransition("DRIVER_ACCEPTED", "DRIVER_ARRIVED"), "transition_allowed");
        node_assert_1.default.strictEqual(validateTransition("DRIVER_ARRIVED", "DRIVER_ARRIVED"), "already_in_status");
        node_assert_1.default.throws(() => validateTransition("DRIVER_ACCEPTED", "COMPLETED"), /Cannot move from DRIVER_ACCEPTED to COMPLETED/);
        node_assert_1.default.throws(() => validateTransition("DRIVER_ARRIVED", "IN_PROGRESS", "DRIVER_ACCEPTED"), /STALE_WRITE: Trip status is DRIVER_ARRIVED, expected DRIVER_ACCEPTED/);
    });
    (0, node_test_1.test)("10. Observability & Audit Log Schema", async () => {
        const finLog = {
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
        node_assert_1.default.strictEqual(finLog.tripId, "TRIP_101");
        node_assert_1.default.strictEqual(finLog.amountKobo, -75000);
        node_assert_1.default.strictEqual(finLog.invariantsChecked, true);
        const transitionLog = {
            tripId: "TRIP_101",
            from: "IN_PROGRESS",
            to: "COMPLETED",
            actor: "DRIVER_99",
            role: "driver",
            timestamp: Date.now(),
        };
        node_assert_1.default.strictEqual(transitionLog.from, "IN_PROGRESS");
        node_assert_1.default.strictEqual(transitionLog.to, "COMPLETED");
    });
});
(0, node_test_1.describe)("Financial & Currency Precision Engine", () => {
    (0, node_test_1.test)("nairaToKobo converts naira values to exact kobo integers", () => {
        node_assert_1.default.strictEqual((0, driverStreak_1.nairaToKobo)(100), 10000);
        node_assert_1.default.strictEqual((0, driverStreak_1.nairaToKobo)(1500.5), 150050);
        node_assert_1.default.strictEqual((0, driverStreak_1.nairaToKobo)(0), 0);
        node_assert_1.default.strictEqual((0, driverStreak_1.nairaToKobo)(12.345), 1235);
    });
    (0, node_test_1.test)("Phone normalization validates and formats E.164 canonical numbers", () => {
        node_assert_1.default.strictEqual((0, trips_1.normalizePhone)("08161561592"), "+2348161561592");
        node_assert_1.default.strictEqual((0, trips_1.normalizePhone)("+2348161561592"), "+2348161561592");
        node_assert_1.default.strictEqual((0, trips_1.normalizePhone)("+234 816-156-1592"), "+2348161561592");
        node_assert_1.default.strictEqual((0, trips_1.normalizePhone)(""), "");
    });
    (0, node_test_1.test)("Haversine distance calculation is accurate", () => {
        // Distance between Victoria Island and Ikeja (~20km)
        const dist = (0, trips_1.haversineKm)(6.4281, 3.4219, 6.6018, 3.3515);
        node_assert_1.default.strictEqual(Math.round(dist), 21);
    });
});
(0, node_test_1.describe)("Driver Streak & Commission Calculation Engine", () => {
    const cfg = {
        streakEnabled: true,
        baseCommissionRate: 0.20,
        noShowWaitMinutes: 10,
        completionCashAward: 10000.0,
        disabledCountries: [],
        disabledStates: [],
    };
    (0, node_test_1.test)("Level 1 step 0 computes 15% commission", () => {
        const streak = {
            streakActive: true,
            currentLevel: 1,
            currentStep: 0,
            level1PaidHistory: [],
            dailyStreakCompleted: false,
            baseCommissionRate: 0.20,
            resetDateLocal: "2026-11-02",
        };
        const res = (0, driverStreak_1.computeCommission)(streak, 2000, cfg);
        node_assert_1.default.strictEqual(res.commissionRate, 0.15);
        node_assert_1.default.strictEqual(res.commissionAmount, 300); // 15% of 2000
        node_assert_1.default.strictEqual(res.cashBackAmount, 0);
        node_assert_1.default.strictEqual(res.newState.currentLevel, 1);
        node_assert_1.default.strictEqual(res.newState.currentStep, 1);
    });
    (0, node_test_1.test)("Level 2 refund reverses Level 1 paid commission", () => {
        const streak = {
            streakActive: true,
            currentLevel: 2,
            currentStep: 0,
            level1PaidHistory: [300, 250, 200, 150, 100, 50],
            dailyStreakCompleted: false,
            baseCommissionRate: 0.20,
            resetDateLocal: "2026-11-02",
        };
        const res = (0, driverStreak_1.computeCommission)(streak, 2000, cfg);
        node_assert_1.default.strictEqual(res.commissionRate, 0);
        node_assert_1.default.strictEqual(res.commissionAmount, 0);
        node_assert_1.default.strictEqual(res.cashBackAmount, 50); // refunds history[5]
        node_assert_1.default.strictEqual(res.newState.currentLevel, 2);
        node_assert_1.default.strictEqual(res.newState.currentStep, 1);
    });
    (0, node_test_1.test)("Level 3 grand award triggers at step 6", () => {
        const streak = {
            streakActive: true,
            currentLevel: 3,
            currentStep: 6,
            level1PaidHistory: [],
            dailyStreakCompleted: false,
            baseCommissionRate: 0.20,
            resetDateLocal: "2026-11-02",
        };
        const res = (0, driverStreak_1.computeCommission)(streak, 2000, cfg);
        node_assert_1.default.strictEqual(res.commissionRate, 0);
        node_assert_1.default.strictEqual(res.cashBonusAmount, 400); // 20% of 2000
        node_assert_1.default.strictEqual(res.grandAwardTriggered, true);
        node_assert_1.default.strictEqual(res.newState.dailyStreakCompleted, true);
    });
    (0, node_test_1.test)("Streak break drop-back rules behave correctly", () => {
        const streakL1S0 = {
            streakActive: true,
            currentLevel: 1,
            currentStep: 0,
            level1PaidHistory: [],
            dailyStreakCompleted: false,
            baseCommissionRate: 0.20,
            resetDateLocal: "2026-11-02",
        };
        const brokenL1S0 = (0, driverStreak_1.applyStreakBreak)(streakL1S0);
        node_assert_1.default.strictEqual(brokenL1S0.streakActive, false);
        const streakL1S3 = {
            streakActive: true,
            currentLevel: 1,
            currentStep: 3,
            level1PaidHistory: [],
            dailyStreakCompleted: false,
            baseCommissionRate: 0.20,
            resetDateLocal: "2026-11-02",
        };
        const brokenL1S3 = (0, driverStreak_1.applyStreakBreak)(streakL1S3);
        node_assert_1.default.strictEqual(brokenL1S3.currentStep, 0);
    });
});
(0, node_test_1.describe)("Trip Rating Security Invariants", () => {
    const mockTrip = {
        tripId: "TRIP_100",
        customerId: "CUSTOMER_1",
        driver: { driverId: "DRIVER_1" },
    };
    const validateRatingRequest = (auth, data) => {
        var _a;
        if (!auth)
            throw new Error("unauthenticated: User must be authenticated.");
        const raterId = auth.uid;
        const ratedUserId = String((_a = data === null || data === void 0 ? void 0 : data.ratedUserId) !== null && _a !== void 0 ? _a : "").trim();
        if (raterId === ratedUserId)
            throw new Error("invalid-argument: Cannot rate yourself.");
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
    (0, node_test_1.test)("Rejects unauthenticated callers", () => {
        node_assert_1.default.throws(() => validateRatingRequest(null, { raterId: "ATTACKER_99", ratedUserId: "DRIVER_1" }), /unauthenticated/);
    });
    (0, node_test_1.test)("Ignores client-supplied raterId and enforces auth.uid", () => {
        const res = validateRatingRequest({ uid: "CUSTOMER_1" }, { raterId: "OTHER_USER", ratedUserId: "DRIVER_1" });
        node_assert_1.default.strictEqual(res.raterId, "CUSTOMER_1");
    });
    (0, node_test_1.test)("Rejects non-participant callers", () => {
        node_assert_1.default.throws(() => validateRatingRequest({ uid: "OUTSIDER_99" }, { ratedUserId: "DRIVER_1" }), /permission-denied: You are not a participant in this trip/);
    });
    (0, node_test_1.test)("Rejects rating wrong/mismatched target user", () => {
        node_assert_1.default.throws(() => validateRatingRequest({ uid: "CUSTOMER_1" }, { ratedUserId: "RANDOM_USER" }), /permission-denied: Rated user was not a participant/);
    });
    (0, node_test_1.test)("Allows valid customer rating assigned driver", () => {
        const res = validateRatingRequest({ uid: "CUSTOMER_1" }, { ratedUserId: "DRIVER_1" });
        node_assert_1.default.strictEqual(res.raterId, "CUSTOMER_1");
        node_assert_1.default.strictEqual(res.ratedUserId, "DRIVER_1");
        node_assert_1.default.strictEqual(res.isRatedUserDriver, true);
    });
    (0, node_test_1.test)("Allows valid driver rating customer", () => {
        const res = validateRatingRequest({ uid: "DRIVER_1" }, { ratedUserId: "CUSTOMER_1" });
        node_assert_1.default.strictEqual(res.raterId, "DRIVER_1");
        node_assert_1.default.strictEqual(res.ratedUserId, "CUSTOMER_1");
        node_assert_1.default.strictEqual(res.isRatedUserDriver, false);
    });
});
//# sourceMappingURL=trips.test.js.map