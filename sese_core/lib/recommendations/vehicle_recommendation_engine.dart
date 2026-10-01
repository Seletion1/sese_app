import '../models/vehicle_category.dart';
import 'vehicle_recommendation_config.dart';

/// Pure, UI-free decision logic for the Smart Dynamic Recommendation Engine.
///
/// Everything here is a deterministic function of
/// ([VehicleRecommendationConfig], trip distance, workflow) — no Firestore,
/// no widgets — so it is unit-testable and shared by `sese_ride` (dispatch
/// selectors, warning dialogs) and potentially `sese_hub` previews.
///
/// Money and fares are never computed here; only which vehicle is badged
/// "Recommended" and which selections deserve a confirmation warning.
class VehicleRecommendationEngine {
  const VehicleRecommendationEngine._();

  /// Delivery recommendations for [distanceKm], as a set (multiple vehicles
  /// can share the badge):
  /// - below `kekeMaxDistanceKm` → bicycle + tricycle (shortest hops);
  /// - below `bicycleMaxDistanceKm` → bicycle + motorcycle (mid-range);
  /// - at/above `motorcycleMinDistanceKm` → motorcycle only (long haul).
  ///
  /// Returns empty when no category earns the badge (negative distance, or a
  /// gap between the bicycle ceiling and the motorcycle floor); the UI then
  /// falls back to the server's `isRecommended`.
  static Set<VehicleCategory> recommendedDeliveriesFor(
    double distanceKm,
    VehicleRecommendationConfig config,
  ) {
    if (distanceKm < 0) return const {};
    if (distanceKm >= config.motorcycleMinDistanceKm) {
      return {VehicleCategory.motorcycle};
    }
    if (distanceKm >= config.kekeMaxDistanceKm) {
      return {VehicleCategory.bicycle, VehicleCategory.motorcycle};
    }
    if (distanceKm < config.bicycleMaxDistanceKm) {
      return {VehicleCategory.bicycle, VehicleCategory.tricycle};
    }
    return const {};
  }

  /// Heavy-duty vehicles: Van and Truck. Selecting either locks out the
  /// small-vehicle options (see [isSmallVehicle]) — a heavy-cargo broadcast
  /// must never page bicycle/tricycle/motorcycle riders.
  static bool isHeavyDuty(VehicleCategory category) {
    return category == VehicleCategory.van ||
        category == VehicleCategory.truck;
  }

  /// Small vehicles: Bicycle, Tricycle (Keke), Motorcycle. Disabled while a
  /// heavy-duty vehicle is selected.
  static bool isSmallVehicle(VehicleCategory category) {
    return category == VehicleCategory.bicycle ||
        category == VehicleCategory.tricycle ||
        category == VehicleCategory.motorcycle;
  }

  /// Whether tricycle (Keke) should be offered as a passenger option.
  /// Below [kekeMaxDistanceKm] it is shown and recommended; at/above it the
  /// UI unchecks it by default while keeping it visible.
  static bool offerKekeForRide(
    double distanceKm,
    VehicleRecommendationConfig config,
  ) {
    return distanceKm >= 0 && distanceKm < config.kekeMaxDistanceKm;
  }

  /// Per-vehicle ceiling above which a selection is "non-ideal" and deserves
  /// the Smart Distance Warning dialog. Vehicles without an entry (car, van,
  /// truck) are never warned about — they suit any distance.
  static double? warningCeilingFor(
    VehicleCategory category,
    VehicleRecommendationConfig config,
  ) {
    switch (category) {
      case VehicleCategory.bicycle:
        return config.bicycleMaxDistanceKm;
      case VehicleCategory.tricycle:
        return config.kekeMaxDistanceKm;
      case VehicleCategory.motorcycle:
      case VehicleCategory.car:
      case VehicleCategory.van:
      case VehicleCategory.truck:
        return null;
    }
  }

  /// Subset of [selected] whose warning ceiling is exceeded by [distanceKm],
  /// in a stable display order (bicycle, tricycle).
  static List<VehicleCategory> nonIdealSelections(
    double distanceKm,
    Iterable<VehicleCategory> selected,
    VehicleRecommendationConfig config,
  ) {
    const order = [VehicleCategory.bicycle, VehicleCategory.tricycle];
    return order.where((c) {
      if (!selected.contains(c)) return false;
      final ceiling = warningCeilingFor(c, config);
      return ceiling != null && distanceKm > ceiling;
    }).toList();
  }
}
