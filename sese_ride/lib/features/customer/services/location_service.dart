import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:geolocator/geolocator.dart';
import 'package:http/http.dart' as http;
import 'package:latlong2/latlong.dart';
import 'package:sese_core/sese_core.dart';

/// Represents a place suggestion from an address search.
///
/// [placeId] is set for Google predictions (resolved to coordinates with
/// one Details call); cached locations carry coordinates directly with
/// [isFromCache] = true (0 API calls).
class PlaceSuggestion {
  final String description;
  final double lat;
  final double lng;
  final String? placeId;
  final String? mainText;
  final String? secondaryText;
  final String? tag;
  final bool isFromCache;
  final int useCount;

  PlaceSuggestion({
    required this.description,
    required this.lat,
    required this.lng,
    this.placeId,
    this.mainText,
    this.secondaryText,
    this.tag,
    this.isFromCache = false,
    this.useCount = 0,
  });

  LatLng get latLng => LatLng(lat, lng);

  /// Builds a [PlaceSuggestion] from a local zero-cost [RecentLocation].
  factory PlaceSuggestion.fromRecent(RecentLocation loc) {
    return PlaceSuggestion(
      description: loc.formattedAddress,
      mainText: loc.mainText,
      secondaryText: loc.secondaryText,
      lat: loc.lat,
      lng: loc.lng,
      placeId: loc.placeId,
      tag: loc.displayTag,
      isFromCache: true,
      useCount: loc.useCount,
    );
  }
}

/// GPS + Geocoding + Routing utilities, 100% Google Maps Platform.
///
///   - Reverse geocode: Google Geocoding API via the `googleMapsProxy`
///     callable (server holds the key — none exists in Dart).
///   - Forward geocode / Autocomplete: Google Places API via the proxy.
///   - Route geometry: Google Directions API via the proxy (encoded
///     polyline decoded client-side).
///
/// The legacy OSM Nominatim/OSRM direct calls are gone: every network
/// hop goes through the proxy, and every failure degrades to the same
/// fallbacks as before (coord string / empty list / straight line), so
/// the booking flow is never blocked by search.
///
/// Test seams are unchanged — widget tests keep working offline.
class LocationService {
  static final GoogleMapsService _maps = GoogleMapsService();

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

  /// Fast position cache for instant boot rendering.
  static LatLng? _cachedLastKnown;

  /// The last successfully resolved GPS position, cached in memory.\
  ///
  /// Safe to read synchronously \u2014 returns null until the first position fix
  /// has been obtained. Used to bias autocomplete suggestions around the
  /// user's area without an extra async round-trip.\
  static LatLng? get lastKnownPosition => _cachedLastKnown;

  /// Pre-warms location permissions and fetches last known position on boot.
  static Future<void> primeFastLocation() async {
    try {
      final enabled = await Geolocator.isLocationServiceEnabled();
      if (!enabled) return;
      final permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.always || permission == LocationPermission.whileInUse) {
        final lastKnown = await Geolocator.getLastKnownPosition();
        if (lastKnown != null) {
          _cachedLastKnown = LatLng(lastKnown.latitude, lastKnown.longitude);
        }
      }
    } catch (_) {}
  }

  /// Returns the current device position.
  ///
  /// Uses [Geolocator.getLastKnownPosition] for fast instant response, while
  /// fetching high-accuracy position in the background.
  static Future<LatLng?> getCurrentLatLng() async {
    if (customPositionProvider != null) {
      return customPositionProvider!();
    }
    try {
      final enabled = await Geolocator.isLocationServiceEnabled();
      if (!enabled) return _cachedLastKnown;

      var permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
      }
      if (permission == LocationPermission.denied ||
          permission == LocationPermission.deniedForever) {
        return _cachedLastKnown;
      }

      // Fast path 1: Return cached in-memory position if recent
      final lastKnown = await Geolocator.getLastKnownPosition().catchError((_) => null);
      if (lastKnown != null) {
        _cachedLastKnown = LatLng(lastKnown.latitude, lastKnown.longitude);
      }

      // Fast path 2: Try best-accuracy position with an 8 s deadline.
      // Using bestForNavigation (GPS + sensor fusion, < 10 m) rather than
      // the previous LocationAccuracy.high so every caller of this service
      // gets the same quality fix as customer_home_map_screen.  8 s gives
      // GPS adequate time on a cold start without indefinitely blocking.
      try {
        final pos = await Geolocator.getCurrentPosition(
          locationSettings: const LocationSettings(
            accuracy: LocationAccuracy.bestForNavigation,
            timeLimit: Duration(seconds: 8),
          ),
        );
        _cachedLastKnown = LatLng(pos.latitude, pos.longitude);
        return _cachedLastKnown;
      } catch (_) {
        // Fall back to last known position if current position times out
        if (_cachedLastKnown != null) return _cachedLastKnown;
        if (lastKnown != null) {
          return LatLng(lastKnown.latitude, lastKnown.longitude);
        }
        return null;
      }
    } catch (e) {
      debugPrint('LocationService.getCurrentLatLng error: $e');
      return _cachedLastKnown;
    }
  }

  // ── Reverse Geocode (Google Geocoding via proxy, Nominatim fallback) ────────

  /// Converts [lat]/[lng] into a clean, human-readable street address.
  ///
  /// Tries the Google Geocoding proxy first. When it returns a raw coordinate
  /// string (proxy offline / quota exhausted / key not provisioned) it
  /// immediately retries using OpenStreetMap Nominatim — a free, no-key
  /// reverse-geocoder. The raw-coord string is only shown when both services
  /// fail (no connection at all). This keeps the pickup field human-readable
  /// even during development before the `GOOGLE_MAPS_API_KEY` env-var is set.
  static Future<String> getCleanAddress(double lat, double lng) =>
      reverseGeocode(lat, lng);

  static Future<String> reverseGeocode(double lat, double lng) async {
    if (customReverseGeocodeProvider != null) {
      final addr = await customReverseGeocodeProvider!(lat, lng);
      CountryDetectionService.instance.updateFromAddress(addr);
      return addr;
    }
    // Hub feature pin: explicit 'google' skips Nominatim; explicit
    // 'cartodb' skips Google. Otherwise the chain decides the primary and
    // the other engine stays as fallback (search never goes single-point).
    final controller = MapConfigController.instance;
    final isGoogle = controller.geocodingNominatimOnly
        ? false
        : controller.geocodingGoogleOnly || controller.isGoogle;
    if (isGoogle) {
      // Primary: Google Geocoding proxy.
      final addr = await _maps.reverseGeocode(lat, lng);
      // Detect the raw-coord fallback format ("12.34567, 5.67890") and retry
      // with Nominatim so the user always sees a meaningful street address —
      // unless Hub pinned Google-only.
      final isRawCoord = RegExp(r'^-?\d+\.\d+,\s*-?\d+\.\d+$').hasMatch(addr.trim());
      if (!isRawCoord) {
        CountryDetectionService.instance.updateFromAddress(addr);
        return addr;
      }
      if (controller.geocodingGoogleOnly) {
        CountryDetectionService.instance.updateFromAddress(addr);
        return addr;
      }
      final fallback = await _nominatimReverseGeocode(lat, lng);
      final result = fallback.isNotEmpty ? fallback : addr;
      CountryDetectionService.instance.updateFromAddress(result);
      return result;
    } else {
      // Primary: OpenStreetMap Nominatim for OSM / CartoDB configurations.
      final fallback = await _nominatimReverseGeocode(lat, lng);
      if (fallback.isNotEmpty) {
        CountryDetectionService.instance.updateFromAddress(fallback);
        return fallback;
      }
      // Fallback to Google proxy if Nominatim is offline/slow — unless Hub
      // pinned Nominatim-only.
      if (controller.geocodingNominatimOnly) {
        CountryDetectionService.instance.updateFromAddress('');
        return '';
      }
      final addr = await _maps.reverseGeocode(lat, lng);
      CountryDetectionService.instance.updateFromAddress(addr);
      return addr;
    }
  }

  /// OpenStreetMap Nominatim reverse geocode — free, no API key.
  ///
  /// Used as a fallback when the Google proxy returns raw coordinates.
  /// Returns an empty string on any error so the caller can fall through
  /// to the raw-coord last-resort without any exception propagation.
  static Future<String> _nominatimReverseGeocode(
      double lat, double lng) async {
    try {
      final uri = Uri.parse(
        'https://nominatim.openstreetmap.org/reverse'
        '?format=jsonv2&lat=$lat&lon=$lng&addressdetails=1&accept-language=en',
      );
      final response = await http
          .get(uri, headers: {'User-Agent': 'SeSe-Ride-App/1.0'})
          .timeout(const Duration(seconds: 8));
      if (response.statusCode != 200) return '';
      final data = json.decode(response.body) as Map<String, dynamic>;
      // Prefer the display_name field (full address). Fall back to the
      // structured address components if display_name is missing.
      final displayName = (data['display_name'] as String?)?.trim() ?? '';
      if (displayName.isNotEmpty) return displayName;
      final address = data['address'] as Map<String, dynamic>?;
      if (address == null) return '';
      // Build a short readable string from the most useful components.
      final parts = <String>[
        address['road'] as String? ?? '',
        address['suburb'] as String? ??
            address['neighbourhood'] as String? ?? '',
        address['city'] as String? ??
            address['town'] as String? ??
            address['village'] as String? ?? '',
        address['state'] as String? ?? '',
      ].where((s) => s.isNotEmpty).toList();
      return parts.join(', ');
    } catch (e) {
      debugPrint('LocationService._nominatimReverseGeocode error: $e');
      return '';
    }
  }

  /// OpenStreetMap Nominatim search fallback — free, no API key.
  static Future<List<PlaceSuggestion>> _nominatimSearch(String query) async {
    try {
      final uri = Uri.parse(
        'https://nominatim.openstreetmap.org/search'
        '?format=jsonv2&q=${Uri.encodeComponent(query)}&addressdetails=1&accept-language=en&countrycodes=ng&limit=5',
      );
      final response = await http
          .get(uri, headers: {'User-Agent': 'SeSe-Ride-App/1.0'})
          .timeout(const Duration(seconds: 5));
      if (response.statusCode != 200) return [];
      final list = json.decode(response.body) as List<dynamic>;
      return list.map((item) {
        final map = item as Map<String, dynamic>;
        final displayName = (map['display_name'] as String?)?.trim() ?? query;
        final lat = double.tryParse(map['lat']?.toString() ?? '0') ?? 0;
        final lng = double.tryParse(map['lon']?.toString() ?? '0') ?? 0;
        return PlaceSuggestion(
          description: displayName,
          lat: lat,
          lng: lng,
          placeId: null,
        );
      }).where((s) => s.lat != 0 && s.lng != 0).toList();
    } catch (e) {
      debugPrint('LocationService._nominatimSearch error: $e');
      return [];
    }
  }

  // ── Forward Geocode (Google Places via proxy with Nominatim fallback) ────

  /// Converts a free-text [query] into a [LatLng] via Places Autocomplete +
  /// one Details call. Returns `null` on miss or network error.
  static Future<LatLng?> forwardGeocode(String query) async {
    final trimmed = query.trim();
    if (trimmed.isEmpty) return null;

    final isGoogle = MapConfigController.instance.isGoogle;
    if (isGoogle) {
      try {
        final details = await _maps.geocode(trimmed);
        if (details != null) return LatLng(details.lat, details.lng);
      } catch (e) {
        debugPrint('LocationService.forwardGeocode error: $e');
      }
      final nomResults = await _nominatimSearch(trimmed);
      if (nomResults.isNotEmpty) return nomResults.first.latLng;
      return null;
    } else {
      final nomResults = await _nominatimSearch(trimmed);
      if (nomResults.isNotEmpty) return nomResults.first.latLng;
      try {
        final details = await _maps.geocode(trimmed);
        if (details != null) return LatLng(details.lat, details.lng);
      } catch (_) {}
      return null;
    }
  }

  /// Fetches autocomplete predictions for [query] via the proxy, falling back to
  /// Nominatim search if proxy yields no predictions or fails.
  static Future<List<PlaceSuggestion>> fetchSuggestions(
    String query, {
    double? biasLat,
    double? biasLng,
  }) async {
    if (customSuggestionsProvider != null) {
      return customSuggestionsProvider!(query);
    }
    final trimmed = query.trim();
    if (trimmed.isEmpty) return [];

    // Hub feature pin (same rule as [reverseGeocode]): explicit 'google'
    // skips Nominatim; explicit 'cartodb' skips Google; otherwise the chain
    // decides the primary with the other as fallback.
    final controller = MapConfigController.instance;
    final isGoogle = controller.geocodingNominatimOnly
        ? false
        : controller.geocodingGoogleOnly || controller.isGoogle;
    if (isGoogle) {
      try {
        final predictions = await _maps.autocomplete(
          trimmed,
          lat: biasLat,
          lng: biasLng,
        );
        if (predictions.isNotEmpty) {
          return predictions
              .map((p) => PlaceSuggestion(
                    description: p.description.isNotEmpty
                        ? p.description
                        : [p.mainText, p.secondaryText]
                            .where((s) => s.isNotEmpty)
                            .join(', '),
                    mainText: p.mainText.isNotEmpty ? p.mainText : null,
                    secondaryText:
                        p.secondaryText.isNotEmpty ? p.secondaryText : null,
                    lat: 0,
                    lng: 0,
                    placeId: p.placeId,
                  ))
              .toList();
        }
      } catch (e) {
        debugPrint('LocationService.fetchSuggestions error: $e');
      }
      if (controller.geocodingGoogleOnly) return [];
      return _nominatimSearch(trimmed);
    } else {
      final nomResults = await _nominatimSearch(trimmed);
      if (nomResults.isNotEmpty) return nomResults;
      if (controller.geocodingNominatimOnly) return [];
      try {
        final predictions = await _maps.autocomplete(
          trimmed,
          lat: biasLat,
          lng: biasLng,
        );
        if (predictions.isNotEmpty) {
          return predictions
              .map((p) => PlaceSuggestion(
                    description: p.description.isNotEmpty
                        ? p.description
                        : [p.mainText, p.secondaryText]
                            .where((s) => s.isNotEmpty)
                            .join(', '),
                    mainText: p.mainText.isNotEmpty ? p.mainText : null,
                    secondaryText:
                        p.secondaryText.isNotEmpty ? p.secondaryText : null,
                    lat: 0,
                    lng: 0,
                    placeId: p.placeId,
                  ))
              .toList();
        }
      } catch (_) {}
      return [];
    }
  }

  /// Resolves a prediction's coordinates with one Details call. Returns
  /// null on failure (caller keeps the field unresolved, never blocked).
  /// Suggestions from cache or with existing coordinates resolve immediately (0 API calls).
  static Future<PlaceSuggestion?> resolvePrediction(
      PlaceSuggestion suggestion) async {
    if (suggestion.isFromCache ||
        (suggestion.lat != 0 && suggestion.lng != 0)) {
      return suggestion;
    }
    final placeId = suggestion.placeId;
    if (placeId == null || placeId.isEmpty) return suggestion;
    try {
      final details = await _maps.details(placeId);
      final display = details.displayAddress.isNotEmpty
          ? details.displayAddress
          : suggestion.description;
      final main = details.name.isNotEmpty
          ? details.name
          : (suggestion.mainText ?? display);
      return PlaceSuggestion(
        description: display,
        mainText: main,
        secondaryText: details.formattedAddress.isNotEmpty
            ? details.formattedAddress
            : suggestion.secondaryText,
        lat: details.lat,
        lng: details.lng,
        placeId: placeId,
      );
    } catch (e) {
      debugPrint('LocationService.resolvePrediction error: $e');
      return null;
    }
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

  // ── Route geometry (Google Directions → OSRM fallback) ───────────────────

  /// Full driving route: road polyline + distance (metres) + duration (seconds).
  ///
  /// Routing priority:
  /// 1. **Google Directions API** via the `googleMapsProxy` callable — traffic-
  ///    aware, highest accuracy for Nigeria road networks.
  /// 2. **OSRM public router** (`router.project-osrm.org`) — free, requires no
  ///    auth and no API key, good coverage of Lagos / South-West Nigeria. Used
  ///    whenever Google fails (auth race on startup, quota, network timeout).
  /// 3. **Empty result** — caller draws a straight pickup→dropoff line as an
  ///    absolute last resort so the booking flow is never blocked.
  ///
  /// [distanceM] and [durationS] are 0 when only the fallback straight line is
  /// used; callers should hide the distance/ETA badge in that case.
  static Future<({List<LatLng> points, int distanceM, int durationS})> fetchRoute(
    LatLng pickup,
    LatLng dropoff,
  ) async {
    // Test seam: customRouteProvider skips all network calls.
    if (customRouteProvider != null) {
      final pts = await customRouteProvider!(pickup, dropoff);
      return (points: pts, distanceM: 0, durationS: 0);
    }

    // ── 1. Google Directions (proxy callable) ─────────────────────────────
    try {
      final route = await _maps.directions(
        originLat: pickup.latitude,
        originLng: pickup.longitude,
        destLat: dropoff.latitude,
        destLng: dropoff.longitude,
      );
      if (route.points.isNotEmpty) {
        return (
          points: route.points.map((p) => LatLng(p.lat, p.lng)).toList(),
          distanceM: route.distanceM,
          durationS: route.durationS,
        );
      }
    } catch (e) {
      debugPrint('LocationService.fetchRoute: Google Directions failed: $e');
    }

    // ── 2. OSRM public router (free fallback) ─────────────────────────────
    try {
      final result = await _fetchOsrmRoute(pickup, dropoff);
      if (result.points.isNotEmpty) return result;
    } catch (e) {
      debugPrint('LocationService.fetchRoute: OSRM fallback failed: $e');
    }

    // ── 3. No road data — caller uses straight line ────────────────────────
    return (points: <LatLng>[], distanceM: 0, durationS: 0);
  }

  /// Fetches the driving route as road points (Directions overview
  /// polyline, decoded client-side). Returns an empty list on failure —
  /// callers fall back to a straight pickup→dropoff line.
  ///
  /// Thin wrapper around [fetchRoute] kept for backward compatibility with
  /// call sites that only need the point list (driver screens, live trip,
  /// proximity trigger service).
  static Future<List<LatLng>> fetchRoutePolyline(
    LatLng pickup,
    LatLng dropoff,
  ) async {
    final result = await fetchRoute(pickup, dropoff);
    return result.points;
  }

  /// Queries the OSRM public routing engine for a driving route.
  ///
  /// OSRM uses the same Google-compatible encoded polyline format when
  /// `geometries=polyline` is requested, so [GoogleMapsService.decodePolyline]
  /// decodes it correctly. The endpoint is stateless and unauthenticated.
  static Future<({List<LatLng> points, int distanceM, int durationS})>
      _fetchOsrmRoute(LatLng pickup, LatLng dropoff) async {
    // OSRM expects coordinates as lng,lat (longitude first).
    final uri = Uri.parse(
      'https://router.project-osrm.org/route/v1/driving/'
      '${pickup.longitude},${pickup.latitude};'
      '${dropoff.longitude},${dropoff.latitude}'
      '?overview=full&geometries=polyline',
    );
    final response =
        await http.get(uri).timeout(const Duration(seconds: 12));
    if (response.statusCode != 200) {
      throw Exception('OSRM HTTP ${response.statusCode}');
    }
    final body = jsonDecode(response.body) as Map<String, dynamic>;
    final code = body['code'] as String? ?? '';
    if (code != 'Ok') throw Exception('OSRM status: $code');

    final routes = body['routes'] as List<dynamic>?;
    final first = (routes != null && routes.isNotEmpty)
        ? routes[0] as Map<String, dynamic>?
        : null;
    if (first == null) throw Exception('OSRM: no routes returned');

    final encoded = first['geometry'] as String? ?? '';
    final distanceM = (first['distance'] as num? ?? 0).toInt();
    final durationS = (first['duration'] as num? ?? 0).toInt();

    if (encoded.isEmpty) throw Exception('OSRM: empty geometry');

    // Reuse the same decoder used for Google's encoded polyline — the format
    // is identical (precision 5, same zigzag encoding, same coordinate order).
    final decoded = GoogleMapsService.decodePolyline(encoded);
    return (
      points: decoded.map((p) => LatLng(p.lat, p.lng)).toList(),
      distanceM: distanceM,
      durationS: durationS,
    );
  }

  // ── Private helpers ────────────────────────────────────────────────────────
}

/// Service providing location autocomplete suggestions.
///
/// Thin delegation shim kept for backward compatibility with call sites
/// outside [LocationService]. Pass an optional [biasLatLng] to bias
/// autocomplete results around the user's current location.
class LocationAutocompleteService {
  static Future<List<PlaceSuggestion>> fetchSuggestions(
    String query, {
    LatLng? biasLatLng,
  }) =>
      LocationService.fetchSuggestions(
        query,
        biasLat: biasLatLng?.latitude,
        biasLng: biasLatLng?.longitude,
      );
}
