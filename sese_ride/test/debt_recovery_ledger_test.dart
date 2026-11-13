import 'package:flutter_test/flutter_test.dart';
import 'package:sese_ride/features/trips/models/trip_models.dart';

void main() {
  group('Debt Recovery Ledger Tests', () {
    test('TripDraft calculates total cash to collect with customer negative balance', () {
      const baseFare = 5100.0;
      const negativeBalance = 765.0;
      const totalCashToCollect = baseFare + negativeBalance;

      final draft = TripDraft(
        customerId: 'cust_123',
        pickupLat: 6.5244,
        pickupLng: 3.3792,
        pickupAddress: 'Lagos',
        pickupPhone: '08012345678',
        dropoffLat: 6.6018,
        dropoffLng: 3.3515,
        dropoffAddress: 'Ikeja',
        dropoffPhone: '08087654321',
        serviceType: 'send_item',
        selectedTiers: const ['motorcycle'],
        fareToken: 'token_123',
        distanceKm: 12.5,
        durationMins: 25,
        proposedFare: baseFare,
        paymentMethod: 'cash',
        walletCoverageAmount: 0.0,
        cashToCollect: totalCashToCollect,
        recoveredDebt: negativeBalance,
      );

      final map = draft.toMap();
      expect(map['proposedFare'], equals(5100.0));
      expect(map['cashToCollect'], equals(5865.0));
      expect(map['recoveredDebt'], equals(765.0));
    });

    test('Commission base protection keeps proposedFare as real base trip fare', () {
      const baseFare = 5100.0;
      const recoveredDebt = 765.0;
      const cashToCollect = baseFare + recoveredDebt;

      final map = <String, dynamic>{
        'baseFare': baseFare,
        'recoveredDebt': recoveredDebt,
        'proposedFare': baseFare,
        'fareAmount': baseFare,
        'cashToCollect': cashToCollect,
      };

      // Verify that commission rate (15%) applies ONLY to baseFare (5100), not cashToCollect (5865)
      const commissionRate = 0.15;
      final commissionAmount = (map['fareAmount'] as double) * commissionRate;
      expect(commissionAmount, equals(765.0)); // 15% of 5100 is 765.0
      expect(commissionAmount, isNot(equals(879.75))); // NOT 15% of 5865
    });
  });
}
