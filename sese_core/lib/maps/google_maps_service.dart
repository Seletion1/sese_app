import 'package:cloud_functions/cloud_functions.dart';
import 'package:flutter/foundation.dart';

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

/// Centralized Google Maps Platform client. EVERY web-service call
/// (autocomplete/details/geocode/directions) funnels through the
/// `googleMapsProxy` callable, which attaches the restricted server key —
/// there is deliberately no key, no `http` import, and no Google URL
/// anywhere in Dart.
///
/// All methods are best-effort and never throw raw errors: failures
/// surface as [GoogleMapsException] with a display-safe message, and the
/// repo convention (graceful degradation without Firebase) applies — a
/// missing Firebase app resolves to `offline`, never a crash.
class GoogleMapsService {
  final FirebaseFunctions? _functions;

  /// Test seam: replaces the callable round-trip entirely. Return the
  /// decoded `data` map the proxy would have sent (e.g.
  /// `{'predictions': [...]}`).
  @visibleForTesting
  static Future<Map<String, dynamic>> Function(
    String action,
    Map<String, dynamic> params,
  )? callableOverride;

  const GoogleMapsService([this._functions]);

  FirebaseFunctions? get _fx {
    if (_functions != null) return _functions;
    try {
      return FirebaseFunctions.instance;
    } catch (_) {
      return null;
    }
  }

  Future<Map<String, dynamic>> _call(
    String action,
    Map<String, dynamic> params,
  ) async {
    if (callableOverride != null) {
      return callableOverride!(action, params);
    }
    final fx = _fx;
    if (fx == null) {
      throw const GoogleMapsException(
        'offline',
        'Location search needs a connection.',
      );
    }
    try {
      final res = await fx
          .httpsCallable('googleMapsProxy')
          .call(<String, dynamic>{'action': action, ...params});
      final data = res.data;
      if (data is Map) return Map<String, dynamic>.from(data);
      throw const GoogleMapsException(
        'unavailable',
        'Location lookup failed. Please try again.',
      );
    } on FirebaseFunctionsException catch (e) {
      throw GoogleMapsException(_codeOf(e.code), _messageOf(e));
    } catch (e) {
      debugPrint('GoogleMapsService.$action failed: $e');
      throw const GoogleMapsException(
        'offline',
        'Location search needs a connection.',
      );
    }
  }

  static String _codeOf(String code) {
    switch (code) {
      case 'resource-exhausted':
        return 'quota';
      case 'not-found':
        return 'not-found';
      case 'unauthenticated':
      case 'permission-denied':
        return 'denied';
      case 'invalid-argument':
        return 'denied';
      default:
        return 'unavailable';
    }
  }

  static String _messageOf(FirebaseFunctionsException e) {
    final msg = e.message ?? '';
    if (msg.isNotEmpty) return msg;
    switch (e.code) {
      case 'resource-exhausted':
        return 'Search quota is exhausted. Try a recent location or try again later.';
      case 'not-found':
        return 'No matching places found.';
      case 'unauthenticated':
        return 'You must sign in to search.';
      default:
        return 'Location lookup failed. Please try again.';
    }
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
