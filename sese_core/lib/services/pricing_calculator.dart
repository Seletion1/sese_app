import '../models/pricing_config.dart';
import '../models/trip_estimate.dart';
import '../models/vehicle_category.dart';

/// Central server-side calculation engine for dynamic trip & delivery fares.
/// All pricing formulas and guarantees are strictly evaluated through this engine.
class PricingCalculator {
  /// Calculates a trip estimate for a specific [category], [distanceKm], and [durationMinutes].
  /// If [category] is [VehicleCategory.car] and a passenger [tier] is specified,
  /// the tier's dynamic multiplier is applied.
  static TripEstimate calculateEstimate({
    required RegionConfig config,
    required VehicleCategory category,
    RideTier? tier,
    required double distanceKm,
    required double durationMinutes,
    double? surgeOverride,
  }) {
    final rate = config.pricingRates[category] ??
        RegionConfig.globalDefault().pricingRates[category]!;

    final surge = surgeOverride ??
        (rate.surgeMultiplier * config.regionalSurgeMultiplier);

    double tierMultiplier = 1.0;
    String label = category.displayName;

    if (category == VehicleCategory.car && tier != null) {
      tierMultiplier = config.carTierThresholds.multiplierFor(tier);
      label = config.carTierThresholds.labelFor(tier);
    }

    // Distance and time fare calculations
    final distanceFare = distanceKm * rate.distanceRatePerKm;
    final timeFare = durationMinutes * rate.timeRatePerMinute;

    // Subtotal before multipliers
    final variableFare = (distanceFare + timeFare) * surge * tierMultiplier;

    // Total fare: Base fee floor + variable fare
    // Base fee is the minimum floor price for any trip or delivery
    final calculatedTotal = rate.baseFee + variableFare;
    final totalFare = calculatedTotal < rate.baseFee ? rate.baseFee : calculatedTotal;

    return TripEstimate(
      category: category,
      tier: tier,
      label: label,
      distanceKm: distanceKm,
      durationMinutes: durationMinutes,
      baseFee: rate.baseFee,
      distanceFare: distanceFare,
      timeFare: timeFare,
      surgeMultiplier: surge,
      tierMultiplier: tierMultiplier,
      totalFare: _roundToTwoDecimals(totalFare),
      currencySymbol: config.currencySymbol,
      currencyCode: config.currencyCode,
    );
  }

  /// Calculates dynamic estimates for ALL delivery vehicle categories.
  static Map<VehicleCategory, TripEstimate> calculateDeliveryOptions({
    required RegionConfig config,
    required double distanceKm,
    required double durationMinutes,
    double? surgeOverride,
  }) {
    final results = <VehicleCategory, TripEstimate>{};
    for (final cat in VehicleCategory.values) {
      if (cat.isDeliveryEligible) {
        results[cat] = calculateEstimate(
          config: config,
          category: cat,
          distanceKm: distanceKm,
          durationMinutes: durationMinutes,
          surgeOverride: surgeOverride,
        );
      }
    }
    return results;
  }

  /// Calculates dynamic estimates for all passenger Car / Sedan tiers (Comfort, Premium, Luxe).
  static Map<RideTier, TripEstimate> calculateRideHailingTiers({
    required RegionConfig config,
    required double distanceKm,
    required double durationMinutes,
    double? surgeOverride,
  }) {
    final results = <RideTier, TripEstimate>{};
    for (final tier in RideTier.values) {
      results[tier] = calculateEstimate(
        config: config,
        category: VehicleCategory.car,
        tier: tier,
        distanceKm: distanceKm,
        durationMinutes: durationMinutes,
        surgeOverride: surgeOverride,
      );
    }
    return results;
  }

  /// Generates a Multi-Vehicle Dispatch Proposal for package delivery,
  /// guaranteeing strict per-vehicle dynamic pricing rate calculation for each selected category.
  static MultiVehicleDispatchProposal createMultiVehicleDispatch({
    required String orderId,
    required String customerId,
    required String pickupAddress,
    required String dropoffAddress,
    required RegionConfig config,
    required List<VehicleCategory> selectedCategories,
    required double distanceKm,
    required double durationMinutes,
    double? surgeOverride,
  }) {
    final estimates = <VehicleCategory, TripEstimate>{};

    for (final category in selectedCategories) {
      estimates[category] = calculateEstimate(
        config: config,
        category: category,
        distanceKm: distanceKm,
        durationMinutes: durationMinutes,
        surgeOverride: surgeOverride,
      );
    }

    return MultiVehicleDispatchProposal(
      orderId: orderId,
      customerId: customerId,
      pickupAddress: pickupAddress,
      dropoffAddress: dropoffAddress,
      distanceKm: distanceKm,
      durationMinutes: durationMinutes,
      requestedCategories: List.unmodifiable(selectedCategories),
      perVehicleEstimates: Map.unmodifiable(estimates),
      createdAt: DateTime.now(),
    );
  }

  static double _roundToTwoDecimals(double value) {
    return (value * 100).roundToDouble() / 100;
  }
}
