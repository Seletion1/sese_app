/// Clean Dart mirrors of the `googleMapsProxy` Cloud Function DTOs plus the
/// zero-cost address-reuse model.
///
/// ALL web-service traffic (autocomplete/details/geocode/directions) flows
/// through the server proxy — no Google key exists in Dart, native configs
/// aside (SDK-render keys, app-restricted). See `GoogleMapsService`.
library;

/// A single Google Places Autocomplete prediction (no coordinates — those
/// require a Details fetch, which is exactly the call the recents cache
/// exists to skip).
class PlacePrediction {
  final String placeId;
  final String description;
  final String mainText;
  final String secondaryText;

  const PlacePrediction({
    required this.placeId,
    required this.description,
    required this.mainText,
    required this.secondaryText,
  });

  factory PlacePrediction.fromMap(Map<String, dynamic> map) {
    return PlacePrediction(
      placeId: (map['placeId'] ?? '').toString(),
      description: (map['description'] ?? '').toString(),
      mainText: (map['mainText'] ?? map['description'] ?? '').toString(),
      secondaryText: (map['secondaryText'] ?? '').toString(),
    );
  }

  Map<String, dynamic> toMap() => {
        'placeId': placeId,
        'description': description,
        'mainText': mainText,
        'secondaryText': secondaryText,
      };
}

/// Resolved place coordinates + formatted address (one Details call).
class PlaceDetails {
  final String placeId;
  final double lat;
  final double lng;
  final String formattedAddress;
  final String name;

  const PlaceDetails({
    required this.placeId,
    required this.lat,
    required this.lng,
    required this.formattedAddress,
    required this.name,
  });

  factory PlaceDetails.fromMap(Map<String, dynamic> map) {
    return PlaceDetails(
      placeId: (map['placeId'] ?? '').toString(),
      lat: (map['lat'] as num? ?? 0).toDouble(),
      lng: (map['lng'] as num? ?? 0).toDouble(),
      formattedAddress: (map['formattedAddress'] ?? '').toString(),
      name: (map['name'] ?? '').toString(),
    );
  }

  /// Display address preferring the formatted address, then the name.
  String get displayAddress =>
      formattedAddress.isNotEmpty ? formattedAddress : name;
}

/// A successfully booked/selected location, cached locally (SharedPrefs)
/// and backed up to `users/{uid}/recent_locations/{placeId}`.
///
/// Tapping one re-enters the booking flow with ZERO Google API calls —
/// that is the entire cost strategy. `lastUsedMs` drives MRU order and
/// cross-device merge (newest wins per placeId).
class RecentLocation {
  /// Cap on the local cache (bounded storage, bounded Firestore writes).
  static const int maxCached = 20;

  /// How many surface immediately on the search screen (0 API calls).
  static const int topShown = 5;

  final String placeId;
  final String formattedAddress;
  final String mainText;
  final String secondaryText;
  final double lat;
  final double lng;
  final int lastUsedMs;

  const RecentLocation({
    required this.placeId,
    required this.formattedAddress,
    required this.mainText,
    required this.secondaryText,
    required this.lat,
    required this.lng,
    required this.lastUsedMs,
  });

  /// Builds from a fresh Details resolution (stamps `now` as last-used).
  factory RecentLocation.fromDetails(
    PlaceDetails details, {
    int? nowMs,
  }) {
    final address = details.displayAddress;
    return RecentLocation(
      placeId: details.placeId,
      formattedAddress: address,
      mainText: details.name.isNotEmpty ? details.name : address,
      secondaryText:
          details.name.isNotEmpty && address != details.name ? address : '',
      lat: details.lat,
      lng: details.lng,
      lastUsedMs: nowMs ?? DateTime.now().millisecondsSinceEpoch,
    );
  }

  /// Bumps last-used to now (a re-tap is fresh usage).
  RecentLocation touched({int? nowMs}) => RecentLocation(
        placeId: placeId,
        formattedAddress: formattedAddress,
        mainText: mainText,
        secondaryText: secondaryText,
        lat: lat,
        lng: lng,
        lastUsedMs: nowMs ?? DateTime.now().millisecondsSinceEpoch,
      );

  factory RecentLocation.fromMap(Map<String, dynamic> map) {
    return RecentLocation(
      placeId: (map['placeId'] ?? '').toString(),
      formattedAddress: (map['formattedAddress'] ?? '').toString(),
      mainText: (map['mainText'] ?? '').toString(),
      secondaryText: (map['secondaryText'] ?? '').toString(),
      lat: (map['lat'] as num? ?? 0).toDouble(),
      lng: (map['lng'] as num? ?? 0).toDouble(),
      lastUsedMs: (map['lastUsedMs'] as num? ?? 0).toInt(),
    );
  }

  Map<String, dynamic> toMap() => {
        'placeId': placeId,
        'formattedAddress': formattedAddress,
        'mainText': mainText,
        'secondaryText': secondaryText,
        'lat': lat,
        'lng': lng,
        'lastUsedMs': lastUsedMs,
      };

  bool get isValid =>
      placeId.isNotEmpty && formattedAddress.isNotEmpty && lat != 0 && lng != 0;
}
