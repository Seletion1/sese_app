import assert from "node:assert";
import { test, describe } from "node:test";

describe("Driver Order-Skip Workflow, Penalty Recording & Pool Escalation", () => {
  interface DriverCandidate {
    id: string;
    distanceKm: number;
    isOnline: boolean;
  }

  interface MockDriverStreak {
    driverId: string;
    currentLevel: number;
    currentStep: number;
    streakBrokenCount: number;
  }

  interface MockTrip {
    id: string;
    status: string;
    dispatchTier: number;
    dispatchStep: number;
    pingDriverId: string | null;
    pingDriverIds: string[];
    attemptedDriverIds: string[];
    cancellationSource: string | null;
    declineCount: number;
    rejections: Array<{ driverId: string; action: string; timestamp: number }>;
    statusHistory: Array<{ from: string; to: string; actor: string; role: string; reason: string; timestamp: number }>;
    tierExpiresAt: number | null;
  }

  const MAX_SEQUENTIAL_DRIVERS = 3;
  const DEFAULT_SEARCH_RADIUS_KM = 3.0;

  function breakDriverStreak(streak: MockDriverStreak, reason: string): void {
    streak.currentStep = 0; // Reset step on streak break
    streak.streakBrokenCount += 1;
  }

  function advanceSequentialDispatch(
    trip: MockTrip,
    availableDrivers: DriverCandidate[],
    searchRadiusKm = DEFAULT_SEARCH_RADIUS_KM
  ): void {
    if (
      trip.dispatchStep >= MAX_SEQUENTIAL_DRIVERS ||
      trip.attemptedDriverIds.length >= MAX_SEQUENTIAL_DRIVERS
    ) {
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
      .filter(
        (d) =>
          d.isOnline &&
          d.distanceKm <= searchRadiusKm &&
          !trip.attemptedDriverIds.includes(d.id)
      )
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

  function handleDeclineTrip(
    trip: MockTrip,
    driverId: string,
    action: "skipped" | "rejected",
    streak: MockDriverStreak,
    availableDrivers: DriverCandidate[]
  ): void {
    assert.strictEqual(trip.status, "WAITING_FOR_ACCEPTANCE", "Trip must be WAITING_FOR_ACCEPTANCE");
    assert.strictEqual(trip.pingDriverId, driverId, "Only pinged driver can decline or skip");

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

  function sweepTimedOutPings(
    trips: MockTrip[],
    driverStreaks: Map<string, MockDriverStreak>,
    availableDrivers: DriverCandidate[],
    cutoffTime: number
  ): void {
    for (const trip of trips) {
      if (
        trip.status === "WAITING_FOR_ACCEPTANCE" &&
        trip.tierExpiresAt !== null &&
        trip.tierExpiresAt < cutoffTime
      ) {
        const ignoredDriverId = trip.pingDriverId;
        if (ignoredDriverId) {
          const streak = driverStreaks.get(ignoredDriverId);
          if (streak) breakDriverStreak(streak, "ping_expired");

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

  test("1. Explicit driver skip sets cancellationSource='skipped_by_driver', breaks streak, and advances dispatch to 2nd driver", () => {
    const drivers: DriverCandidate[] = [
      { id: "driver_1", distanceKm: 0.5, isOnline: true },
      { id: "driver_2", distanceKm: 1.2, isOnline: true },
      { id: "driver_3", distanceKm: 2.0, isOnline: true },
    ];

    const driver1Streak: MockDriverStreak = {
      driverId: "driver_1",
      currentLevel: 1,
      currentStep: 3,
      streakBrokenCount: 0,
    };

    const trip: MockTrip = {
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
    assert.strictEqual(trip.status, "WAITING_FOR_ACCEPTANCE");
    assert.strictEqual(trip.pingDriverId, "driver_1");

    // Driver 1 skips the incoming request
    handleDeclineTrip(trip, "driver_1", "skipped", driver1Streak, drivers);

    // Verify cancellationSource, rejections, statusHistory
    assert.strictEqual(trip.cancellationSource, "skipped_by_driver");
    assert.strictEqual(trip.declineCount, 1);
    assert.strictEqual(trip.rejections.length, 1);
    assert.strictEqual(trip.rejections[0].driverId, "driver_1");
    assert.strictEqual(trip.rejections[0].action, "skipped");
    assert.strictEqual(trip.statusHistory.length, 1);

    // Verify Driver 1 streak penalty applied
    assert.strictEqual(driver1Streak.currentStep, 0);
    assert.strictEqual(driver1Streak.streakBrokenCount, 1);

    // Verify sequential dispatch re-routed order to Driver 2
    assert.strictEqual(trip.status, "WAITING_FOR_ACCEPTANCE");
    assert.strictEqual(trip.pingDriverId, "driver_2");
    assert.strictEqual(trip.dispatchStep, 2);
  });

  test("2. Three consecutive skips by drivers escalate the order directly to the Public Order Pool (MARKETPLACE_OPEN)", () => {
    const drivers: DriverCandidate[] = [
      { id: "driver_1", distanceKm: 0.5, isOnline: true },
      { id: "driver_2", distanceKm: 1.0, isOnline: true },
      { id: "driver_3", distanceKm: 1.5, isOnline: true },
    ];

    const streaks = new Map<string, MockDriverStreak>([
      ["driver_1", { driverId: "driver_1", currentLevel: 1, currentStep: 2, streakBrokenCount: 0 }],
      ["driver_2", { driverId: "driver_2", currentLevel: 2, currentStep: 4, streakBrokenCount: 0 }],
      ["driver_3", { driverId: "driver_3", currentLevel: 1, currentStep: 1, streakBrokenCount: 0 }],
    ]);

    const trip: MockTrip = {
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
    handleDeclineTrip(trip, "driver_1", "skipped", streaks.get("driver_1")!, drivers);

    // Driver 2 pinged & skips
    assert.strictEqual(trip.pingDriverId, "driver_2");
    handleDeclineTrip(trip, "driver_2", "skipped", streaks.get("driver_2")!, drivers);

    // Driver 3 pinged & skips
    assert.strictEqual(trip.pingDriverId, "driver_3");
    handleDeclineTrip(trip, "driver_3", "skipped", streaks.get("driver_3")!, drivers);

    // Order escalated to Public Pool (Step 4 / MARKETPLACE_OPEN)
    assert.strictEqual(trip.status, "MARKETPLACE_OPEN");
    assert.strictEqual(trip.dispatchTier, 3);
    assert.strictEqual(trip.dispatchStep, 4);
    assert.strictEqual(trip.pingDriverId, null);
    assert.strictEqual(trip.declineCount, 3);
    assert.strictEqual(trip.rejections.length, 3);
  });

  test("3. Scheduled 1-minute sweep (sweepTripPings) automatically expires ignored pings, penalizes streaks, and advances dispatch", () => {
    const drivers: DriverCandidate[] = [
      { id: "driver_1", distanceKm: 0.8, isOnline: true },
      { id: "driver_2", distanceKm: 1.4, isOnline: true },
    ];

    const driverStreaks = new Map<string, MockDriverStreak>([
      ["driver_1", { driverId: "driver_1", currentLevel: 2, currentStep: 3, streakBrokenCount: 0 }],
    ]);

    const now = Date.now();
    const trip: MockTrip = {
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
    assert.strictEqual(driverStreaks.get("driver_1")!.currentStep, 0);

    // Verify cancellationSource recorded as skipped_by_driver
    assert.strictEqual(trip.cancellationSource, "skipped_by_driver");
    assert.strictEqual(trip.rejections.length, 1);
    assert.strictEqual(trip.rejections[0].action, "skipped");

    // Verify dispatch advanced to Driver 2
    assert.strictEqual(trip.status, "WAITING_FOR_ACCEPTANCE");
    assert.strictEqual(trip.pingDriverId, "driver_2");
    assert.strictEqual(trip.dispatchStep, 2);
  });
});
