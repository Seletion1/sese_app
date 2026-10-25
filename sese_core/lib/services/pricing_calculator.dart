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

    // Total fare: Base fee floor + variable fare, rounded to nearest 100
    // Base fee is the minimum floor price for any trip or delivery
    final calculatedTotal = rate.baseFee + variableFare;
    final totalFare = roundToNearest100(calculatedTotal, minFloor: rate.baseFee);

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
      totalFare: totalFare,
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

  /// Rounds a fare amount to the nearest 100.
  ///
  /// Rule:
  /// - If the remainder (amount % 100) is 50 or higher, it rounds UP to the nearest 100.
  /// - If the remainder is less than 50, it rounds DOWN to the nearest 100.
  ///
  /// Examples:
  /// - 3,612 -> 3,600 (remainder 12 < 50)
  /// - 2,576 -> 2,600 (remainder 76 >= 50)
  /// - 3,650 -> 3,700 (remainder 50 >= 50)
  static double roundToNearest100(double amount, {double minFloor = 0}) {
    if (amount <= 0) return 0.0;
    final intAmount = amount.round();
    final remainder = intAmount % 100;
    int rounded;
    if (remainder >= 50) {
      rounded = intAmount - remainder + 100;
    } else {
      rounded = intAmount - remainder;
    }
    final floorRounded = (minFloor > 0) ? minFloor.round() : 0;
    if (floorRounded > 0 && rounded < floorRounded) {
      final floorRemainder = floorRounded % 100;
      rounded = floorRemainder == 0
          ? floorRounded
          : (floorRounded -
              floorRemainder +
              (floorRemainder >= 50 ? 100 : 0));
    }
    return rounded.toDouble();
  }
}
