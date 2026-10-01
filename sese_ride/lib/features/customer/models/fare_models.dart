/// Server-authoritative fare models.
///
/// All monetary values shown in the UI come exclusively from these models
/// returned by the [FareService] — no client-side arithmetic is performed.
library;

import 'package:latlong2/latlong.dart';

// ── Request ───────────────────────────────────────────────────────────────────

/// The service type sent to the `calculateFare` Cloud Function.
enum FareServiceType {
  ride,
  sendItem,
  receiveItem;

  String get apiValue {
    switch (this) {
      case FareServiceType.ride:
        return 'ride';
      case FareServiceType.sendItem:
        return 'send_item';
      case FareServiceType.receiveItem:
        return 'receive_item';
    }
  }
}

/// Input payload for the `calculateFare` callable.
class FareRequest {
  final LatLng pickup;
  final LatLng dropoff;
  final FareServiceType serviceType;
  final List<String> selectedTiers;
  final String? countryCode;
  final String? stateOrRegion;

  const FareRequest({
    required this.pickup,
    required this.dropoff,
    required this.serviceType,
    required this.selectedTiers,
    this.countryCode,
    this.stateOrRegion,
  });

  Map<String, dynamic> toMap() => {
        'pickup': {'lat': pickup.latitude, 'lng': pickup.longitude},
        'dropoff': {'lat': dropoff.latitude, 'lng': dropoff.longitude},
        'serviceType': serviceType.apiValue,
        'selectedTiers': selectedTiers,
        if (countryCode != null) 'countryCode': countryCode,
        if (stateOrRegion != null) 'stateOrRegion': stateOrRegion,
      };
}

// ── Response ─────────────────────────────────────────────────────────────────

/// Server-computed fare for a single vehicle tier.
class FareTier {
  final String tierId;
  final String name;
  final bool isRecommended;

  /// Pre-formatted string from the server, e.g. "₦1,850.00". Render directly.
  final String fareFormatted;

  /// Raw amount for sorting/comparison only — never reformat on client.
  final double fareAmount;

  const FareTier({
    required this.tierId,
    required this.name,
    required this.isRecommended,
    required this.fareFormatted,
    required this.fareAmount,
  });

  factory FareTier.fromMap(Map<String, dynamic> map) {
    return FareTier(
      tierId: (map['tierId'] ?? '').toString(),
      name: (map['name'] ?? '').toString(),
      isRecommended: map['isRecommended'] == true,
      fareFormatted: (map['fareFormatted'] ?? '').toString(),
      fareAmount: (map['fareAmount'] as num?)?.toDouble() ?? 0.0,
    );
  }
}

/// Complete server response from `calculateFare`.
class FareResponse {
  /// Actual road-network distance in kilometres.
  final double distanceKm;

  /// Estimated road-network travel time in minutes.
  final double durationMins;

  /// Per-tier fare breakdown — render these values verbatim.
  final List<FareTier> tiers;

  /// HMAC-signed token echoed back at booking confirmation so the server
  /// can reject tampered fares. Store opaquely — never parse on client.
  final String fareToken;

  const FareResponse({
    required this.distanceKm,
    required this.durationMins,
    required this.tiers,
    required this.fareToken,
  });

  factory FareResponse.fromMap(Map<String, dynamic> map) {
    final rawTiers = (map['tiers'] as List<dynamic>? ?? []);
    return FareResponse(
      distanceKm: (map['distanceKm'] as num?)?.toDouble() ?? 0.0,
      durationMins: (map['durationMins'] as num?)?.toDouble() ?? 0.0,
      tiers: rawTiers
          .map((t) => FareTier.fromMap(Map<String, dynamic>.from(t as Map)))
          .toList(),
      fareToken: (map['fareToken'] ?? '').toString(),
    );
  }

  FareTier? tierById(String tierId) {
    try {
      return tiers.firstWhere((t) => t.tierId == tierId);
    } catch (_) {
      return null;
    }
  }

  FareTier? get recommendedTier {
    try {
      return tiers.firstWhere((t) => t.isRecommended);
    } catch (_) {
      return tiers.isNotEmpty ? tiers.first : null;
    }
  }
}

// ── Errors ────────────────────────────────────────────────────────────────────

/// Thrown when the `calculateFare` callable returns an error or the network
/// is unavailable. Always carry a [userMessage] safe to show in the UI.
class FareException implements Exception {
  final String code;
  final String userMessage;

  const FareException(this.code, this.userMessage);

  @override
  String toString() => 'FareException($code): $userMessage';
}
