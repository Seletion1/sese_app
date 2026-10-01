import '../models/car_tier_thresholds.dart';
import '../models/vehicle_category.dart';

/// Classifies passenger vehicles into RideTier classes based on manufacture year
/// and dynamic thresholds configured by Super Admin.
class VehicleTierClassifier {
  final CarTierThresholds thresholds;

  const VehicleTierClassifier([this.thresholds = const CarTierThresholds()]);

  /// Returns the ride tier for a given passenger vehicle category and year.
  /// For non-car categories (e.g. bicycle, motorcycle, van), returns null.
  RideTier? classify({
    required VehicleCategory category,
    required int manufactureYear,
  }) {
    if (category != VehicleCategory.car) {
      return null;
    }
    return thresholds.classifyYear(manufactureYear);
  }

  /// Formats human-readable explanation of why a vehicle got assigned to a tier.
  String explainClassification(int year) {
    final tier = thresholds.classifyYear(year);
    final label = thresholds.labelFor(tier);
    if (year >= thresholds.luxeMinYear) {
      return '$label: Manufactured $year (>= ${thresholds.luxeMinYear})';
    } else if (year >= thresholds.premiumMinYear && year <= thresholds.premiumMaxYear) {
      return '$label: Manufactured $year (${thresholds.premiumMinYear}-${thresholds.premiumMaxYear})';
    } else {
      return '$label: Manufactured $year (< ${thresholds.premiumMinYear})';
    }
  }
}
