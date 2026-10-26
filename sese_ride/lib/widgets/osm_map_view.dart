import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart' as fm;
import 'package:google_maps_flutter/google_maps_flutter.dart' as gmaps;
import 'package:latlong2/latlong.dart';
import 'package:latlong2/latlong.dart' as base;

/// Shared OpenStreetMap view for sese_ride's OSM-pinned surfaces.
///
/// Live-trip tracking, real-time movement, and the turn-by-turn cockpit
/// render here (see [MapProviderPolicy]); browsing/idle surfaces render
/// the Google branch of `SeSeMapView` instead. Geocoding stays OSM
/// Nominatim and routing OSRM (see `LocationService`) on every surface —
/// only the browsing TILES are Google.
///
/// Thin wrapper around [fm.FlutterMap] that keeps the rest of the app on
/// the plain [base.LatLng] data type: positions convert at this boundary.
/// Camera moves go through [SeSeMapController] so screens never touch the
/// map controller directly.
///
/// OSM tile usage requires attribution — rendered by the built-in
/// attribution widget (bottom-right). Do not overlay anything on the
/// bottom corners of this widget.
class OsmMapView extends StatefulWidget {
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

  /// Optional override for dark map tiles (e.g. for driver cockpit view).
  final bool? isDarkOverride;

  /// Test seam: when set, a plain placeholder renders instead of the real
  /// tile map (network tiles stall `flutter_test`).
  /// Set to [BlankTileProvider()] in test setup.
  static Object? debugTileProviderOverride;

  /// Optional path to a local `.mbtiles` SQLite file.
  final String? localMbtilePath;

  /// Optional custom tile server URL template from RemoteKeysConfig.
  final String? customTileUrlTemplate;

  /// Optional callback invoked when tile loading fails/times out.
  final VoidCallback? onTileError;

  /// When true, indicates live user location is displayed.
  final bool showMyLocation;

  /// Live user fix driving the blue-dot marker on raster engines. When null
  /// the dot falls back to [initialCenter] (legacy static behavior). Screens
  /// holding a `Geolocator.getPositionStream` subscription pass each fix
  /// here so the dot tracks the ground truth instead of a stale coordinate.
  final base.LatLng? userLocation;

  /// Optional camera move listener (for pin-drop modals and dragging).
  final void Function(base.LatLng center)? onCameraMove;

  /// Optional debounced camera idle listener.
  final void Function(base.LatLng center)? onCameraIdle;

  /// Optional map tap listener.
  final void Function(base.LatLng point)? onTap;

  /// Optional active engine identifier (e.g. 'mapbox' or 'cartodb') used to enforce
  /// clean unmounting and disposal of native platform views / tile caches on switch.
  final String? providerKey;

  const OsmMapView({
    super.key,
    required this.mapController,
    required this.initialCenter,
    this.initialZoom = 15.0,
    this.markers = const [],
    this.polylines = const [],
    this.isDarkOverride,
    this.localMbtilePath,
    this.customTileUrlTemplate,
    this.showMyLocation = false,
    this.userLocation,
    this.onTileError,
    this.onCameraMove,
    this.onCameraIdle,
    this.onTap,
    this.providerKey,
  });

  /// Builds a colored map pin marker at [point].
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
  State<OsmMapView> createState() => _OsmMapViewState();
}

class _OsmMapViewState extends State<OsmMapView> {
  Timer? _idleDebounce;
  base.LatLng? _lastCenter;

  @override
  void didUpdateWidget(covariant OsmMapView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if ((widget.initialCenter.latitude != oldWidget.initialCenter.latitude ||
            widget.initialCenter.longitude != oldWidget.initialCenter.longitude) &&
        widget.mapController.isFollowingUser) {
      widget.mapController.move(widget.initialCenter, widget.initialZoom);
    }
  }

  @override
  void dispose() {
    _idleDebounce?.cancel();
    super.dispose();
  }

  void _onPositionChanged(fm.MapCamera camera, bool hasGesture) {
    // Genuine user pan/zoom frees the camera from the GPS stream. The
    // flag is authoritative here (flutter_map reports it per event), so no
    // programmatic-window check is needed on this branch.
    if (hasGesture) {
      widget.mapController.handleUserGesture();
    }
    final center = base.LatLng(camera.center.latitude, camera.center.longitude);
    _lastCenter = center;
    widget.onCameraMove?.call(center);
    if (widget.onCameraIdle != null) {
      _idleDebounce?.cancel();
      _idleDebounce = Timer(const Duration(milliseconds: 500), () {
        if (mounted && _lastCenter != null) {
          widget.onCameraIdle?.call(_lastCenter!);
        }
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final isDark =
        widget.isDarkOverride ?? (Theme.of(context).brightness == Brightness.dark);

    if (OsmMapView.debugTileProviderOverride != null) {
      // Widget tests: no network tiles — render a map-colored placeholder.
      return Container(
        color: isDark ? const Color(0xFF1E1E1E) : const Color(0xFFE5E3DF),
      );
    }

    // Prefer custom tile URL template from remote keys if set, else fall back to CartoDB with retina {r} support.
    final tileUrl = (widget.customTileUrlTemplate != null &&
            widget.customTileUrlTemplate!.trim().isNotEmpty &&
            !widget.customTileUrlTemplate!.contains('light_all'))
        ? widget.customTileUrlTemplate!
        : (isDark
            ? 'https://{s}.basemaps.cartocdn.com/dark_all/{z}/{x}/{y}{r}.png'
            : 'https://{s}.basemaps.cartocdn.com/rastertiles/voyager/{z}/{x}/{y}{r}.png');

    final effectiveKey = widget.providerKey ??
        (tileUrl.contains('mapbox') ? 'mapbox' : 'cartodb');

    return fm.FlutterMap(
      key: ValueKey('flutter_map_${effectiveKey}_${tileUrl.hashCode}'),
      mapController: widget.mapController.native,
      options: fm.MapOptions(
        initialCenter: _toFm(widget.initialCenter),
        initialZoom: widget.initialZoom,
        minZoom: 3,
        maxZoom: 19,
        interactionOptions: const fm.InteractionOptions(
          flags: fm.InteractiveFlag.all,
        ),
        onMapReady: widget.mapController.markReady,
        onPositionChanged: _onPositionChanged,
        onTap: (tapPos, point) {
          widget.onTap?.call(base.LatLng(point.latitude, point.longitude));
        },
      ),
      children: [
        fm.TileLayer(
          key: ValueKey('tile_layer_${effectiveKey}_${tileUrl.hashCode}'),
          urlTemplate: tileUrl,
          subdomains: const ['a', 'b', 'c', 'd'],
          userAgentPackageName: 'com.sesetech.sese_ride',
          // Cap native zoom to 18 for CartoDB to prevent 404 blank screens at zoom 19
          maxNativeZoom: 18,
          maxZoom: 19,
          // Instantaneous display eliminates layer overlapping and tile ghosting
          tileDisplay: const fm.TileDisplay.instantaneous(),
          evictErrorTileStrategy: fm.EvictErrorTileStrategy.dispose,
          // Only enable retinaMode when template has {r} or on Mapbox endpoints
          retinaMode: tileUrl.contains('{r}') || tileUrl.contains('mapbox'),
          errorTileCallback: (fm.TileImage tile, Object error, StackTrace? stackTrace) {
            widget.onTileError?.call();
          },
        ),
        fm.PolylineLayer(
          polylines: [
            for (final r in widget.polylines)
              fm.Polyline(
                points: r.points.map(_toFm).toList(),
                color: r.color,
                strokeWidth: r.width.toDouble(),
              ),
          ],
        ),
        fm.MarkerLayer(
          markers: [
            for (final m in widget.markers)
              fm.Marker(
                point: _toFm(m.point),
                width: 44,
                height: 44,
                child: _PinGlyph(color: m.color, label: m.label),
              ),
          ],
        ),
        fm.RichAttributionWidget(
          attributions: [
            fm.TextSourceAttribution(
              tileUrl.contains('mapbox')
                  ? '© Mapbox © OpenStreetMap'
                  : '© CARTO © OpenStreetMap',
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

/// Teardrop-ish pin glyph with an optional letter badge, or glowing blue dot for user position.
class _PinGlyph extends StatelessWidget {
  final Color color;
  final String? label;

  const _PinGlyph({required this.color, this.label});

  @override
  Widget build(BuildContext context) {
    final isNavArrow =
        label == 'NAV' || label == 'NAVIGATION_ARROW' || label == '🚗';
    if (isNavArrow) {
      return Container(
        width: 42,
        height: 42,
        decoration: BoxDecoration(
          color: color,
          shape: BoxShape.circle,
          border: Border.all(color: Colors.white, width: 2.5),
          boxShadow: const [
            BoxShadow(
              color: Colors.black38,
              blurRadius: 6,
              offset: Offset(0, 3),
            ),
          ],
        ),
        child: const Center(
          child: Icon(
            Icons.navigation_rounded,
            color: Colors.white,
            size: 24,
          ),
        ),
      );
    }

    final isDriver =
        label == 'DRIVER' || label == 'NEARBY_DRIVER' || label == 'VEHICLE';
    if (isDriver) {
      return Container(
        width: 38,
        height: 38,
        decoration: BoxDecoration(
          color: Colors.white,
          shape: BoxShape.circle,
          border: Border.all(color: color, width: 2.2),
          boxShadow: const [
            BoxShadow(
              color: Colors.black26,
              blurRadius: 5,
              offset: Offset(0, 2),
            ),
          ],
        ),
        child: Center(
          child: Icon(
            Icons.directions_car_filled_rounded,
            color: color,
            size: 20,
          ),
        ),
      );
    }

    final isBlueDot = color == Colors.blue && (label == null || label!.isEmpty);
    if (isBlueDot) {
      return Container(
        width: 36,
        height: 36,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: const Color(0xFF4285F4).withValues(alpha: 0.22),
          border: Border.all(color: const Color(0xFF4285F4).withValues(alpha: 0.45), width: 1.5),
        ),
        child: Center(
          child: Container(
            width: 18,
            height: 18,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: const Color(0xFF4285F4),
              border: Border.all(color: Colors.white, width: 2.5),
              boxShadow: const [
                BoxShadow(
                  color: Colors.black38,
                  blurRadius: 4,
                  offset: Offset(0, 2),
                ),
              ],
            ),
          ),
        ),
      );
    }

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

/// Camera handle for [OsmMapView] (and the Google branch of [SeSeMapView]).
///
/// Queues moves until a renderer reports ready ([markReady] for OSM,
/// [attachGoogle] for Google) instead of throwing — every method is safe
/// to call unconditionally, including from widget tests rendering the
/// placeholder.
///
/// When a Google controller is attached, camera ops drive it; otherwise
/// they drive the OSM controller. Screens never need to know which
/// renderer is live — that is [MapProviderPolicy]'s decision.
class SeSeMapController {
  final fm.MapController _native = fm.MapController();
  final List<void Function()> _pending = [];
  bool _ready = false;

  /// Attached Google renderer (set by the Google branch of [SeSeMapView]
  /// via `onMapCreated`). Null on OSM surfaces and in widget tests.
  gmaps.GoogleMapController? _google;

  /// Direct access for advanced camera ops (zoom in/out buttons).
  /// Prefer [move]/[fitPoints]; guard with try/catch — the controller
  /// throws while no map is bound.
  fm.MapController get native => _native;

  // ── GPS follow state ────────────────────────────────────────────────────
  //
  // When true, fresh GPS fixes drive the camera ([SeseUniversalMap] calls
  // [followTo] on each fix). Any manual pan clears it; the recenter button
  // restores it via [recenterTo]. Defaults to true so a freshly opened map
  // tracks until the user first grabs it.
  bool isFollowingUser = true;

  /// Marks the start of a programmatic camera animation. Moves issued
  /// through [move]/[fitPoints]/[zoomBy]/[followTo]/[recenterTo] set a
  /// short window during which camera callbacks are NOT treated as user
  /// gestures (native animations report a stream of moves with no gesture
  /// flag — without the window every recenter would instantly un-follow).
  DateTime? _programmaticUntil;
  static const _programmaticWindow = Duration(milliseconds: 1200);

  void _noteProgrammatic() {
    _programmaticUntil = DateTime.now().add(_programmaticWindow);
  }

  /// True while inside a programmatic animation window.
  bool get isInProgrammaticWindow =>
      _programmaticUntil?.isAfter(DateTime.now()) ?? false;

  /// Called by map views when the USER pans/zooms (never for programmatic
  /// moves). Frees the camera so exploration never fights the GPS stream.
  void handleUserGesture() {
    if (isFollowingUser) {
      isFollowingUser = false;
      onFollowingChanged?.call();
    }
  }

  /// Fired whenever [isFollowingUser] flips (manual pan or recenter), so
  /// screens with follow-dependent UI (e.g. cockpit tracking tint) can
  /// rebuild. Screens own setting/clearing this hook in init/dispose.
  VoidCallback? onFollowingChanged;

  /// Re-center action: re-engages follow AND animates to the live fix.
  /// Screens must route their recenter buttons here (not bare [move]) or
  /// the camera will track once and then stop on the next pan state.
  Future<void> recenterTo(base.LatLng target, double zoom) {
    if (!isFollowingUser) {
      isFollowingUser = true;
      onFollowingChanged?.call();
    } else {
      isFollowingUser = true;
    }
    return move(target, zoom);
  }

  /// Follows the live fix WITHOUT touching the zoom (recenter owns zoom).
  /// Called per GPS tick while [isFollowingUser] is true.
  Future<void> followTo(base.LatLng target) {
    void run() {
      final google = _google;
      if (google != null) {
        // newLatLng keeps the current zoom — follow never re-zooms.
        google.animateCamera(
          gmaps.CameraUpdate.newLatLng(_toG(target)),
        );
        return;
      }
      _native.move(
        LatLng(target.latitude, target.longitude),
        _native.camera.zoom,
      );
    }

    if (!_ready && _google == null) {
      _pending.add(run);
      return Future.value();
    }
    try {
      _noteProgrammatic();
      run();
    } catch (e) {
      debugPrint('SeSeMapController.followTo failed: $e');
    }
    return Future.value();
  }

  /// Called by [OsmMapView] once the tile map is ready; flushes queued moves.
  void markReady() {
    _ready = true;
    _flushPending();
  }

  /// Called by the Google branch of [SeSeMapView] once the native map is
  /// created; flushes queued moves onto Google.
  void attachGoogle(gmaps.GoogleMapController controller) {
    _google = controller;
    _flushPending();
  }

  /// Called when the Google branch disposes so later moves fall back to
  /// the OSM path instead of hitting a dead controller.
  void detachGoogle() {
    _google = null;
  }

  void _flushPending() {
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

  static gmaps.LatLng _toG(base.LatLng point) =>
      gmaps.LatLng(point.latitude, point.longitude);

  /// Centers the camera on [target] at [zoom].
  Future<void> move(base.LatLng target, double zoom) async {
    void run() {
      _noteProgrammatic();
      final google = _google;
      if (google != null) {
        google.animateCamera(
          gmaps.CameraUpdate.newLatLngZoom(_toG(target), zoom),
        );
        return;
      }
      _native.move(LatLng(target.latitude, target.longitude), zoom);
    }

    if (!_ready && _google == null) {
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
      _noteProgrammatic();
      final google = _google;
      if (google != null) {
        google.animateCamera(gmaps.CameraUpdate.zoomBy(delta));
        return;
      }
      final cam = _native.camera;
      _native.move(
        cam.center,
        (cam.zoom + delta).clamp(3.0, 19.0),
      );
    }

    if (!_ready && _google == null) {
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
      _noteProgrammatic();
      final google = _google;
      if (google != null) {
        // May throw if the native view has no size yet (called pre-layout);
        // the caller-facing try/catch below swallows it — the next
        // interaction re-fits.
        google.animateCamera(
          gmaps.CameraUpdate.newLatLngBounds(
            gmaps.LatLngBounds(
              southwest: gmaps.LatLng(
                math.min(a.latitude, b.latitude),
                math.min(a.longitude, b.longitude),
              ),
              northeast: gmaps.LatLng(
                math.max(a.latitude, b.latitude),
                math.max(a.longitude, b.longitude),
              ),
            ),
            padding,
          ),
        );
        return;
      }
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

    if (!_ready && _google == null) {
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

/// Shared circular recenter/fit floating action button overlaid on every map view.
///
/// Clean floating white card with elevation and standard target/crosshairs icon.
class MapRecenterButton extends StatelessWidget {
  final VoidCallback onTap;
  final IconData icon;
  final Color? color;

  const MapRecenterButton({
    super.key,
    required this.onTap,
    this.icon = Icons.my_location,
    this.color,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final iconColor = color ?? (isDark ? Colors.white : const Color(0xFF4285F4));
    return Material(
      shape: const CircleBorder(),
      elevation: 4,
      shadowColor: Colors.black26,
      color: isDark ? const Color(0xFF2C2C2C) : Colors.white,
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Icon(icon, color: iconColor, size: 24),
        ),
      ),
    );
  }
}
