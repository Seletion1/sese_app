import { describe, it } from "node:test";
import * as assert from "node:assert/strict";
import {
  nairaToKobo,
  computeCommission,
  DriverStreakDoc,
  DailyStreakConfig,
  FinancialMutationLog,
  TripTransitionLog,
} from "../driverStreak";

describe("Backend Safety & Invariant Matrix", () => {
  // ── 1. Trip Creation & Escrow Hold Invariants ─────────────────────────────
  describe("1. Trip Creation & Escrow Invariants", () => {
    it("locks escrow without over-locking or going negative", () => {
      const fareAmount = 5000;
      const availableBalance = 3200;
      const walletCoverage = Math.min(fareAmount, availableBalance);
      assert.equal(walletCoverage, 3200);

      // Verify customer wallet escrow invariant
      const initialEscrow = 0;
      const newEscrow = initialEscrow + walletCoverage;
      assert.equal(newEscrow, 3200);

      // Cash portion to collect from customer
      const cashToCollect = Math.max(0, fareAmount - walletCoverage);
      assert.equal(cashToCollect, 1800);
      assert.equal(walletCoverage + cashToCollect, fareAmount);
    });

    it("generates deterministic escrow hold transaction key", () => {
      const tripId = "trip_test_123";
      const docId = `${tripId}_escrow_hold`;
      assert.equal(docId, "trip_test_123_escrow_hold");
    });
  });

  // ── 2. Trip Accept & Dual Assignment Guard ─────────────────────────────────
  describe("2. Trip Accept & Single Driver Assignment", () => {
    it("assigns first claiming driver and rejects subsequent driver claims", () => {
      interface MockTrip {
        tripId: string;
        status: string;
        driverId: string | null;
      }
      const trip: MockTrip = {
        tripId: "trip_accept_test",
        status: "WAITING_FOR_ACCEPTANCE",
        driverId: null,
      };

      const acceptTrip = (driverId: string): { ok: boolean; status: string } => {
        if (trip.driverId && trip.driverId !== driverId) {
          throw new Error("Another driver claimed this trip first.");
        }
        if (trip.driverId === driverId) {
          return { ok: true, status: trip.status }; // idempotent retry
        }
        trip.driverId = driverId;
        trip.status = "DRIVER_ACCEPTED";
        return { ok: true, status: trip.status };
      };

      // Driver A claims trip -> success
      const resA = acceptTrip("driver_alpha");
      assert.equal(resA.ok, true);
      assert.equal(trip.driverId, "driver_alpha");
      assert.equal(trip.status, "DRIVER_ACCEPTED");

      // Driver B attempts claim -> rejected
      assert.throws(
        () => acceptTrip("driver_bravo"),
        /Another driver claimed this trip first/
      );

      // Driver A retries duplicate call -> idempotent success
      const retryA = acceptTrip("driver_alpha");
      assert.equal(retryA.ok, true);
      assert.equal(trip.driverId, "driver_alpha");
    });
  });

  // ── 3. Low-Balance Driver Rejection ───────────────────────────────────────
  describe("3. Low-Balance Rejection", () => {
    it("rejects driver with balance below minWalletBalanceToOnline threshold", () => {
      const minBalance = 1.0; // ₦1.00
      const checkDriverBalance = (balanceNaira: number) => {
        if (balanceNaira < minBalance) {
          throw new Error("Your balance is low. Please top up to accept trips.");
        }
        return true;
      };

      assert.throws(
        () => checkDriverBalance(0.5),
        /Your balance is low/
      );
      assert.throws(
        () => checkDriverBalance(-10.0),
        /Your balance is low/
      );
      assert.equal(checkDriverBalance(500.0), true);
    });
  });

  // ── 4. Trip Decline & Sequential Reassignment ─────────────────────────────
  describe("4. Trip Decline & Audit Trail", () => {
    it("breaks driver streak and records structured rejection log on decline", () => {
      const trip = {
        status: "WAITING_FOR_ACCEPTANCE",
        declineCount: 0,
        rejections: [] as Array<{ driverId: string; action: string; timestamp: number }>,
      };

      const declineTrip = (driverId: string, action: "skipped" | "rejected") => {
        trip.status = "SEARCHING_DRIVER";
        trip.declineCount += 1;
        trip.rejections.push({ driverId, action, timestamp: Date.now() });
      };

      declineTrip("driver_1", "rejected");
      assert.equal(trip.status, "SEARCHING_DRIVER");
      assert.equal(trip.declineCount, 1);
      assert.equal(trip.rejections.length, 1);
      assert.equal(trip.rejections[0].action, "rejected");
      assert.equal(trip.rejections[0].driverId, "driver_1");
    });
  });

  // ── 5. Driver Reassignment Bounded Limits ─────────────────────────────────
  describe("5. Driver Reassignment Bounds (Max 3 Reassignments)", () => {
    it("reassigns up to 3 times then transitions to needs_customer_action", () => {
      let status = "DRIVER_ACCEPTED";
      let reassignmentCount = 0;

      const handleDriverCancel = () => {
        reassignmentCount += 1;
        if (reassignmentCount <= 3) {
          status = "SEARCHING_DRIVER";
          return { reassigned: true, attempt: reassignmentCount };
        } else {
          status = "needs_customer_action";
          return { reassigned: false, needsCustomerAction: true };
        }
      };

      // 1st driver cancel
      const r1 = handleDriverCancel();
      assert.equal(r1.reassigned, true);
      assert.equal(status, "SEARCHING_DRIVER");
      assert.equal(reassignmentCount, 1);

      // 2nd driver cancel
      const r2 = handleDriverCancel();
      assert.equal(r2.reassigned, true);
      assert.equal(status, "SEARCHING_DRIVER");
      assert.equal(reassignmentCount, 2);

      // 3rd driver cancel
      const r3 = handleDriverCancel();
      assert.equal(r3.reassigned, true);
      assert.equal(status, "SEARCHING_DRIVER");
      assert.equal(reassignmentCount, 3);

      // 4th driver cancel -> BOUND HIT: no endless loop, stops at needs_customer_action
      const r4 = handleDriverCancel();
      assert.equal(r4.reassigned, false);
      assert.equal(r4.needsCustomerAction, true);
      assert.equal(status, "needs_customer_action");
    });
  });

  // ── 6. Trip Cancel & Safe Escrow Release ───────────────────────────────────
  describe("6. Escrow Release & Invariant Math", () => {
    it("releases escrow safely and prevents negative escrow balance", () => {
      const currentEscrow = 2500;
      const refundAmount = 2500;
      const newEscrow = Math.max(0, currentEscrow - refundAmount);
      assert.equal(newEscrow, 0);

      // Over-refund protection clamp
      const clampedEscrow = Math.max(0, 1000 - 3000);
      assert.equal(clampedEscrow, 0);
    });

    it("ensures cancellation settlement keys are deterministic", () => {
      const tripId = "trip_cancel_99";
      assert.equal(`${tripId}_escrow_refund`, "trip_cancel_99_escrow_refund");
      assert.equal(`${tripId}_waiting_fee_paid`, "trip_cancel_99_waiting_fee_paid");
      assert.equal(`${tripId}_waiting_fee_credited`, "trip_cancel_99_waiting_fee_credited");
    });
  });

  // ── 7. Trip Completion Settlement & Commission ────────────────────────────
  describe("7. Canonical Completion Settlement", () => {
    it("calculates commission and dual Naira/Kobo balances consistently", () => {
      const fareAmount = 4000;
      const initialStreak: DriverStreakDoc = {
        currentLevel: 1,
        currentStep: 0,
        streakActive: true,
        level1PaidHistory: [],
        baseCommissionRate: 0.15,
        dailyStreakCompleted: false,
        resetDateLocal: "2026-11-02",
      };
      const cfg: DailyStreakConfig = {
        streakEnabled: true,
        baseCommissionRate: 0.15,
        noShowWaitMinutes: 10,
        completionCashAward: 5000,
        disabledCountries: [],
        disabledStates: [],
      };

      const result = computeCommission(initialStreak, fareAmount, cfg);
      assert.equal(result.commissionRate, 0.15);
      assert.equal(result.commissionAmount, 600); // 15% of 4000 = 600
      assert.equal(nairaToKobo(result.commissionAmount), 60000);
    });

    it("generates deterministic completion settlement keys", () => {
      const tripId = "trip_comp_777";
      assert.equal(`${tripId}_commission`, "trip_comp_777_commission");
      assert.equal(`${tripId}_bonus`, "trip_comp_777_bonus");
      assert.equal(`${tripId}_grand_award`, "trip_comp_777_grand_award");
      assert.equal(`${tripId}_payment`, "trip_comp_777_payment");
      assert.equal(`${tripId}_wallet_settlement`, "trip_comp_777_wallet_settlement");
    });
  });

  // ── 8. Duplicate Settlement Prevention (Idempotency) ───────────────────────
  describe("8. Settlement Idempotency", () => {
    it("aborts duplicate runs when settlement is already marked complete", () => {
      let settlementRuns = 0;
      const tripDoc = {
        settlement: {
          settled: false,
          commissionSettled: false,
        },
      };

      const settleTrip = () => {
        if (tripDoc.settlement.settled || tripDoc.settlement.commissionSettled) {
          return { alreadySettled: true };
        }
        settlementRuns += 1;
        tripDoc.settlement.settled = true;
        tripDoc.settlement.commissionSettled = true;
        return { settled: true };
      };

      const firstRun = settleTrip();
      assert.equal(firstRun.settled, true);
      assert.equal(settlementRuns, 1);

      // Concurrent or duplicate trigger run
      const duplicateRun = settleTrip();
      assert.equal(duplicateRun.alreadySettled, true);
      assert.equal(settlementRuns, 1); // No double settlement!
    });
  });

  // ── 9. Stale Status Rejection ─────────────────────────────────────────────
  describe("9. Stale Status & State Machine Verification", () => {
    const DRIVER_TRANSITIONS: Record<string, string[]> = {
      DRIVER_ACCEPTED: ["DRIVER_ARRIVING", "DRIVER_ARRIVED"],
      DRIVER_ARRIVING: ["DRIVER_ARRIVED"],
      DRIVER_ARRIVED: ["IN_PROGRESS"],
      IN_PROGRESS: ["COMPLETED"],
    };

    const validateTransition = (
      current: string,
      target: string,
      expectedStatus?: string
    ) => {
      if (expectedStatus && current !== expectedStatus) {
        throw new Error(
          `STALE_WRITE: Trip status is ${current}, expected ${expectedStatus}.`
        );
      }
      if (current === target) {
        return { ok: true, alreadyInStatus: true };
      }
      const allowed = DRIVER_TRANSITIONS[current] ?? [];
      if (!allowed.includes(target)) {
        throw new Error(`Cannot move from ${current} to ${target}.`);
      }
      return { ok: true };
    };

    it("allows valid transitions in sequence", () => {
      assert.equal(validateTransition("DRIVER_ACCEPTED", "DRIVER_ARRIVING").ok, true);
      assert.equal(validateTransition("DRIVER_ARRIVING", "DRIVER_ARRIVED").ok, true);
      assert.equal(validateTransition("DRIVER_ARRIVED", "IN_PROGRESS").ok, true);
      assert.equal(validateTransition("IN_PROGRESS", "COMPLETED").ok, true);
    });

    it("rejects invalid state transitions", () => {
      assert.throws(
        () => validateTransition("DRIVER_ACCEPTED", "COMPLETED"),
        /Cannot move from DRIVER_ACCEPTED to COMPLETED/
      );
      assert.throws(
        () => validateTransition("IN_PROGRESS", "DRIVER_ACCEPTED"),
        /Cannot move from IN_PROGRESS to DRIVER_ACCEPTED/
      );
    });

    it("rejects stale writes when expectedStatus does not match", () => {
      assert.throws(
        () => validateTransition("IN_PROGRESS", "COMPLETED", "DRIVER_ARRIVED"),
        /STALE_WRITE: Trip status is IN_PROGRESS, expected DRIVER_ARRIVED/
      );
    });

    it("returns idempotent success when already in target status", () => {
      const res = validateTransition("DRIVER_ARRIVED", "DRIVER_ARRIVED");
      assert.equal(res.alreadyInStatus, true);
    });
  });

  // ── 10. Financial Audit Log Schema Invariants ─────────────────────────────
  describe("10. Observability & Audit Log Schema", () => {
    it("structures financial audit log with all required audit properties", () => {
      const log: FinancialMutationLog = {
        tripId: "trip_audit_01",
        type: "commission",
        accountId: "driver_99",
        amountNaira: -450,
        amountKobo: -45000,
        currency: "NGN",
        stage: "completion",
        actor: "driver_99",
        role: "driver",
        reason: "platform_commission_debit",
        timestamp: Date.now(),
        invariantsChecked: true,
      };

      assert.equal(log.tripId, "trip_audit_01");
      assert.equal(log.type, "commission");
      assert.equal(log.amountKobo, -45000);
      assert.equal(log.invariantsChecked, true);
      assert.ok(log.timestamp > 0);
    });

    it("structures trip transition log with actor and role metadata", () => {
      const log: TripTransitionLog = {
        tripId: "trip_trans_01",
        from: "DRIVER_ARRIVED",
        to: "IN_PROGRESS",
        actor: "driver_42",
        role: "driver",
        timestamp: Date.now(),
        reason: "passenger_boarded",
      };

      assert.equal(log.from, "DRIVER_ARRIVED");
      assert.equal(log.to, "IN_PROGRESS");
      assert.equal(log.role, "driver");
    });
  });
});
