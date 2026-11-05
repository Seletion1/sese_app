import 'dart:math' as math;

/// Core deterministic calculation engine for wallet balances, commissions,
/// and driver online balance thresholds.
///
/// Mirrors the exact server-side algorithms executed inside Cloud Functions
/// (`functions/src/trips.ts` and `functions/src/driverStreak.ts`).
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
