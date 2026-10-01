import 'vehicle_category.dart';

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
      distanceKm: (map['distanceKm'] as num?)?.toDouble() ?? 0.0,
      durationMinutes: (map['durationMinutes'] as num?)?.toDouble() ?? 0.0,
      baseFee: (map['baseFee'] as num?)?.toDouble() ?? 0.0,
      distanceFare: (map['distanceFare'] as num?)?.toDouble() ?? 0.0,
      timeFare: (map['timeFare'] as num?)?.toDouble() ?? 0.0,
      surgeMultiplier: (map['surgeMultiplier'] as num?)?.toDouble() ?? 1.0,
      tierMultiplier: (map['tierMultiplier'] as num?)?.toDouble() ?? 1.0,
      totalFare: (map['totalFare'] as num?)?.toDouble() ?? 0.0,
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
