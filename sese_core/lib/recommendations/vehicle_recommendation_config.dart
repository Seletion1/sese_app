import 'package:cloud_firestore/cloud_firestore.dart';

/// Distance thresholds driving the Smart Dynamic Recommendation Engine,
/// stored at `system_configs/vehicle_recommendations`.
///
/// All values are editable in sese_hub (Dynamic Config tab) without an app
/// release. Clients fall back to these compiled defaults when the document
/// is missing/unreadable.
///
/// Semantics (all in kilometres, all comparisons are `<` unless noted):
/// - Delivery: below [bicycleMaxDistanceKm] the engine recommends bicycle for
///   the shortest hops and tricycle up to the ceiling; at or above
///   [motorcycleMinDistanceKm] it recommends motorcycle.
/// - Passenger: below [kekeMaxDistanceKm] tricycle (Keke) is offered and
///   recommended for short intra-neighbourhood trips; at or above it,
///   tricycle is unchecked by default and Standard/Comfort is recommended.
class VehicleRecommendationConfig {
  /// Delivery ceiling for bicycle recommendation. Default 10.0.
  final double bicycleMaxDistanceKm;

  /// Passenger + delivery ceiling for tricycle (Keke) recommendation.
  /// Default 5.0.
  final double kekeMaxDistanceKm;

  /// Delivery floor for motorcycle recommendation. Default 10.0.
  final double motorcycleMinDistanceKm;

  const VehicleRecommendationConfig({
    this.bicycleMaxDistanceKm = 10.0,
    this.kekeMaxDistanceKm = 5.0,
    this.motorcycleMinDistanceKm = 10.0,
  });

  factory VehicleRecommendationConfig.fromMap(Map<String, dynamic>? map) {
    map ??= const {};
    double d(String k, double fb) =>
        (map![k] is num) ? (map[k] as num).toDouble() : fb;
    return VehicleRecommendationConfig(
      bicycleMaxDistanceKm: d('bicycleMaxDistanceKm', 10.0),
      kekeMaxDistanceKm: d('kekeMaxDistanceKm', 5.0),
      motorcycleMinDistanceKm: d('motorcycleMinDistanceKm', 10.0),
    );
  }

  Map<String, dynamic> toMap() => {
        'bicycleMaxDistanceKm': bicycleMaxDistanceKm,
        'kekeMaxDistanceKm': kekeMaxDistanceKm,
        'motorcycleMinDistanceKm': motorcycleMinDistanceKm,
        'updatedAt': FieldValue.serverTimestamp(),
      };

  VehicleRecommendationConfig copyWith({
    double? bicycleMaxDistanceKm,
    double? kekeMaxDistanceKm,
    double? motorcycleMinDistanceKm,
  }) {
    return VehicleRecommendationConfig(
      bicycleMaxDistanceKm:
          bicycleMaxDistanceKm ?? this.bicycleMaxDistanceKm,
      kekeMaxDistanceKm: kekeMaxDistanceKm ?? this.kekeMaxDistanceKm,
      motorcycleMinDistanceKm:
          motorcycleMinDistanceKm ?? this.motorcycleMinDistanceKm,
    );
  }
}

/// Field descriptors for the Hub Dynamic Config form (label + help).
class VehicleRecommendationFieldMeta {
  final String key;
  final String label;
  final String help;

  const VehicleRecommendationFieldMeta({
    required this.key,
    required this.label,
    required this.help,
  });

  static const List<VehicleRecommendationFieldMeta> all = [
    VehicleRecommendationFieldMeta(
      key: 'bicycleMaxDistanceKm',
      label: 'Bicycle max distance (km)',
      help: 'Delivery: bicycle is recommended below this distance.',
    ),
    VehicleRecommendationFieldMeta(
      key: 'kekeMaxDistanceKm',
      label: 'Keke max distance (km)',
      help:
          'Passenger: tricycle is offered and recommended below this distance. '
          'Delivery: tricycle is recommended between the short-hop ceiling and here.',
    ),
    VehicleRecommendationFieldMeta(
      key: 'motorcycleMinDistanceKm',
      label: 'Motorcycle min distance (km)',
      help: 'Delivery: motorcycle is recommended at or above this distance.',
    ),
  ];
}
