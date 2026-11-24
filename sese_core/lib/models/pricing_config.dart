import 'car_tier_thresholds.dart';
import 'vehicle_category.dart';
import 'package:sese_core/utils/safe_json.dart';

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
      baseFee: safeNum(map['baseFee'])?.toDouble() ?? 500.0,
      distanceRatePerKm: safeNum(map['distanceRatePerKm'])?.toDouble() ?? 150.0,
      timeRatePerMinute: safeNum(map['timeRatePerMinute'])?.toDouble() ?? 20.0,
      surgeMultiplier: safeNum(map['surgeMultiplier'])?.toDouble() ?? 1.0,
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

/// Configuration for dispatch, waiting time, and commission policies.
///
/// Stored under `system_configs/{docId}.dailyStreakConfig` in Firestore.
class DailyStreakConfig {
  /// Flat commission rate applied (0–1).
  /// Default: 0.20 (20%).
  final double baseCommissionRate;

  /// Minimum minutes the driver must wait after tapping "Arrived" before a
  /// customer no-show cancel is protected. Default: 10 minutes.
  final int noShowWaitMinutes;

  /// Whether proximity auto-arrival at pickup or drop-off is enabled.
  /// Default: true.
  final bool autoArrivalEnabled;

  /// Duration in seconds for the auto-arrival countdown. Default: 5 seconds.
  final int autoArrivalCountdownSeconds;

  /// Global switch to enable or disable paid waiting time charges system-wide.
  final bool enableWaitingTimeBilling;

  /// Grace/free waiting minutes at customer pickup before paid waiting billing starts.
  final int freeWaitingMinutes;

  /// Waiting fee charged per minute after the grace period expires (in Naira).
  final double waitingRatePerMinute;

  /// When true, customers and drivers cannot cancel a trip once it has
  /// transitioned to [TripStatus.inProgress] or [TripStatus.pendingCustomerApproval].
  ///
  /// Enforced server-side in `cancelTrip` (functions/src/trips.ts). This flag
  /// is the client-side mirror used to show/hide the "Cancel ride" button on
  /// [LiveTripScreen] so the UI matches backend policy without an extra round-trip.
  final bool enableCancellationLock;

  const DailyStreakConfig({
    this.baseCommissionRate = 0.20,
    this.noShowWaitMinutes = 10,
    this.autoArrivalEnabled = true,
    this.autoArrivalCountdownSeconds = 5,
    this.enableWaitingTimeBilling = true,
    this.freeWaitingMinutes = 10,
    this.waitingRatePerMinute = 20.0,
    this.enableCancellationLock = true,
  });

  Map<String, dynamic> toMap() => {
        'baseCommissionRate': baseCommissionRate,
        'noShowWaitMinutes': noShowWaitMinutes,
        'autoArrivalEnabled': autoArrivalEnabled,
        'autoArrivalCountdownSeconds': autoArrivalCountdownSeconds,
        'enableWaitingTimeBilling': enableWaitingTimeBilling,
        'freeWaitingMinutes': freeWaitingMinutes,
        'waitingRatePerMinute': waitingRatePerMinute,
        'enableCancellationLock': enableCancellationLock,
      };

  factory DailyStreakConfig.fromMap(Map<String, dynamic>? map) {
    if (map == null) return const DailyStreakConfig();
    return DailyStreakConfig(
      baseCommissionRate:
          safeNum(map['baseCommissionRate'])?.toDouble() ?? 0.20,
      noShowWaitMinutes: safeNum(map['noShowWaitMinutes'])?.toInt() ?? 10,
      autoArrivalEnabled: (map['autoArrivalEnabled'] as bool?) ?? true,
      autoArrivalCountdownSeconds:
          safeNum(map['autoArrivalCountdownSeconds'])?.toInt() ?? 5,
      enableWaitingTimeBilling:
          (map['enableWaitingTimeBilling'] as bool?) ?? true,
      freeWaitingMinutes:
          safeNum(map['freeWaitingMinutes'])?.toInt() ?? 10,
      waitingRatePerMinute:
          safeNum(map['waitingRatePerMinute'])?.toDouble() ?? 20.0,
      enableCancellationLock:
          (map['enableCancellationLock'] as bool?) ?? true,
    );
  }

  DailyStreakConfig copyWith({
    double? baseCommissionRate,
    int? noShowWaitMinutes,
    bool? autoArrivalEnabled,
    int? autoArrivalCountdownSeconds,
    bool? enableWaitingTimeBilling,
    int? freeWaitingMinutes,
    double? waitingRatePerMinute,
    bool? enableCancellationLock,
  }) {
    return DailyStreakConfig(
      baseCommissionRate: baseCommissionRate ?? this.baseCommissionRate,
      noShowWaitMinutes: noShowWaitMinutes ?? this.noShowWaitMinutes,
      autoArrivalEnabled: autoArrivalEnabled ?? this.autoArrivalEnabled,
      autoArrivalCountdownSeconds:
          autoArrivalCountdownSeconds ?? this.autoArrivalCountdownSeconds,
      enableWaitingTimeBilling:
          enableWaitingTimeBilling ?? this.enableWaitingTimeBilling,
      freeWaitingMinutes: freeWaitingMinutes ?? this.freeWaitingMinutes,
      waitingRatePerMinute: waitingRatePerMinute ?? this.waitingRatePerMinute,
      enableCancellationLock:
          enableCancellationLock ?? this.enableCancellationLock,
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

  /// Dispatch, waiting time, and commission configuration.
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
    this.dailyStreakConfig = const DailyStreakConfig(),
    required this.updatedAt,
  });

  bool get isGlobalDefault => id == 'global_default';
  bool get isCountryRule => stateOrRegion.isEmpty && !isGlobalDefault;
  bool get isStateOverride => stateOrRegion.isNotEmpty;

  /// Formats an amount with currency symbol. Cleanly formats whole numbers
  /// (e.g. ₦3,600) without trailing decimals.
  String formatCurrency(num amount) {
    if (amount % 1 == 0) {
      final whole = amount.toInt().toString().replaceAllMapped(
            RegExp(r'(\d{1,3})(?=(\d{3})+(?!\d))'),
            (Match m) => '${m[1]},',
          );
      return '$currencySymbol$whole';
    }
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
          safeNum(map['regionalSurgeMultiplier'])?.toDouble() ?? 1.0,
      pricingRates: pricingMap,
      carTierThresholds: CarTierThresholds.fromMap(
        map['carTierThresholds'] as Map<String, dynamic>?,
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
      dailyStreakConfig: dailyStreakConfig ?? this.dailyStreakConfig,
      updatedAt: updatedAt ?? this.updatedAt,
    );
  }
}
