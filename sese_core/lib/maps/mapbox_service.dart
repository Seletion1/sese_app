import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import 'google_maps_service.dart';
import 'map_config_controller.dart';
import 'place_models.dart';

/// Centralized Mapbox Platform client for geocoding, search autocomplete,
/// and driving directions.
///
/// Ensures search queries and reverse-geocodes target high-granularity features
/// (`types=address,poi,neighborhood,locality`) so street-level results are never
/// truncated to broad neighborhood/area names alone.
class MapboxService {
  final http.Client _client;

  const MapboxService([http.Client? client]) : _client = client ?? const _DefaultHttpClient();

  String? _resolveToken(String? explicitToken) {
    if (explicitToken != null && explicitToken.trim().isNotEmpty) {
      return explicitToken.trim();
    }
    return MapConfigController.instance.currentConfig.resolvedMapboxToken;
  }

  /// Reverse geocode: converts [lat]/[lng] into a full, human-readable street address.
  ///
  /// Restricts place types to `address,poi,neighborhood,locality` so results always
  /// include street numbers and road names when available rather than broad regions.
  Future<String> reverseGeocode(
    double lat,
    double lng, {
    String? token,
  }) async {
    final activeToken = _resolveToken(token);
    if (activeToken == null || activeToken.isEmpty) return '';

    try {
      final uri = Uri.parse(
        'https://api.mapbox.com/geocoding/v5/mapbox.places/$lng,$lat.json'
        '?access_token=$activeToken'
        '&types=address,poi,neighborhood,locality'
        '&country=ng'
        '&language=en',
      );

      final response = await _client.get(uri).timeout(const Duration(seconds: 8));
      if (response.statusCode != 200) {
        debugPrint('MapboxService.reverseGeocode error: HTTP ${response.statusCode}');
        return '';
      }

      final data = json.decode(response.body) as Map<String, dynamic>;
      final features = data['features'] as List<dynamic>?;
      if (features == null || features.isEmpty) return '';

      final first = features.first as Map<String, dynamic>;
      return _extractFormattedName(first);
    } catch (e) {
      debugPrint('MapboxService.reverseGeocode failed: $e');
      return '';
    }
  }

  /// Places search / autocomplete with street-level bias and proximity.
  Future<List<PlacePrediction>> autocomplete(
    String query, {
    double? lat,
    double? lng,
    String? token,
  }) async {
    final trimmed = query.trim();
    if (trimmed.isEmpty) return [];

    final activeToken = _resolveToken(token);
    if (activeToken == null || activeToken.isEmpty) return [];

    try {
      var url = 'https://api.mapbox.com/geocoding/v5/mapbox.places/${Uri.encodeComponent(trimmed)}.json'
          '?access_token=$activeToken'
          '&types=address,poi,neighborhood,locality'
          '&country=ng'
          '&language=en'
          '&limit=5';

      if (lat != null && lng != null) {
        url += '&proximity=$lng,$lat';
      }

      final uri = Uri.parse(url);
      final response = await _client.get(uri).timeout(const Duration(seconds: 6));
      if (response.statusCode != 200) return [];

      final data = json.decode(response.body) as Map<String, dynamic>;
      final features = data['features'] as List<dynamic>?;
      if (features == null || features.isEmpty) return [];

      final predictions = <PlacePrediction>[];
      for (final item in features) {
        if (item is! Map<String, dynamic>) continue;
        final placeId = (item['id'] ?? '').toString();
        final placeName = _extractFormattedName(item);
        final text = (item['text'] ?? '').toString();
        final addressNum = (item['address'] ?? '').toString();
        final mainText = addressNum.isNotEmpty ? '$addressNum $text' : text;

        final contextList = item['context'] as List<dynamic>?;
        final secondaryParts = <String>[];
        if (contextList != null) {
          for (final ctx in contextList) {
            if (ctx is Map<String, dynamic> && ctx['text'] != null) {
              secondaryParts.add(ctx['text'].toString());
            }
          }
        }
        final secondaryText = secondaryParts.join(', ');

        predictions.add(
          PlacePrediction(
            placeId: placeId,
            description: placeName,
            mainText: mainText.isNotEmpty ? mainText : placeName,
            secondaryText: secondaryText,
          ),
        );
      }
      return predictions;
    } catch (e) {
      debugPrint('MapboxService.autocomplete failed: $e');
      return [];
    }
  }

  /// Forward geocode: resolves free-text [query] into coordinates and address details.
  Future<PlaceDetails?> geocode(
    String query, {
    double? lat,
    double? lng,
    String? token,
  }) async {
    final trimmed = query.trim();
    if (trimmed.isEmpty) return null;

    final activeToken = _resolveToken(token);
    if (activeToken == null || activeToken.isEmpty) return null;

    try {
      var url = 'https://api.mapbox.com/geocoding/v5/mapbox.places/${Uri.encodeComponent(trimmed)}.json'
          '?access_token=$activeToken'
          '&types=address,poi,neighborhood,locality'
          '&country=ng'
          '&language=en'
          '&limit=1';

      if (lat != null && lng != null) {
        url += '&proximity=$lng,$lat';
      }

      final response = await _client.get(Uri.parse(url)).timeout(const Duration(seconds: 6));
      if (response.statusCode != 200) return null;

      final data = json.decode(response.body) as Map<String, dynamic>;
      final features = data['features'] as List<dynamic>?;
      if (features == null || features.isEmpty) return null;

      final first = features.first as Map<String, dynamic>;
      final placeId = (first['id'] ?? '').toString();
      final placeName = _extractFormattedName(first);
      final center = first['center'] as List<dynamic>?;
      if (center == null || center.length < 2) return null;

      final resultLng = (center[0] as num).toDouble();
      final resultLat = (center[1] as num).toDouble();

      return PlaceDetails(
        placeId: placeId,
        lat: resultLat,
        lng: resultLng,
        formattedAddress: placeName,
        name: (first['text'] ?? placeName).toString(),
      );
    } catch (e) {
      debugPrint('MapboxService.geocode failed: $e');
      return null;
    }
  }

  /// Driving directions: computes optimal road route, distance, and duration.
  Future<GoogleRoute> directions({
    required double originLat,
    required double originLng,
    required double destLat,
    required double destLng,
    String? token,
  }) async {
    final activeToken = _resolveToken(token);
    if (activeToken == null || activeToken.isEmpty) {
      return const GoogleRoute(points: [], distanceM: 0, durationS: 0);
    }

    try {
      final url = 'https://api.mapbox.com/directions/v5/mapbox/driving/'
          '$originLng,$originLat;$destLng,$destLat'
          '?access_token=$activeToken'
          '&geometries=polyline'
          '&overview=full';

      final response = await _client.get(Uri.parse(url)).timeout(const Duration(seconds: 10));
      if (response.statusCode != 200) {
        return const GoogleRoute(points: [], distanceM: 0, durationS: 0);
      }

      final data = json.decode(response.body) as Map<String, dynamic>;
      final routes = data['routes'] as List<dynamic>?;
      if (routes == null || routes.isEmpty) {
        return const GoogleRoute(points: [], distanceM: 0, durationS: 0);
      }

      final first = routes.first as Map<String, dynamic>;
      final poly = (first['geometry'] ?? '').toString();
      final distance = (first['distance'] as num? ?? 0).round();
      final duration = (first['duration'] as num? ?? 0).round();

      return GoogleRoute(
        points: GoogleMapsService.decodePolyline(poly),
        distanceM: distance,
        durationS: duration,
      );
    } catch (e) {
      debugPrint('MapboxService.directions failed: $e');
      return const GoogleRoute(points: [], distanceM: 0, durationS: 0);
    }
  }

  static String _extractFormattedName(Map<String, dynamic> feature) {
    final placeName = (feature['place_name'] ?? '').toString().trim();
    final addressNum = (feature['address'] ?? '').toString().trim();
    final text = (feature['text'] ?? '').toString().trim();

    if (addressNum.isNotEmpty && text.isNotEmpty && !placeName.startsWith(addressNum)) {
      return '$addressNum $placeName';
    }
    return placeName.isNotEmpty ? placeName : text;
  }
}

class _DefaultHttpClient implements http.Client {
  const _DefaultHttpClient();

  @override
  Future<http.Response> get(Uri url, {Map<String, String>? headers}) => http.get(url, headers: headers);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
