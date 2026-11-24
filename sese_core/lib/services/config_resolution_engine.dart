import '../models/car_tier_thresholds.dart';
import '../models/pricing_config.dart';
import '../models/vehicle_category.dart';

/// Evaluates and merges configuration across the system fallback chain:
/// `Global Default` -> `Country-Specific Rule` -> `State-Specific Override`.
class ConfigResolutionEngine {
  /// Resolves effective configuration by merging the fallback cascade:
  /// - [globalDefault]: Mandatory baseline (defaults to [RegionConfig.globalDefault]).
  /// - [countryRule]: Optional country configuration (e.g. NG, US, KE).
  /// - [stateOverride]: Optional state/city configuration (e.g. Lagos, Nairobi, CA).
  static RegionConfig resolve({
    RegionConfig? globalDefault,
    RegionConfig? countryRule,
    RegionConfig? stateOverride,
  }) {
    final base = globalDefault ?? RegionConfig.globalDefault();

    if (countryRule == null && stateOverride == null) {
      return base;
    }

    // Step 1: Merge Country into Global Base
    final mergedCountry = countryRule != null
        ? _mergeConfigs(parent: base, child: countryRule)
        : base;

    // Step 2: Merge State Override into Country-merged config
    if (stateOverride != null) {
      return _mergeConfigs(parent: mergedCountry, child: stateOverride);
    }

    return mergedCountry;
  }

  /// Locates and resolves from an arbitrary collection of configs given country and state.
  static RegionConfig resolveFromList({
    required List<RegionConfig> allConfigs,
    required String countryCode,
    String? stateOrRegion,
  }) {
    final cleanCountry = countryCode.trim().toUpperCase();
    final cleanState = stateOrRegion?.trim().toLowerCase() ?? '';

    RegionConfig? global;
    RegionConfig? country;
    RegionConfig? state;

    for (final cfg in allConfigs) {
      if (cfg.isGlobalDefault) {
        global = cfg;
      } else if (cfg.countryCode.toUpperCase() == cleanCountry && cfg.stateOrRegion.isEmpty) {
        country = cfg;
      } else if (cfg.countryCode.toUpperCase() == cleanCountry &&
                 cleanState.isNotEmpty &&
                 cfg.stateOrRegion.toLowerCase() == cleanState) {
        state = cfg;
      }
    }

    return resolve(
      globalDefault: global,
      countryRule: country,
      stateOverride: state,
    );
  }

  static RegionConfig _mergeConfigs({
    required RegionConfig parent,
    required RegionConfig child,
  }) {
    // Merge vehicle pricing rates: child overrides parent per vehicle category
    final mergedRates = Map<VehicleCategory, VehiclePricingRate>.from(parent.pricingRates);
    for (final entry in child.pricingRates.entries) {
      mergedRates[entry.key] = entry.value;
    }

    // Merge car tier thresholds: child overrides if non-default or specified
    final mergedThresholds = CarTierThresholds(
      comfortMaxYear: child.carTierThresholds.comfortMaxYear !=
              CarTierThresholds.defaultComfortMaxYear
          ? child.carTierThresholds.comfortMaxYear
          : parent.carTierThresholds.comfortMaxYear,
      premiumMinYear: child.carTierThresholds.premiumMinYear !=
              CarTierThresholds.defaultPremiumMinYear
          ? child.carTierThresholds.premiumMinYear
          : parent.carTierThresholds.premiumMinYear,
      premiumMaxYear: child.carTierThresholds.premiumMaxYear !=
              CarTierThresholds.defaultPremiumMaxYear
          ? child.carTierThresholds.premiumMaxYear
          : parent.carTierThresholds.premiumMaxYear,
      luxeMinYear: child.carTierThresholds.luxeMinYear !=
              CarTierThresholds.defaultLuxeMinYear
          ? child.carTierThresholds.luxeMinYear
          : parent.carTierThresholds.luxeMinYear,
      comfortLabel: child.carTierThresholds.comfortLabel.isNotEmpty
          ? child.carTierThresholds.comfortLabel
          : parent.carTierThresholds.comfortLabel,
      premiumLabel: child.carTierThresholds.premiumLabel.isNotEmpty
          ? child.carTierThresholds.premiumLabel
          : parent.carTierThresholds.premiumLabel,
      luxeLabel: child.carTierThresholds.luxeLabel.isNotEmpty
          ? child.carTierThresholds.luxeLabel
          : parent.carTierThresholds.luxeLabel,
      comfortMultiplier: child.carTierThresholds.comfortMultiplier !=
              CarTierThresholds.defaultComfortMultiplier
          ? child.carTierThresholds.comfortMultiplier
          : parent.carTierThresholds.comfortMultiplier,
      premiumMultiplier: child.carTierThresholds.premiumMultiplier !=
              CarTierThresholds.defaultPremiumMultiplier
          ? child.carTierThresholds.premiumMultiplier
          : parent.carTierThresholds.premiumMultiplier,
      luxeMultiplier: child.carTierThresholds.luxeMultiplier !=
              CarTierThresholds.defaultLuxeMultiplier
          ? child.carTierThresholds.luxeMultiplier
          : parent.carTierThresholds.luxeMultiplier,
    );

    final mergedDailyStreak = _mergeDailyStreak(
      parent.dailyStreakConfig,
      child.dailyStreakConfig,
    );

    return RegionConfig(
      id: child.id.isNotEmpty ? child.id : parent.id,
      countryCode: child.countryCode.isNotEmpty ? child.countryCode : parent.countryCode,
      stateOrRegion: child.stateOrRegion.isNotEmpty ? child.stateOrRegion : parent.stateOrRegion,
      currencyCode: child.currencyCode.isNotEmpty ? child.currencyCode : parent.currencyCode,
      currencySymbol: child.currencySymbol.isNotEmpty ? child.currencySymbol : parent.currencySymbol,
      regionalSurgeMultiplier: child.regionalSurgeMultiplier > 0
          ? child.regionalSurgeMultiplier
          : parent.regionalSurgeMultiplier,
      pricingRates: mergedRates,
      carTierThresholds: mergedThresholds,
      dailyStreakConfig: mergedDailyStreak,
      updatedAt: child.updatedAt.isAfter(parent.updatedAt)
          ? child.updatedAt
          : parent.updatedAt,
    );
  }

  /// Merges two [DailyStreakConfig] levels (parent → child).
  ///
  /// - Scalar fields: child wins only when customized (differs from the
  ///   model default); otherwise the parent value is inherited.
  static DailyStreakConfig _mergeDailyStreak(
    DailyStreakConfig parent,
    DailyStreakConfig child,
  ) {
    const defaults = DailyStreakConfig();

    return DailyStreakConfig(
      baseCommissionRate:
          child.baseCommissionRate != defaults.baseCommissionRate
              ? child.baseCommissionRate
              : parent.baseCommissionRate,
      noShowWaitMinutes:
          child.noShowWaitMinutes != defaults.noShowWaitMinutes
              ? child.noShowWaitMinutes
              : parent.noShowWaitMinutes,
      autoArrivalEnabled:
          parent.autoArrivalEnabled && child.autoArrivalEnabled,
      autoArrivalCountdownSeconds:
          child.autoArrivalCountdownSeconds != defaults.autoArrivalCountdownSeconds
              ? child.autoArrivalCountdownSeconds
              : parent.autoArrivalCountdownSeconds,
      enableWaitingTimeBilling:
          child.enableWaitingTimeBilling != defaults.enableWaitingTimeBilling
              ? child.enableWaitingTimeBilling
              : parent.enableWaitingTimeBilling,
      freeWaitingMinutes:
          child.freeWaitingMinutes != defaults.freeWaitingMinutes
              ? child.freeWaitingMinutes
              : parent.freeWaitingMinutes,
      waitingRatePerMinute:
          child.waitingRatePerMinute != defaults.waitingRatePerMinute
              ? child.waitingRatePerMinute
              : parent.waitingRatePerMinute,
      enableCancellationLock:
          child.enableCancellationLock != defaults.enableCancellationLock
              ? child.enableCancellationLock
              : parent.enableCancellationLock,
    );
  }
}
