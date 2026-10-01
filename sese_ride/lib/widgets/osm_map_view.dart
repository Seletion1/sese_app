import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart' as fm;
import 'package:latlong2/latlong.dart';
import 'package:latlong2/latlong.dart' as base;

/// Shared map view for sese_ride, rendered 100% with OpenStreetMap.
///
/// No Google Maps anywhere: tiles come from OpenStreetMap, geocoding from
/// OSM Nominatim and routing from OSRM (see `LocationService`). There is no
/// Maps API key in any native config or web entrypoint.
///
/// Thin wrapper around [fm.FlutterMap] that keeps the rest of the app on
/// the plain [base.LatLng] data type: positions convert at this boundary.
/// Camera moves go through [SeSeMapController] so screens never touch the
/// map controller directly.
///
/// OSM tile usage requires attribution — rendered by the built-in
/// attribution widget (bottom-right). Do not overlay anything on the
/// bottom corners of this widget.
class OsmMapView extends StatelessWidget {
  /// Camera controller. Create one per screen and keep it in state.
  /// Later position updates must call `move`/`fitPoints` — the initial
  /// center applies at creation.
  final SeSeMapController mapController;

  /// Initial camera center. Applies once, at creation.
  final base.LatLng initialCenter;

  /// Initial zoom level (~0–19 for OSM tiles).
  final double initialZoom;

  /// Point markers (build with [OsmMapView.pin]).
  final List<MapPin> markers;

  /// Route lines (build with [OsmMapView.route]).
  final List<MapRoute> polylines;

  /// Test seam: when set, a plain placeholder renders instead of the real
  /// tile map (network tiles stall `flutter_test`).
  /// Set to [BlankTileProvider()] in test setup.
  static Object? debugTileProviderOverride;

  const OsmMapView({
    super.key,
    required this.mapController,
    required this.initialCenter,
    this.initialZoom = 15.0,
    this.markers = const [],
    this.polylines = const [],
  });

  /// Builds a colored map pin marker at [point].
  ///
  /// Pass [label] (`'A'`/`'B'`) for pickup/drop-off style pins like the
  /// incoming-offer sheet.
  static MapPin pin({
    required base.LatLng point,
    required Color color,
    String? id,
    String? label,
  }) {
    return MapPin(
      id: id ?? '${point.latitude},${point.longitude},${color.toARGB32()}',
      point: point,
      color: color,
      label: label,
    );
  }

  /// Builds a route polyline through [points].
  static MapRoute route({
    required List<base.LatLng> points,
    Color color = Colors.orangeAccent,
    int width = 4,
    String id = 'route',
  }) {
    return MapRoute(id: id, points: points, color: color, width: width);
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    if (debugTileProviderOverride != null) {
      // Widget tests: no network tiles — render a map-colored placeholder.
      return Container(
        color: isDark ? const Color(0xFF1E1E1E) : const Color(0xFFE5E3DF),
      );
    }

    final tileUrl = isDark
        ? 'https://{s}.basemaps.cartocdn.com/dark_all/{z}/{x}/{y}.png'
        : 'https://tile.openstreetmap.org/{z}/{x}/{y}.png';

    return fm.FlutterMap(
      mapController: mapController.native,
      options: fm.MapOptions(
        initialCenter: _toFm(initialCenter),
        initialZoom: initialZoom,
        minZoom: 3,
        maxZoom: 19,
        onMapReady: mapController.markReady,
      ),
      children: [
        fm.TileLayer(
          urlTemplate: tileUrl,
          subdomains: const ['a', 'b', 'c', 'd'],
          userAgentPackageName: 'com.sesetech.sese_ride',
        ),
        fm.PolylineLayer(
          polylines: [
            for (final r in polylines)
              fm.Polyline(
                points: r.points.map(_toFm).toList(),
                color: r.color,
                strokeWidth: r.width.toDouble(),
              ),
          ],
        ),
        fm.MarkerLayer(
          markers: [
            for (final m in markers)
              fm.Marker(
                point: _toFm(m.point),
                width: 44,
                height: 44,
                child: _PinGlyph(color: m.color, label: m.label),
              ),
          ],
        ),
        const fm.RichAttributionWidget(
          attributions: [
            fm.TextSourceAttribution(
              '© OpenStreetMap contributors',
            ),
          ],
        ),
      ],
    );
  }

  static LatLng _toFm(base.LatLng point) =>
      LatLng(point.latitude, point.longitude);
}

/// App-level pin description (rendered as an OSM marker by [OsmMapView]).
class MapPin {
  final String id;
  final base.LatLng point;
  final Color color;

  /// Optional letter badge drawn inside the pin (`'A'`/`'B'`).
  final String? label;

  const MapPin({
    required this.id,
    required this.point,
    required this.color,
    this.label,
  });
}

/// App-level route description (rendered as an OSM polyline by [OsmMapView]).
class MapRoute {
  final String id;
  final List<base.LatLng> points;
  final Color color;
  final int width;

  const MapRoute({
    required this.id,
    required this.points,
    required this.color,
    required this.width,
  });
}

/// Teardrop-ish pin glyph with an optional letter badge.
class _PinGlyph extends StatelessWidget {
  final Color color;
  final String? label;

  const _PinGlyph({required this.color, this.label});

  @override
  Widget build(BuildContext context) {
    return Stack(
      alignment: Alignment.center,
      children: [
        Icon(Icons.location_on, color: color, size: 44),
        if (label != null && label!.isNotEmpty)
          Positioned(
            top: 7,
            child: Text(
              label!,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 14,
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
      ],
    );
  }
}

/// Camera handle for [OsmMapView].
///
/// Queues moves until the flutter_map controller reports ready
/// ([markReady]) instead of throwing — every method is safe to call
/// unconditionally, including from widget tests rendering the placeholder.
class SeSeMapController {
  final fm.MapController _native = fm.MapController();
  final List<void Function()> _pending = [];
  bool _ready = false;

  /// Direct access for advanced camera ops (zoom in/out buttons).
  /// Prefer [move]/[fitPoints]; guard with try/catch — the controller
  /// throws while no map is bound.
  fm.MapController get native => _native;

  /// Called by [OsmMapView] once the tile map is ready; flushes queued moves.
  void markReady() {
    _ready = true;
    final queued = List<void Function()>.of(_pending);
    _pending.clear();
    for (final fn in queued) {
      try {
        fn();
      } catch (e) {
        debugPrint('SeSeMapController: pending camera update failed: $e');
      }
    }
  }

  /// Centers the camera on [target] at [zoom].
  Future<void> move(base.LatLng target, double zoom) async {
    void run() {
      _native.move(LatLng(target.latitude, target.longitude), zoom);
    }

    if (!_ready) {
      _pending.add(run);
      return;
    }
    try {
      run();
    } catch (e) {
      debugPrint('SeSeMapController.move failed: $e');
    }
  }

  /// Adjusts zoom relative to the current level (custom +/- buttons).
  Future<void> zoomBy(double delta) async {
    void run() {
      final cam = _native.camera;
      _native.move(
        cam.center,
        (cam.zoom + delta).clamp(3.0, 19.0),
      );
    }

    if (!_ready) {
      _pending.add(run);
      return;
    }
    try {
      run();
    } catch (e) {
      debugPrint('SeSeMapController.zoomBy failed: $e');
    }
  }

  /// Fits the camera to contain both [a] and [b] with [padding] insets.
  /// When both points coincide, centers on [a] at street zoom instead.
  Future<void> fitPoints(
    base.LatLng a,
    base.LatLng b, {
    double padding = 56,
  }) async {
    if (a.latitude == b.latitude && a.longitude == b.longitude) {
      return move(a, 15.0);
    }
    void run() {
      final bounds = fm.LatLngBounds(
        LatLng(
          math.min(a.latitude, b.latitude),
          math.min(a.longitude, b.longitude),
        ),
        LatLng(
          math.max(a.latitude, b.latitude),
          math.max(a.longitude, b.longitude),
        ),
      );
      _native.fitCamera(
        fm.CameraFit.bounds(
          bounds: bounds,
          padding: EdgeInsets.all(padding),
        ),
      );
    }

    if (!_ready) {
      _pending.add(run);
      return;
    }
    try {
      run();
    } catch (e) {
      debugPrint('SeSeMapController.fitPoints failed: $e');
    }
  }
}

/// Test seam placeholder (kept for the `debugTileProviderOverride` API used
/// in widget-test setup). The OSM map renders no network tiles in tests.
class BlankTileProvider {
  const BlankTileProvider();
}

/// Shared circular recenter/fit button overlaid on every map.
///
/// White circle + green GPS icon, matching the customer home style, so
/// users always have a visible "center my location / fit route" affordance.
class MapRecenterButton extends StatelessWidget {
  final VoidCallback onTap;
  final IconData icon;

  const MapRecenterButton({
    super.key,
    required this.onTap,
    this.icon = Icons.gps_fixed,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      shape: const CircleBorder(),
      elevation: 4,
      color: Theme.of(context).cardColor,
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Icon(icon, color: Colors.green, size: 28),
        ),
      ),
    );
  }
}
