import 'vehicle_category.dart';

/// Configuration for dynamic year thresholds, display names, and pricing multipliers
/// for Car / Sedan passenger ride tiers.
///
/// Default rules:
/// - Standard / Comfort Class: Vehicles manufactured before 2010 (< 2010).
/// - Executive / Premium Class: Vehicles manufactured between 2010 and 2019 (2010..2019).
/// - Luxe / Super Class: Vehicles manufactured in 2020 or newer (>= 2020).
class CarTierThresholds {
  static const int defaultComfortMaxYear = 2009;
  static const int defaultPremiumMinYear = 2010;
  static const int defaultPremiumMaxYear = 2019;
  static const int defaultLuxeMinYear = 2020;
  static const double defaultComfortMultiplier = 1.0;
  static const double defaultPremiumMultiplier = 1.35;
  static const double defaultLuxeMultiplier = 1.75;

  final int comfortMaxYear; // default 2009 (< 2010)
  final int premiumMinYear; // default 2010
  final int premiumMaxYear; // default 2019
  final int luxeMinYear;    // default 2020 (>= 2020)

  final String comfortLabel;
  final String premiumLabel;
  final String luxeLabel;

  final double comfortMultiplier;
  final double premiumMultiplier;
  final double luxeMultiplier;

  const CarTierThresholds({
    this.comfortMaxYear = defaultComfortMaxYear,
    this.premiumMinYear = defaultPremiumMinYear,
    this.premiumMaxYear = defaultPremiumMaxYear,
    this.luxeMinYear = defaultLuxeMinYear,
    this.comfortLabel = 'Standard / Comfort',
    this.premiumLabel = 'Executive / Premium',
    this.luxeLabel = 'Luxe / Super',
    this.comfortMultiplier = defaultComfortMultiplier,
    this.premiumMultiplier = defaultPremiumMultiplier,
    this.luxeMultiplier = defaultLuxeMultiplier,
  });

  /// Classifies a vehicle manufacture year into its corresponding [RideTier].
  RideTier classifyYear(int year) {
    if (year >= luxeMinYear) {
      return RideTier.luxe;
    } else if (year >= premiumMinYear && year <= premiumMaxYear) {
      return RideTier.premium;
    } else {
      return RideTier.comfort;
    }
  }

  /// Returns user-friendly display name for the tier.
  String labelFor(RideTier tier) {
    switch (tier) {
      case RideTier.comfort:
        return comfortLabel;
      case RideTier.premium:
        return premiumLabel;
      case RideTier.luxe:
        return luxeLabel;
    }
  }

  /// Returns multiplier for the tier.
  double multiplierFor(RideTier tier) {
    switch (tier) {
      case RideTier.comfort:
        return comfortMultiplier;
      case RideTier.premium:
        return premiumMultiplier;
      case RideTier.luxe:
        return luxeMultiplier;
    }
  }

  Map<String, dynamic> toMap() {
    return {
      'comfortMaxYear': comfortMaxYear,
      'premiumMinYear': premiumMinYear,
      'premiumMaxYear': premiumMaxYear,
      'luxeMinYear': luxeMinYear,
      'comfortLabel': comfortLabel,
      'premiumLabel': premiumLabel,
      'luxeLabel': luxeLabel,
      'comfortMultiplier': comfortMultiplier,
      'premiumMultiplier': premiumMultiplier,
      'luxeMultiplier': luxeMultiplier,
    };
  }

  factory CarTierThresholds.fromMap(Map<String, dynamic>? map) {
    if (map == null) return const CarTierThresholds();
    return CarTierThresholds(
      comfortMaxYear: (map['comfortMaxYear'] as num?)?.toInt() ?? 2009,
      premiumMinYear: (map['premiumMinYear'] as num?)?.toInt() ?? 2010,
      premiumMaxYear: (map['premiumMaxYear'] as num?)?.toInt() ?? 2019,
      luxeMinYear: (map['luxeMinYear'] as num?)?.toInt() ?? 2020,
      comfortLabel: map['comfortLabel'] ?? 'Standard / Comfort',
      premiumLabel: map['premiumLabel'] ?? 'Executive / Premium',
      luxeLabel: map['luxeLabel'] ?? 'Luxe / Super',
      comfortMultiplier: (map['comfortMultiplier'] as num?)?.toDouble() ?? 1.0,
      premiumMultiplier: (map['premiumMultiplier'] as num?)?.toDouble() ?? 1.35,
      luxeMultiplier: (map['luxeMultiplier'] as num?)?.toDouble() ?? 1.75,
    );
  }

  CarTierThresholds copyWith({
    int? comfortMaxYear,
    int? premiumMinYear,
    int? premiumMaxYear,
    int? luxeMinYear,
    String? comfortLabel,
    String? premiumLabel,
    String? luxeLabel,
    double? comfortMultiplier,
    double? premiumMultiplier,
    double? luxeMultiplier,
  }) {
    return CarTierThresholds(
      comfortMaxYear: comfortMaxYear ?? this.comfortMaxYear,
      premiumMinYear: premiumMinYear ?? this.premiumMinYear,
      premiumMaxYear: premiumMaxYear ?? this.premiumMaxYear,
      luxeMinYear: luxeMinYear ?? this.luxeMinYear,
      comfortLabel: comfortLabel ?? this.comfortLabel,
      premiumLabel: premiumLabel ?? this.premiumLabel,
      luxeLabel: luxeLabel ?? this.luxeLabel,
      comfortMultiplier: comfortMultiplier ?? this.comfortMultiplier,
      premiumMultiplier: premiumMultiplier ?? this.premiumMultiplier,
      luxeMultiplier: luxeMultiplier ?? this.luxeMultiplier,
    );
  }
}
