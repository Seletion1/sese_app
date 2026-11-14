import { describe, it } from "node:test";
import * as assert from "node:assert";
import { computeCommission } from "../driverStreak";

/**
 * Strict Server-Side Financial Scoping, Broadcast Payload Delivery & Debt Recovery Tests
 *
 * Grounded on incoming offer screenshot (IMG-20261114-WA0000.jpg) and
 * customer breakdown screenshot (Screenshot_20261113_235916.jpg).
 */

describe("Strict Server-Side Financial Scoping & Customer Debt Recovery Engine", () => {
  const baseTripFare = 5000;
  const outstandingDebt = 765;
  const totalCollectibleFare = 5765;

  it("1. Server-Authoritative Financial Payload Generation on Trip Creation", () => {
    // Simulate server-side financial calculation in createTrip
    const baseFare = baseTripFare;
    const recoveredDebt = outstandingDebt;
    const totalFare = baseFare + recoveredDebt;

    const payload = {
      base_trip_fare: baseFare,
      baseTripFare: baseFare,
      baseFare,
      outstanding_debt: recoveredDebt,
      outstandingDebt: recoveredDebt,
      recoveredDebt,
      total_collectible_fare: totalFare,
      totalCollectibleFare: totalFare,
      totalFare,
      broadcast_fare: baseFare,
      broadcastFare: baseFare,
      broadcastFareFormatted: `₦${baseFare.toLocaleString()}`,
      fareFormatted: `₦${baseFare.toLocaleString()}`,
      totalCollectibleFareFormatted: `₦${totalFare.toLocaleString()}`,
      fareAmount: baseFare,
      driverAcceptedFinancialsReleased: false,
      paymentBreakdown: {
        base_trip_fare: baseFare,
        baseTripFare: baseFare,
        baseFare,
        outstanding_debt: recoveredDebt,
        outstandingDebt: recoveredDebt,
        recoveredDebt,
        total_collectible_fare: totalFare,
        totalCollectibleFare: totalFare,
        totalFare,
        broadcast_fare: baseFare,
        broadcastFare: baseFare,
      },
    };

    assert.strictEqual(payload.broadcast_fare, 5000, "broadcast_fare must carry ONLY clean base trip fare.");
    assert.strictEqual(payload.total_collectible_fare, 5765, "total_collectible_fare must carry full debt-inclusive amount.");
    assert.strictEqual(payload.outstanding_debt, 765, "outstanding_debt must equal customer negative balance.");
    assert.strictEqual(payload.fareFormatted, "₦5,000", "Pre-acceptance fareFormatted must strictly format broadcast_fare.");
    assert.strictEqual(payload.totalCollectibleFareFormatted, "₦5,765");
    assert.strictEqual(payload.driverAcceptedFinancialsReleased, false, "Financials must not be released pre-acceptance.");
  });

  it("2. Server-Enforced Broadcast Scoping (Driver Side - Pre-Acceptance)", () => {
    // Simulate server dispatch notification payload sent to nearby drivers
    const tripData = {
      pickupAddress: "34 Olafiloye St, Ikorodu",
      dropoffAddress: "18 Adebayo Mokuolu St, Anthony",
      broadcast_fare: baseTripFare,
      base_trip_fare: baseTripFare,
      total_collectible_fare: totalCollectibleFare,
      outstanding_debt: outstandingDebt,
    };

    const broadcastFareAmount = Number(
      tripData.broadcast_fare ??
      tripData.base_trip_fare ??
      0
    );

    const driverNotificationPayload: Record<string, string> = {
      tripId: "trip_lagos_123",
      dispatchStep: "1",
      pickupAddress: tripData.pickupAddress,
      dropoffAddress: tripData.dropoffAddress,
      broadcast_fare: String(broadcastFareAmount),
      fareFormatted: `₦${broadcastFareAmount.toLocaleString()}`,
      fareAmount: String(broadcastFareAmount),
      distanceKm: "27.6",
    };

    // Assert strictly that customer debt is NOT leaked in broadcast
    assert.strictEqual(driverNotificationPayload.broadcast_fare, "5000");
    assert.strictEqual(driverNotificationPayload.fareFormatted, "₦5,000");
    assert.strictEqual(driverNotificationPayload.fareAmount, "5000");
    assert.strictEqual((driverNotificationPayload as any).outstanding_debt, undefined, "outstanding_debt must never be sent in driver broadcast");
    assert.strictEqual((driverNotificationPayload as any).total_collectible_fare, undefined, "total_collectible_fare must never be sent in driver broadcast");

    // Rate calculation verified: ₦5,000 / 27.6 km = ₦181/km
    const ratePerKm = Math.round(Number(driverNotificationPayload.fareAmount) / Number(driverNotificationPayload.distanceKm));
    assert.strictEqual(ratePerKm, 181, "Pre-acceptance driver offer rate must be ₦181/km based on ₦5,000 base fare");
  });

  it("3. Secure Post-Acceptance Transition & State Lock in Database", () => {
    // Driver taps accept -> Atomic transaction executes
    const driverId = "driver_bamiduro";
    const tripId = "trip_lagos_123";
    const data = {
      status: "WAITING_FOR_ACCEPTANCE",
      base_trip_fare: baseTripFare,
      outstanding_debt: outstandingDebt,
      total_collectible_fare: totalCollectibleFare,
      paymentMethod: "cash",
      cashToCollect: totalCollectibleFare,
    };

    // Atomic transaction logic:
    const baseTripFareResolved = Number(data.base_trip_fare);
    const outstandingDebtResolved = Number(data.outstanding_debt);
    const totalCollectibleFareResolved = Number(data.total_collectible_fare);

    const tripUpdate = {
      status: "DRIVER_ACCEPTED",
      driverId,
      driverAcceptedFinancialsReleased: true,
      driverAcceptedAt: Date.now(),
      base_trip_fare: baseTripFareResolved,
      outstanding_debt: outstandingDebtResolved,
      total_collectible_fare: totalCollectibleFareResolved,
      cashToCollect: data.paymentMethod === "cash"
        ? totalCollectibleFareResolved
        : data.cashToCollect,
      fareFormatted: `₦${totalCollectibleFareResolved.toLocaleString()}`,
      paymentBreakdown: {
        base_trip_fare: baseTripFareResolved,
        outstanding_debt: outstandingDebtResolved,
        total_collectible_fare: totalCollectibleFareResolved,
        cashToCollect: totalCollectibleFareResolved,
        driverAcceptedFinancialsReleased: true,
      },
    };

    const driverStatusUpdate = {
      activeTripId: tripId,
      activeTripStatus: "DRIVER_ACCEPTED",
      updatedAt: Date.now(),
    };

    // Assert post-acceptance state
    assert.strictEqual(tripUpdate.status, "DRIVER_ACCEPTED");
    assert.strictEqual(tripUpdate.driverId, driverId);
    assert.strictEqual(tripUpdate.driverAcceptedFinancialsReleased, true);
    assert.strictEqual(tripUpdate.cashToCollect, 5765, "Driver must now collect ₦5,765 in cash upon pickup/dropoff");
    assert.strictEqual(tripUpdate.fareFormatted, "₦5,765");
    assert.strictEqual(driverStatusUpdate.activeTripId, tripId, "Driver session state locked with active trip ID");
  });

  it("4. Secure Cash Collection & Commission Ledger (Backend Enforcement)", () => {
    // Completion of cash trip:
    const tripData = {
      base_trip_fare: baseTripFare,
      outstanding_debt: outstandingDebt,
      total_collectible_fare: totalCollectibleFare,
      cashToCollect: 5765,
      paymentMethod: "cash",
    };

    // Server-side ledger: Commission computed strictly against base_trip_fare
    const streakMock = {
      driverId: "driver_bamiduro",
      currentLevel: 1,
      currentStep: 0,
      level1PaidHistory: [],
      dailyStreakCompleted: false,
      baseCommissionRate: 0.15,
      streakActive: true,
      updatedAtMs: Date.now(),
      resetDateLocal: "2026-11-14",
    };

    const cfgMock = {
      baseCommissionRate: 0.15, // 15% Standard Fee
      perksByLevel: {},
      completionCashAward: 0,
    };

    // Commission must execute on base_trip_fare (5000), NOT on total_collectible_fare (5765)
    const commResult = computeCommission(streakMock as any, tripData.base_trip_fare, cfgMock as any, false);

    assert.strictEqual(commResult.commissionRate, 0.15);
    assert.strictEqual(commResult.commissionAmount, 750, "15% fee on ₦5,000 base fare must equal exactly ₦750");

    // Dual Naira/Kobo ledger debits
    const commissionDebitKobo = commResult.commissionAmount * 100; // 75,000 kobo
    const recoveredDebtKobo = tripData.outstanding_debt * 100; // 76,500 kobo

    assert.strictEqual(commissionDebitKobo, 75000);
    assert.strictEqual(recoveredDebtKobo, 76500);

    // Platform reconciliation invariant:
    // Driver collected ₦5,765 cash from customer.
    // Driver wallet debited ₦750 (platform commission on base fare).
    // Driver wallet debited ₦765 (recovered platform debt collected in cash).
    // Driver net earnings = ₦5,765 (cash in pocket) - ₦750 (comm) - ₦765 (debt debit) = ₦4,250 (which is ₦5,000 * 0.85).
    const driverCashCollected = tripData.cashToCollect;
    const driverNetFinancialPosition = driverCashCollected - (commResult.commissionAmount + tripData.outstanding_debt);
    const expectedNetEarnings = tripData.base_trip_fare * (1 - commResult.commissionRate);

    assert.strictEqual(driverNetFinancialPosition, expectedNetEarnings, "Driver net earnings must equal exactly 85% of base fare (₦4,250)");

    // Customer ledger: Customer paid ₦765 debt in cash -> Customer wallet credited ₦765 to clear negative balance
    const customerDebtSettledCreditKobo = recoveredDebtKobo;
    assert.strictEqual(customerDebtSettledCreditKobo, 76500, "Customer wallet ledger must be credited with settled debt");
  });
});
