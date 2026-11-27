import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
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
  static final MapboxService _mapbox = const MapboxService();

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

      final permission = await Geolocator.checkPermission();
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
        if (pos.isMocked) {
          debugPrint('LocationService: Fake GPS / Mock Location detected.');
          return _cachedLastKnown;
        }
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

    final controller = MapConfigController.instance;
    final provider = controller.providerTypeForFeatureOrNull(MapFeature.geocoding);
    final fallbackCoord = '${lat.toStringAsFixed(5)}, ${lng.toStringAsFixed(5)}';

    if (provider == null) {
      return fallbackCoord;
    }

    bool isRaw(String s) =>
        s.trim().isEmpty || RegExp(r'^-?\d+\.\d+,\s*-?\d+\.\d+$').hasMatch(s.trim());

    if (provider == MapProviderType.mapbox) {
      final mbAddr = await _mapbox.reverseGeocode(lat, lng);
      if (!isRaw(mbAddr)) {
        CountryDetectionService.instance.updateFromAddress(mbAddr);
        return mbAddr;
      }
      return fallbackCoord;
    }

    final gAddr = await _maps.reverseGeocode(lat, lng);
    if (!isRaw(gAddr)) {
      CountryDetectionService.instance.updateFromAddress(gAddr);
      return gAddr;
    }
    return fallbackCoord;
  }

  // ── Forward Geocode (strictly follows active Hub provider) ────────────────

  /// Converts a free-text [query] into a [LatLng] using the active Hub provider.
  static Future<LatLng?> forwardGeocode(String query) async {
    final trimmed = query.trim();
    if (trimmed.isEmpty) return null;

    final provider = MapConfigController.instance
        .providerTypeForFeatureOrNull(MapFeature.geocoding);
    if (provider == null) return null;

    if (provider == MapProviderType.mapbox) {
      try {
        final mb = await _mapbox.geocode(trimmed);
        if (mb != null) return LatLng(mb.lat, mb.lng);
      } catch (e) {
        debugPrint('LocationService.forwardGeocode Mapbox error: $e');
      }
      return null;
    }

    try {
      final details = await _maps.geocode(trimmed);
      if (details != null) return LatLng(details.lat, details.lng);
    } catch (e) {
      debugPrint('LocationService.forwardGeocode Google error: $e');
    }
    return null;
  }

  /// Fetches autocomplete predictions for [query] using the active Hub provider.
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

    final provider = MapConfigController.instance
        .providerTypeForFeatureOrNull(MapFeature.geocoding);
    if (provider == null) return [];

    List<PlaceSuggestion> toSuggestions(List<PlacePrediction> preds) => preds
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

    if (provider == MapProviderType.mapbox) {
      try {
        final mb = await _mapbox.autocomplete(trimmed, lat: biasLat, lng: biasLng);
        return toSuggestions(mb);
      } catch (e) {
        debugPrint('LocationService.fetchSuggestions Mapbox error: $e');
        return [];
      }
    }

    try {
      final predictions = await _maps.autocomplete(
        trimmed,
        lat: biasLat,
        lng: biasLng,
      );
      return toSuggestions(predictions);
    } catch (e) {
      debugPrint('LocationService.fetchSuggestions Google error: $e');
      return [];
    }
  }

  /// Resolves a prediction's coordinates with one Details call using the active
  /// Hub provider. Returns null on failure or when unconfigured.
  static Future<PlaceSuggestion?> resolvePrediction(
      PlaceSuggestion suggestion) async {
    if (suggestion.isFromCache ||
        (suggestion.lat != 0 && suggestion.lng != 0)) {
      return suggestion;
    }
    final placeId = suggestion.placeId;
    if (placeId == null || placeId.isEmpty) return suggestion;

    final provider = MapConfigController.instance
        .providerTypeForFeatureOrNull(MapFeature.geocoding);
    if (provider == null) return null;

    if (provider == MapProviderType.mapbox) {
      try {
        final details = await _mapbox.geocode(suggestion.description);
        if (details != null) {
          return PlaceSuggestion(
            description: details.formattedAddress,
            mainText: details.name,
            secondaryText: suggestion.secondaryText,
            lat: details.lat,
            lng: details.lng,
            placeId: placeId,
          );
        }
      } catch (e) {
        debugPrint('LocationService.resolvePrediction Mapbox error: $e');
      }
      return null;
    }

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
      debugPrint('LocationService.resolvePrediction Google error: $e');
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

  // ── Route geometry (Google Directions → Mapbox → OSRM fallback chain) ────

  /// Full driving route: road polyline + distance (metres) + duration (seconds).
  ///
  /// Routing priority:
  /// 1. **Google Directions API** via the `googleMapsProxy` callable — traffic-aware.
  /// 2. **Mapbox Directions API** — turn-by-turn routing with traffic metrics.
  /// 3. **OSRM public router** (`router.project-osrm.org`) — free, requires no key.
  /// 4. **Empty result** — caller draws a straight line as last resort.
  static Future<({List<LatLng> points, int distanceM, int durationS})> fetchRoute(
    LatLng pickup,
    LatLng dropoff,
  ) async {
    // Test seam: customRouteProvider skips all network calls.
    if (customRouteProvider != null) {
      final pts = await customRouteProvider!(pickup, dropoff);
      return (points: pts, distanceM: 0, durationS: 0);
    }

    final provider = MapConfigController.instance
        .providerTypeForFeatureOrNull(MapFeature.routing);
    if (provider == null) {
      return (points: <LatLng>[], distanceM: 0, durationS: 0);
    }

    if (provider == MapProviderType.mapbox) {
      try {
        final route = await _mapbox.directions(
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
        debugPrint('LocationService.fetchRoute: Mapbox Directions failed: $e');
      }
      return (points: <LatLng>[], distanceM: 0, durationS: 0);
    }

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

    return (points: <LatLng>[], distanceM: 0, durationS: 0);
  }

  /// Fetches the driving route as road points (Directions overview
  /// polyline, decoded client-side). Returns an empty list on failure —
  /// callers fall back to a straight pickup→dropoff line.
  ///
  /// Thin wrapper around [fetchRoute] kept for backward compatibility with
  /// call sites that only need the point list (driver screens, live trip,
  /// proximity trigger service).
  ///
  /// Guarantees uninterrupted navigation display: if the routing engine fails
  /// or returns <2 points, automatically falls back to a straight-line vector
  /// between [pickup] and [dropoff].
  static Future<List<LatLng>> fetchRoutePolyline(
    LatLng pickup,
    LatLng dropoff,
  ) async {
    final result = await fetchRoute(pickup, dropoff);
    if (result.points.length >= 2) return result.points;
    return [pickup, dropoff];
  }

  /// Calculates remaining route distance in meters along the polyline path
  /// from [currentPos] to the end of [routePoints].
  static double calculateRemainingRouteDistanceM(
    LatLng currentPos,
    List<LatLng> routePoints, {
    LatLng? fallbackDestination,
  }) {
    if (routePoints.isEmpty) {
      if (fallbackDestination != null && currentPos.latitude != 0) {
        return const Distance().as(LengthUnit.Meter, currentPos, fallbackDestination);
      }
      return 0.0;
    }
    if (routePoints.length == 1) {
      return const Distance().as(LengthUnit.Meter, currentPos, routePoints.first);
    }

    int closestIdx = 0;
    double minDistance = double.infinity;
    for (int i = 0; i < routePoints.length; i++) {
      final dist = const Distance().as(LengthUnit.Meter, currentPos, routePoints[i]);
      if (dist < minDistance) {
        minDistance = dist;
        closestIdx = i;
      }
    }

    double totalM = const Distance().as(
      LengthUnit.Meter,
      currentPos,
      routePoints[closestIdx],
    );

    for (int i = closestIdx; i < routePoints.length - 1; i++) {
      totalM += const Distance().as(
        LengthUnit.Meter,
        routePoints[i],
        routePoints[i + 1],
      );
    }

    return totalM;
  }

  /// Fetches complete route details including step-by-step turn guidance instructions.
  static Future<
      ({
        List<LatLng> points,
        int distanceM,
        int durationS,
        List<RouteStep> steps
      })> fetchRouteDetails(LatLng pickup, LatLng dropoff) async {
    final route = await fetchRoute(pickup, dropoff);
    final steps = route.points.length >= 2
        ? _generateFallbackSteps(route.points, pickup, dropoff)
        : <RouteStep>[];
    return (
      points: route.points,
      distanceM: route.distanceM,
      durationS: route.durationS,
      steps: steps,
    );
  }

  /// Computes compass bearing in degrees (0–360° clockwise from north)
  /// between two geographical coordinates [start] and [end].
  static double calculateBearing(LatLng start, LatLng end) {
    final startLat = start.latitude * (math.pi / 180.0);
    final startLng = start.longitude * (math.pi / 180.0);
    final endLat = end.latitude * (math.pi / 180.0);
    final endLng = end.longitude * (math.pi / 180.0);

    final dLng = endLng - startLng;
    final y = math.sin(dLng) * math.cos(endLat);
    final x = math.cos(startLat) * math.sin(endLat) -
        math.sin(startLat) * math.cos(endLat) * math.cos(dLng);

    final bearing = math.atan2(y, x) * (180.0 / math.pi);
    return (bearing + 360.0) % 360.0;
  }

  static double _calculateBearing(LatLng start, LatLng end) =>
      calculateBearing(start, end);

  static List<RouteStep> _generateFallbackSteps(
      List<LatLng> points, LatLng pickup, LatLng dropoff) {
    if (points.length < 2) return [];
    final totalM = const Distance().as(LengthUnit.Meter, pickup, dropoff);
    if (totalM < 80) {
      return [
        RouteStep(
          location: dropoff,
          instruction: 'Arrive at destination',
          maneuverType: 'arrive',
          maneuverModifier: 'straight',
          distanceMeters: totalM,
        ),
      ];
    }

    final List<RouteStep> steps = [];
    steps.add(
      RouteStep(
        location: pickup,
        instruction: 'Head toward destination',
        maneuverType: 'depart',
        maneuverModifier: 'straight',
        distanceMeters: const Distance().as(LengthUnit.Meter, pickup, points.first),
      ),
    );

    LatLng lastManeuverPoint = pickup;

    // Detect distinct turns by scanning bearing changes across consecutive segments
    for (int i = 1; i < points.length - 1; i++) {
      final prev = points[i - 1];
      final curr = points[i];
      final next = points[i + 1];

      final distFromLastManeuver =
          const Distance().as(LengthUnit.Meter, lastManeuverPoint, curr);
      // Suppress turns closer than 35m from previous maneuver to prevent spamming
      if (distFromLastManeuver < 35.0) continue;

      final b1 = _calculateBearing(prev, curr);
      final b2 = _calculateBearing(curr, next);

      var diff = (b2 - b1 + 360.0) % 360.0;
      if (diff > 180.0) diff -= 360.0;

      if (diff.abs() >= 28.0) {
        String instruction;
        String modifier;

        if (diff > 28.0 && diff <= 65.0) {
          modifier = 'slight right';
          instruction = 'Turn slight right';
        } else if (diff > 65.0 && diff <= 125.0) {
          modifier = 'right';
          instruction = 'Turn right';
        } else if (diff > 125.0) {
          modifier = 'sharp right';
          instruction = 'Turn sharp right';
        } else if (diff < -28.0 && diff >= -65.0) {
          modifier = 'slight left';
          instruction = 'Turn slight left';
        } else if (diff < -65.0 && diff >= -125.0) {
          modifier = 'left';
          instruction = 'Turn left';
        } else {
          modifier = 'sharp left';
          instruction = 'Turn sharp left';
        }

        steps.add(
          RouteStep(
            location: curr,
            instruction: instruction,
            maneuverType: 'turn',
            maneuverModifier: modifier,
            distanceMeters: distFromLastManeuver,
          ),
        );
        lastManeuverPoint = curr;
      }
    }

    // Always append final arrival step at dropoff
    final remainingToDropoff =
        const Distance().as(LengthUnit.Meter, lastManeuverPoint, dropoff);
    steps.add(
      RouteStep(
        location: dropoff,
        instruction: 'Arrive at destination',
        maneuverType: 'arrive',
        maneuverModifier: 'straight',
        distanceMeters: remainingToDropoff,
      ),
    );

    return steps;
  }

  // ── Private helpers ────────────────────────────────────────────────────────
}

/// Represents a step-by-step turn-by-turn guidance instruction along a route leg.
class RouteStep {
  final LatLng location;
  final String instruction;
  final String maneuverType;
  final String maneuverModifier;
  final double distanceMeters;
  final String streetName;

  const RouteStep({
    required this.location,
    required this.instruction,
    this.maneuverType = 'turn',
    this.maneuverModifier = 'straight',
    this.distanceMeters = 0.0,
    this.streetName = '',
  });

  /// Formats step instruction dynamically with live distance to the maneuver.
  String formatDynamicInstruction(double distM) {
    if (maneuverType == 'arrive') {
      if (distM < 30) return 'Arriving at destination';
      final distStr = distM < 1000
          ? '${distM.round()}m'
          : '${(distM / 1000).toStringAsFixed(1)}km';
      return 'In $distStr, arrive at destination';
    }

    final distStr = distM < 1000
        ? '${(distM / 10).round() * 10}m'
        : '${(distM / 1000).toStringAsFixed(1)}km';

    if (instruction.startsWith('In ')) {
      return instruction;
    }

    final baseText = instruction.isNotEmpty
        ? instruction
        : (streetName.isNotEmpty ? 'Continue on $streetName' : 'Head toward destination');

    if (distM < 25) {
      return baseText;
    }

    if (baseText.toLowerCase().startsWith('turn') ||
        baseText.toLowerCase().startsWith('continue') ||
        baseText.toLowerCase().startsWith('head') ||
        baseText.toLowerCase().startsWith('keep') ||
        baseText.toLowerCase().startsWith('merge')) {
      return 'In $distStr, ${baseText.substring(0, 1).toLowerCase()}${baseText.substring(1)}';
    }

    return 'In $distStr, $baseText';
  }

  /// Maps the maneuver modifier/type to a turn arrow icon.
  IconData get maneuverIconData {
    final type = maneuverType.toLowerCase();
    final mod = maneuverModifier.toLowerCase();

    if (type == 'arrive') return Icons.place_rounded;
    if (mod.contains('right')) {
      if (mod.contains('slight')) return Icons.turn_slight_right_rounded;
      if (mod.contains('sharp')) return Icons.turn_sharp_right_rounded;
      return Icons.turn_right_rounded;
    }
    if (mod.contains('left')) {
      if (mod.contains('slight')) return Icons.turn_slight_left_rounded;
      if (mod.contains('sharp')) return Icons.turn_sharp_left_rounded;
      return Icons.turn_left_rounded;
    }
    if (mod.contains('u-turn') || mod.contains('uturn')) {
      return Icons.u_turn_left_rounded;
    }
    return Icons.straight_rounded;
  }
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
