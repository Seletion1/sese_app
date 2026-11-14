"use strict";
var __importDefault = (this && this.__importDefault) || function (mod) {
    return (mod && mod.__esModule) ? mod : { "default": mod };
};
Object.defineProperty(exports, "__esModule", { value: true });
const node_assert_1 = __importDefault(require("node:assert"));
const node_test_1 = require("node:test");
const trips_1 = require("../trips");
(0, node_test_1.describe)("Drop-off Geofencing, Distance Validation & Remote Approval Engine", () => {
    // Ikeja City Mall dropoff coordinates: 6.6190, 3.3582
    const DROPOFF_LAT = 6.6190;
    const DROPOFF_LNG = 3.3582;
    function createTestTrip(overrides = {}) {
        return Object.assign({ id: "trip_geofence_123", status: "IN_PROGRESS", customerId: "cust_abc", driverId: "driver_xyz", dropoff: {
                lat: DROPOFF_LAT,
                lng: DROPOFF_LNG,
                address: "Ikeja City Mall, Alausa, Ikeja",
            }, dropoffApprovalStatus: null, statusHistory: [
                {
                    from: "DRIVER_ARRIVED",
                    to: "IN_PROGRESS",
                    actor: "driver_xyz",
                    role: "driver",
                    timestamp: Date.now() - 600000,
                },
            ] }, overrides);
    }
    // Simulated server validation logic matching advanceTripStatus
    function validateAndCompleteTrip(trip, callerId, driverLocation, configuredRadiusMeters = 500) {
        if (callerId !== trip.driverId) {
            throw new Error("permission-denied: Not your trip.");
        }
        if (trip.status !== "IN_PROGRESS") {
            throw new Error(`failed-precondition: Cannot move from ${trip.status} to COMPLETED.`);
        }
        // Geofence check if not already customer-approved
        if (trip.dropoffApprovalStatus !== "APPROVED") {
            if (!driverLocation || (!driverLocation.lat && !driverLocation.lng)) {
                throw new Error("failed-precondition: Driver GPS location is required to verify drop-off geofence.");
            }
            const distKm = (0, trips_1.haversineKm)(driverLocation.lat, driverLocation.lng, trip.dropoff.lat, trip.dropoff.lng);
            const distM = Math.round(distKm * 1000);
            if (distM > configuredRadiusMeters) {
                throw new Error(`failed-precondition: OUT_OF_RANGE: Driver is outside drop-off location (${distM}m away, max allowed is ${configuredRadiusMeters}m). Customer confirmation required.`);
            }
        }
        trip.status = "COMPLETED";
        trip.completedAt = Date.now();
        trip.statusHistory.push({
            from: "IN_PROGRESS",
            to: "COMPLETED",
            actor: callerId,
            role: "driver",
            timestamp: Date.now(),
        });
        return { ok: true, status: trip.status };
    }
    // Simulated requestDropoffApproval logic
    function requestDropoffApproval(trip, callerId, driverLocation, configuredRadiusMeters = 500) {
        if (callerId !== trip.driverId) {
            throw new Error("permission-denied: Not your trip.");
        }
        if (trip.status !== "IN_PROGRESS") {
            throw new Error(`failed-precondition: Trip must be IN_PROGRESS (currently ${trip.status}).`);
        }
        const distKm = (0, trips_1.haversineKm)(driverLocation.lat, driverLocation.lng, trip.dropoff.lat, trip.dropoff.lng);
        const distanceM = Math.round(distKm * 1000);
        trip.dropoffApprovalStatus = "PENDING";
        trip.dropoffApprovalRequestedAt = Date.now();
        trip.dropoffApprovalDriverLocation = driverLocation;
        trip.dropoffApprovalDistanceMeters = distanceM;
        trip.statusHistory.push({
            from: trip.status,
            to: trip.status,
            actor: callerId,
            role: "driver",
            action: "request_dropoff_approval",
            distanceMeters: distanceM,
            timestamp: Date.now(),
        });
        return { ok: true, pending: true, distanceMeters: distanceM, radiusMeters: configuredRadiusMeters };
    }
    // Simulated respondDropoffApproval logic
    function respondDropoffApproval(trip, callerId, approved) {
        if (callerId !== trip.customerId) {
            throw new Error("permission-denied: Only the customer who ordered this trip can respond to drop-off approval.");
        }
        if (trip.dropoffApprovalStatus !== "PENDING") {
            throw new Error("failed-precondition: No pending drop-off approval request.");
        }
        if (approved) {
            trip.dropoffApprovalStatus = "APPROVED";
            trip.dropoffApprovalRespondedAt = Date.now();
            trip.status = "COMPLETED";
            trip.completedAt = Date.now();
            trip.statusHistory.push({
                from: "IN_PROGRESS",
                to: "COMPLETED",
                actor: callerId,
                role: "customer",
                reason: "remote_customer_dropoff_approved",
                timestamp: Date.now(),
            });
            return { ok: true, approved: true, completed: true };
        }
        else {
            trip.dropoffApprovalStatus = "REJECTED";
            trip.dropoffApprovalRespondedAt = Date.now();
            trip.statusHistory.push({
                from: trip.status,
                to: trip.status,
                actor: callerId,
                role: "customer",
                reason: "remote_customer_dropoff_rejected",
                timestamp: Date.now(),
            });
            return { ok: true, approved: false, completed: false };
        }
    }
    (0, node_test_1.test)("1. In-Range Completion: allows immediate completion when within default 500m radius", () => {
        const trip = createTestTrip();
        // Driver is ~150 meters from drop-off destination
        const nearLocation = { lat: 6.6198, lng: 3.3590 };
        const result = validateAndCompleteTrip(trip, "driver_xyz", nearLocation, 500);
        node_assert_1.default.strictEqual(result.ok, true);
        node_assert_1.default.strictEqual(result.status, "COMPLETED");
        node_assert_1.default.strictEqual(trip.status, "COMPLETED");
        node_assert_1.default.ok(trip.completedAt > 0);
    });
    (0, node_test_1.test)("2. Out-of-Range Rejection: strictly blocks completion when driver is beyond 500m", () => {
        const trip = createTestTrip();
        // Driver is ~2.8 km away in Maryland/Anthony
        const farLocation = { lat: 6.5700, lng: 3.3650 };
        node_assert_1.default.throws(() => validateAndCompleteTrip(trip, "driver_xyz", farLocation, 500), /OUT_OF_RANGE/);
        // Trip remains IN_PROGRESS and uncompleted
        node_assert_1.default.strictEqual(trip.status, "IN_PROGRESS");
        node_assert_1.default.strictEqual(trip.completedAt, undefined);
    });
    (0, node_test_1.test)("3. Hub Configurable Drop-Off Radius: respects custom 1000m setting from Hub", () => {
        const trip = createTestTrip();
        // Driver is ~750m away from dropoff
        const intermediateLocation = { lat: 6.6255, lng: 3.3560 };
        // With default 500m radius -> rejected
        node_assert_1.default.throws(() => validateAndCompleteTrip(trip, "driver_xyz", intermediateLocation, 500), /OUT_OF_RANGE/);
        // With Hub configured 1000m radius -> allowed
        const result = validateAndCompleteTrip(trip, "driver_xyz", intermediateLocation, 1000);
        node_assert_1.default.strictEqual(result.ok, true);
        node_assert_1.default.strictEqual(result.status, "COMPLETED");
    });
    (0, node_test_1.test)("4. Out-of-Range Handling: driver sends confirmation request, entering PENDING state", () => {
        const trip = createTestTrip();
        const farLocation = { lat: 6.5700, lng: 3.3650 };
        const response = requestDropoffApproval(trip, "driver_xyz", farLocation, 500);
        node_assert_1.default.strictEqual(response.ok, true);
        node_assert_1.default.strictEqual(response.pending, true);
        node_assert_1.default.ok(response.distanceMeters > 500);
        node_assert_1.default.strictEqual(trip.dropoffApprovalStatus, "PENDING");
        node_assert_1.default.ok(trip.dropoffApprovalRequestedAt > 0);
        node_assert_1.default.deepStrictEqual(trip.dropoffApprovalDriverLocation, farLocation);
    });
    (0, node_test_1.test)("5. Security Gate: rejects requestDropoffApproval from unauthorized non-assigned driver", () => {
        const trip = createTestTrip();
        const farLocation = { lat: 6.5700, lng: 3.3650 };
        node_assert_1.default.throws(() => requestDropoffApproval(trip, "attacker_driver", farLocation, 500), /permission-denied/);
        node_assert_1.default.strictEqual(trip.dropoffApprovalStatus, null);
    });
    (0, node_test_1.test)("6. Remote Customer Approval: customer approves out-of-range dropoff, finalizing completion", () => {
        const trip = createTestTrip({
            dropoffApprovalStatus: "PENDING",
            dropoffApprovalRequestedAt: Date.now() - 30000,
            dropoffApprovalDistanceMeters: 2800,
        });
        const result = respondDropoffApproval(trip, "cust_abc", true);
        node_assert_1.default.strictEqual(result.ok, true);
        node_assert_1.default.strictEqual(result.approved, true);
        node_assert_1.default.strictEqual(result.completed, true);
        node_assert_1.default.strictEqual(trip.status, "COMPLETED");
        node_assert_1.default.strictEqual(trip.dropoffApprovalStatus, "APPROVED");
        node_assert_1.default.ok(trip.dropoffApprovalRespondedAt > 0);
    });
    (0, node_test_1.test)("7. Remote Customer Rejection: customer rejects dropoff, keeping trip active in IN_PROGRESS", () => {
        const trip = createTestTrip({
            dropoffApprovalStatus: "PENDING",
            dropoffApprovalRequestedAt: Date.now() - 30000,
            dropoffApprovalDistanceMeters: 2800,
        });
        const result = respondDropoffApproval(trip, "cust_abc", false);
        node_assert_1.default.strictEqual(result.ok, true);
        node_assert_1.default.strictEqual(result.approved, false);
        node_assert_1.default.strictEqual(result.completed, false);
        node_assert_1.default.strictEqual(trip.status, "IN_PROGRESS");
        node_assert_1.default.strictEqual(trip.dropoffApprovalStatus, "REJECTED");
        node_assert_1.default.strictEqual(trip.completedAt, undefined);
    });
    (0, node_test_1.test)("8. Security Gate: rejects response from non-customer caller", () => {
        const trip = createTestTrip({
            dropoffApprovalStatus: "PENDING",
            dropoffApprovalRequestedAt: Date.now() - 30000,
        });
        node_assert_1.default.throws(() => respondDropoffApproval(trip, "intruder_user", true), /permission-denied/);
        node_assert_1.default.strictEqual(trip.status, "IN_PROGRESS");
        node_assert_1.default.strictEqual(trip.dropoffApprovalStatus, "PENDING");
    });
    (0, node_test_1.test)("9. Bypasses geofence check once customer has explicitly APPROVED remote drop-off", () => {
        const trip = createTestTrip({
            dropoffApprovalStatus: "APPROVED",
        });
        // Driver is 3km away, but customer already approved
        const farLocation = { lat: 6.5700, lng: 3.3650 };
        const result = validateAndCompleteTrip(trip, "driver_xyz", farLocation, 500);
        node_assert_1.default.strictEqual(result.ok, true);
        node_assert_1.default.strictEqual(result.status, "COMPLETED");
    });
});
//# sourceMappingURL=dropoff_geofence.test.js.map