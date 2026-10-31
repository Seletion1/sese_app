import 'package:flutter_test/flutter_test.dart';
import 'package:sese_core/sese_core.dart';

void main() {
  group('WalletCalculationEngine', () {
    test('converts Naira to Kobo accurately', () {
      expect(WalletCalculationEngine.nairaToKobo(0.0), 0);
      expect(WalletCalculationEngine.nairaToKobo(1.0), 100);
      expect(WalletCalculationEngine.nairaToKobo(1500.50), 150050);
      expect(WalletCalculationEngine.nairaToKobo(4010.25), 401025);
      expect(WalletCalculationEngine.nairaToKobo(double.nan), 0);
      expect(WalletCalculationEngine.nairaToKobo(double.infinity), 0);
    });

    test('converts Kobo to Naira accurately', () {
      expect(WalletCalculationEngine.koboToNaira(0), 0.0);
      expect(WalletCalculationEngine.koboToNaira(100), 1.0);
      expect(WalletCalculationEngine.koboToNaira(150050), 1500.50);
      expect(WalletCalculationEngine.koboToNaira(401025), 4010.25);
    });

    test('calculates trip settlement without floating-point drift', () {
      final settlement = WalletCalculationEngine.calculateTripSettlement(
        fareAmount: 4000.0,
        commissionRate: 0.15,
        walletCoverageAmount: 2000.0,
      );

      expect(settlement.commissionAmount, 600.0);
      expect(settlement.driverNetEarnings, 3400.0);
      expect(settlement.cashToCollect, 2000.0);
    });

    test('calculates trip settlement with full cash payment', () {
      final settlement = WalletCalculationEngine.calculateTripSettlement(
        fareAmount: 5200.0,
        commissionRate: 0.15,
        walletCoverageAmount: 0.0,
      );

      expect(settlement.commissionAmount, 780.0);
      expect(settlement.driverNetEarnings, 4420.0);
      expect(settlement.cashToCollect, 5200.0);
    });

    test('calculates trip settlement with full wallet coverage', () {
      final settlement = WalletCalculationEngine.calculateTripSettlement(
        fareAmount: 3000.0,
        commissionRate: 0.15,
        walletCoverageAmount: 3000.0,
      );

      expect(settlement.commissionAmount, 450.0);
      expect(settlement.driverNetEarnings, 2550.0);
      expect(settlement.cashToCollect, 0.0);
    });

    test('calculates wallet coverage correctly for partial and full balances', () {
      // Partial wallet balance
      final partial = WalletCalculationEngine.calculateWalletCoverage(
        fareAmount: 4000.0,
        walletBalance: 1500.0,
      );
      expect(partial.walletCoverage, 1500.0);
      expect(partial.remainingCash, 2500.0);

      // Excess wallet balance
      final excess = WalletCalculationEngine.calculateWalletCoverage(
        fareAmount: 4000.0,
        walletBalance: 10000.0,
      );
      expect(excess.walletCoverage, 4000.0);
      expect(excess.remainingCash, 0.0);

      // Zero or negative wallet balance
      final zero = WalletCalculationEngine.calculateWalletCoverage(
        fareAmount: 4000.0,
        walletBalance: -500.0,
      );
      expect(zero.walletCoverage, 0.0);
      expect(zero.remainingCash, 4000.0);
    });

    test('enforces driver minimum balance to go online', () {
      expect(
        WalletCalculationEngine.isEligibleToGoOnline(
          walletBalanceNaira: 1000.0,
          minBalanceNaira: 1.0,
        ),
        isTrue,
      );
      expect(
        WalletCalculationEngine.isEligibleToGoOnline(
          walletBalanceNaira: 1.0,
          minBalanceNaira: 1.0,
        ),
        isTrue,
      );
      expect(
        WalletCalculationEngine.isEligibleToGoOnline(
          walletBalanceNaira: 0.0,
          minBalanceNaira: 1.0,
        ),
        isFalse,
      );
      expect(
        WalletCalculationEngine.isEligibleToGoOnline(
          walletBalanceNaira: -250.0,
          minBalanceNaira: 1.0,
        ),
        isFalse,
      );
      expect(
        WalletCalculationEngine.isEligibleToGoOnline(
          walletBalanceNaira: double.nan,
          minBalanceNaira: 1.0,
        ),
        isFalse,
      );
    });
  });

  group('SplitFareCalculation (Split-Payment Math)', () {
    test('splits evenly when fare divides cleanly', () {
      // ₦3,000 across 2 co-payers + 1 requester (3 parties = ₦1,000 each)
      final split = SplitFareCalculation.fromNaira(
        totalFareNaira: 3000.0,
        numCoPayers: 2,
      );

      expect(split.totalParties, 3);
      expect(split.shareKobo, 100000);
      expect(split.remainderKobo, 0);
      expect(split.requesterShareNaira, 1000.0);
      expect(split.coPayerShareNaira, 1000.0);
      expect(
        split.requesterShareKobo + (split.coPayerShareKobo * 2),
        split.totalFareKobo,
      );
    });

    test('requester absorbs fractional remainder with zero data loss', () {
      // ₦1,000.00 (100,000 kobo) across 2 co-payers + 1 requester = 3 parties
      // 100,000 / 3 = 33,333 kobo each, remainder = 1 kobo
      // Requester gets 33,334 kobo (₦333.34), co-payers get 33,333 kobo (₦333.33)
      final split = SplitFareCalculation.compute(
        totalFareKobo: 100000,
        numCoPayers: 2,
      );

      expect(split.totalParties, 3);
      expect(split.shareKobo, 33333);
      expect(split.remainderKobo, 1);
      expect(split.requesterShareKobo, 33334);
      expect(split.coPayerShareKobo, 33333);
      expect(
        split.requesterShareKobo + (split.coPayerShareKobo * split.numCoPayers),
        100000,
      );
    });

    test('supports up to 5 co-payers (6 parties)', () {
      final split = SplitFareCalculation.fromNaira(
        totalFareNaira: 7000.0,
        numCoPayers: 5,
      );

      expect(split.totalParties, 6);
      expect(
        split.requesterShareKobo + (split.coPayerShareKobo * 5),
        split.totalFareKobo,
      );
    });

    test('throws ArgumentError on invalid inputs', () {
      expect(
        () => SplitFareCalculation.compute(totalFareKobo: 0, numCoPayers: 1),
        throwsArgumentError,
      );
      expect(
        () => SplitFareCalculation.compute(totalFareKobo: -100, numCoPayers: 1),
        throwsArgumentError,
      );
      expect(
        () => SplitFareCalculation.compute(totalFareKobo: 1000, numCoPayers: 0),
        throwsArgumentError,
      );
      expect(
        () => SplitFareCalculation.compute(totalFareKobo: 1000, numCoPayers: 6),
        throwsArgumentError,
      );
    });
  });

  group('DispatchTuning (Dispatch Escalation Flow)', () {
    const tuning = DispatchTuning(
      dispatchRadiusKm: 10,
      tier1RadiusKm: 3,
      tier3RadiusKm: 10,
      tier1TimeoutSec: 15,
      candidateLimit: 25,
    );

    test('resolves correct radius per dispatch tier', () {
      expect(tuning.radiusForTier(1), 3.0);
      expect(tuning.radiusForTier(3), 10.0);
    });

    test('escalates to pool when candidates are empty', () {
      expect(
        tuning.shouldEscalateToPool(candidateCount: 0, attemptedCount: 0),
        isTrue,
      );
    });

    test('escalates to pool when all candidates have been attempted', () {
      expect(
        tuning.shouldEscalateToPool(candidateCount: 3, attemptedCount: 3),
        isTrue,
      );
      expect(
        tuning.shouldEscalateToPool(candidateCount: 5, attemptedCount: 6),
        isTrue,
      );
    });

    test('escalates to pool when candidate limit is reached', () {
      expect(
        tuning.shouldEscalateToPool(candidateCount: 50, attemptedCount: 25),
        isTrue,
      );
    });

    test('escalates to pool when Stage 1 timeout expires', () {
      expect(
        tuning.shouldEscalateToPool(
          candidateCount: 10,
          attemptedCount: 1,
          isTier1Expired: true,
        ),
        isTrue,
      );
    });

    test('does NOT escalate while valid unattempted Stage 1 drivers remain', () {
      expect(
        tuning.shouldEscalateToPool(
          candidateCount: 5,
          attemptedCount: 2,
          isTier1Expired: false,
        ),
        isFalse,
      );
    });
  });
}
