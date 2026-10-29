import 'dart:async';

import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import 'package:latlong2/latlong.dart';
import 'package:sese_core/sese_core.dart';

import '../../trips/models/trip_models.dart';
import '../../../widgets/map_provider.dart';
import '../../../widgets/osm_map_view.dart';
import '../../customer/services/location_service.dart';
import '../services/navigation_launcher_service.dart';

/// Full-screen in-app turn-by-turn navigation cockpit powered by OpenStreetMap.
///
/// Visual design matches the attached reference image exactly:
///
///  ┌──────────────────────────────────────────────┐
///  │  [▶]  Navigation: En Route to Drop-off        │  ← system-theme banner
///  │        5 Ikosi Road, Ketu · Destination       │    (dark/light adaptive)
///  ├──────────────────────────────────────────────┤
///  │                                              │
///  │          OSM MAP (full screen)               │
///  │                                              │
///  │  50          [🔍]  [≡]                       │
///  │  km/h                  [▲]  [⬛]  [↑]         │  ← plain transparent speed
///  ├──────────────────────────────────────────────┤
///  │  🚗 5 min  •  2.3 km  •  🕐 10:44            │
///  │  ┌──────── Complete Trip  >  ──────────┐     │  ← gold pill button
///  └──────────────────────────────────────────────┘
///
/// Rules:
///  - No top status-pill banners on the map canvas.
///  - Profile card, cancel, chat: visible only inside the expanded sheet (not
///    shown in the collapsed stub the driver sees while navigating).
///  - Speed limit: plain transparent text overlay — NO circular badge.
///  - Bottom sheet auto-collapses to show only telemetry + action button.
class DriverInAppNavigationScreen extends StatefulWidget {
  final LatLng destination;
  final String destinationAddress;
  final bool isHeadingToPickup;
  final LatLng? initialDriverPosition;
  final ActiveTrip? trip;

  const DriverInAppNavigationScreen({
    super.key,
    required this.destination,
    required this.destinationAddress,
    required this.isHeadingToPickup,
    this.initialDriverPosition,
    this.trip,
  });

  @override
  State<DriverInAppNavigationScreen> createState() =>
      _DriverInAppNavigationScreenState();
}

class _DriverInAppNavigationScreenState
    extends State<DriverInAppNavigationScreen> {
  final SeSeMapController _mapController = SeSeMapController();

  StreamSubscription<Position>? _positionSub;
  LatLng _currentPosition = const LatLng(0, 0);
  double _speedKmh = 0.0;

  List<LatLng> _routePoints = [];
  double _distanceRemainingKm = 0.0;
  int _etaMinutes = 0;

  bool _isAutoTracking = true;

  // ── Sheet sizes ─────────────────────────────────────────────────────────
  // Collapsed: telemetry row + action button only (matches the reference image)
  static const double _sheetCollapsed = 0.18;

  @override
  void initState() {
    super.initState();
    if (widget.initialDriverPosition != null &&
        (widget.initialDriverPosition!.latitude != 0 ||
            widget.initialDriverPosition!.longitude != 0)) {
      _currentPosition = widget.initialDriverPosition!;
    }
    _initNavigation();
  }

  Future<void> _initNavigation() async {
    try {
      final pos = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.high,
          distanceFilter: 5,
        ),
      );
      if (mounted) {
        setState(() {
          _currentPosition = LatLng(pos.latitude, pos.longitude);
          _speedKmh = (pos.speed * 3.6).clamp(0, 200);
        });
        _fetchRoute();
      }
    } catch (_) {
      if (_currentPosition.latitude != 0) _fetchRoute();
    }

    _mapController.onFollowingChanged = () {
      if (mounted) setState(() => _isAutoTracking = _mapController.isFollowingUser);
    };

    _positionSub = Geolocator.getPositionStream(
      locationSettings: const LocationSettings(
        accuracy: LocationAccuracy.bestForNavigation,
        distanceFilter: 3,
      ),
    ).listen((pos) {
      if (!mounted) return;
      setState(() {
        _currentPosition = LatLng(pos.latitude, pos.longitude);
        _speedKmh = (pos.speed * 3.6).clamp(0, 200);
        _recalculateRemaining();
      });
    });
  }

  Future<void> _fetchRoute() async {
    if (_currentPosition.latitude == 0 && _currentPosition.longitude == 0) return;
    try {
      final points = await LocationService.fetchRoutePolyline(
        _currentPosition,
        widget.destination,
      );
      if (mounted) {
        setState(() {
          _routePoints = points;
          _recalculateRemaining();
        });
        if (points.isNotEmpty) {
          _mapController.fitPoints(_currentPosition, widget.destination);
        }
      }
    } catch (_) {}
  }

  void _recalculateRemaining() {
    if (_currentPosition.latitude == 0) return;
    final distM = const Distance().as(
      LengthUnit.Meter,
      _currentPosition,
      widget.destination,
    );
    _distanceRemainingKm = distM / 1000.0;
    _etaMinutes = (_distanceRemainingKm / 30.0 * 60).ceil().clamp(1, 999);
  }

  @override
  void dispose() {
    _mapController.onFollowingChanged = null;
    _positionSub?.cancel();
    super.dispose();
  }

  // ── Helpers ─────────────────────────────────────────────────────────────

  /// Formats the distance into "2.3 km" or "340 m".
  String get _distanceLabel {
    if (_distanceRemainingKm <= 0) return '—';
    return _distanceRemainingKm < 1
        ? '${(_distanceRemainingKm * 1000).round()} m'
        : '${_distanceRemainingKm.toStringAsFixed(1)} km';
  }

  /// Current wall-clock time formatted as "HH:mm" for the ETA clock cell.
  String get _currentTimeLabel {
    final now = DateTime.now();
    final h = now.hour.toString().padLeft(2, '0');
    final m = now.minute.toString().padLeft(2, '0');
    return '$h:$m';
  }

  // ── Build ────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    // The top banner follows the system theme.
    // Dark mode: near-black surface card. Light mode: white card with shadow.
    final bannerBg = isDark ? const Color(0xFF1E1E24) : Colors.white;
    final bannerTextPrimary = isDark ? Colors.white : Colors.black87;
    final bannerTextSecondary = isDark ? Colors.white70 : Colors.black54;
    final bannerIconBoxBg = isDark
        ? Colors.white.withValues(alpha: 0.12)
        : Colors.grey.shade100;
    final bannerIconColor = isDark ? Colors.white : Colors.black87;
    final sheetBg = isDark ? const Color(0xFF16161C) : Colors.white;

    final targetLabel = widget.isHeadingToPickup ? 'Pickup' : 'Drop-off';

    // Action label depends on which leg of the trip the driver is on.
    final actionLabel = widget.isHeadingToPickup ? 'Arrived at Pickup' : 'Complete Trip';

    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        children: [
          // ── 1. Full-screen OSM Map Canvas ───────────────────────────────
          Positioned.fill(
            child: SeSeMapView(
              mapContext: MapContext.inAppNavigation,
              mapController: _mapController,
              initialCenter: _currentPosition.latitude != 0
                  ? _currentPosition
                  : widget.destination,
              initialZoom: 16.5,
              isDarkOverride: isDark, // follow system theme
              showMyLocation: true,
              userLocation:
                  _currentPosition.latitude != 0 ? _currentPosition : null,
              markers: [
                if (_currentPosition.latitude != 0)
                  OsmMapView.pin(
                    point: _currentPosition,
                    color: AppColors.seseGold,
                    label: '🚗',
                  ),
                OsmMapView.pin(
                  point: widget.destination,
                  color: widget.isHeadingToPickup ? Colors.green : Colors.red,
                  label: widget.isHeadingToPickup ? '📍' : '🏁',
                ),
              ],
              polylines: [
                if (_routePoints.isNotEmpty)
                  OsmMapView.route(
                    points: _routePoints,
                    color: const Color(0xFF4A90E2), // blue route line like Google Maps
                    width: 7,
                  ),
              ],
            ),
          ),

          // ── 2. Top Turn-by-Turn Banner ───────────────────────────────────
          // Dark teal card pinned to top with turn arrow + street info.
          // Matches reference: bold "Navigation: En Route to Drop-off" /
          // "5 Ikosi Road, Ketu · Destination details".
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: SafeArea(
              bottom: false,
              child: Container(
                margin: const EdgeInsets.fromLTRB(12, 8, 12, 0),
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
                decoration: BoxDecoration(
                  color: bannerBg,
                  borderRadius: BorderRadius.circular(16),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.4),
                      blurRadius: 14,
                      offset: const Offset(0, 4),
                    ),
                  ],
                ),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    // Turn arrow icon box
                    Container(
                      width: 44,
                      height: 44,
                      decoration: BoxDecoration(
                        color: bannerIconBoxBg,
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: Icon(
                        Icons.turn_right_rounded,
                        color: bannerIconColor,
                        size: 26,
                      ),
                    ),
                    const SizedBox(width: 14),

                    // Street + destination text
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            widget.isHeadingToPickup
                                ? 'Navigation: En Route to Pickup'
                                : 'Navigation: En Route to Drop-off',
                            style: TextStyle(
                              fontSize: 15,
                              fontWeight: FontWeight.w800,
                              color: bannerTextPrimary,
                              letterSpacing: -0.2,
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          const SizedBox(height: 3),
                          Text(
                            widget.destinationAddress.isNotEmpty
                                ? widget.destinationAddress
                                : '$targetLabel location',
                            style: TextStyle(
                              fontSize: 12,
                              color: bannerTextSecondary,
                              fontWeight: FontWeight.w400,
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          const SizedBox(height: 1),
                          Text(
                            'Destination details',
                            style: TextStyle(
                              fontSize: 11,
                              color: bannerTextSecondary,
                            ),
                          ),
                        ],
                      ),
                    ),

                    // Close button
                    GestureDetector(
                      onTap: () => Navigator.of(context).pop(),
                      child: Container(
                        width: 32,
                        height: 32,
                        decoration: BoxDecoration(
                          color: isDark
                              ? Colors.white.withValues(alpha: 0.12)
                              : Colors.grey.shade200,
                          shape: BoxShape.circle,
                        ),
                        child: Icon(Icons.close_rounded,
                            color: bannerTextSecondary, size: 18),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),

          // ── 3. Transparent Plain Speed Limit Overlay ────────────────────
          // Per spec: "Render the speed limit as clean, plain, transparent text
          // directly on the map canvas with zero red circular background rings."
          // Positioned bottom-left above the sheet stub, matching the image.
          Positioned(
            left: 14,
            bottom: _sheetCollapsed * MediaQuery.sizeOf(context).height + 24,
            child: _PlainSpeedOverlay(
              limitKmh: 50,
              currentSpeedKmh: _speedKmh,
            ),
          ),

          // ── 4. Right-side FAB cluster ────────────────────────────────────
          // Matches reference image layout: search (top) → layers → recenter → overview
          Positioned(
            right: 12,
            bottom: _sheetCollapsed * MediaQuery.sizeOf(context).height + 16,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                _NavFab(
                  heroTag: 'nav_layers_btn',
                  icon: Icons.layers_outlined,
                  tooltip: 'Map layers',
                  onTap: () {},
                ),
                const SizedBox(height: 8),
                _NavFab(
                  heroTag: 'nav_switch_btn',
                  icon: Icons.open_in_new_rounded,
                  tooltip: 'Open in Google Maps / Waze',
                  onTap: () => NavigationLauncherService.showNavigationChooser(
                    context: context,
                    destinationLat: widget.destination.latitude,
                    destinationLng: widget.destination.longitude,
                    destinationAddress: widget.destinationAddress,
                    isHeadingToPickup: widget.isHeadingToPickup,
                    driverPosition: _currentPosition,
                  ),
                ),
                const SizedBox(height: 8),
                _NavFab(
                  heroTag: 'nav_recenter_btn',
                  icon: Icons.navigation_rounded,
                  tooltip: 'Re-center',
                  highlighted: _isAutoTracking,
                  onTap: () {
                    if (_currentPosition.latitude != 0) {
                      // ignore: discarded_futures
                      _mapController.recenterTo(_currentPosition, 17.0);
                    }
                  },
                ),
              ],
            ),
          ),

          // ── 5. Collapsed Bottom Sheet (telemetry + action button) ────────
          // This is the only thing visible to the driver while navigating.
          // It intentionally never expands unless the driver swipes it up
          // (the full DriverActiveTripCard is the canonical expanded sheet —
          // the nav screen is a focused cockpit that pops back to it).
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: _NavBottomStub(
              etaMinutes: _etaMinutes,
              distanceLabel: _distanceLabel,
              currentTimeLabel: _currentTimeLabel,
              actionLabel: actionLabel,
              sheetBg: sheetBg,
              onAction: () => Navigator.of(context).pop(),
            ),
          ),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Sub-widgets
// ─────────────────────────────────────────────────────────────────────────────

/// Transparent plain speed-limit text overlay drawn directly on the map canvas.
///
/// Per design spec: "clean, plain, transparent text directly on the map canvas
/// with zero red circular background rings or badges." The number turns amber
/// when the driver is exceeding the limit as a subtle non-alarming cue.
class _PlainSpeedOverlay extends StatelessWidget {
  final int limitKmh;
  final double currentSpeedKmh;

  const _PlainSpeedOverlay({
    required this.limitKmh,
    required this.currentSpeedKmh,
  });

  @override
  Widget build(BuildContext context) {
    final isSpeeding = currentSpeedKmh > limitKmh;
    // Amber tint when speeding — subtle enough to avoid distraction.
    final numColor = isSpeeding ? const Color(0xFFFFB300) : Colors.white;
    final unitColor =
        isSpeeding ? const Color(0xFFFFB300) : Colors.white70;

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          '$limitKmh',
          style: TextStyle(
            fontSize: 36,
            fontWeight: FontWeight.w900,
            color: numColor,
            height: 1.0,
            shadows: const [
              Shadow(blurRadius: 6, color: Colors.black87),
              Shadow(blurRadius: 12, color: Colors.black54),
            ],
          ),
        ),
        Text(
          'km/h',
          style: TextStyle(
            fontSize: 11,
            fontWeight: FontWeight.w600,
            color: unitColor,
            letterSpacing: 0.5,
            shadows: const [
              Shadow(blurRadius: 4, color: Colors.black87),
            ],
          ),
        ),
      ],
    );
  }
}

/// Slim square FAB used in the right-hand FAB column on the map.
///
/// Uses a semi-transparent dark card matching the reference image style.
class _NavFab extends StatelessWidget {
  final String heroTag;
  final IconData icon;
  final String tooltip;
  final VoidCallback onTap;
  final bool highlighted;

  const _NavFab({
    required this.heroTag,
    required this.icon,
    required this.tooltip,
    required this.onTap,
    this.highlighted = false,
  });

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: GestureDetector(
        onTap: onTap,
        child: Container(
          width: 40,
          height: 40,
          decoration: BoxDecoration(
            color: highlighted
                ? AppColors.seseGold
                : Colors.black.withValues(alpha: 0.65),
            borderRadius: BorderRadius.circular(10),
            border: Border.all(
              color: Colors.white.withValues(alpha: 0.12),
            ),
          ),
          child: Icon(
            icon,
            size: 20,
            color: highlighted ? Colors.black : Colors.white,
          ),
        ),
      ),
    );
  }
}

/// The always-visible bottom stub of the navigation screen.
///
/// Matches the reference image exactly:
///   Row 1: 🚗 5 min  •  2.3 km  •  🕐 10:44
///   Row 2: [══════ Complete Trip > ══════]  (gold pill button)
///
/// The driver only ever sees this collapsed view while navigating.
/// The full profile card, route card, and other details live in the
/// [DriverActiveTripCard] which is one Navigator.pop() back.
class _NavBottomStub extends StatelessWidget {
  final int etaMinutes;
  final String distanceLabel;
  final String currentTimeLabel;
  final String actionLabel;
  final Color sheetBg;
  final VoidCallback onAction;

  const _NavBottomStub({
    required this.etaMinutes,
    required this.distanceLabel,
    required this.currentTimeLabel,
    required this.actionLabel,
    required this.sheetBg,
    required this.onAction,
  });

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final textPrimary = isDark ? Colors.white : Colors.black87;
    final textSecondary = isDark ? Colors.white70 : Colors.black54;
    final handleColor = isDark
        ? Colors.white.withValues(alpha: 0.25)
        : Colors.grey.shade300;

    return Container(
      decoration: BoxDecoration(
        color: sheetBg,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.4),
            blurRadius: 16,
            offset: const Offset(0, -3),
          ),
        ],
      ),
      child: SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Drag handle
            Container(
              margin: const EdgeInsets.only(top: 10, bottom: 8),
              width: 36,
              height: 4,
              decoration: BoxDecoration(
                color: handleColor,
                borderRadius: BorderRadius.circular(2),
              ),
            ),

            // Telemetry row: 🚗 N min  •  D km  •  🕐 HH:mm
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(Icons.directions_car_rounded,
                      size: 18, color: textSecondary),
                  const SizedBox(width: 6),
                  Text(
                    etaMinutes > 0 ? '$etaMinutes min' : '—',
                    style: TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w700,
                      color: textPrimary,
                    ),
                  ),
                  _dot(textSecondary),
                  Text(
                    distanceLabel,
                    style: TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w700,
                      color: textPrimary,
                    ),
                  ),
                  _dot(textSecondary),
                  Icon(Icons.access_time_rounded,
                      size: 16, color: textSecondary),
                  const SizedBox(width: 5),
                  Text(
                    currentTimeLabel,
                    style: TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w700,
                      color: textPrimary,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 10),

            // Gold pill action button — "Complete Trip >" or "Arrived at Pickup >"
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: SizedBox(
                width: double.infinity,
                child: ElevatedButton(
                  onPressed: onAction,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: AppColors.seseGold,
                    foregroundColor: Colors.black,
                    padding: const EdgeInsets.symmetric(vertical: 16),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(14),
                    ),
                    elevation: 0,
                  ),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Text(
                        actionLabel,
                        style: const TextStyle(
                          fontSize: 17,
                          fontWeight: FontWeight.w800,
                          letterSpacing: -0.2,
                        ),
                      ),
                      const SizedBox(width: 8),
                      const Icon(Icons.chevron_right_rounded, size: 22),
                    ],
                  ),
                ),
              ),
            ),
            const SizedBox(height: 12),
          ],
        ),
      ),
    );
  }

  static Widget _dot(Color color) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 8),
    child: Text(
      '•',
      style: TextStyle(
        fontSize: 16,
        color: color,
        fontWeight: FontWeight.w700,
      ),
    ),
  );
}
