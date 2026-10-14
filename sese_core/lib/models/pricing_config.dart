import 'car_tier_thresholds.dart';
import 'vehicle_category.dart';

/// Pricing rates defined for a specific vehicle category.
class VehiclePricingRate {
  /// Base fee / minimum charge floor for any trip or delivery.
  final double baseFee;

  /// Cost per kilometer.
  final double distanceRatePerKm;

  /// Cost per minute of travel / waiting.
  final double timeRatePerMinute;

  /// Optional per-vehicle surge or difficulty multiplier (defaults to 1.0).
  final double surgeMultiplier;

  const VehiclePricingRate({
    required this.baseFee,
    required this.distanceRatePerKm,
    required this.timeRatePerMinute,
    this.surgeMultiplier = 1.0,
  });

  Map<String, dynamic> toMap() {
    return {
      'baseFee': baseFee,
      'distanceRatePerKm': distanceRatePerKm,
      'timeRatePerMinute': timeRatePerMinute,
      'surgeMultiplier': surgeMultiplier,
    };
  }

  factory VehiclePricingRate.fromMap(Map<String, dynamic>? map) {
    if (map == null) {
      return const VehiclePricingRate(
        baseFee: 500.0,
        distanceRatePerKm: 150.0,
        timeRatePerMinute: 20.0,
        surgeMultiplier: 1.0,
      );
    }
    return VehiclePricingRate(
      baseFee: (map['baseFee'] as num?)?.toDouble() ?? 500.0,
      distanceRatePerKm: (map['distanceRatePerKm'] as num?)?.toDouble() ?? 150.0,
      timeRatePerMinute: (map['timeRatePerMinute'] as num?)?.toDouble() ?? 20.0,
      surgeMultiplier: (map['surgeMultiplier'] as num?)?.toDouble() ?? 1.0,
    );
  }

  VehiclePricingRate copyWith({
    double? baseFee,
    double? distanceRatePerKm,
    double? timeRatePerMinute,
    double? surgeMultiplier,
  }) {
    return VehiclePricingRate(
      baseFee: baseFee ?? this.baseFee,
      distanceRatePerKm: distanceRatePerKm ?? this.distanceRatePerKm,
      timeRatePerMinute: timeRatePerMinute ?? this.timeRatePerMinute,
      surgeMultiplier: surgeMultiplier ?? this.surgeMultiplier,
    );
  }
}

/// Streak bonus tier trigger and payout.
class StreakTier {
  final int completedTripsTrigger; // e.g. 5 trips
  final double bonusPayout;        // e.g. ₦1,500

  const StreakTier({
    required this.completedTripsTrigger,
    required this.bonusPayout,
  });

  Map<String, dynamic> toMap() => {
    'completedTripsTrigger': completedTripsTrigger,
    'bonusPayout': bonusPayout,
  };

  factory StreakTier.fromMap(Map<String, dynamic> map) {
    return StreakTier(
      completedTripsTrigger: (map['completedTripsTrigger'] as num?)?.toInt() ?? 5,
      bonusPayout: (map['bonusPayout'] as num?)?.toDouble() ?? 1000.0,
    );
  }
}

/// Dynamic streak and reward configuration per region.
class StreakRewardConfig {
  static const double defaultGrandAward = 15000.0;
  static const int defaultGrandTargetTrips = 30;

  final bool enabled;

  /// Completion cycle: 'daily', 'weekly', or 'monthly'.
  final String cycle;

  final List<StreakTier> tiers;
  final double grandCompletionCashAward; // e.g. ₦10,000 for completing full cycle
  final int grandCompletionTargetTrips;  // e.g. 30 trips

  const StreakRewardConfig({
    this.enabled = true,
    this.cycle = 'daily',
    this.tiers = const [
      StreakTier(completedTripsTrigger: 5, bonusPayout: 1000.0),
      StreakTier(completedTripsTrigger: 10, bonusPayout: 2500.0),
      StreakTier(completedTripsTrigger: 20, bonusPayout: 6000.0),
    ],
    this.grandCompletionCashAward = defaultGrandAward,
    this.grandCompletionTargetTrips = defaultGrandTargetTrips,
  });

  Map<String, dynamic> toMap() {
    return {
      'enabled': enabled,
      'cycle': cycle,
      'tiers': tiers.map((e) => e.toMap()).toList(),
      'grandCompletionCashAward': grandCompletionCashAward,
      'grandCompletionTargetTrips': grandCompletionTargetTrips,
    };
  }

  factory StreakRewardConfig.fromMap(Map<String, dynamic>? map) {
    if (map == null) return const StreakRewardConfig();
    final tiersList = (map['tiers'] as List<dynamic>?)
            ?.map((e) => StreakTier.fromMap(Map<String, dynamic>.from(e)))
            .toList() ??
        const [
          StreakTier(completedTripsTrigger: 5, bonusPayout: 1000.0),
          StreakTier(completedTripsTrigger: 10, bonusPayout: 2500.0),
          StreakTier(completedTripsTrigger: 20, bonusPayout: 6000.0),
        ];

    return StreakRewardConfig(
      enabled: (map['enabled'] as bool?) ?? true,
      cycle: (map['cycle'] as String?) ?? 'daily',
      tiers: tiersList,
      grandCompletionCashAward:
          (map['grandCompletionCashAward'] as num?)?.toDouble() ?? 15000.0,
      grandCompletionTargetTrips:
          (map['grandCompletionTargetTrips'] as num?)?.toInt() ?? 30,
    );
  }

  StreakRewardConfig copyWith({
    bool? enabled,
    String? cycle,
    List<StreakTier>? tiers,
    double? grandCompletionCashAward,
    int? grandCompletionTargetTrips,
  }) {
    return StreakRewardConfig(
      enabled: enabled ?? this.enabled,
      cycle: cycle ?? this.cycle,
      tiers: tiers ?? this.tiers,
      grandCompletionCashAward:
          grandCompletionCashAward ?? this.grandCompletionCashAward,
      grandCompletionTargetTrips:
          grandCompletionTargetTrips ?? this.grandCompletionTargetTrips,
    );
  }
}

/// Configuration for the Dynamic Driver Daily Commission Tiering system.
///
/// Stored under `system_configs/{docId}.dailyStreakConfig` in Firestore.
/// When [streakEnabled] is false for the driver's region the driver simply
/// pays the flat [baseCommissionRate] commission — no streak mechanics apply.
class DailyStreakConfig {
  /// Whether the streak system is active. Default: true (active globally).
  final bool streakEnabled;

  /// Flat commission rate applied when streak is inactive or broken (0–1).
  /// Default: 0.20 (20%).
  final double baseCommissionRate;

  /// Minimum minutes the driver must wait after tapping "Arrived" before a
  /// customer no-show cancel is streak-protected. Default: 10 minutes.
  final int noShowWaitMinutes;

  /// Cash amount credited to the driver wallet upon completing the full
  /// Level 3 grand award (all 3 levels complete). Default: ₦10,000.
  final double completionCashAward;

  /// Whether proximity auto-arrival at pickup or drop-off is enabled.
  /// Default: true.
  final bool autoArrivalEnabled;

  /// Duration in seconds for the auto-arrival countdown. Default: 5 seconds.
  final int autoArrivalCountdownSeconds;

  /// Country codes (e.g. ["KE"]) where the streak is explicitly disabled.
  /// Country-level disables cascade to all states within that country.
  final List<String> disabledCountries;

  /// State keys (format "COUNTRYCODE_STATENAME", e.g. "NG_LAGOS") where
  /// the streak is explicitly disabled at the state level.
  final List<String> disabledStates;

  const DailyStreakConfig({
    this.streakEnabled = true,
    this.baseCommissionRate = 0.20,
    this.noShowWaitMinutes = 10,
    this.completionCashAward = 10000.0,
    this.autoArrivalEnabled = true,
    this.autoArrivalCountdownSeconds = 5,
    this.disabledCountries = const [],
    this.disabledStates = const [],
  });

  /// Returns true when the streak engine should be active for a driver
  /// located in [countryCode] / [stateOrRegion].
  bool isEnabledForRegion({
    required String countryCode,
    required String stateOrRegion,
  }) {
    if (!streakEnabled) return false;
    if (disabledCountries.contains(countryCode.toUpperCase())) return false;
    final stateKey =
        '${countryCode.toUpperCase()}_${stateOrRegion.toUpperCase().replaceAll(' ', '_')}';
    if (disabledStates.contains(stateKey)) return false;
    return true;
  }

  Map<String, dynamic> toMap() => {
        'streakEnabled': streakEnabled,
        'baseCommissionRate': baseCommissionRate,
        'noShowWaitMinutes': noShowWaitMinutes,
        'completionCashAward': completionCashAward,
        'autoArrivalEnabled': autoArrivalEnabled,
        'autoArrivalCountdownSeconds': autoArrivalCountdownSeconds,
        'disabledCountries': disabledCountries,
        'disabledStates': disabledStates,
      };

  factory DailyStreakConfig.fromMap(Map<String, dynamic>? map) {
    if (map == null) return const DailyStreakConfig();
    return DailyStreakConfig(
      streakEnabled: (map['streakEnabled'] as bool?) ?? true,
      baseCommissionRate:
          (map['baseCommissionRate'] as num?)?.toDouble() ?? 0.20,
      noShowWaitMinutes: (map['noShowWaitMinutes'] as num?)?.toInt() ?? 10,
      completionCashAward:
          (map['completionCashAward'] as num?)?.toDouble() ?? 10000.0,
      autoArrivalEnabled: (map['autoArrivalEnabled'] as bool?) ?? true,
      autoArrivalCountdownSeconds:
          (map['autoArrivalCountdownSeconds'] as num?)?.toInt() ?? 5,
      disabledCountries: (map['disabledCountries'] as List<dynamic>?)
              ?.map((e) => e.toString())
              .toList() ??
          const [],
      disabledStates: (map['disabledStates'] as List<dynamic>?)
              ?.map((e) => e.toString())
              .toList() ??
          const [],
    );
  }

  DailyStreakConfig copyWith({
    bool? streakEnabled,
    double? baseCommissionRate,
    int? noShowWaitMinutes,
    double? completionCashAward,
    bool? autoArrivalEnabled,
    int? autoArrivalCountdownSeconds,
    List<String>? disabledCountries,
    List<String>? disabledStates,
  }) {
    return DailyStreakConfig(
      streakEnabled: streakEnabled ?? this.streakEnabled,
      baseCommissionRate: baseCommissionRate ?? this.baseCommissionRate,
      noShowWaitMinutes: noShowWaitMinutes ?? this.noShowWaitMinutes,
      completionCashAward: completionCashAward ?? this.completionCashAward,
      autoArrivalEnabled: autoArrivalEnabled ?? this.autoArrivalEnabled,
      autoArrivalCountdownSeconds:
          autoArrivalCountdownSeconds ?? this.autoArrivalCountdownSeconds,
      disabledCountries: disabledCountries ?? this.disabledCountries,
      disabledStates: disabledStates ?? this.disabledStates,
    );
  }
}

/// Regionally scoped configuration doc representing:
/// 1. Global Default: `global_default`
/// 2. Country-Specific Rule: e.g. `country_NG`, `country_US`
/// 3. State-Specific Override: e.g. `state_NG_LAGOS`, `state_US_CA`
class RegionConfig {
  /// Unique document ID in Firestore: e.g. 'global_default', 'country_NG', 'state_NG_LAGOS'
  final String id;

  /// Country code (e.g. 'GLOBAL', 'NG', 'US', 'KE')
  final String countryCode;

  /// State or region name (empty for global/country level)
  final String stateOrRegion;

  /// Local currency ISO code: 'NGN', 'USD', 'KES', etc.
  final String currencyCode;

  /// Local currency symbol: '₦', '$', 'KSh', etc.
  final String currencySymbol;

  /// Regional surge multiplier applied across all vehicles in this region
  final double regionalSurgeMultiplier;

  /// Pricing rates mapped by VehicleCategory
  final Map<VehicleCategory, VehiclePricingRate> pricingRates;

  /// Dynamic car tier thresholds and multipliers
  final CarTierThresholds carTierThresholds;

  /// Dynamic streak & reward configuration for drivers.
  final StreakRewardConfig streakRewards;

  /// Dynamic streak & reward configuration for customers.
  final StreakRewardConfig customerStreakRewards;

  /// New 3-level daily commission tiering configuration.
  /// Active by default for all regions; admins may disable per country/state.
  final DailyStreakConfig dailyStreakConfig;

  final DateTime updatedAt;

  const RegionConfig({
    required this.id,
    required this.countryCode,
    this.stateOrRegion = '',
    required this.currencyCode,
    required this.currencySymbol,
    this.regionalSurgeMultiplier = 1.0,
    required this.pricingRates,
    this.carTierThresholds = const CarTierThresholds(),
    this.streakRewards = const StreakRewardConfig(),
    this.customerStreakRewards = const StreakRewardConfig(cycle: 'weekly'),
    this.dailyStreakConfig = const DailyStreakConfig(),
    required this.updatedAt,
  });

  bool get isGlobalDefault => id == 'global_default';
  bool get isCountryRule => stateOrRegion.isEmpty && !isGlobalDefault;
  bool get isStateOverride => stateOrRegion.isNotEmpty;

  /// Formats an amount with currency symbol.
  String formatCurrency(num amount) {
    return '$currencySymbol${amount.toStringAsFixed(2)}';
  }

  Map<String, dynamic> toMap() {
    final pricingMap = <String, dynamic>{};
    for (final entry in pricingRates.entries) {
      pricingMap[entry.key.name] = entry.value.toMap();
    }

    return {
      'id': id,
      'countryCode': countryCode,
      'stateOrRegion': stateOrRegion,
      'currencyCode': currencyCode,
      'currencySymbol': currencySymbol,
      'regionalSurgeMultiplier': regionalSurgeMultiplier,
      'pricingRates': pricingMap,
      'carTierThresholds': carTierThresholds.toMap(),
      'streakRewards': streakRewards.toMap(),
      'customerStreakRewards': customerStreakRewards.toMap(),
      'dailyStreakConfig': dailyStreakConfig.toMap(),
      'updatedAt': updatedAt.toIso8601String(),
    };
  }

  factory RegionConfig.fromMap(Map<String, dynamic> map) {
    final pricingMap = <VehicleCategory, VehiclePricingRate>{};
    final rawPricing = map['pricingRates'] as Map<String, dynamic>?;

    for (final cat in VehicleCategory.values) {
      if (rawPricing != null && rawPricing.containsKey(cat.name)) {
        pricingMap[cat] = VehiclePricingRate.fromMap(
          Map<String, dynamic>.from(rawPricing[cat.name] as Map),
        );
      } else {
        // Fallback default for missing categories
        pricingMap[cat] = _defaultRateForCategory(
          cat,
          map['currencyCode'] ?? 'NGN',
        );
      }
    }

    return RegionConfig(
      id: map['id'] ?? 'global_default',
      countryCode: map['countryCode'] ?? 'GLOBAL',
      stateOrRegion: map['stateOrRegion'] ?? '',
      currencyCode: map['currencyCode'] ?? 'NGN',
      currencySymbol: map['currencySymbol'] ?? '₦',
      regionalSurgeMultiplier:
          (map['regionalSurgeMultiplier'] as num?)?.toDouble() ?? 1.0,
      pricingRates: pricingMap,
      carTierThresholds: CarTierThresholds.fromMap(
        map['carTierThresholds'] as Map<String, dynamic>?,
      ),
      streakRewards: StreakRewardConfig.fromMap(
        map['streakRewards'] as Map<String, dynamic>?,
      ),
      customerStreakRewards: StreakRewardConfig.fromMap(
        (map['customerStreakRewards'] ?? map['customerRewards'])
            as Map<String, dynamic>?,
      ),
      dailyStreakConfig: DailyStreakConfig.fromMap(
        map['dailyStreakConfig'] as Map<String, dynamic>?,
      ),
      updatedAt: _parseDateTime(map['updatedAt']),
    );
  }

  static DateTime _parseDateTime(dynamic value) {
    if (value == null) return DateTime.now();
    if (value is DateTime) return value;
    if (value is int) return DateTime.fromMillisecondsSinceEpoch(value);
    if (value is String) return DateTime.tryParse(value) ?? DateTime.now();
    try {
      final dynamic dyn = value;
      return dyn.toDate() as DateTime;
    } catch (_) {}
    return DateTime.now();
  }

  /// Default baseline configuration.
  factory RegionConfig.globalDefault() {
    final rates = <VehicleCategory, VehiclePricingRate>{
      VehicleCategory.bicycle: const VehiclePricingRate(
        baseFee: 300.0,
        distanceRatePerKm: 80.0,
        timeRatePerMinute: 10.0,
      ),
      VehicleCategory.motorcycle: const VehiclePricingRate(
        baseFee: 400.0,
        distanceRatePerKm: 120.0,
        timeRatePerMinute: 15.0,
      ),
      VehicleCategory.tricycle: const VehiclePricingRate(
        baseFee: 450.0,
        distanceRatePerKm: 130.0,
        timeRatePerMinute: 18.0,
      ),
      VehicleCategory.car: const VehiclePricingRate(
        baseFee: 600.0,
        distanceRatePerKm: 180.0,
        timeRatePerMinute: 25.0,
      ),
      VehicleCategory.van: const VehiclePricingRate(
        baseFee: 1200.0,
        distanceRatePerKm: 300.0,
        timeRatePerMinute: 40.0,
      ),
      VehicleCategory.truck: const VehiclePricingRate(
        baseFee: 2500.0,
        distanceRatePerKm: 500.0,
        timeRatePerMinute: 60.0,
      ),
    };

    return RegionConfig(
      id: 'global_default',
      countryCode: 'GLOBAL',
      stateOrRegion: '',
      currencyCode: 'NGN',
      currencySymbol: '₦',
      regionalSurgeMultiplier: 1.0,
      pricingRates: rates,
      carTierThresholds: const CarTierThresholds(),
      streakRewards: const StreakRewardConfig(),
      customerStreakRewards: const StreakRewardConfig(cycle: 'weekly'),
      updatedAt: DateTime.now(),
    );
  }

  static VehiclePricingRate _defaultRateForCategory(
    VehicleCategory cat,
    String currency,
  ) {
    // Basic scaling if USD is used
    final isUsd = currency.toUpperCase() == 'USD';
    final scale = isUsd ? 0.001 : 1.0;

    switch (cat) {
      case VehicleCategory.bicycle:
        return VehiclePricingRate(
          baseFee: 300.0 * scale,
          distanceRatePerKm: 80.0 * scale,
          timeRatePerMinute: 10.0 * scale,
        );
      case VehicleCategory.motorcycle:
        return VehiclePricingRate(
          baseFee: 400.0 * scale,
          distanceRatePerKm: 120.0 * scale,
          timeRatePerMinute: 15.0 * scale,
        );
      case VehicleCategory.tricycle:
        return VehiclePricingRate(
          baseFee: 450.0 * scale,
          distanceRatePerKm: 130.0 * scale,
          timeRatePerMinute: 18.0 * scale,
        );
      case VehicleCategory.car:
        return VehiclePricingRate(
          baseFee: 600.0 * scale,
          distanceRatePerKm: 180.0 * scale,
          timeRatePerMinute: 25.0 * scale,
        );
      case VehicleCategory.van:
        return VehiclePricingRate(
          baseFee: 1200.0 * scale,
          distanceRatePerKm: 300.0 * scale,
          timeRatePerMinute: 40.0 * scale,
        );
      case VehicleCategory.truck:
        return VehiclePricingRate(
          baseFee: 2500.0 * scale,
          distanceRatePerKm: 500.0 * scale,
          timeRatePerMinute: 60.0 * scale,
        );
    }
  }

  RegionConfig copyWith({
    String? id,
    String? countryCode,
    String? stateOrRegion,
    String? currencyCode,
    String? currencySymbol,
    double? regionalSurgeMultiplier,
    Map<VehicleCategory, VehiclePricingRate>? pricingRates,
    CarTierThresholds? carTierThresholds,
    StreakRewardConfig? streakRewards,
    StreakRewardConfig? customerStreakRewards,
    DailyStreakConfig? dailyStreakConfig,
    DateTime? updatedAt,
  }) {
    return RegionConfig(
      id: id ?? this.id,
      countryCode: countryCode ?? this.countryCode,
      stateOrRegion: stateOrRegion ?? this.stateOrRegion,
      currencyCode: currencyCode ?? this.currencyCode,
      currencySymbol: currencySymbol ?? this.currencySymbol,
      regionalSurgeMultiplier:
          regionalSurgeMultiplier ?? this.regionalSurgeMultiplier,
      pricingRates: pricingRates ?? this.pricingRates,
      carTierThresholds: carTierThresholds ?? this.carTierThresholds,
      streakRewards: streakRewards ?? this.streakRewards,
      customerStreakRewards:
          customerStreakRewards ?? this.customerStreakRewards,
      dailyStreakConfig: dailyStreakConfig ?? this.dailyStreakConfig,
      updatedAt: updatedAt ?? this.updatedAt,
    );
  }
}
