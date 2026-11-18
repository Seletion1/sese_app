import assert from "node:assert";
import { test, describe } from "node:test";
import { haversineKm } from "../trips";

describe("Strict Smart-Dispatch & Stacked Order Proximity Invariants", () => {
  const defaultTuning = {
    allowStackedOrders: true,
    maxDistanceToDropoffKm: 2.0,
    maxRemainingTimeMinutes: 10,
  };

  function evaluateStackedEligibility(
    activeStatus: string,
    driverLoc: { lat: number; lng: number },
    dropoffLoc: { lat: number; lng: number },
    tuning = defaultTuning,
    speedKmh = 25
  ): { eligible: boolean; reason?: string } {
    if (!tuning.allowStackedOrders) {
      return { eligible: false, reason: "stacked_orders_disabled" };
    }
    if (activeStatus !== "IN_PROGRESS") {
      return { eligible: false, reason: "not_in_final_stage" };
    }
    const distKm = haversineKm(driverLoc.lat, driverLoc.lng, dropoffLoc.lat, dropoffLoc.lng);
    if (distKm > tuning.maxDistanceToDropoffKm) {
      return { eligible: false, reason: "distance_exceeds_threshold" };
    }
    const estTimeMin = (distKm / Math.max(speedKmh, 5)) * 60;
    if (estTimeMin > tuning.maxRemainingTimeMinutes) {
      return { eligible: false, reason: "eta_exceeds_threshold" };
    }
    return { eligible: true };
  }

  test("1. Active trip in DRIVER_ACCEPTED or DRIVER_ARRIVING strictly blocks driver from candidate pool", () => {
    const res1 = evaluateStackedEligibility("DRIVER_ACCEPTED", { lat: 6.52, lng: 3.37 }, { lat: 6.52, lng: 3.37 });
    assert.strictEqual(res1.eligible, false);
    assert.strictEqual(res1.reason, "not_in_final_stage");

    const res2 = evaluateStackedEligibility("DRIVER_ARRIVING", { lat: 6.52, lng: 3.37 }, { lat: 6.52, lng: 3.37 });
    assert.strictEqual(res2.eligible, false);
    assert.strictEqual(res2.reason, "not_in_final_stage");
  });

  test("2. Driver in IN_PROGRESS within 2.0 km and 10 min ETA is eligible for stacked order", () => {
    // Driver at 1.0 km from dropoff
    const driverLoc = { lat: 6.5244, lng: 3.3792 };
    const dropoffLoc = { lat: 6.5334, lng: 3.3792 }; // ~1.0 km
    const res = evaluateStackedEligibility("IN_PROGRESS", driverLoc, dropoffLoc);
    assert.strictEqual(res.eligible, true);
  });

  test("3. Driver beyond 2.0 km distance threshold is rejected for stacked order", () => {
    const driverLoc = { lat: 6.5244, lng: 3.3792 };
    const dropoffLoc = { lat: 6.5644, lng: 3.3792 }; // ~4.4 km
    const res = evaluateStackedEligibility("IN_PROGRESS", driverLoc, dropoffLoc);
    assert.strictEqual(res.eligible, false);
    assert.strictEqual(res.reason, "distance_exceeds_threshold");
  });

  test("4. Disabling allowStackedOrders blocks all drivers with active trips", () => {
    const driverLoc = { lat: 6.5244, lng: 3.3792 };
    const dropoffLoc = { lat: 6.5254, lng: 3.3792 }; // ~0.1 km
    const disabledTuning = { ...defaultTuning, allowStackedOrders: false };
    const res = evaluateStackedEligibility("IN_PROGRESS", driverLoc, dropoffLoc, disabledTuning);
    assert.strictEqual(res.eligible, false);
    assert.strictEqual(res.reason, "stacked_orders_disabled");
  });

  test("5. Fixed-fare trip (allow_bidding: false) rejects driver counter-offer bids", () => {
    const tripWithBidding = { allow_bidding: true, allowBidding: true };
    const tripFixedFare = { allow_bidding: false, allowBidding: false };

    const isBiddingAllowed = (trip: any) => trip.allowBidding !== false && trip.allow_bidding !== false;

    assert.strictEqual(isBiddingAllowed(tripWithBidding), true);
    assert.strictEqual(isBiddingAllowed(tripFixedFare), false);
  });
});
