import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:geolocator/geolocator.dart';
import 'package:http/http.dart' as http;
import 'package:latlong2/latlong.dart';

/// Represents a place suggestion from an address search.
class PlaceSuggestion {
  final String description;
  final double lat;
  final double lng;

  PlaceSuggestion({
    required this.description,
    required this.lat,
    required this.lng,
  });

  LatLng get latLng => LatLng(lat, lng);
}

/// GPS + Geocoding + Routing utilities powered 100% by OpenStreetMap.
///
///   - Reverse geocode: OSM Nominatim (`lat/lng` → human-readable address).
///   - Forward geocode / Autocomplete: OSM Nominatim search.
///   - Route geometry: OSRM public demo server (driving profile, GeoJSON).
///
/// No API key, no billing, no quota tied to a cloud account.
///
/// Production note: the public Nominatim (`nominatim.openstreetmap.org`) and
/// OSRM (`router.project-osrm.org`) demo endpoints carry fair-use limits
/// (Nominatim: max 1 req/s, valid `User-Agent` required). At scale, self-host
/// Nominatim + OSRM/Valhalla or front them with a caching backend (e.g. a
/// `seseRoutingHttp` Cloud Function) instead of calling them from clients.
///
/// All network calls are best-effort: failures return a fallback string /
/// empty list rather than throwing, so the booking flow is never blocked.
class LocationService {
  /// Identifies this app to the Nominatim fair-use policy, which requires a
  /// valid `User-Agent` (or Referer) on every request.
  static const String _userAgent = 'sese_ride/1.0.0 (Flutter; OpenStreetMap)';

  static const Duration _networkTimeout = Duration(seconds: 8);

  /// Test seams to mock location and reverse geocoding in tests.
  static Future<LatLng?> Function()? customPositionProvider;
  static Future<String> Function(double lat, double lng)? customReverseGeocodeProvider;

  /// Test seams for forward search, suggestions + route geometry (avoid network in tests).
  static Future<List<PlaceSuggestion>> Function(String query)?
      customSuggestionsProvider;
  static Future<({LatLng latLng, String displayName})?> Function(String query)?
      customSearchProvider;
  static Future<List<LatLng>> Function(LatLng pickup, LatLng dropoff)?
      customRouteProvider;

  /// Resets all test seams. Call in test tearDown.
  static void resetTestSeams() {
    customPositionProvider = null;
    customReverseGeocodeProvider = null;
    customSuggestionsProvider = null;
    customSearchProvider = null;
    customRouteProvider = null;
  }

  // ── GPS ────────────────────────────────────────────────────────────────────

  /// Returns the current device position.
  ///
  /// Requests permission if not granted. Returns `null` if location is
  /// unavailable or permission is denied (so the caller can show a fallback).
  static Future<LatLng?> getCurrentLatLng() async {
    if (customPositionProvider != null) {
      return customPositionProvider!();
    }
    try {
      final enabled = await Geolocator.isLocationServiceEnabled();
      if (!enabled) return null;

      var permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
      }
      if (permission == LocationPermission.denied ||
          permission == LocationPermission.deniedForever) {
        return null;
      }

      final pos = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.high,
          timeLimit: Duration(seconds: 10),
        ),
      );
      return LatLng(pos.latitude, pos.longitude);
    } catch (e) {
      debugPrint('LocationService.getCurrentLatLng error: $e');
      return null;
    }
  }

  // ── Reverse Geocode (OSM Nominatim) ────────────────────────────────────────

  /// Converts [lat]/[lng] into a clean, human-readable street address.
  ///
  /// Uses OSM Nominatim reverse geocoding with mandatory attribution.
  /// Example result: `"14 Olafiranye St, Isawo, Lagos"`.
  /// Falls back to `"lat, lng"` string on any error.
  static Future<String> getCleanAddress(double lat, double lng) =>
      reverseGeocode(lat, lng);

  static Future<String> reverseGeocode(double lat, double lng) async {
    if (customReverseGeocodeProvider != null) {
      return customReverseGeocodeProvider!(lat, lng);
    }
    try {
      final uri = Uri.parse(
        'https://nominatim.openstreetmap.org/reverse'
        '?format=jsonv2&lat=$lat&lon=$lng&zoom=18&addressdetails=1',
      );
      final response = await http
          .get(uri, headers: {'User-Agent': _userAgent})
          .timeout(_networkTimeout);

      if (response.statusCode != 200) {
        return _fallbackCoord(lat, lng);
      }
      final json = jsonDecode(response.body) as Map<String, dynamic>;
      if (json.containsKey('error')) {
        debugPrint('Nominatim reverse-geocode: ${json['error']}');
        return _fallbackCoord(lat, lng);
      }
      final displayName = json['display_name'] as String?;
      if (displayName != null && displayName.isNotEmpty) {
        return _shortenDisplayName(displayName);
      }
      return _fallbackCoord(lat, lng);
    } catch (e) {
      debugPrint('LocationService.reverseGeocode error: $e');
      return _fallbackCoord(lat, lng);
    }
  }

  // ── Forward Geocode (OSM Nominatim search) ─────────────────────────────────

  /// Converts a free-text [query] into a [LatLng] via OSM Nominatim search.
  ///
  /// Returns `null` if no result found or on network error.
  static Future<LatLng?> forwardGeocode(String query) async {
    final trimmed = query.trim();
    if (trimmed.isEmpty) return null;
    try {
      final results = await _nominatimSearch(trimmed, limit: 1);
      if (results.isEmpty) return null;
      return results.first.latLng;
    } catch (e) {
      debugPrint('LocationService.forwardGeocode error: $e');
      return null;
    }
  }

  /// Fetches autocomplete suggestions for a given [query] via OSM Nominatim.
  ///
  /// Returns a list of [PlaceSuggestion] with cleaned street descriptions
  /// and lat/lng coordinates. Returns an empty list on failure or empty input.
  static Future<List<PlaceSuggestion>> fetchSuggestions(String query) async {
    if (customSuggestionsProvider != null) {
      return customSuggestionsProvider!(query);
    }
    final trimmed = query.trim();
    if (trimmed.isEmpty) return [];
    try {
      return await _nominatimSearch(trimmed, limit: 5);
    } catch (e) {
      debugPrint('LocationService.fetchSuggestions error: $e');
      return [];
    }
  }

  static Future<List<PlaceSuggestion>> _nominatimSearch(
    String query, {
    int limit = 5,
  }) async {
    final uri = Uri.parse(
      'https://nominatim.openstreetmap.org/search'
      '?format=jsonv2&q=${Uri.encodeComponent(query)}'
      '&addressdetails=1&limit=$limit&accept-language=en',
    );
    final response = await http
        .get(uri, headers: {'User-Agent': _userAgent})
        .timeout(_networkTimeout);

    if (response.statusCode != 200) return [];
    final json = jsonDecode(response.body) as List<dynamic>;
    final suggestions = <PlaceSuggestion>[];
    for (final item in json) {
      final map = item as Map<String, dynamic>;
      // Nominatim returns coordinates as strings.
      final lat = double.tryParse('${map['lat']}');
      final lng = double.tryParse('${map['lon']}');
      final displayName = (map['display_name'] ?? '').toString();
      if (lat != null && lng != null && displayName.isNotEmpty) {
        suggestions.add(PlaceSuggestion(
          description: _shortenDisplayName(displayName),
          lat: lat,
          lng: lng,
        ));
      }
    }
    return suggestions;
  }

  /// Returns the display name and lat/lng for a forward-geocode result.
  static Future<({LatLng latLng, String displayName})?> searchAddress(
      String query) async {
    if (customSearchProvider != null) {
      return customSearchProvider!(query);
    }
    final suggestions = await fetchSuggestions(query);
    if (suggestions.isEmpty) return null;
    return (latLng: suggestions.first.latLng, displayName: suggestions.first.description);
  }

  // ── Route geometry (OSRM) ──────────────────────────────────────────────────

  /// Fetches driving route points from the OSRM public demo server.
  ///
  /// Returns the route as a list of [LatLng] points decoded from the GeoJSON
  /// geometry (`[lng, lat]` pairs). Returns an empty list on failure.
  static Future<List<LatLng>> fetchRoutePolyline(
    LatLng pickup,
    LatLng dropoff,
  ) async {
    if (customRouteProvider != null) {
      return customRouteProvider!(pickup, dropoff);
    }
    try {
      final url = Uri.parse(
        'https://router.project-osrm.org/route/v1/driving/'
        '${pickup.longitude},${pickup.latitude};'
        '${dropoff.longitude},${dropoff.latitude}'
        '?overview=full&geometries=geojson',
      );
      final response = await http
          .get(url, headers: {'User-Agent': _userAgent})
          .timeout(const Duration(seconds: 10));

      if (response.statusCode != 200) {
        debugPrint('OSRM route error: ${response.statusCode} ${response.body}');
        return [];
      }

      final json = jsonDecode(response.body) as Map<String, dynamic>;
      if (json['code'] != 'Ok') {
        debugPrint('OSRM route code: ${json['code']}');
        return [];
      }
      final routes = json['routes'] as List<dynamic>?;
      if (routes == null || routes.isEmpty) return [];

      final geometry =
          (routes.first as Map<String, dynamic>)['geometry'] as Map<String, dynamic>?;
      final coordinates = geometry?['coordinates'] as List<dynamic>?;
      if (coordinates == null || coordinates.isEmpty) return [];

      // GeoJSON positions are [longitude, latitude].
      return coordinates.map((point) {
        final pair = point as List<dynamic>;
        final lng = (pair[0] as num).toDouble();
        final lat = (pair[1] as num).toDouble();
        return LatLng(lat, lng);
      }).toList();
    } catch (e) {
      debugPrint('LocationService.fetchRoutePolyline error: $e');
      return [];
    }
  }

  // ── Private helpers ────────────────────────────────────────────────────────

  static String _fallbackCoord(double lat, double lng) =>
      '${lat.toStringAsFixed(5)}, ${lng.toStringAsFixed(5)}';

  /// Shortens a long display name to the first 3-4 meaningful parts.
  static String _shortenDisplayName(String displayName) {
    final parts = displayName.split(', ');
    if (parts.length <= 4) return displayName;
    return parts.take(4).join(', ');
  }
}

/// Service providing location autocomplete suggestions.
class LocationAutocompleteService {
  static Future<List<PlaceSuggestion>> fetchSuggestions(String query) =>
      LocationService.fetchSuggestions(query);
}
