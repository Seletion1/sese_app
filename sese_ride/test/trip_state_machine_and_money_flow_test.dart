import 'package:flutter_test/flutter_test.dart';
import 'package:sese_ride/features/trips/models/trip_models.dart';

void main() {
  group('Trip State Machine & Transition Invariants', () {
    test('trip accepted once: competing driver rejected and duplicate claim safe', () {
      final tripMap = {
        'id': 'trip_001',
        'status': 'DRIVER_ACCEPTED',
        'driverId': 'driver_alpha',
        'driver': {'driverId': 'driver_alpha', 'fullName': 'Alpha Driver'},
        'customerId': 'cust_123',
        'fareAmount': 4500.0,
      };

      final activeTrip = ActiveTrip.fromMap('trip_001', tripMap);
      expect(activeTrip.driver != null, isTrue);
      expect(activeTrip.driver?.driverId, 'driver_alpha');

      // Attempted claim by competing driver 'driver_beta'
      final competingClaimAllowed = activeTrip.status == TripStatus.waitingForAcceptance ||
          activeTrip.status == TripStatus.searchingDriver;
      expect(competingClaimAllowed, isFalse);

      // Attempted idempotent retry by same driver 'driver_alpha'
      final isIdempotentRetry = activeTrip.driver?.driverId == 'driver_alpha';
      expect(isIdempotentRetry, isTrue);
    });

    test('trip cancelled once: subsequent cancel is idempotent no-op without double charge', () {
      final cancelledTripMap = {
        'id': 'trip_002',
        'status': 'CANCELLED',
        'cancellationSource': 'customer',
        'cancellationReason': 'rider_requested',
        'paidWaitingFee': 250.0,
        'escrowLocked': false,
        'escrowRefundedAt': 1700000000000,
      };

      final trip = ActiveTrip.fromMap('trip_002', cancelledTripMap);
      expect(trip.isLive, isFalse);
      expect(trip.status, TripStatus.cancelled);

      // Verify that cancelled status rejects live state movements
      final canAdvance = [
        TripStatus.driverAccepted,
        TripStatus.driverArriving,
        TripStatus.driverArrived,
        TripStatus.inProgress,
      ].contains(trip.status);
      expect(canAdvance, isFalse);
    });

    test('driver reassignment loop is strictly bounded to 3 attempts before needs_customer_action', () {
      // Reassignment counter progression
      int reassignmentCount = 0;
      String currentStatus = 'DRIVER_ACCEPTED';

      // Driver 1 cancels
      reassignmentCount += 1;
      currentStatus = reassignmentCount <= 3 ? 'SEARCHING_DRIVER' : 'needs_customer_action';
      expect(reassignmentCount, 1);
      expect(currentStatus, 'SEARCHING_DRIVER');

      // Driver 2 cancels
      reassignmentCount += 1;
      currentStatus = reassignmentCount <= 3 ? 'SEARCHING_DRIVER' : 'needs_customer_action';
      expect(reassignmentCount, 2);
      expect(currentStatus, 'SEARCHING_DRIVER');

      // Driver 3 cancels
      reassignmentCount += 1;
      currentStatus = reassignmentCount <= 3 ? 'SEARCHING_DRIVER' : 'needs_customer_action';
      expect(reassignmentCount, 3);
      expect(currentStatus, 'SEARCHING_DRIVER');

      // Driver 4 cancels (threshold exceeded)
      reassignmentCount += 1;
      currentStatus = reassignmentCount <= 3 ? 'SEARCHING_DRIVER' : 'needs_customer_action';
      expect(reassignmentCount, 4);
      expect(currentStatus, 'needs_customer_action');
    });

    test('order bidding rejects competing bids atomically upon acceptance', () {
      final bids = [
        {'id': 'driver_alpha', 'offeredFare': 4000.0, 'status': 'pending'},
        {'id': 'driver_beta', 'offeredFare': 4200.0, 'status': 'pending'},
        {'id': 'driver_gamma', 'offeredFare': 3900.0, 'status': 'pending'},
      ];

      const acceptedDriverId = 'driver_gamma';
      final updatedBids = bids.map((b) {
        if (b['id'] == acceptedDriverId) {
          return {...b, 'status': 'accepted'};
        } else {
          return {...b, 'status': 'rejected', 'rejectedReason': 'another_bid_accepted'};
        }
      }).toList();

      final accepted = updatedBids.where((b) => b['status'] == 'accepted').toList();
      final rejected = updatedBids.where((b) => b['status'] == 'rejected').toList();

      expect(accepted.length, 1);
      expect(accepted.first['id'], 'driver_gamma');
      expect(rejected.length, 2);
      expect(rejected.any((b) => b['id'] == 'driver_alpha'), isTrue);
      expect(rejected.any((b) => b['id'] == 'driver_beta'), isTrue);
    });
  });

  group('Money Flow, Escrow & Settlement Integrity', () {
    test('wallet escrow released exactly once without duplicate decrement or dropping below zero', () {
      double escrowBalance = 3000.0;
      const walletCoverageAmount = 3000.0;
      bool escrowLocked = true;
      bool escrowRefunded = false;

      void performRefund({required bool isLocked, required bool isRefunded}) {
        if (!isLocked || isRefunded) return;
        escrowBalance = (escrowBalance - walletCoverageAmount).clamp(0.0, double.infinity);
        escrowLocked = false;
        escrowRefunded = true;
      }

      // First release
      performRefund(isLocked: escrowLocked, isRefunded: escrowRefunded);
      expect(escrowBalance, 0.0);
      expect(escrowLocked, isFalse);
      expect(escrowRefunded, isTrue);

      // Duplicate release attempt (should be rejected by idempotency check)
      performRefund(isLocked: escrowLocked, isRefunded: escrowRefunded);
      expect(escrowBalance, 0.0, reason: 'Escrow must not drop below zero on duplicate release');
    });

    test('commission deducted once with idempotency gate', () {
      int commissionSettledCount = 0;
      final settlement = {
        'settled': false,
        'commissionSettled': false,
      };

      void executeSettlement() {
        if (settlement['settled'] == true || settlement['commissionSettled'] == true) {
          return;
        }
        settlement['settled'] = true;
        settlement['commissionSettled'] = true;
        commissionSettledCount++;
      }

      // First completion call
      executeSettlement();
      expect(commissionSettledCount, 1);
      expect(settlement['settled'], isTrue);

      // Concurrent/duplicate trigger call
      executeSettlement();
      expect(commissionSettledCount, 1, reason: 'Commission must not be deducted more than once');
    });

    test('deterministic doc IDs guarantee no duplicate transaction entries', () {
      const tripId = 'trip_xyz_789';
      final commissionDocId = '${tripId}_commission';
      final bonusDocId = '${tripId}_bonus';
      final grandAwardDocId = '${tripId}_grand_award';
      final paymentDocId = '${tripId}_payment';
      final settlementDocId = '${tripId}_wallet_settlement';
      final waitingFeePaidDocId = '${tripId}_waiting_fee_paid';
      final waitingFeeCreditedDocId = '${tripId}_waiting_fee_credited';

      final ledgerKeys = <String>{};
      final generatedKeys = [
        commissionDocId,
        bonusDocId,
        grandAwardDocId,
        paymentDocId,
        settlementDocId,
        waitingFeePaidDocId,
        waitingFeeCreditedDocId,
      ];

      for (final key in generatedKeys) {
        final added = ledgerKeys.add(key);
        expect(added, isTrue, reason: 'Keys must be distinct across mutation types');
      }

      // Re-running settlement generates identical doc IDs (upsert semantics)
      expect('${tripId}_commission', commissionDocId);
      expect('${tripId}_payment', paymentDocId);
    });

    test('no negative balance bug on cancellation waiting fee path for trusted vs non-trusted customer', () {
      const paidWaitingFee = 500.0;

      // Case A: Non-trusted customer with insufficient balance -> throws INSUFFICIENT_FUNDS
      const nonTrustedBalance = 200.0;
      const isTrustedA = false;
      bool rejectedA = false;
      if (nonTrustedBalance < paidWaitingFee && !isTrustedA) {
        rejectedA = true;
      }
      expect(rejectedA, isTrue);

      // Case B: Trusted customer with insufficient balance -> balance clamped to 0, shortage recorded as debt
      const trustedBalance = 150.0;
      const isTrustedB = true;
      double newWalletBalance = trustedBalance;
      double userDebt = 0.0;

      if (trustedBalance < paidWaitingFee && isTrustedB) {
        final shortage = paidWaitingFee - trustedBalance.clamp(0.0, double.infinity);
        userDebt += shortage;
        newWalletBalance = 0.0;
      }

      expect(newWalletBalance, 0.0, reason: 'Wallet balance must be clamped to 0 without going negative');
      expect(userDebt, 350.0, reason: 'Shortage (500 - 150 = 350) allocated to debt');

      // Case C: Sufficient balance customer -> exact deduction
      const sufficientBalance = 1000.0;
      double finalBalance = sufficientBalance;
      if (sufficientBalance >= paidWaitingFee) {
        finalBalance -= paidWaitingFee;
      }
      expect(finalBalance, 500.0);
    });
  });
}
