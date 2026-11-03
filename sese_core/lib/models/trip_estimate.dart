import 'vehicle_category.dart';
import 'package:sese_core/utils/safe_json.dart';

/// Fare estimate details for a specific vehicle category or car ride tier.
class TripEstimate {
  final VehicleCategory category;
  final RideTier? tier;
  final String label;
  final double distanceKm;
  final double durationMinutes;
  final double baseFee;
  final double distanceFare;
  final double timeFare;
  final double surgeMultiplier;
  final double tierMultiplier;
  final double totalFare;
  final String currencySymbol;
  final String currencyCode;

  const TripEstimate({
    required this.category,
    this.tier,
    required this.label,
    required this.distanceKm,
    required this.durationMinutes,
    required this.baseFee,
    required this.distanceFare,
    required this.timeFare,
    required this.surgeMultiplier,
    required this.tierMultiplier,
    required this.totalFare,
    required this.currencySymbol,
    required this.currencyCode,
  });

  String get formattedTotal => '$currencySymbol${totalFare.toStringAsFixed(2)}';
  String get formattedBaseFee => '$currencySymbol${baseFee.toStringAsFixed(2)}';

  Map<String, dynamic> toMap() {
    return {
      'category': category.name,
      'tier': tier?.name,
      'label': label,
      'distanceKm': distanceKm,
      'durationMinutes': durationMinutes,
      'baseFee': baseFee,
      'distanceFare': distanceFare,
      'timeFare': timeFare,
      'surgeMultiplier': surgeMultiplier,
      'tierMultiplier': tierMultiplier,
      'totalFare': totalFare,
      'currencySymbol': currencySymbol,
      'currencyCode': currencyCode,
    };
  }

  factory TripEstimate.fromMap(Map<String, dynamic> map) {
    return TripEstimate(
      category: VehicleCategory.fromString(map['category'] ?? 'car'),
      tier: map['tier'] != null ? RideTier.fromString(map['tier']) : null,
      label: map['label'] ?? '',
      distanceKm: safeNum(map['distanceKm'])?.toDouble() ?? 0.0,
      durationMinutes: safeNum(map['durationMinutes'])?.toDouble() ?? 0.0,
      baseFee: safeNum(map['baseFee'])?.toDouble() ?? 0.0,
      distanceFare: safeNum(map['distanceFare'])?.toDouble() ?? 0.0,
      timeFare: safeNum(map['timeFare'])?.toDouble() ?? 0.0,
      surgeMultiplier: safeNum(map['surgeMultiplier'])?.toDouble() ?? 1.0,
      tierMultiplier: safeNum(map['tierMultiplier'])?.toDouble() ?? 1.0,
      totalFare: safeNum(map['totalFare'])?.toDouble() ?? 0.0,
      currencySymbol: map['currencySymbol'] ?? '₦',
      currencyCode: map['currencyCode'] ?? 'NGN',
    );
  }
}

/// A multi-vehicle broadcast payload for package delivery.
/// Contains distinct pricing guarantees for each selected vehicle category.
class MultiVehicleDispatchProposal {
  final String orderId;
  final String customerId;
  final String pickupAddress;
  final String dropoffAddress;
  final double distanceKm;
  final double durationMinutes;
  final List<VehicleCategory> requestedCategories;
  final Map<VehicleCategory, TripEstimate> perVehicleEstimates;
  final DateTime createdAt;

  const MultiVehicleDispatchProposal({
    required this.orderId,
    required this.customerId,
    required this.pickupAddress,
    required this.dropoffAddress,
    required this.distanceKm,
    required this.durationMinutes,
    required this.requestedCategories,
    required this.perVehicleEstimates,
    required this.createdAt,
  });

  /// Guaranteed dynamic fare for an individual driver operating a given category.
  TripEstimate? estimateFor(VehicleCategory category) =>
      perVehicleEstimates[category];

  Map<String, dynamic> toMap() {
    final estimatesMap = <String, dynamic>{};
    for (final e in perVehicleEstimates.entries) {
      estimatesMap[e.key.name] = e.value.toMap();
    }

    return {
      'orderId': orderId,
      'customerId': customerId,
      'pickupAddress': pickupAddress,
      'dropoffAddress': dropoffAddress,
      'distanceKm': distanceKm,
      'durationMinutes': durationMinutes,
      'requestedCategories': requestedCategories.map((c) => c.name).toList(),
      'perVehicleEstimates': estimatesMap,
      'createdAt': createdAt.toIso8601String(),
    };
  }
}
