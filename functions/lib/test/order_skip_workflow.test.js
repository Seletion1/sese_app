"use strict";
var __importDefault = (this && this.__importDefault) || function (mod) {
    return (mod && mod.__esModule) ? mod : { "default": mod };
};
Object.defineProperty(exports, "__esModule", { value: true });
const node_assert_1 = __importDefault(require("node:assert"));
const node_test_1 = require("node:test");
(0, node_test_1.describe)("Driver Order-Skip Workflow, Penalty Recording & Pool Escalation", () => {
    const MAX_SEQUENTIAL_DRIVERS = 3;
    const DEFAULT_SEARCH_RADIUS_KM = 3.0;
    function breakDriverStreak(streak, reason) {
        streak.currentStep = 0; // Reset step on streak break
        streak.streakBrokenCount += 1;
    }
    function advanceSequentialDispatch(trip, availableDrivers, searchRadiusKm = DEFAULT_SEARCH_RADIUS_KM) {
        if (trip.dispatchStep >= MAX_SEQUENTIAL_DRIVERS ||
            trip.attemptedDriverIds.length >= MAX_SEQUENTIAL_DRIVERS) {
            // Escalates to Public Order Pool (Step 4 / MARKETPLACE_OPEN)
            trip.status = "MARKETPLACE_OPEN";
            trip.dispatchTier = 3;
            trip.dispatchStep = 4;
            trip.pingDriverId = null;
            trip.pingDriverIds = [];
            trip.tierExpiresAt = null;
            return;
        }
        const eligible = availableDrivers
            .filter((d) => d.isOnline &&
            d.distanceKm <= searchRadiusKm &&
            !trip.attemptedDriverIds.includes(d.id))
            .sort((a, b) => a.distanceKm - b.distanceKm);
        if (eligible.length === 0) {
            trip.status = "MARKETPLACE_OPEN";
            trip.dispatchTier = 3;
            trip.dispatchStep = 4;
            trip.pingDriverId = null;
            trip.pingDriverIds = [];
            trip.tierExpiresAt = null;
            return;
        }
        const nextDriver = eligible[0];
        trip.dispatchStep += 1;
        trip.status = "WAITING_FOR_ACCEPTANCE";
        trip.dispatchTier = 1;
        trip.pingDriverId = nextDriver.id;
        trip.pingDriverIds = [nextDriver.id];
        trip.attemptedDriverIds.push(nextDriver.id);
        trip.tierExpiresAt = Date.now() + 20000; // 20s ping expiry
    }
    function handleDeclineTrip(trip, driverId, action, streak, availableDrivers) {
        node_assert_1.default.strictEqual(trip.status, "WAITING_FOR_ACCEPTANCE", "Trip must be WAITING_FOR_ACCEPTANCE");
        node_assert_1.default.strictEqual(trip.pingDriverId, driverId, "Only pinged driver can decline or skip");
        const cancellationSource = action === "skipped" ? "skipped_by_driver" : "rejected_by_driver";
        const now = Date.now();
        trip.status = "SEARCHING_DRIVER";
        trip.pingDriverId = null;
        trip.pingDriverIds = [];
        trip.cancellationSource = cancellationSource;
        trip.declineCount += 1;
        trip.rejections.push({ driverId, action, timestamp: now });
        trip.statusHistory.push({
            from: "WAITING_FOR_ACCEPTANCE",
            to: "SEARCHING_DRIVER",
            actor: driverId,
            role: "driver",
            reason: action,
            timestamp: now,
        });
        // Penalize driver streak
        breakDriverStreak(streak, "driver_declined");
        // Advance to next driver or pool
        advanceSequentialDispatch(trip, availableDrivers);
    }
    function sweepTimedOutPings(trips, driverStreaks, availableDrivers, cutoffTime) {
        for (const trip of trips) {
            if (trip.status === "WAITING_FOR_ACCEPTANCE" &&
                trip.tierExpiresAt !== null &&
                trip.tierExpiresAt < cutoffTime) {
                const ignoredDriverId = trip.pingDriverId;
                if (ignoredDriverId) {
                    const streak = driverStreaks.get(ignoredDriverId);
                    if (streak)
                        breakDriverStreak(streak, "ping_expired");
                    trip.cancellationSource = "skipped_by_driver";
                    trip.declineCount += 1;
                    trip.rejections.push({
                        driverId: ignoredDriverId,
                        action: "skipped",
                        timestamp: cutoffTime,
                    });
                }
                trip.status = "SEARCHING_DRIVER";
                trip.pingDriverId = null;
                trip.pingDriverIds = [];
                advanceSequentialDispatch(trip, availableDrivers);
            }
        }
    }
    (0, node_test_1.test)("1. Explicit driver skip sets cancellationSource='skipped_by_driver', breaks streak, and advances dispatch to 2nd driver", () => {
        const drivers = [
            { id: "driver_1", distanceKm: 0.5, isOnline: true },
            { id: "driver_2", distanceKm: 1.2, isOnline: true },
            { id: "driver_3", distanceKm: 2.0, isOnline: true },
        ];
        const driver1Streak = {
            driverId: "driver_1",
            currentLevel: 1,
            currentStep: 3,
            streakBrokenCount: 0,
        };
        const trip = {
            id: "trip_101",
            status: "SEARCHING_DRIVER",
            dispatchTier: 1,
            dispatchStep: 0,
            pingDriverId: null,
            pingDriverIds: [],
            attemptedDriverIds: [],
            cancellationSource: null,
            declineCount: 0,
            rejections: [],
            statusHistory: [],
            tierExpiresAt: null,
        };
        // Step 1: Initial ping to Driver 1
        advanceSequentialDispatch(trip, drivers);
        node_assert_1.default.strictEqual(trip.status, "WAITING_FOR_ACCEPTANCE");
        node_assert_1.default.strictEqual(trip.pingDriverId, "driver_1");
        // Driver 1 skips the incoming request
        handleDeclineTrip(trip, "driver_1", "skipped", driver1Streak, drivers);
        // Verify cancellationSource, rejections, statusHistory
        node_assert_1.default.strictEqual(trip.cancellationSource, "skipped_by_driver");
        node_assert_1.default.strictEqual(trip.declineCount, 1);
        node_assert_1.default.strictEqual(trip.rejections.length, 1);
        node_assert_1.default.strictEqual(trip.rejections[0].driverId, "driver_1");
        node_assert_1.default.strictEqual(trip.rejections[0].action, "skipped");
        node_assert_1.default.strictEqual(trip.statusHistory.length, 1);
        // Verify Driver 1 streak penalty applied
        node_assert_1.default.strictEqual(driver1Streak.currentStep, 0);
        node_assert_1.default.strictEqual(driver1Streak.streakBrokenCount, 1);
        // Verify sequential dispatch re-routed order to Driver 2
        node_assert_1.default.strictEqual(trip.status, "WAITING_FOR_ACCEPTANCE");
        node_assert_1.default.strictEqual(trip.pingDriverId, "driver_2");
        node_assert_1.default.strictEqual(trip.dispatchStep, 2);
    });
    (0, node_test_1.test)("2. Three consecutive skips by drivers escalate the order directly to the Public Order Pool (MARKETPLACE_OPEN)", () => {
        const drivers = [
            { id: "driver_1", distanceKm: 0.5, isOnline: true },
            { id: "driver_2", distanceKm: 1.0, isOnline: true },
            { id: "driver_3", distanceKm: 1.5, isOnline: true },
        ];
        const streaks = new Map([
            ["driver_1", { driverId: "driver_1", currentLevel: 1, currentStep: 2, streakBrokenCount: 0 }],
            ["driver_2", { driverId: "driver_2", currentLevel: 2, currentStep: 4, streakBrokenCount: 0 }],
            ["driver_3", { driverId: "driver_3", currentLevel: 1, currentStep: 1, streakBrokenCount: 0 }],
        ]);
        const trip = {
            id: "trip_102",
            status: "SEARCHING_DRIVER",
            dispatchTier: 1,
            dispatchStep: 0,
            pingDriverId: null,
            pingDriverIds: [],
            attemptedDriverIds: [],
            cancellationSource: null,
            declineCount: 0,
            rejections: [],
            statusHistory: [],
            tierExpiresAt: null,
        };
        // Driver 1 pinged & skips
        advanceSequentialDispatch(trip, drivers);
        handleDeclineTrip(trip, "driver_1", "skipped", streaks.get("driver_1"), drivers);
        // Driver 2 pinged & skips
        node_assert_1.default.strictEqual(trip.pingDriverId, "driver_2");
        handleDeclineTrip(trip, "driver_2", "skipped", streaks.get("driver_2"), drivers);
        // Driver 3 pinged & skips
        node_assert_1.default.strictEqual(trip.pingDriverId, "driver_3");
        handleDeclineTrip(trip, "driver_3", "skipped", streaks.get("driver_3"), drivers);
        // Order escalated to Public Pool (Step 4 / MARKETPLACE_OPEN)
        node_assert_1.default.strictEqual(trip.status, "MARKETPLACE_OPEN");
        node_assert_1.default.strictEqual(trip.dispatchTier, 3);
        node_assert_1.default.strictEqual(trip.dispatchStep, 4);
        node_assert_1.default.strictEqual(trip.pingDriverId, null);
        node_assert_1.default.strictEqual(trip.declineCount, 3);
        node_assert_1.default.strictEqual(trip.rejections.length, 3);
    });
    (0, node_test_1.test)("3. Scheduled 1-minute sweep (sweepTripPings) automatically expires ignored pings, penalizes streaks, and advances dispatch", () => {
        const drivers = [
            { id: "driver_1", distanceKm: 0.8, isOnline: true },
            { id: "driver_2", distanceKm: 1.4, isOnline: true },
        ];
        const driverStreaks = new Map([
            ["driver_1", { driverId: "driver_1", currentLevel: 2, currentStep: 3, streakBrokenCount: 0 }],
        ]);
        const now = Date.now();
        const trip = {
            id: "trip_103",
            status: "WAITING_FOR_ACCEPTANCE",
            dispatchTier: 1,
            dispatchStep: 1,
            pingDriverId: "driver_1",
            pingDriverIds: ["driver_1"],
            attemptedDriverIds: ["driver_1"],
            cancellationSource: null,
            declineCount: 0,
            rejections: [],
            statusHistory: [],
            tierExpiresAt: now - 5000, // Expired 5 seconds ago
        };
        // Run sweep at current time cutoff
        sweepTimedOutPings([trip], driverStreaks, drivers, now);
        // Verify streak penalized
        node_assert_1.default.strictEqual(driverStreaks.get("driver_1").currentStep, 0);
        // Verify cancellationSource recorded as skipped_by_driver
        node_assert_1.default.strictEqual(trip.cancellationSource, "skipped_by_driver");
        node_assert_1.default.strictEqual(trip.rejections.length, 1);
        node_assert_1.default.strictEqual(trip.rejections[0].action, "skipped");
        // Verify dispatch advanced to Driver 2
        node_assert_1.default.strictEqual(trip.status, "WAITING_FOR_ACCEPTANCE");
        node_assert_1.default.strictEqual(trip.pingDriverId, "driver_2");
        node_assert_1.default.strictEqual(trip.dispatchStep, 2);
    });
});
//# sourceMappingURL=order_skip_workflow.test.js.map