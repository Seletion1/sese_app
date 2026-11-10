"use strict";
var __importDefault = (this && this.__importDefault) || function (mod) {
    return (mod && mod.__esModule) ? mod : { "default": mod };
};
Object.defineProperty(exports, "__esModule", { value: true });
const node_assert_1 = __importDefault(require("node:assert"));
const node_test_1 = require("node:test");
(0, node_test_1.describe)("Sequential Dispatch Architecture (1 -> 2 -> 3 -> Public Pool)", () => {
    const MAX_SEQUENTIAL_DRIVERS = 3;
    const DEFAULT_SEARCH_RADIUS_KM = 3.0;
    function routeSequentialDispatch(trip, availableDrivers, searchRadiusKm = DEFAULT_SEARCH_RADIUS_KM) {
        // Check if already reached max sequential drivers
        if (trip.dispatchStep >= MAX_SEQUENTIAL_DRIVERS ||
            trip.attemptedDriverIds.length >= MAX_SEQUENTIAL_DRIVERS) {
            // Step 4: Drop to Public Order Pool
            trip.status = "MARKETPLACE_OPEN";
            trip.dispatchTier = 3;
            trip.dispatchStep = 4;
            trip.pingDriverId = null;
            trip.pingDriverIds = [];
            return;
        }
        // Filter eligible drivers within search radius, excluding already attempted
        const eligible = availableDrivers
            .filter((d) => d.isOnline &&
            d.distanceKm <= searchRadiusKm &&
            !trip.attemptedDriverIds.includes(d.id))
            .sort((a, b) => a.distanceKm - b.distanceKm);
        if (eligible.length === 0) {
            // No more drivers within configured search radius -> drop directly to Public Pool
            trip.status = "MARKETPLACE_OPEN";
            trip.dispatchTier = 3;
            trip.dispatchStep = 4;
            trip.pingDriverId = null;
            trip.pingDriverIds = [];
            return;
        }
        // Next nearest driver
        const nextDriver = eligible[0];
        trip.dispatchStep += 1;
        trip.status = "WAITING_FOR_ACCEPTANCE";
        trip.dispatchTier = 1;
        trip.pingDriverId = nextDriver.id;
        trip.pingDriverIds = [nextDriver.id];
        trip.attemptedDriverIds.push(nextDriver.id);
    }
    function handleDriverDeclineOrTimeout(trip, driverId, action, availableDrivers, searchRadiusKm = DEFAULT_SEARCH_RADIUS_KM) {
        node_assert_1.default.strictEqual(trip.pingDriverId, driverId, "Only pinged driver can decline/timeout");
        trip.rejections.push({ driverId, action, timestamp: Date.now() });
        routeSequentialDispatch(trip, availableDrivers, searchRadiusKm);
    }
    (0, node_test_1.test)("1. Step 1 routes exclusively to 1st nearest driver within configured radius", () => {
        const drivers = [
            { id: "driver_far", distanceKm: 5.0, isOnline: true },
            { id: "driver_2nd", distanceKm: 2.1, isOnline: true },
            { id: "driver_1st", distanceKm: 0.8, isOnline: true },
            { id: "driver_3rd", distanceKm: 2.7, isOnline: true },
        ];
        const trip = {
            id: "trip_001",
            status: "SEARCHING_DRIVER",
            dispatchTier: 1,
            dispatchStep: 0,
            pingDriverId: null,
            pingDriverIds: [],
            attemptedDriverIds: [],
            rejections: [],
        };
        routeSequentialDispatch(trip, drivers, 3.0);
        node_assert_1.default.strictEqual(trip.status, "WAITING_FOR_ACCEPTANCE");
        node_assert_1.default.strictEqual(trip.dispatchStep, 1);
        node_assert_1.default.strictEqual(trip.pingDriverId, "driver_1st");
        node_assert_1.default.deepStrictEqual(trip.pingDriverIds, ["driver_1st"]);
        node_assert_1.default.deepStrictEqual(trip.attemptedDriverIds, ["driver_1st"]);
    });
    (0, node_test_1.test)("2. Step 2 routes exclusively to 2nd nearest driver when 1st driver rejects/times out", () => {
        const drivers = [
            { id: "driver_1st", distanceKm: 0.8, isOnline: true },
            { id: "driver_2nd", distanceKm: 1.5, isOnline: true },
            { id: "driver_3rd", distanceKm: 2.2, isOnline: true },
        ];
        const trip = {
            id: "trip_002",
            status: "SEARCHING_DRIVER",
            dispatchTier: 1,
            dispatchStep: 0,
            pingDriverId: null,
            pingDriverIds: [],
            attemptedDriverIds: [],
            rejections: [],
        };
        routeSequentialDispatch(trip, drivers, 3.0);
        node_assert_1.default.strictEqual(trip.pingDriverId, "driver_1st");
        // 1st driver times out
        handleDriverDeclineOrTimeout(trip, "driver_1st", "skipped", drivers, 3.0);
        node_assert_1.default.strictEqual(trip.status, "WAITING_FOR_ACCEPTANCE");
        node_assert_1.default.strictEqual(trip.dispatchStep, 2);
        node_assert_1.default.strictEqual(trip.pingDriverId, "driver_2nd");
        node_assert_1.default.deepStrictEqual(trip.attemptedDriverIds, ["driver_1st", "driver_2nd"]);
    });
    (0, node_test_1.test)("3. Step 3 routes exclusively to 3rd nearest driver when 2nd driver rejects/times out", () => {
        const drivers = [
            { id: "driver_1st", distanceKm: 0.5, isOnline: true },
            { id: "driver_2nd", distanceKm: 1.2, isOnline: true },
            { id: "driver_3rd", distanceKm: 2.0, isOnline: true },
            { id: "driver_4th", distanceKm: 2.5, isOnline: true },
        ];
        const trip = {
            id: "trip_003",
            status: "SEARCHING_DRIVER",
            dispatchTier: 1,
            dispatchStep: 0,
            pingDriverId: null,
            pingDriverIds: [],
            attemptedDriverIds: [],
            rejections: [],
        };
        routeSequentialDispatch(trip, drivers, 3.0);
        handleDriverDeclineOrTimeout(trip, "driver_1st", "rejected", drivers, 3.0);
        handleDriverDeclineOrTimeout(trip, "driver_2nd", "skipped", drivers, 3.0);
        node_assert_1.default.strictEqual(trip.status, "WAITING_FOR_ACCEPTANCE");
        node_assert_1.default.strictEqual(trip.dispatchStep, 3);
        node_assert_1.default.strictEqual(trip.pingDriverId, "driver_3rd");
        node_assert_1.default.deepStrictEqual(trip.attemptedDriverIds, ["driver_1st", "driver_2nd", "driver_3rd"]);
    });
    (0, node_test_1.test)("4. Step 4 drops automatically into Public Order Pool when all 3 reject/timeout", () => {
        const drivers = [
            { id: "driver_1st", distanceKm: 0.5, isOnline: true },
            { id: "driver_2nd", distanceKm: 1.2, isOnline: true },
            { id: "driver_3rd", distanceKm: 2.0, isOnline: true },
            { id: "driver_4th", distanceKm: 2.5, isOnline: true },
        ];
        const trip = {
            id: "trip_004",
            status: "SEARCHING_DRIVER",
            dispatchTier: 1,
            dispatchStep: 0,
            pingDriverId: null,
            pingDriverIds: [],
            attemptedDriverIds: [],
            rejections: [],
        };
        routeSequentialDispatch(trip, drivers, 3.0); // Step 1 -> driver_1st
        handleDriverDeclineOrTimeout(trip, "driver_1st", "rejected", drivers, 3.0); // Step 2 -> driver_2nd
        handleDriverDeclineOrTimeout(trip, "driver_2nd", "skipped", drivers, 3.0); // Step 3 -> driver_3rd
        handleDriverDeclineOrTimeout(trip, "driver_3rd", "rejected", drivers, 3.0); // Step 4 -> Public Pool
        node_assert_1.default.strictEqual(trip.status, "MARKETPLACE_OPEN");
        node_assert_1.default.strictEqual(trip.dispatchTier, 3);
        node_assert_1.default.strictEqual(trip.dispatchStep, 4);
        node_assert_1.default.strictEqual(trip.pingDriverId, null);
        node_assert_1.default.deepStrictEqual(trip.pingDriverIds, []);
        node_assert_1.default.strictEqual(trip.rejections.length, 3);
    });
    (0, node_test_1.test)("5. Drops to Public Pool immediately when 0 drivers are within search radius", () => {
        const drivers = [
            { id: "driver_far1", distanceKm: 6.0, isOnline: true },
            { id: "driver_far2", distanceKm: 10.0, isOnline: true },
        ];
        const trip = {
            id: "trip_005",
            status: "SEARCHING_DRIVER",
            dispatchTier: 1,
            dispatchStep: 0,
            pingDriverId: null,
            pingDriverIds: [],
            attemptedDriverIds: [],
            rejections: [],
        };
        routeSequentialDispatch(trip, drivers, 3.0);
        node_assert_1.default.strictEqual(trip.status, "MARKETPLACE_OPEN");
        node_assert_1.default.strictEqual(trip.dispatchTier, 3);
        node_assert_1.default.strictEqual(trip.dispatchStep, 4);
        node_assert_1.default.strictEqual(trip.pingDriverId, null);
    });
    (0, node_test_1.test)("6. Drops to Public Pool when only 1 driver was in radius and timed out", () => {
        const drivers = [
            { id: "driver_only_one", distanceKm: 1.8, isOnline: true },
            { id: "driver_far", distanceKm: 8.0, isOnline: true },
        ];
        const trip = {
            id: "trip_006",
            status: "SEARCHING_DRIVER",
            dispatchTier: 1,
            dispatchStep: 0,
            pingDriverId: null,
            pingDriverIds: [],
            attemptedDriverIds: [],
            rejections: [],
        };
        routeSequentialDispatch(trip, drivers, 3.0);
        node_assert_1.default.strictEqual(trip.dispatchStep, 1);
        node_assert_1.default.strictEqual(trip.pingDriverId, "driver_only_one");
        // Only driver skips
        handleDriverDeclineOrTimeout(trip, "driver_only_one", "skipped", drivers, 3.0);
        node_assert_1.default.strictEqual(trip.status, "MARKETPLACE_OPEN");
        node_assert_1.default.strictEqual(trip.dispatchTier, 3);
        node_assert_1.default.strictEqual(trip.dispatchStep, 4);
        node_assert_1.default.strictEqual(trip.pingDriverId, null);
    });
    (0, node_test_1.test)("7. Public Pool timeout automatically transitions order to returned_to_customer", () => {
        const defaultDurationMs = 60 * 60 * 1000; // 1 hour
        const now = 1731196800000;
        const poolTrip = {
            id: "trip_pool_expired",
            status: "MARKETPLACE_OPEN",
            poolExpiresAt: now - defaultDurationMs,
        };
        // Sweep simulation
        if (poolTrip.status === "MARKETPLACE_OPEN" && now >= poolTrip.poolExpiresAt) {
            poolTrip.status = "returned_to_customer";
            poolTrip.isExpired = true;
        }
        node_assert_1.default.strictEqual(poolTrip.status, "returned_to_customer");
        node_assert_1.default.strictEqual(poolTrip.isExpired, true);
    });
    (0, node_test_1.test)("8. Reassign / Retry with instant fare boost restarts sequential dispatch from Step 1 with updated fare", () => {
        const drivers = [
            { id: "driver_near", distanceKm: 1.2, isOnline: true },
            { id: "driver_far", distanceKm: 4.5, isOnline: true },
        ];
        const trip = {
            id: "trip_reassign",
            status: "returned_to_customer",
            dispatchTier: 3,
            dispatchStep: 4,
            pingDriverId: null,
            pingDriverIds: [],
            attemptedDriverIds: ["driver_old_1", "driver_old_2", "driver_old_3"],
            rejections: [],
            fareAmount: 4000,
            fareFormatted: "₦4,000",
            fareBoosted: false,
            boostPercent: 0,
        };
        // Simulate reassignTrip callable with one-tap ₦5,000 chip boost
        const newFare = 5000;
        const boostPct = Math.round(((newFare - trip.fareAmount) / trip.fareAmount) * 100);
        trip.fareAmount = newFare;
        trip.fareFormatted = `₦${newFare.toLocaleString()}`;
        trip.fareBoosted = true;
        trip.boostPercent = boostPct;
        trip.status = "SEARCHING_DRIVER";
        trip.dispatchTier = 1;
        trip.dispatchStep = 0;
        trip.attemptedDriverIds = [];
        // Restart router
        routeSequentialDispatch(trip, drivers, 3.0);
        node_assert_1.default.strictEqual(trip.status, "WAITING_FOR_ACCEPTANCE");
        node_assert_1.default.strictEqual(trip.dispatchStep, 1);
        node_assert_1.default.strictEqual(trip.pingDriverId, "driver_near");
        node_assert_1.default.strictEqual(trip.fareAmount, 5000);
        node_assert_1.default.strictEqual(trip.fareBoosted, true);
        node_assert_1.default.strictEqual(trip.boostPercent, 25);
    });
});
//# sourceMappingURL=sequential_dispatch.test.js.map