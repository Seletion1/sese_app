import 'dart:convert';

import 'package:cloud_functions/cloud_functions.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import 'map_config_controller.dart';
import 'place_models.dart';

/// User-safe failure from the Maps proxy. [message] may be shown verbatim.
class GoogleMapsException implements Exception {
  /// Machine code: `offline`, `quota`, `not-found`, `unavailable`, `denied`.
  final String code;
  final String message;

  const GoogleMapsException(this.code, this.message);

  @override
  String toString() => 'GoogleMapsException($code): $message';
}

/// Centralized Google Maps Platform client.
///
/// Uses the live platform-restricted Google Maps API key configured in
/// SeseHub (`system_config/api_keys` via [MapConfigController]) with zero
/// hardcoded keys.
///
/// All methods are best-effort and never throw raw errors: failures
/// surface as [GoogleMapsException] with a display-safe message.
class GoogleMapsService {
  // ignore: unused_field
  final FirebaseFunctions? _functions;
  final http.Client? _client;

  /// Test seam: replaces the remote round-trip entirely. Return the
  /// decoded `data` map (e.g. `{'predictions': [...]}`).
  @visibleForTesting
  static Future<Map<String, dynamic>> Function(
    String action,
    Map<String, dynamic> params,
  )? callableOverride;

  const GoogleMapsService([
    this._functions,
    http.Client? client,
  ]) : _client = client;

  String _resolveApiKey() {
    final cfg = MapConfigController.instance.currentConfig;
    return cfg.resolvedGoogleHttpKey;
  }

  Future<Map<String, dynamic>> _call(
    String action,
    Map<String, dynamic> params,
  ) async {
    if (callableOverride != null) {
      return callableOverride!(action, params);
    }

    final cfg = MapConfigController.instance.currentConfig;
    final apiKey = _resolveApiKey();
    if (apiKey.isEmpty) {
      if (cfg.hasValidGoogleKey) {
        debugPrint(
          'GoogleMapsService.$action blocked: native SDK key is present, '
          'but google_maps.web_key is empty in SeseHub. Refusing to send '
          'platform-restricted SDK key to HTTP endpoint.',
        );
        throw const GoogleMapsException(
          'unconfigured',
          'Google Maps Web API key (web_key) is not configured in SeseHub.',
        );
      }
      throw const GoogleMapsException(
        'unconfigured',
        'Google Maps API key is not configured in SeseHub.',
      );
    }

    try {
      switch (action) {
        case 'autocomplete':
          return await _restAutocomplete(apiKey, params);
        case 'details':
          return await _restDetails(apiKey, params);
        case 'geocode':
          return await _restGeocode(apiKey, params);
        case 'reverseGeocode':
          return await _restReverseGeocode(apiKey, params);
        case 'directions':
          return await _restDirections(apiKey, params);
        default:
          throw const GoogleMapsException(
            'unavailable',
            'Unsupported Google Maps action.',
          );
      }
    } on GoogleMapsException {
      rethrow;
    } catch (e) {
      debugPrint('GoogleMapsService.$action failed: $e');
      throw const GoogleMapsException(
        'offline',
        'Location search needs a connection.',
      );
    }
  }

  Future<Map<String, dynamic>> _getJson(Uri uri) async {
    final client = _client ?? http.Client();
    final http.Response response;
    try {
      response = await client.get(uri).timeout(const Duration(seconds: 8));
    } finally {
      if (_client == null) client.close();
    }
    if (response.statusCode != 200) {
      throw GoogleMapsException(
        'unavailable',
        'Location lookup failed (HTTP ${response.statusCode}).',
      );
    }
    final decoded = json.decode(response.body);
    if (decoded is! Map) {
      throw const GoogleMapsException(
        'unavailable',
        'Location lookup failed. Please try again.',
      );
    }
    final data = Map<String, dynamic>.from(decoded);
    final status = (data['status'] ?? '').toString().toUpperCase();
    if (status == 'OK') return data;
    if (status == 'ZERO_RESULTS') {
      throw const GoogleMapsException('not-found', 'No matching places found.');
    }
    if (status == 'OVER_QUERY_LIMIT' || status == 'OVER_DAILY_LIMIT') {
      throw const GoogleMapsException(
        'quota',
        'Search quota is exhausted. Try a recent location or try again later.',
      );
    }
    if (status == 'REQUEST_DENIED' || status == 'INVALID_REQUEST') {
      final errMsg =
          (data['error_message'] ?? 'Google Maps request denied.').toString();
      debugPrint('GoogleMapsService $status (${uri.path}): $errMsg');
      throw GoogleMapsException(
        'denied',
        errMsg,
      );
    }
    throw const GoogleMapsException(
      'unavailable',
      'Location lookup failed. Please try again.',
    );
  }

  Future<Map<String, dynamic>> _restAutocomplete(
    String apiKey,
    Map<String, dynamic> params,
  ) async {
    final query = <String, String>{
      'input': (params['input'] ?? '').toString(),
      'components': 'country:ng',
      'key': apiKey,
    };
    final lat = params['lat'];
    final lng = params['lng'];
    if (lat != null && lng != null) {
      query['location'] = '$lat,$lng';
      query['radius'] = '50000';
    }
    final uri = Uri.https(
      'maps.googleapis.com',
      '/maps/api/place/autocomplete/json',
      query,
    );
    final data = await _getJson(uri);
    final rawPreds = data['predictions'] as List? ?? const [];
    final normalized = rawPreds.whereType<Map>().map((raw) {
      final p = Map<String, dynamic>.from(raw);
      final fmt = p['structured_formatting'] is Map
          ? Map<String, dynamic>.from(p['structured_formatting'] as Map)
          : <String, dynamic>{};
      return <String, dynamic>{
        'placeId': (p['place_id'] ?? '').toString(),
        'description': (p['description'] ?? '').toString(),
        'mainText': (fmt['main_text'] ?? '').toString(),
        'secondaryText': (fmt['secondary_text'] ?? '').toString(),
      };
    }).toList();
    return {'predictions': normalized};
  }

  Future<Map<String, dynamic>> _restDetails(
    String apiKey,
    Map<String, dynamic> params,
  ) async {
    final uri = Uri.https(
      'maps.googleapis.com',
      '/maps/api/place/details/json',
      {
        'place_id': (params['input'] ?? '').toString(),
        'fields': 'place_id,name,formatted_address,geometry',
        'key': apiKey,
      },
    );
    final data = await _getJson(uri);
    final result = data['result'] is Map
        ? Map<String, dynamic>.from(data['result'] as Map)
        : <String, dynamic>{};
    final geom = result['geometry'] is Map
        ? Map<String, dynamic>.from(result['geometry'] as Map)
        : <String, dynamic>{};
    final loc = geom['location'] is Map
        ? Map<String, dynamic>.from(geom['location'] as Map)
        : <String, dynamic>{};
    return {
      'details': {
        'placeId': (result['place_id'] ?? params['input'] ?? '').toString(),
        'name': (result['name'] ?? '').toString(),
        'formattedAddress': (result['formatted_address'] ?? '').toString(),
        'lat': (loc['lat'] as num?)?.toDouble() ?? 0.0,
        'lng': (loc['lng'] as num?)?.toDouble() ?? 0.0,
      },
    };
  }

  Future<Map<String, dynamic>> _restGeocode(
    String apiKey,
    Map<String, dynamic> params,
  ) async {
    final uri = Uri.https(
      'maps.googleapis.com',
      '/maps/api/geocode/json',
      {
        'address': (params['input'] ?? '').toString(),
        'components': 'country:NG',
        'key': apiKey,
      },
    );
    final data = await _getJson(uri);
    final results = data['results'] as List? ?? const [];
    if (results.isEmpty || results.first is! Map) {
      throw const GoogleMapsException('not-found', 'No matching places found.');
    }
    final first = Map<String, dynamic>.from(results.first as Map);
    final geom = first['geometry'] is Map
        ? Map<String, dynamic>.from(first['geometry'] as Map)
        : <String, dynamic>{};
    final loc = geom['location'] is Map
        ? Map<String, dynamic>.from(geom['location'] as Map)
        : <String, dynamic>{};
    final formatted = (first['formatted_address'] ?? '').toString();
    return {
      'address': {
        'placeId': (first['place_id'] ?? '').toString(),
        'name': formatted,
        'formattedAddress': formatted,
        'lat': (loc['lat'] as num?)?.toDouble() ?? 0.0,
        'lng': (loc['lng'] as num?)?.toDouble() ?? 0.0,
      },
    };
  }

  Future<Map<String, dynamic>> _restReverseGeocode(
    String apiKey,
    Map<String, dynamic> params,
  ) async {
    final uri = Uri.https(
      'maps.googleapis.com',
      '/maps/api/geocode/json',
      {
        'latlng': '${params['lat']},${params['lng']}',
        'key': apiKey,
      },
    );
    final data = await _getJson(uri);
    final results = data['results'] as List? ?? const [];
    if (results.isEmpty || results.first is! Map) {
      throw const GoogleMapsException('not-found', 'No address found.');
    }
    final first = Map<String, dynamic>.from(results.first as Map);
    return {
      'address': (first['formatted_address'] ?? '').toString(),
    };
  }

  Future<Map<String, dynamic>> _restDirections(
    String apiKey,
    Map<String, dynamic> params,
  ) async {
    final uri = Uri.https(
      'maps.googleapis.com',
      '/maps/api/directions/json',
      {
        'origin': '${params['originLat']},${params['originLng']}',
        'destination': '${params['destLat']},${params['destLng']}',
        'mode': 'driving',
        'key': apiKey,
      },
    );
    final data = await _getJson(uri);
    final routes = data['routes'] as List? ?? const [];
    if (routes.isEmpty || routes.first is! Map) {
      throw const GoogleMapsException('not-found', 'No route found.');
    }
    final first = Map<String, dynamic>.from(routes.first as Map);
    final overview = first['overview_polyline'] is Map
        ? Map<String, dynamic>.from(first['overview_polyline'] as Map)
        : <String, dynamic>{};
    final legs = first['legs'] as List? ?? const [];
    int distanceM = 0;
    int durationS = 0;
    if (legs.isNotEmpty && legs.first is Map) {
      final leg = Map<String, dynamic>.from(legs.first as Map);
      final dist = leg['distance'] is Map ? leg['distance'] as Map : const {};
      final dur = leg['duration'] is Map ? leg['duration'] as Map : const {};
      distanceM = (dist['value'] as num?)?.toInt() ?? 0;
      durationS = (dur['value'] as num?)?.toInt() ?? 0;
    }
    return {
      'polyline': (overview['points'] ?? '').toString(),
      'distanceM': distanceM,
      'durationS': durationS,
    };
  }

  /// Places Autocomplete (Nigeria-biased server-side). Empty query returns
  /// immediately with no call — the UI shows recents instead.
  Future<List<PlacePrediction>> autocomplete(
    String query, {
    double? lat,
    double? lng,
  }) async {
    if (query.trim().isEmpty) return [];
    final params = <String, dynamic>{'input': query.trim()};
    if (lat != null && lng != null) {
      params['lat'] = lat;
      params['lng'] = lng;
    }
    try {
      final data = await _call('autocomplete', params);
      final list = data['predictions'];
      if (list is! List) return [];
      return list
          .whereType<Map>()
          .map((m) => PlacePrediction.fromMap(
              Map<String, dynamic>.from(m)))
          .where((p) => p.placeId.isNotEmpty)
          .toList();
    } on GoogleMapsException catch (e) {
      if (e.code == 'not-found') return [];
      rethrow;
    }
  }

  /// Place Details: coordinates + formatted address for a prediction.
  Future<PlaceDetails> details(String placeId) async {
    if (placeId.isEmpty) {
      throw const GoogleMapsException('denied', 'Invalid place selection.');
    }
    final data = await _call('details', {'input': placeId});
    final raw = data['details'];
    if (raw is! Map) {
      throw const GoogleMapsException(
        'not-found',
        'That place has no coordinates.',
      );
    }
    return PlaceDetails.fromMap(Map<String, dynamic>.from(raw));
  }

  /// Forward geocode: free text → first match (or null, never throws for
  /// misses — misses are normal UX, not errors).
  Future<PlaceDetails?> geocode(String query) async {
    if (query.trim().isEmpty) return null;
    try {
      final data = await _call('geocode', {'input': query.trim()});
      final raw = data['address'];
      if (raw is! Map) return null;
      return PlaceDetails.fromMap(Map<String, dynamic>.from(raw));
    } on GoogleMapsException catch (e) {
      if (e.code == 'not-found') return null;
      rethrow;
    }
  }

  /// Reverse geocode: coordinates → human address. Falls back to a
  /// `"lat, lng"` string on any error (never blocks the booking flow).
  Future<String> reverseGeocode(double lat, double lng) async {
    try {
      final data = await _call('reverseGeocode', {'lat': lat, 'lng': lng});
      final address = (data['address'] ?? '').toString();
      return address.isNotEmpty
          ? address
          : _fallbackCoord(lat, lng);
    } on GoogleMapsException {
      return _fallbackCoord(lat, lng);
    }
  }

  /// Driving route: decoded road polyline + distance/duration. Empty
  /// points on any failure — callers fall back to a straight line.
  Future<GoogleRoute> directions({
    required double originLat,
    required double originLng,
    required double destLat,
    required double destLng,
  }) async {
    try {
      final data = await _call('directions', {
        'originLat': originLat,
        'originLng': originLng,
        'destLat': destLat,
        'destLng': destLng,
      });
      final poly = (data['polyline'] ?? '').toString();
      return GoogleRoute(
        points: decodePolyline(poly),
        distanceM: (data['distanceM'] as num? ?? 0).toInt(),
        durationS: (data['durationS'] as num? ?? 0).toInt(),
      );
    } on GoogleMapsException {
      return const GoogleRoute(points: [], distanceM: 0, durationS: 0);
    }
  }

  static String _fallbackCoord(double lat, double lng) =>
      '${lat.toStringAsFixed(5)}, ${lng.toStringAsFixed(5)}';

  /// Decodes a Google encoded polyline into `[lat, lng]` pairs.
  /// Pure function — no platform, no network, unit-testable.
  static List<({double lat, double lng})> decodePolyline(String encoded) {
    final points = <({double lat, double lng})>[];
    var index = 0;
    var lat = 0;
    var lng = 0;
    while (index < encoded.length) {
      var shift = 0;
      var result = 0;
      int byte;
      do {
        byte = encoded.codeUnitAt(index++) - 63;
        result |= (byte & 0x1f) << shift;
        shift += 5;
      } while (byte >= 0x20);
      final dLat = (result & 1) != 0 ? ~(result >> 1) : (result >> 1);
      lat += dLat;
      shift = 0;
      result = 0;
      do {
        byte = encoded.codeUnitAt(index++) - 63;
        result |= (byte & 0x1f) << shift;
        shift += 5;
      } while (byte >= 0x20);
      final dLng = (result & 1) != 0 ? ~(result >> 1) : (result >> 1);
      lng += dLng;
      points.add((lat: lat / 1e5, lng: lng / 1e5));
    }
    return points;
  }
}

/// Road route: decoded points plus totals (0s when unresolved).
class GoogleRoute {
  final List<({double lat, double lng})> points;
  final int distanceM;
  final int durationS;

  const GoogleRoute({
    required this.points,
    required this.distanceM,
    required this.durationS,
  });
}
