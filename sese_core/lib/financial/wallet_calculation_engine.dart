import 'dart:math' as math;

/// Core deterministic calculation engine for wallet balances, commissions,
/// split payments, and driver online balance thresholds.
///
/// Mirrors the exact server-side algorithms executed inside Cloud Functions
/// (`functions/src/trips.ts`, `functions/src/driverStreak.ts`, and `functions/src/peerPayments.ts`).
abstract final class WalletCalculationEngine {
  /// Converts Naira (standard currency unit) to Kobo (sub-unit integer), rounding cleanly.
  static int nairaToKobo(double naira) {
    if (naira.isNaN || naira.isInfinite) return 0;
    return (naira * 100).round();
  }

  /// Converts Kobo (sub-unit integer) to Naira.
  static double koboToNaira(int kobo) {
    return kobo / 100.0;
  }

  /// Calculates platform commission and driver net earnings.
  static ({
    double commissionAmount,
    double driverNetEarnings,
    double cashToCollect,
  }) calculateTripSettlement({
    required double fareAmount,
    required double commissionRate,
    double walletCoverageAmount = 0.0,
  }) {
    final cleanFare = math.max(0.0, fareAmount);
    final cleanRate = commissionRate.clamp(0.0, 1.0);
    final commission = (cleanFare * cleanRate).roundToDouble();
    final netEarnings = math.max(0.0, cleanFare - commission);
    final cash = math.max(0.0, cleanFare - walletCoverageAmount);
    return (
      commissionAmount: commission,
      driverNetEarnings: netEarnings,
      cashToCollect: cash,
    );
  }

  /// Calculates user wallet coverage and residual cash to collect for a booking.
  static ({double walletCoverage, double remainingCash}) calculateWalletCoverage({
    required double fareAmount,
    required double walletBalance,
  }) {
    final cleanFare = math.max(0.0, fareAmount);
    final cleanBal = math.max(0.0, walletBalance);
    final coverage = math.min(cleanFare, cleanBal);
    final remaining = math.max(0.0, cleanFare - coverage);
    return (
      walletCoverage: coverage,
      remainingCash: remaining,
    );
  }

  /// Checks if a driver meets the minimum balance threshold to go online and accept trips.
  static bool isEligibleToGoOnline({
    required double walletBalanceNaira,
    double minBalanceNaira = 1.0,
  }) {
    if (walletBalanceNaira.isNaN || walletBalanceNaira.isInfinite) return false;
    return walletBalanceNaira >= minBalanceNaira;
  }
}

/// Pure, deterministic calculation of split fare distribution across co-payers.
///
/// Matches the exact server-side algorithm in Cloud Functions (`peerPayments.ts`).
/// The trip requester absorbs any fractional kobo remainder so that the sum of
/// all split parts equals the total fare with zero data loss.
class SplitFareCalculation {
  final int totalFareKobo;
  final int numCoPayers;
  final int totalParties;
  final int shareKobo;
  final int remainderKobo;
  final int requesterShareKobo;
  final int coPayerShareKobo;

  const SplitFareCalculation._({
    required this.totalFareKobo,
    required this.numCoPayers,
    required this.totalParties,
    required this.shareKobo,
    required this.remainderKobo,
    required this.requesterShareKobo,
    required this.coPayerShareKobo,
  });

  /// Computes integer split shares across [numCoPayers] plus the requester.
  factory SplitFareCalculation.compute({
    required int totalFareKobo,
    required int numCoPayers,
  }) {
    if (totalFareKobo <= 0) {
      throw ArgumentError.value(totalFareKobo, 'totalFareKobo', 'Must be positive');
    }
    if (numCoPayers < 1 || numCoPayers > 5) {
      throw ArgumentError.value(numCoPayers, 'numCoPayers', 'Must be between 1 and 5 co-payers');
    }
    final parties = numCoPayers + 1;
    final share = totalFareKobo ~/ parties;
    final remainder = totalFareKobo - (share * parties);
    final requesterShare = share + remainder;
    final coPayerShare = share;

    assert(
      requesterShare + (coPayerShare * numCoPayers) == totalFareKobo,
      'Split parts must sum exactly to total fare',
    );

    return SplitFareCalculation._(
      totalFareKobo: totalFareKobo,
      numCoPayers: numCoPayers,
      totalParties: parties,
      shareKobo: share,
      remainderKobo: remainder,
      requesterShareKobo: requesterShare,
      coPayerShareKobo: coPayerShare,
    );
  }

  /// Convenience constructor taking total fare in Naira.
  factory SplitFareCalculation.fromNaira({
    required double totalFareNaira,
    required int numCoPayers,
  }) {
    final kobo = WalletCalculationEngine.nairaToKobo(totalFareNaira);
    return SplitFareCalculation.compute(
      totalFareKobo: kobo,
      numCoPayers: numCoPayers,
    );
  }

  double get requesterShareNaira => requesterShareKobo / 100.0;
  double get coPayerShareNaira => coPayerShareKobo / 100.0;
}
