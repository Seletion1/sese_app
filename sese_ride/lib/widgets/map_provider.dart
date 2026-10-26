import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart' as gmaps;
import 'package:google_maps_flutter_android/google_maps_flutter_android.dart'
    show GoogleMapsFlutterAndroid;
import 'package:google_maps_flutter_platform_interface/google_maps_flutter_platform_interface.dart'
    show GoogleMapsFlutterPlatform;
import 'package:latlong2/latlong.dart';
import 'package:sese_core/sese_core.dart';

import 'osm_map_view.dart';
import 'google_style_map_overlay.dart';

// Re-export the shared data types so screens only need to import map_provider.dart.
export 'osm_map_view.dart' show SeSeMapController, MapPin, MapRoute, MapRecenterButton;

/// Map rendering context. Documents surface intent across the app lifecycle.
enum MapContext {
  /// Address search, location selection, static previews, idle driver
  /// positioning, initial customer browsing.
  browsing,

  /// Driver home canvas while online but trip-free.
  idlePositioning,

  /// Customer real-time driver tracking after an order is placed.
  activeTrip,

  /// Live GPS marker movement during a trip.
  realtimeTracking,

  /// Driver in-app turn-by-turn cockpit.
  inAppNavigation,
}

/// Which tile renderer a surface uses.
///
/// Provider priority: [googleMaps] → [mapbox] → [cartoDb].
/// [openStreetMap] is fully deprecated; any code path that would have selected
/// it now selects [cartoDb] instead.
enum MapProvider {
  googleMaps,
  mapbox,
  cartoDb,

  /// Deprecated — maps to [cartoDb] at runtime. Do not reference in new code.
  @Deprecated('OSM is deprecated. Use cartoDb or mapbox instead.')
  openStreetMap,
}

/// Map Provider Architecture Strategy.
///
/// Dynamically resolves renderer based on [MapConfigController] state.
/// Fallback chain: **Google Maps → Mapbox → CartoDB**.
///
/// Per-feature Hub pins ([MapFeature]) override the global chain for their
/// feature area: navigation cockpit, live tracking, geocoding (service
/// layer), and backend routing each resolve independently. Credential and
/// fallback safety always applies — a pinned provider without a valid key
/// still cascades down the chain.
abstract final class MapProviderPolicy {
  /// Maps a rendering context to its Hub feature slot. Browsing/idle
  /// surfaces follow the global chain (`null`); trip surfaces resolve
  /// their dedicated slot.
  static MapFeature? featureForContext(MapContext context) {
    switch (context) {
      case MapContext.inAppNavigation:
        return MapFeature.navigation;
      case MapContext.activeTrip:
      case MapContext.realtimeTracking:
        return MapFeature.tracking;
      case MapContext.browsing:
      case MapContext.idlePositioning:
        return null;
    }
  }

  /// Resolves the renderer. Respects [MapConfigController.instance] and
  /// dynamic fallbacks including the Mapbox fallback and circuit breaker.
  ///
  /// When [feature] is non-null and Hub-pinned to an explicit provider, that
  /// provider wins (subject to key/fallback safety). Defaults to the slot
  /// for [context] via [featureForContext].
  static MapProvider resolve(
    MapContext context, {
    String? activeMapProvider,
    GlobalMapConfig? mapConfig,
    MapFeature? feature,
  }) {
    final cfg = mapConfig ??
        (activeMapProvider != null && activeMapProvider.isNotEmpty
            ? GlobalMapConfig(activeProvider: activeMapProvider)
            : MapConfigController.instance.currentConfig);

    final slot = feature ?? featureForContext(context);
    if (slot != null) {
      final pinned = cfg.featureProviderRaw(slot);
      if (pinned != 'auto') {
        return _resolveCode(pinned, cfg);
      }
    }

    if (cfg.isCartoDb) return MapProvider.cartoDb;

    if (cfg.isMapbox) {
      if (MapConfigController.instance.isMapboxFallbackActive ||
          !cfg.hasValidMapboxToken) {
        return MapProvider.cartoDb;
      }
      return MapProvider.mapbox;
    }

    if (cfg.isGoogle) {
      if (MapConfigController.instance.isGoogleFallbackActive ||
          !cfg.hasValidApiKey) {
        // Cascade: try Mapbox, then CartoDB
        if (cfg.hasValidMapboxToken &&
            !MapConfigController.instance.isMapboxFallbackActive) {
          return MapProvider.mapbox;
        }
        return MapProvider.cartoDb;
      }
      return MapProvider.googleMaps;
    }

    return MapProvider.cartoDb;
  }

  /// Resolves an explicit Hub-pinned provider code with full safety:
  /// missing keys, GMS absence (handled by callers via [gmsOk]), and active
  /// fallbacks all cascade down the chain instead of going blank.
  static MapProvider _resolveCode(String code, GlobalMapConfig cfg) {
    final controller = MapConfigController.instance;
    switch (code) {
      case 'google':
        if (controller.isGoogleFallbackActive || !cfg.hasValidApiKey) {
          if (cfg.hasValidMapboxToken && !controller.isMapboxFallbackActive) {
            return MapProvider.mapbox;
          }
          return MapProvider.cartoDb;
        }
        return MapProvider.googleMaps;
      case 'mapbox':
        if (controller.isMapboxFallbackActive || !cfg.hasValidMapboxToken) {
          return MapProvider.cartoDb;
        }
        return MapProvider.mapbox;
      case 'cartodb':
      default:
        return MapProvider.cartoDb;
    }
  }
}

/// Google Play Services presence probe (Android only).
///
/// Backed by `MainActivity` (`GoogleApiAvailability` via reflection, so no
/// extra dependency). Cached per process; fail-open (`true`) on iOS, tests,
/// and any channel failure so GMS devices never change behavior. When the
/// probe reports unavailable, [SeseUniversalMap] falls back to Mapbox or CartoDB.
abstract final class GmsAvailability {
  static const _channel =
      MethodChannel('com.sesetech.sese_ride/gms_availability');

  static Future<bool>? _cached;
  static bool? _cachedValue;

  /// Test seam: force a fixed answer.
  @visibleForTesting
  static bool? debugOverride;

  /// Probes `/proc/meminfo` synchronously on Android to identify entry-tier devices (<= 4GB RAM).
  ///
  /// On devices with <= 4GB RAM (e.g. Nokia G20, MediaTek entry devices), Google Play Services
  /// maps dynamite compiler loop drops hundreds of frames and causes native Scudo memory
  /// exhaustion and ANR watchdog kills.
  static bool _isLowRamOrProblematicDevice() {
    if (!Platform.isAndroid) return false;
    try {
      final meminfoFile = File('/proc/meminfo');
      if (meminfoFile.existsSync()) {
        final content = meminfoFile.readAsStringSync();
        final match = RegExp(r'MemTotal:\s+(\d+)\s+kB', caseSensitive: false).firstMatch(content);
        if (match != null) {
          final memKb = int.tryParse(match.group(1) ?? '');
          // If total RAM <= 4.2GB (~4,400,000 kB), classify as entry-tier / low-RAM device.
          if (memKb != null && memKb <= 4400000) {
            debugPrint('GmsAvailability: Low-RAM device detected via /proc/meminfo ($memKb kB). Routing to pure Dart raster tiles.');
            return true;
          }
        }
      }
    } catch (e) {
      debugPrint('GmsAvailability: Error probing /proc/meminfo: $e');
    }
    return false;
  }

  /// Synchronously returns whether GMS is available if already resolved or detectable via
  /// direct Linux hardware inspection, or null if the async probe is still in flight.
  static bool? get isAvailableSync {
    if (debugOverride != null) return debugOverride;
    if (_cachedValue != null) return _cachedValue;
    if (!Platform.isAndroid) return true;
    if (_isLowRamOrProblematicDevice()) {
      _cachedValue = false;
      return false;
    }
    return null;
  }

  static Future<bool> isAvailable() {
    final forced = debugOverride;
    if (forced != null) return Future.value(forced);
    return _cached ??= _check();
  }

  static Future<bool> _check() async {
    if (!Platform.isAndroid) {
      _cachedValue = true;
      return true;
    }

    // Synchronous memory check via /proc/meminfo (works instantly across hot restarts).
    if (_isLowRamOrProblematicDevice()) {
      _cachedValue = false;
      return false;
    }

    // Check device model property via getprop ro.product.model.
    try {
      final proc = await Process.run('getprop', ['ro.product.model']);
      final model = proc.stdout.toString().toLowerCase();
      if (model.contains('g20') || model.contains('nokia')) {
        debugPrint('GmsAvailability: Detected $model device. Forcing pure raster tile fallback.');
        _cachedValue = false;
        return false;
      }
    } catch (_) {}

    try {
      final available = await _channel.invokeMethod<bool>('isAvailable') ?? false;
      _cachedValue = available;
      return available;
    } catch (e) {
      debugPrint('GmsAvailability check failed, assuming raster fallback: $e');
      _cachedValue = false;
      return false;
    }
  }
}

/// Non-intrusive warning banner displayed when a map provider degrades and
/// gracefully falls back to a secondary or tertiary provider.
class MapFallbackBanner extends StatelessWidget {
  final String message;
  final VoidCallback? onDismiss;

  const MapFallbackBanner({
    super.key,
    required this.message,
    this.onDismiss,
  });

  @override
  Widget build(BuildContext context) {
    return Positioned(
      top: 12,
      left: 12,
      right: 12,
      child: Material(
        key: const Key('map_fallback_banner'),
        color: Colors.amber.shade900.withValues(alpha: 0.94),
        borderRadius: BorderRadius.circular(8),
        elevation: 4,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          child: Row(
            children: [
              const Icon(Icons.warning_amber_rounded, color: Colors.white, size: 18),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  message,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              if (onDismiss != null)
                InkWell(
                  onTap: onDismiss,
                  borderRadius: BorderRadius.circular(12),
                  child: const Padding(
                    padding: EdgeInsets.all(4),
                    child: Icon(Icons.close, color: Colors.white70, size: 16),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Unified, policy-aware map view: the single reusable wrapper widget that
/// 100% of screens, modals, search sheets, and pin-drop pickers must use.
///
/// Dynamically synchronizes with [MapConfigController.instance].
/// Seamlessly handles Google Maps, Mapbox, and CartoDB engines with automatic
/// cascading degradation and graceful fallbacks.
///
/// ## Provider fallback chain
/// **Google Maps → Mapbox → CartoDB**
///
/// ## Cold-start & mid-trip protection
/// Trip contexts ([MapContext.activeTrip], [MapContext.realtimeTracking],
/// [MapContext.inAppNavigation]) snapshot the map config at widget creation
/// and resolve their renderer from that snapshot for their whole lifetime —
/// Hub edits, fallback trips, and circuit events never tear down or swap
/// the engine mid-trip. Provider changes take effect on those surfaces at
/// the next fresh widget creation (cold start of the trip screen).
///
/// ## Mandatory features present on every map surface
/// - Live blue dot GPS indicator ([showMyLocation] = true recommended).
/// - One-touch camera recenter FAB ([showRecenterFab] + [onRecenterTap]).
/// - Optional Google-style overlay ([showCenterBlueDot] + recenter FAB):
///   fixed center blue-dot indicator with a bottom-right target button.
/// - Full gesture controls: pinch-zoom, pan, 360° rotation on all three renderers.
class SeseUniversalMap extends StatefulWidget {
  /// Rendering context driving [MapProviderPolicy.resolve].
  final MapContext mapContext;

  /// Explicit Hub feature slot override. Defaults to the slot for
  /// [mapContext] ([MapProviderPolicy.featureForContext]): navigation for
  /// the cockpit, tracking for live-trip surfaces, global chain otherwise.
  final MapFeature? feature;

  /// Camera controller. Create one per screen and keep it in state.
  final SeSeMapController mapController;

  /// Initial camera center. Applies once, at creation.
  final LatLng initialCenter;

  /// Initial zoom level (~0–21 for Google, ~0–19 for tile providers).
  final double initialZoom;

  /// Point markers (build with [OsmMapView.pin]).
  final List<MapPin> markers;

  /// Route lines (build with [OsmMapView.route]).
  final List<MapRoute> polylines;

  /// Optional override for dark map tiles / dark style.
  final bool? isDarkOverride;

  /// Optional path to a local `.mbtiles` file for offline tile serving.
  final String? localMbtilePath;

  /// When true, renders the native blue-dot GPS indicator on Google Maps and
  /// passes the flag to tile-based renderers so the parent can supply a
  /// [Colors.blue]-coloured [MapPin] at the user's GPS position.
  final bool showMyLocation;

  /// Live user fix for the raster-engine blue dot (see `OsmMapView`
  /// `userLocation`). The native Google dot tracks the OS location on its
  /// own; Mapbox/CartoDB need this fix per GPS tick or the dot sits on a
  /// stale coordinate while the camera moves. Null falls back to
  /// [initialCenter] (previous behavior).
  final LatLng? userLocation;

  /// When true, Google's built-in recenter button is enabled.
  /// Prefer [showRecenterFab] for cross-provider consistency.
  final bool myLocationButtonEnabled;

  /// When true, overlays the unified [MapRecenterButton] FAB at bottom-right.
  /// [onRecenterTap] must be provided for the button to function.
  final bool showRecenterFab;

  /// Callback for the recenter FAB tap. Typically calls [mapController.move]
  /// with the user's current GPS position.
  final VoidCallback? onRecenterTap;

  /// Optional bottom positioning offset for the recenter FAB (defaults to 16).
  final double? recenterBottom;

  /// Optional right positioning offset for the recenter FAB (defaults to 16).
  final double? recenterRight;

  /// Optional Key for testing the recenter FAB (defaults to const Key('recenter_button')).
  final Key? recenterKey;

  /// Camera move callback (called continuously during panning/zooming).
  final void Function(LatLng center)? onCameraMove;

  /// Debounced camera idle callback (called after movement settles).
  final void Function(LatLng center)? onCameraIdle;

  /// Map tap listener.
  final void Function(LatLng point)? onTap;

  /// When true, displays an exact fixed center-pin overlay for location picking.
  final bool showCenterPin;

  /// Color of the center-pin overlay (defaults to red).
  final Color? centerPinColor;

  /// Optional label badge displayed above the center pin (e.g. "Pickup Point").
  final String? centerPinLabel;

  /// Whether to show the graceful fallback warning banner if the primary provider fails.
  final bool showFallbackBanner;

  /// When true, renders the Google-style overlay center blue-dot indicator
  /// (fixed at the map center; see [GoogleStyleMapOverlay]). Pair with
  /// [showRecenterFab] for the full Google Maps overlay standard.
  final bool showCenterBlueDot;

  /// Test seam: when set, renders a placeholder map without network tiles.
  static Object? get debugTileProviderOverride =>
      OsmMapView.debugTileProviderOverride;
  static set debugTileProviderOverride(Object? val) =>
      OsmMapView.debugTileProviderOverride = val;

  const SeseUniversalMap({
    super.key,
    this.mapContext = MapContext.browsing,
    this.feature,
    required this.mapController,
    required this.initialCenter,
    this.initialZoom = 15.0,
    this.markers = const [],
    this.polylines = const [],
    this.isDarkOverride,
    this.localMbtilePath,
    this.showMyLocation = false,
    this.userLocation,
    this.myLocationButtonEnabled = false,
    this.showRecenterFab = false,
    this.onRecenterTap,
    this.recenterBottom,
    this.recenterRight,
    this.recenterKey,
    this.onCameraMove,
    this.onCameraIdle,
    this.onTap,
    this.showCenterPin = false,
    this.centerPinColor,
    this.centerPinLabel,
    this.showFallbackBanner = true,
    this.showCenterBlueDot = false,
  });

  /// Builds a colored map pin marker at [point].
  static MapPin pin({
    required LatLng point,
    required Color color,
    String? id,
    String? label,
  }) {
    return OsmMapView.pin(
      point: point,
      color: color,
      id: id,
      label: label,
    );
  }

  /// Builds a route polyline through [points].
  static MapRoute route({
    required List<LatLng> points,
    Color color = Colors.orangeAccent,
    int width = 4,
    String id = 'route',
  }) {
    return OsmMapView.route(
      points: points,
      color: color,
      width: width,
      id: id,
    );
  }

  @override
  State<SeseUniversalMap> createState() => _SeseUniversalMapState();
}

/// Backwards-compatible alias for [SeseUniversalMap].
typedef SeSeMapView = SeseUniversalMap;

class _SeseUniversalMapState extends State<SeseUniversalMap> {
  bool _bannerDismissed = false;

  /// Cold-start snapshot: trip contexts freeze the engine config at creation
  /// so Hub edits can never tear down the native view mid-trip. Non-trip
  /// surfaces stay live (null snapshot → resolve from the notifier).
  GlobalMapConfig? _frozenConfig;

  @override
  void initState() {
    super.initState();
    if (_isTripContext(widget.mapContext)) {
      _frozenConfig = MapConfigController.instance.snapshotConfig();
    }
  }

  @override
  void didUpdateWidget(covariant SeseUniversalMap oldWidget) {
    super.didUpdateWidget(oldWidget);
    // GPS follow: while the user hasn't grabbed the map, each fresh fix
    // re-centers the camera on the live dot (zoom untouched). A manual pan
    // clears `isFollowingUser` (see gesture hooks below), so tracking
    // resumes only via the recenter button — exploration never fights GPS.
    final fix = widget.userLocation;
    if (fix != null &&
        fix != oldWidget.userLocation &&
        widget.mapController.isFollowingUser) {
      // ignore: discarded_futures
      widget.mapController.followTo(fix);
    }
  }

  /// Camera-move fan-out for the native Google branch. `google_maps_flutter`
  /// reports no gesture flag, so moves landing inside a programmatic window
  /// (recenter / fit / follow animations) are programmatic; anything else is
  /// the user's hand — which frees the camera from the GPS stream.
  void _handleGoogleCameraMove(LatLng center) {
    if (!widget.mapController.isInProgrammaticWindow) {
      widget.mapController.handleUserGesture();
    }
    widget.onCameraMove?.call(center);
  }

  /// Trip contexts whose engine must never swap mid-session.
  static bool _isTripContext(MapContext context) =>
      context == MapContext.activeTrip ||
      context == MapContext.realtimeTracking ||
      context == MapContext.inAppNavigation;

  void _handleTileError() {
    // Tile errors on Mapbox or CartoDB branches are logged but do not
    // automatically trigger fallback — these are free/lower-stakes renderers.
    debugPrint('SeseUniversalMap: Tile load error on raster branch.');
  }

  void _handleGoogleTileError() {
    // Forwards each Google tile error to the circuit breaker.
    // After 10 consecutive errors the circuit trips and Google is bypassed.
    MapConfigController.instance.recordGoogleTileError();
  }

  @override
  Widget build(BuildContext context) {
    final initialGms = GmsAvailability.isAvailableSync ?? (!Platform.isAndroid);
    return FutureBuilder<bool>(
      future: GmsAvailability.isAvailable(),
      initialData: initialGms,
      builder: (context, gmsSnapshot) {
        final gmsOk = gmsSnapshot.data ?? initialGms;
        return ValueListenableBuilder<GlobalMapConfig>(
          valueListenable: MapConfigController.instance.configNotifier,
          builder: (context, liveConfig, _) {
            final isDark = widget.isDarkOverride ??
                Theme.of(context).brightness == Brightness.dark;

            // Frozen trip snapshot wins when present; everything else
            // follows the live Hub config. Markers/camera always come from
            // widget props, so freezing the ENGINE never freezes the data.
            final mapConfig = _frozenConfig ?? liveConfig;

            var targetProvider = MapProviderPolicy.resolve(
              widget.mapContext,
              mapConfig: mapConfig,
              feature: widget.feature,
            );

            bool isFallbackActive = false;
            String fallbackMessage = 'Primary map provider unavailable.';

            // ── Missing API Key / GMS Graceful Fallback Guard ──────────────
            // Covers both the global Google chain and an explicit per-feature
            // Google pin: a pinned provider without GMS still cascades.
            if (targetProvider == MapProvider.googleMaps && !gmsOk) {
              if (mapConfig.hasValidMapboxToken &&
                  !MapConfigController.instance.isMapboxFallbackActive) {
                targetProvider = MapProvider.mapbox;
                fallbackMessage = 'Google Play Services unavailable. Using Mapbox.';
              } else {
                targetProvider = MapProvider.cartoDb;
                fallbackMessage = 'Google Play Services unavailable. Using CartoDB.';
              }
              isFallbackActive = true;
            }
            if (mapConfig.isGoogle) {
              if (!mapConfig.hasValidApiKey) {
                if (mapConfig.hasValidMapboxToken &&
                    !MapConfigController.instance.isMapboxFallbackActive) {
                  targetProvider = MapProvider.mapbox;
                  fallbackMessage = 'Google Maps API key not set. Using Mapbox tiles.';
                } else {
                  targetProvider = MapProvider.cartoDb;
                  fallbackMessage = 'Google Maps API key not set. Using CartoDB tiles.';
                }
                isFallbackActive = true;
              } else if (!gmsOk) {
                if (mapConfig.hasValidMapboxToken &&
                    !MapConfigController.instance.isMapboxFallbackActive) {
                  targetProvider = MapProvider.mapbox;
                  fallbackMessage = 'Google Play Services unavailable. Using Mapbox.';
                } else {
                  targetProvider = MapProvider.cartoDb;
                  fallbackMessage = 'Google Play Services unavailable. Using CartoDB.';
                }
                isFallbackActive = true;
              } else if (MapConfigController.instance.isGoogleFallbackActive) {
                if (mapConfig.hasValidMapboxToken &&
                    !MapConfigController.instance.isMapboxFallbackActive) {
                  targetProvider = MapProvider.mapbox;
                } else {
                  targetProvider = MapProvider.cartoDb;
                }
                isFallbackActive = true;
                fallbackMessage = MapConfigController.instance.fallbackReason ??
                    'Google Maps unavailable. Falling back to ${targetProvider == MapProvider.mapbox ? "Mapbox" : "CartoDB"}.';
              }
            } else if (mapConfig.isMapbox &&
                (MapConfigController.instance.isMapboxFallbackActive ||
                    !mapConfig.hasValidMapboxToken)) {
              targetProvider = MapProvider.cartoDb;
              isFallbackActive = true;
              fallbackMessage = MapConfigController.instance.mapboxFallbackReason ??
                  'Mapbox unavailable. Using CartoDB tiles.';
            }

            if (OsmMapView.debugTileProviderOverride != null) {
              return Container(
                color:
                    isDark ? const Color(0xFF1E1E1E) : const Color(0xFFE5E3DF),
              );
            }

            final currentEngine = targetProvider.name;
            final providerKey = targetProvider == MapProvider.googleMaps
                ? 'google_maps_${mapConfig.normalizedProvider}'
                : currentEngine;

            final Widget mapCanvas;

            // ignore: deprecated_member_use
            if (targetProvider == MapProvider.googleMaps) {
              mapCanvas = _GoogleMapBranch(
                key: ValueKey('map_branch_$providerKey'),
                providerKey: providerKey,
                mapController: widget.mapController,
                initialCenter: widget.initialCenter,
                initialZoom: widget.initialZoom,
                markers: widget.markers,
                polylines: widget.polylines,
                isDarkOverride: widget.isDarkOverride,
                showMyLocation: widget.showMyLocation,
                myLocationButtonEnabled: widget.myLocationButtonEnabled,
                onTileError: _handleGoogleTileError,
                onCameraMove: _handleGoogleCameraMove,
                onCameraIdle: widget.onCameraIdle,
                onTap: widget.onTap,
              );
            } else {
              // Mapbox or CartoDB — both rendered via OsmMapView (flutter_map TileLayer)
              final tileUrl = targetProvider == MapProvider.mapbox
                  ? mapConfig.resolveMapboxTileUrl(isDark: isDark)
                  : mapConfig.resolveTileUrl(isDark: isDark);

              // Seamless blue-dot parity: if showMyLocation is true and markers
              // do not already supply a user blue dot, inject a live blue-dot pin.
              // The dot tracks `userLocation` (live GPS per tick) and only
              // falls back to the creation center when no fix is held.
              final rasterMarkers = List<MapPin>.from(widget.markers);
              if (widget.showMyLocation &&
                  !rasterMarkers.any((m) =>
                      m.color == Colors.blue &&
                      (m.label == null || m.label!.isEmpty))) {
                rasterMarkers.insert(
                  0,
                  MapPin(
                    id: 'live_user_blue_dot',
                    point: widget.userLocation ?? widget.initialCenter,
                    color: Colors.blue,
                    label: null,
                  ),
                );
              }

              mapCanvas = OsmMapView(
                key: ValueKey('map_raster_${currentEngine}_${tileUrl.hashCode}'),
                providerKey: currentEngine,
                mapController: widget.mapController,
                initialCenter: widget.initialCenter,
                initialZoom: widget.initialZoom,
                markers: rasterMarkers,
                polylines: widget.polylines,
                isDarkOverride: widget.isDarkOverride,
                localMbtilePath: widget.localMbtilePath,
                customTileUrlTemplate: tileUrl,
                showMyLocation: widget.showMyLocation,
                userLocation: widget.userLocation,
                onTileError: _handleTileError,
                onCameraMove: widget.onCameraMove,
                onCameraIdle: widget.onCameraIdle,
                onTap: widget.onTap,
              );
            }

            return Stack(
              children: [
                Positioned.fill(child: mapCanvas),

                // ── Center pin overlay ─────────────────────────────────────
                if (widget.showCenterPin)
                  IgnorePointer(
                    child: Center(
                      child: Padding(
                        padding: const EdgeInsets.only(bottom: 24.0),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            if (widget.centerPinLabel != null &&
                                widget.centerPinLabel!.isNotEmpty)
                              Container(
                                margin: const EdgeInsets.only(bottom: 4),
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 8, vertical: 3),
                                decoration: BoxDecoration(
                                  color: widget.centerPinColor ??
                                      Colors.red.shade700,
                                  borderRadius: BorderRadius.circular(12),
                                  boxShadow: const [
                                    BoxShadow(
                                      color: Colors.black26,
                                      blurRadius: 4,
                                      offset: Offset(0, 2),
                                    ),
                                  ],
                                ),
                                child: Text(
                                  widget.centerPinLabel!,
                                  style: const TextStyle(
                                    color: Colors.white,
                                    fontSize: 11,
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                              ),
                            Icon(
                              Icons.location_pin,
                              size: 40,
                              color:
                                  widget.centerPinColor ?? Colors.red.shade700,
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),

                // ── Google-style center blue dot ─────────────────────────────
                // Fixed positional indicator (not the GPS dot). Renders on
                // every engine — native Google branch included — for one
                // visual standard across providers.
                if (widget.showCenterBlueDot)
                  const IgnorePointer(
                    child: GoogleStyleMapOverlay(),
                  ),

                // ── Recenter FAB ───────────────────────────────────────────
                // Shown when [showRecenterFab] is true. Unified across all
                // three providers so the UX is identical regardless of
                // which engine is active.
                if (widget.showRecenterFab && widget.onRecenterTap != null)
                  Positioned(
                    bottom: widget.recenterBottom ?? 16,
                    right: widget.recenterRight ?? 16,
                    child: MapRecenterButton(
                      key: widget.recenterKey ?? const Key('recenter_button'),
                      onTap: widget.onRecenterTap!,
                    ),
                  ),

                // ── Fallback banner ────────────────────────────────────────
                if (widget.showFallbackBanner &&
                    isFallbackActive &&
                    !_bannerDismissed)
                  MapFallbackBanner(
                    message: fallbackMessage,
                    onDismiss: () => setState(() => _bannerDismissed = true),
                  ),
              ],
            );
          },
        );
      },
    );
  }
}

/// Google Maps renderer for [SeseUniversalMap].
class _GoogleMapBranch extends StatefulWidget {
  final SeSeMapController mapController;
  final LatLng initialCenter;
  final double initialZoom;
  final List<MapPin> markers;
  final List<MapRoute> polylines;
  final bool? isDarkOverride;
  final bool showMyLocation;
  final bool myLocationButtonEnabled;

  /// Called on each Google Maps tile load error. Forwarded to the circuit breaker.
  final VoidCallback? onTileError;

  final void Function(LatLng center)? onCameraMove;
  final void Function(LatLng center)? onCameraIdle;
  final void Function(LatLng point)? onTap;

  /// Active provider identifier used to assign unique platform view keys.
  final String? providerKey;

  const _GoogleMapBranch({
    super.key,
    required this.mapController,
    required this.initialCenter,
    required this.initialZoom,
    required this.markers,
    required this.polylines,
    required this.isDarkOverride,
    this.showMyLocation = false,
    this.myLocationButtonEnabled = false,
    this.onTileError,
    this.onCameraMove,
    this.onCameraIdle,
    this.onTap,
    this.providerKey,
  });

  @override
  State<_GoogleMapBranch> createState() => _GoogleMapBranchState();
}

class _GoogleMapBranchState extends State<_GoogleMapBranch> {
  late LatLng _currentCenter;

  @override
  void initState() {
    super.initState();
    _currentCenter = widget.initialCenter;
    _ensureAndroidHybridComposition();
  }

  /// Configures Android Platform View composition mode.
  /// Uses Texture Layer Hybrid Composition (TLHC) to minimize memory allocations
  /// and avoid Scudo memory allocator exhaustion on entry-level Android devices.
  void _ensureAndroidHybridComposition() {
    final mapsPlatform = GoogleMapsFlutterPlatform.instance;
    if (mapsPlatform is GoogleMapsFlutterAndroid) {
      mapsPlatform.useAndroidViewSurface = false;
    }
  }

  @override
  void dispose() {
    widget.mapController.detachGoogle();
    super.dispose();
  }

  static double _hueFor(Color color) {
    return HSVColor.fromColor(color).hue;
  }

  Future<void> _logMapCreated(gmaps.GoogleMapController controller) async {
    widget.mapController.attachGoogle(controller);
    try {
      debugPrint(
        'SeseUniversalMap: Google map created '
        '(${widget.initialCenter.latitude.toStringAsFixed(4)}, '
        '${widget.initialCenter.longitude.toStringAsFixed(4)}) '
        'zoom ${widget.initialZoom}',
      );
      await widget.mapController.move(
        widget.initialCenter,
        widget.initialZoom.clamp(3.0, 21.0),
      );
    } catch (e) {
      debugPrint('SeseUniversalMap: map init nudge failed: $e');
      MapConfigController.instance.triggerGoogleFallback(
        reason: 'Google Maps renderer failed to initialize.',
      );
    }
  }

  static gmaps.LatLng _toG(LatLng point) =>
      gmaps.LatLng(point.latitude, point.longitude);

  @override
  Widget build(BuildContext context) {
    final isDark =
        widget.isDarkOverride ?? Theme.of(context).brightness == Brightness.dark;
    final providerKey = widget.providerKey ?? 'google_maps';
    return gmaps.GoogleMap(
      key: ValueKey('google_maps_$providerKey'),
      mapType: gmaps.MapType.normal,
      initialCameraPosition: gmaps.CameraPosition(
        target: _toG(widget.initialCenter),
        zoom: widget.initialZoom.clamp(3.0, 21.0),
      ),
      markers: {
        for (final m in widget.markers)
          gmaps.Marker(
            markerId: gmaps.MarkerId(m.id),
            position: _toG(m.point),
            icon: gmaps.BitmapDescriptor.defaultMarkerWithHue(
              _hueFor(m.color),
            ),
            infoWindow: (m.label != null && m.label!.isNotEmpty)
                ? gmaps.InfoWindow(title: m.label)
                : gmaps.InfoWindow.noText,
          ),
      },
      polylines: {
        for (final r in widget.polylines)
          gmaps.Polyline(
            polylineId: gmaps.PolylineId(r.id),
            points: r.points.map(_toG).toList(),
            color: r.color,
            width: r.width,
          ),
      },
      myLocationEnabled: widget.showMyLocation,
      myLocationButtonEnabled: widget.myLocationButtonEnabled,
      zoomGesturesEnabled: true,
      scrollGesturesEnabled: true,
      rotateGesturesEnabled: true,
      tiltGesturesEnabled: true,
      zoomControlsEnabled: false,
      gestureRecognizers: <Factory<OneSequenceGestureRecognizer>>{
        Factory<OneSequenceGestureRecognizer>(
          () => EagerGestureRecognizer(),
        ),
      },
      mapToolbarEnabled: false,
      compassEnabled: true,
      style: isDark ? _darkMapStyle : null,
      onMapCreated: (controller) {
        // ignore: discarded_futures
        _logMapCreated(controller);
      },
      onCameraMove: (pos) {
        _currentCenter = LatLng(pos.target.latitude, pos.target.longitude);
        widget.onCameraMove?.call(_currentCenter);
      },
      onCameraIdle: () {
        widget.onCameraIdle?.call(_currentCenter);
      },
      onTap: (target) {
        widget.onTap?.call(LatLng(target.latitude, target.longitude));
      },
    );
  }
}

/// Dark style for the Google branch.
const String _darkMapStyle = '''
[
  {"elementType": "geometry", "stylers": [{"color": "#212121"}]},
  {"elementType": "labels.text.fill", "stylers": [{"color": "#757575"}]},
  {"elementType": "labels.text.stroke", "stylers": [{"color": "#212121"}]},
  {"featureType": "administrative", "elementType": "geometry", "stylers": [{"color": "#757575"}]},
  {"featureType": "administrative.country", "elementType": "labels.text.fill", "stylers": [{"color": "#9e9e9e"}]},
  {"featureType": "poi", "elementType": "labels.text.fill", "stylers": [{"color": "#757575"}]},
  {"featureType": "poi.park", "elementType": "geometry", "stylers": [{"color": "#181818"}]},
  {"featureType": "road", "elementType": "geometry.fill", "stylers": [{"color": "#2c2c2c"}]},
  {"featureType": "road", "elementType": "labels.text.fill", "stylers": [{"color": "#8a8a8a"}]},
  {"featureType": "road.arterial", "elementType": "geometry", "stylers": [{"color": "#373737"}]},
  {"featureType": "road.highway", "elementType": "geometry", "stylers": [{"color": "#3c3c3c"}]},
  {"featureType": "transit", "elementType": "geometry", "stylers": [{"color": "#2f2f2f"}]},
  {"featureType": "water", "elementType": "geometry", "stylers": [{"color": "#000000"}]},
  {"featureType": "water", "elementType": "labels.text.fill", "stylers": [{"color": "#3d3d3d"}]}
]
''';
