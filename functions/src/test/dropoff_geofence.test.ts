import assert from "node:assert";
import { test, describe } from "node:test";
import { haversineKm } from "../trips";

describe("Drop-off Geofencing, Distance Validation & Remote Approval Engine", () => {
  interface MockTrip {
    id: string;
    status: string;
    customerId: string;
    driverId: string;
    dropoff: { lat: number; lng: number; address: string };
    dropoffApprovalStatus?: string | null;
    dropoffApprovalRequestedAt?: number | null;
    dropoffApprovalRespondedAt?: number | null;
    dropoffApprovalDistanceMeters?: number | null;
    dropoffApprovalDriverLocation?: { lat: number; lng: number } | null;
    completedAt?: number | null;
    statusHistory: Array<{
      from: string;
      to: string;
      actor: string;
      role: string;
      reason?: string;
      action?: string;
      distanceMeters?: number;
      timestamp: number;
    }>;
  }

  // Ikeja City Mall dropoff coordinates: 6.6190, 3.3582
  const DROPOFF_LAT = 6.6190;
  const DROPOFF_LNG = 3.3582;

  function createTestTrip(overrides: Partial<MockTrip> = {}): MockTrip {
    return {
      id: "trip_geofence_123",
      status: "IN_PROGRESS",
      customerId: "cust_abc",
      driverId: "driver_xyz",
      dropoff: {
        lat: DROPOFF_LAT,
        lng: DROPOFF_LNG,
        address: "Ikeja City Mall, Alausa, Ikeja",
      },
      dropoffApprovalStatus: null,
      statusHistory: [
        {
          from: "DRIVER_ARRIVED",
          to: "IN_PROGRESS",
          actor: "driver_xyz",
          role: "driver",
          timestamp: Date.now() - 600000,
        },
      ],
      ...overrides,
    };
  }

  // Simulated server validation logic matching advanceTripStatus
  function validateAndCompleteTrip(
    trip: MockTrip,
    callerId: string,
    driverLocation: { lat: number; lng: number } | null,
    configuredRadiusMeters = 500
  ): { ok: boolean; status: string } {
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

      const distKm = haversineKm(
        driverLocation.lat,
        driverLocation.lng,
        trip.dropoff.lat,
        trip.dropoff.lng
      );
      const distM = Math.round(distKm * 1000);

      if (distM > configuredRadiusMeters) {
        throw new Error(
          `failed-precondition: OUT_OF_RANGE: Driver is outside drop-off location (${distM}m away, max allowed is ${configuredRadiusMeters}m). Customer confirmation required.`
        );
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
  function requestDropoffApproval(
    trip: MockTrip,
    callerId: string,
    driverLocation: { lat: number; lng: number },
    configuredRadiusMeters = 500
  ): { ok: boolean; pending: true; distanceMeters: number; radiusMeters: number } {
    if (callerId !== trip.driverId) {
      throw new Error("permission-denied: Not your trip.");
    }
    if (trip.status !== "IN_PROGRESS") {
      throw new Error(`failed-precondition: Trip must be IN_PROGRESS (currently ${trip.status}).`);
    }

    const distKm = haversineKm(
      driverLocation.lat,
      driverLocation.lng,
      trip.dropoff.lat,
      trip.dropoff.lng
    );
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
  function respondDropoffApproval(
    trip: MockTrip,
    callerId: string,
    approved: boolean
  ): { ok: boolean; approved: boolean; completed: boolean } {
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
    } else {
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

  test("1. In-Range Completion: allows immediate completion when within default 500m radius", () => {
    const trip = createTestTrip();
    // Driver is ~150 meters from drop-off destination
    const nearLocation = { lat: 6.6198, lng: 3.3590 };

    const result = validateAndCompleteTrip(trip, "driver_xyz", nearLocation, 500);
    assert.strictEqual(result.ok, true);
    assert.strictEqual(result.status, "COMPLETED");
    assert.strictEqual(trip.status, "COMPLETED");
    assert.ok(trip.completedAt! > 0);
  });

  test("2. Out-of-Range Rejection: strictly blocks completion when driver is beyond 500m", () => {
    const trip = createTestTrip();
    // Driver is ~2.8 km away in Maryland/Anthony
    const farLocation = { lat: 6.5700, lng: 3.3650 };

    assert.throws(
      () => validateAndCompleteTrip(trip, "driver_xyz", farLocation, 500),
      /OUT_OF_RANGE/
    );
    // Trip remains IN_PROGRESS and uncompleted
    assert.strictEqual(trip.status, "IN_PROGRESS");
    assert.strictEqual(trip.completedAt, undefined);
  });

  test("3. Hub Configurable Drop-Off Radius: respects custom 1000m setting from Hub", () => {
    const trip = createTestTrip();
    // Driver is ~750m away from dropoff
    const intermediateLocation = { lat: 6.6255, lng: 3.3560 };

    // With default 500m radius -> rejected
    assert.throws(
      () => validateAndCompleteTrip(trip, "driver_xyz", intermediateLocation, 500),
      /OUT_OF_RANGE/
    );

    // With Hub configured 1000m radius -> allowed
    const result = validateAndCompleteTrip(trip, "driver_xyz", intermediateLocation, 1000);
    assert.strictEqual(result.ok, true);
    assert.strictEqual(result.status, "COMPLETED");
  });

  test("4. Out-of-Range Handling: driver sends confirmation request, entering PENDING state", () => {
    const trip = createTestTrip();
    const farLocation = { lat: 6.5700, lng: 3.3650 };

    const response = requestDropoffApproval(trip, "driver_xyz", farLocation, 500);
    assert.strictEqual(response.ok, true);
    assert.strictEqual(response.pending, true);
    assert.ok(response.distanceMeters > 500);
    assert.strictEqual(trip.dropoffApprovalStatus, "PENDING");
    assert.ok(trip.dropoffApprovalRequestedAt! > 0);
    assert.deepStrictEqual(trip.dropoffApprovalDriverLocation, farLocation);
  });

  test("5. Security Gate: rejects requestDropoffApproval from unauthorized non-assigned driver", () => {
    const trip = createTestTrip();
    const farLocation = { lat: 6.5700, lng: 3.3650 };

    assert.throws(
      () => requestDropoffApproval(trip, "attacker_driver", farLocation, 500),
      /permission-denied/
    );
    assert.strictEqual(trip.dropoffApprovalStatus, null);
  });

  test("6. Remote Customer Approval: customer approves out-of-range dropoff, finalizing completion", () => {
    const trip = createTestTrip({
      dropoffApprovalStatus: "PENDING",
      dropoffApprovalRequestedAt: Date.now() - 30000,
      dropoffApprovalDistanceMeters: 2800,
    });

    const result = respondDropoffApproval(trip, "cust_abc", true);
    assert.strictEqual(result.ok, true);
    assert.strictEqual(result.approved, true);
    assert.strictEqual(result.completed, true);
    assert.strictEqual(trip.status, "COMPLETED");
    assert.strictEqual(trip.dropoffApprovalStatus, "APPROVED");
    assert.ok(trip.dropoffApprovalRespondedAt! > 0);
  });

  test("7. Remote Customer Rejection: customer rejects dropoff, keeping trip active in IN_PROGRESS", () => {
    const trip = createTestTrip({
      dropoffApprovalStatus: "PENDING",
      dropoffApprovalRequestedAt: Date.now() - 30000,
      dropoffApprovalDistanceMeters: 2800,
    });

    const result = respondDropoffApproval(trip, "cust_abc", false);
    assert.strictEqual(result.ok, true);
    assert.strictEqual(result.approved, false);
    assert.strictEqual(result.completed, false);
    assert.strictEqual(trip.status, "IN_PROGRESS");
    assert.strictEqual(trip.dropoffApprovalStatus, "REJECTED");
    assert.strictEqual(trip.completedAt, undefined);
  });

  test("8. Security Gate: rejects response from non-customer caller", () => {
    const trip = createTestTrip({
      dropoffApprovalStatus: "PENDING",
      dropoffApprovalRequestedAt: Date.now() - 30000,
    });

    assert.throws(
      () => respondDropoffApproval(trip, "intruder_user", true),
      /permission-denied/
    );
    assert.strictEqual(trip.status, "IN_PROGRESS");
    assert.strictEqual(trip.dropoffApprovalStatus, "PENDING");
  });

  test("9. Bypasses geofence check once customer has explicitly APPROVED remote drop-off", () => {
    const trip = createTestTrip({
      dropoffApprovalStatus: "APPROVED",
    });
    // Driver is 3km away, but customer already approved
    const farLocation = { lat: 6.5700, lng: 3.3650 };

    const result = validateAndCompleteTrip(trip, "driver_xyz", farLocation, 500);
    assert.strictEqual(result.ok, true);
    assert.strictEqual(result.status, "COMPLETED");
  });
});
