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

    // Merge streak rewards per-field: a child doc that never customized a
    final mergedStreak = _mergeStreakRewards(
      parent.streakRewards,
      child.streakRewards,
    );

    final mergedCustomerStreak = _mergeStreakRewards(
      parent.customerStreakRewards,
      child.customerStreakRewards,
    );

    // Merge daily commission-tiering config. Disable cascades down the
    // hierarchy (global → country → state): the streak is active only when
    // every level leaves it enabled and neither disable-list covers the
    // region. Scalar overrides apply only when the child doc customized
    // them (i.e. differs from the model default).
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
      streakRewards: mergedStreak,
      customerStreakRewards: mergedCustomerStreak,
      dailyStreakConfig: mergedDailyStreak,
      updatedAt: child.updatedAt.isAfter(parent.updatedAt)
          ? child.updatedAt
          : parent.updatedAt,
    );
  }

  /// Merges two [DailyStreakConfig] levels (parent → child).
  ///
  /// - [streakEnabled] uses AND semantics so a disable at any level
  ///   (global, country, or state) cascades down.
  /// - Scalar fields: child wins only when customized (differs from the
  ///   model default); otherwise the parent value is inherited.
  /// - Disable lists: union of both levels (normalized to upper-case), so a
  ///   country/state disabled globally stays disabled under overrides.
  static DailyStreakConfig _mergeDailyStreak(
    DailyStreakConfig parent,
    DailyStreakConfig child,
  ) {
    const defaults = DailyStreakConfig();
    Set<String> union(List<String> a, List<String> b) => {
          for (final e in [...a, ...b]) e.trim().toUpperCase(),
        }..remove('');

    return DailyStreakConfig(
      streakEnabled: parent.streakEnabled && child.streakEnabled,
      baseCommissionRate:
          child.baseCommissionRate != defaults.baseCommissionRate
              ? child.baseCommissionRate
              : parent.baseCommissionRate,
      noShowWaitMinutes:
          child.noShowWaitMinutes != defaults.noShowWaitMinutes
              ? child.noShowWaitMinutes
              : parent.noShowWaitMinutes,
      completionCashAward:
          child.completionCashAward != defaults.completionCashAward
              ? child.completionCashAward
              : parent.completionCashAward,
      autoArrivalEnabled:
          parent.autoArrivalEnabled && child.autoArrivalEnabled,
      autoArrivalCountdownSeconds:
          child.autoArrivalCountdownSeconds != defaults.autoArrivalCountdownSeconds
              ? child.autoArrivalCountdownSeconds
              : parent.autoArrivalCountdownSeconds,
      disabledCountries:
          union(parent.disabledCountries, child.disabledCountries).toList()
            ..sort(),
      disabledStates:
          union(parent.disabledStates, child.disabledStates).toList()..sort(),
    );
  }

  static StreakRewardConfig _mergeStreakRewards(
    StreakRewardConfig parent,
    StreakRewardConfig child,
  ) {
    return StreakRewardConfig(
      enabled: child.enabled && parent.enabled,
      cycle: child.cycle.isNotEmpty && child.cycle != 'daily'
          ? child.cycle
          : parent.cycle,
      tiers: _isDefaultStreakTiers(child.tiers)
          ? parent.tiers
          : child.tiers,
      grandCompletionCashAward:
          child.grandCompletionCashAward != StreakRewardConfig.defaultGrandAward
              ? child.grandCompletionCashAward
              : parent.grandCompletionCashAward,
      grandCompletionTargetTrips:
          child.grandCompletionTargetTrips != StreakRewardConfig.defaultGrandTargetTrips
              ? child.grandCompletionTargetTrips
              : parent.grandCompletionTargetTrips,
    );
  }

  /// True when [tiers] exactly match the model default (i.e. the child doc
  /// never customized streak tiers, so the parent value must be inherited).
  static bool _isDefaultStreakTiers(List<StreakTier> tiers) {
    if (tiers.length != 3) return false;
    return tiers[0].completedTripsTrigger == 5 &&
        tiers[0].bonusPayout == 1000.0 &&
        tiers[1].completedTripsTrigger == 10 &&
        tiers[1].bonusPayout == 2500.0 &&
        tiers[2].completedTripsTrigger == 20 &&
        tiers[2].bonusPayout == 6000.0;
  }
}
