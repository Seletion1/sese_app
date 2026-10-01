/// Per-driver daily streak state document: `driver_streaks/{driverId}`.
///
/// The backend (Cloud Functions) is the only writer. Clients and the
/// admin SDK read this to render the streak banner and compute commission.
library;

/// Which of the three streak levels the driver is currently in.
///
/// - [level1]: Step-down commission discount (Steps 0–6, 15% → 0%).
/// - [level2]: 0% fee + Level 1 commission cashback (Steps 0–5).
/// - [level3]: 0% fee + cash bonus % of current trip (Steps 0–6).
enum StreakLevel {
  level1,
  level2,
  level3;

  int get number => index + 1;
}

/// Immutable snapshot of a driver's daily commission streak state.
///
/// Resets every night at 00:00 local driver time back to
/// [StreakLevel.level1] step 0.
class DriverStreakState {
  /// The driver UID this document belongs to.
  final String driverId;

  /// Whether the streak engine is active for this driver's region.
  ///
  /// Set to `false` when the admin disables the streak for the driver's
  /// country or state — the driver pays the flat [baseCommissionRate] instead.
  final bool streakActive;

  /// Current level (1, 2, or 3).
  final StreakLevel currentLevel;

  /// Current step within [currentLevel] (0-based).
  ///
  /// - Level 1: 0–6 (step 6 = 0% fee, triggers Level 2 entry)
  /// - Level 2: 0–5 (step 5 = last cashback, triggers Level 3 entry)
  /// - Level 3: 0–6 (step 6 = grand award trigger)
  final int currentStep;

  /// Exact monetary amounts paid as commission in each Level 1 step.
  ///
  /// Index 0 = step 0 amount (15% fee), index 5 = step 5 amount (2.5% fee).
  /// Used by Level 2 to refund in reverse order.
  final List<double> level1PaidHistory;

  /// True once the driver completes Level 3 Step 6 (grand award received).
  /// No more streak progression happens today; resets tomorrow.
  final bool dailyStreakCompleted;

  /// Local calendar date string (YYYY-MM-DD) when this streak was last reset.
  /// The midnight cron compares this to the driver's current local date.
  final String resetDateLocal;

  /// The flat commission rate when the streak is inactive or broken off-streak.
  /// Mirrors the admin-configured [DailyStreakConfig.baseCommissionRate].
  final double baseCommissionRate;

  const DriverStreakState({
    required this.driverId,
    this.streakActive = true,
    this.currentLevel = StreakLevel.level1,
    this.currentStep = 0,
    this.level1PaidHistory = const [],
    this.dailyStreakCompleted = false,
    this.resetDateLocal = '',
    this.baseCommissionRate = 0.20,
  });

  // ── Wire format ──────────────────────────────────────────────────────────

  factory DriverStreakState.fromMap(String driverId, Map<String, dynamic> map) {
    final levelInt = (map['currentLevel'] as num?)?.toInt() ?? 1;
    final level = switch (levelInt) {
      2 => StreakLevel.level2,
      3 => StreakLevel.level3,
      _ => StreakLevel.level1,
    };

    // Canonical key is `level1PaidHistory`; the spec alias
    // `level1PaidCommissionHistory` is accepted on read.
    final rawHistory = map['level1PaidHistory'] is List
        ? map['level1PaidHistory']
        : map['level1PaidCommissionHistory'];
    final history = (rawHistory is List)
        ? rawHistory
            .map((e) => (e as num?)?.toDouble() ?? 0.0)
            .toList()
        : <double>[];

    return DriverStreakState(
      driverId: driverId,
      streakActive: (map['streakActive'] as bool?) ?? true,
      currentLevel: level,
      currentStep: (map['currentStep'] as num?)?.toInt() ?? 0,
      level1PaidHistory: history,
      dailyStreakCompleted: (map['dailyStreakCompleted'] as bool?) ?? false,
      resetDateLocal: (map['resetDateLocal'] as String?) ?? '',
      baseCommissionRate:
          (map['baseCommissionRate'] as num?)?.toDouble() ?? 0.20,
    );
  }

  Map<String, dynamic> toMap() => {
        'driverId': driverId,
        'streakActive': streakActive,
        'currentLevel': currentLevel.number,
        'currentStep': currentStep,
        'level1PaidHistory': level1PaidHistory,
        // Spec alias — kept in sync so backend and clients agree.
        'level1PaidCommissionHistory': level1PaidHistory,
        'dailyStreakCompleted': dailyStreakCompleted,
        'resetDateLocal': resetDateLocal,
        'baseCommissionRate': baseCommissionRate,
      };

  // ── Helpers ───────────────────────────────────────────────────────────────

  /// Human-readable label shown on the dispatch overlay card.
  ///
  /// Examples:
  /// - "Streak Rate: 12.5% Fee"
  /// - "Level 2 Perk: 0% Fee + ₦450 Refund"
  /// - "Level 3 Bonus: 0% Fee + 5.0% Cash Bonus"
  String streakLabel({double fareAmount = 0, String symbol = '₦'}) {
    if (!streakActive || dailyStreakCompleted) {
      final pct = (baseCommissionRate * 100).toStringAsFixed(0);
      return 'Standard Rate: $pct% Fee';
    }
    switch (currentLevel) {
      case StreakLevel.level1:
        final rate = _level1Rate(currentStep);
        if (rate == 0) return '0% Fee — Level 2 Unlocked Next!';
        return 'Streak Rate: ${(rate * 100).toStringAsFixed(1)}% Fee';
      case StreakLevel.level2:
        final refund = _level2Refund;
        final refundStr =
            refund > 0 ? '$symbol${refund.toStringAsFixed(0)} Refund' : 'Refund Pending';
        return 'Level 2 Perk: 0% Fee + $refundStr';
      case StreakLevel.level3:
        final bonus = _level3BonusRate(currentStep);
        return 'Level 3 Bonus: 0% Fee + ${(bonus * 100).toStringAsFixed(1)}% Cash Bonus';
    }
  }

  /// Commission rate for Level 1 step [s] (0-indexed).
  ///
  /// Step 0 = first order of the day = 15%; Step 6 = 0%.
  static double _level1Rate(int step) {
    const rates = [0.15, 0.125, 0.10, 0.075, 0.05, 0.025, 0.0];
    if (step < 0 || step >= rates.length) return 0.0;
    return rates[step];
  }

  /// Amount to be refunded at the current Level 2 step.
  double get _level2Refund {
    // Refunds L1 history in reverse: step0 refunds history[5], step1 refunds history[4]...
    final refundIndex = 5 - currentStep;
    if (refundIndex < 0 || refundIndex >= level1PaidHistory.length) return 0.0;
    return level1PaidHistory[refundIndex];
  }

  /// Cash bonus % for Level 3 step [s] (0-indexed).
  static double _level3BonusRate(int step) {
    const rates = [0.025, 0.05, 0.075, 0.10, 0.125, 0.15, 0.20];
    if (step < 0 || step >= rates.length) return 0.0;
    return rates[step];
  }

  // ── State info getters ────────────────────────────────────────────────────

  /// Total steps in the current level (for progress indicators).
  int get totalStepsInLevel {
    return switch (currentLevel) {
      StreakLevel.level1 => 7, // steps 0-6
      StreakLevel.level2 => 6, // steps 0-5
      StreakLevel.level3 => 7, // steps 0-6
    };
  }

  /// How many steps remain until the next level transition.
  int get stepsToNextMilestone => totalStepsInLevel - currentStep - 1;

  /// True if the driver is at the very beginning (off-streak / just reset).
  bool get isAtStart =>
      currentLevel == StreakLevel.level1 && currentStep == 0 && !streakActive;

  DriverStreakState copyWith({
    bool? streakActive,
    StreakLevel? currentLevel,
    int? currentStep,
    List<double>? level1PaidHistory,
    bool? dailyStreakCompleted,
    String? resetDateLocal,
    double? baseCommissionRate,
  }) {
    return DriverStreakState(
      driverId: driverId,
      streakActive: streakActive ?? this.streakActive,
      currentLevel: currentLevel ?? this.currentLevel,
      currentStep: currentStep ?? this.currentStep,
      level1PaidHistory: level1PaidHistory ?? this.level1PaidHistory,
      dailyStreakCompleted: dailyStreakCompleted ?? this.dailyStreakCompleted,
      resetDateLocal: resetDateLocal ?? this.resetDateLocal,
      baseCommissionRate: baseCommissionRate ?? this.baseCommissionRate,
    );
  }

  @override
  String toString() =>
      'DriverStreakState(L${currentLevel.number}S$currentStep, '
      'active=$streakActive, completed=$dailyStreakCompleted)';
}
