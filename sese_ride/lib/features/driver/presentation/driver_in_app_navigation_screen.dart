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

/// Full-screen in-app turn-by-turn navigation powered by OpenStreetMap.
///
/// Features:
/// - Real-time vehicle marker and camera tracking
/// - Turn banner with distance, street address and next maneuver
/// - Live speed, ETA and distance readout
/// - Quick switch button to launch Google Maps or Waze on demand
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
    // 1. Get initial GPS location
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
      if (_currentPosition.latitude != 0) {
        _fetchRoute();
      }
    }

    // 2. Stream live GPS updates. Camera follow is centralized: each fix
    // flows into SeSeMapView.userLocation, whose didUpdateWidget drives
    // followTo while the controller is following. A manual pan clears
    // follow (hook below repaints the button); no per-tick move here —
    // that would fight the user's hand AND mask gestures from detection.
    _mapController.onFollowingChanged = () {
      if (mounted) {
        setState(() {
          _isAutoTracking = _mapController.isFollowingUser;
        });
      }
    };
    _positionSub = Geolocator.getPositionStream(
      locationSettings: const LocationSettings(
        accuracy: LocationAccuracy.bestForNavigation,
        distanceFilter: 3,
      ),
    ).listen((pos) {
      if (!mounted) return;
      final newPos = LatLng(pos.latitude, pos.longitude);
      setState(() {
        _currentPosition = newPos;
        _speedKmh = (pos.speed * 3.6).clamp(0, 200);
        _recalculateRemaining();
      });
    });
  }

  Future<void> _fetchRoute() async {
    if (_currentPosition.latitude == 0 && _currentPosition.longitude == 0) {
      return;
    }

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
    // Estimate ETA based on 30km/h average urban driving speed
    _etaMinutes = (_distanceRemainingKm / 30.0 * 60).ceil().clamp(1, 999);
  }

  @override
  void dispose() {
    _mapController.onFollowingChanged = null;
    _positionSub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final topBannerBg = isDark ? const Color(0xFF1E1E24) : Colors.white;
    final bottomBarBg = isDark ? const Color(0xFF16161C) : Colors.white;

    final targetLabel = widget.isHeadingToPickup ? 'Pickup' : 'Dropoff';

    return Scaffold(
      body: Stack(
        children: [
          // ── 1. OpenStreetMap Turn-by-Turn Canvas ───────────────────────────
          // Policy-pinned to OSM: the cockpit never depends on a billed key.
          Positioned.fill(
            child: SeSeMapView(
              mapContext: MapContext.inAppNavigation,
              mapController: _mapController,
              initialCenter: _currentPosition.latitude != 0
                  ? _currentPosition
                  : widget.destination,
              initialZoom: 16.5,
              isDarkOverride: isDark,
              // Live fix: raster blue dot tracks GPS per tick and the camera
              // follows until the driver pans (recenter FAB re-engages).
              showMyLocation: true,
              userLocation: _currentPosition.latitude != 0
                  ? _currentPosition
                  : null,
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
                  label: widget.isHeadingToPickup ? 'A' : 'B',
                ),
              ],
              polylines: [
                if (_routePoints.isNotEmpty)
                  OsmMapView.route(
                    points: _routePoints,
                    color: AppColors.seseGold,
                    width: 6,
                  ),
              ],
            ),
          ),

          // ── 2. Top Turn-by-Turn Maneuver Banner ────────────────────────────
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: SafeArea(
              child: Container(
                margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: topBannerBg,
                  borderRadius: BorderRadius.circular(18),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.18),
                      blurRadius: 12,
                      offset: const Offset(0, 4),
                    ),
                  ],
                ),
                child: Row(
                  children: [
                    Container(
                      width: 48,
                      height: 48,
                      decoration: BoxDecoration(
                        color: AppColors.seseGold,
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: const Icon(
                        Icons.navigation_rounded,
                        color: Colors.black,
                        size: 28,
                      ),
                    ),
                    const SizedBox(width: 14),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            _distanceRemainingKm > 0
                                ? 'In ${_distanceRemainingKm < 1 ? '${(_distanceRemainingKm * 1000).round()} m' : '${_distanceRemainingKm.toStringAsFixed(1)} km'}'
                                : 'Following route',
                            style: const TextStyle(
                              fontSize: 18,
                              fontWeight: FontWeight.w800,
                              letterSpacing: -0.2,
                            ),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            widget.destinationAddress.isNotEmpty
                                ? '$targetLabel: ${widget.destinationAddress}'
                                : 'Heading to $targetLabel',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: Theme.of(context).textTheme.bodySmall,
                          ),
                        ],
                      ),
                    ),
                    IconButton(
                      icon: const Icon(Icons.close_rounded),
                      tooltip: 'Exit Navigation',
                      onPressed: () => Navigator.of(context).pop(),
                    ),
                  ],
                ),
              ),
            ),
          ),

          // ── 3. Floating Re-Center & External App Switcher ──────────────────
          Positioned(
            right: 16,
            bottom: 120,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                // Switch to Google Maps or Waze button
                FloatingActionButton.small(
                  heroTag: 'switch_nav_app_btn',
                  backgroundColor: topBannerBg,
                  foregroundColor: AppColors.seseGold,
                  tooltip: 'Open in Google Maps / Waze',
                  onPressed: () => NavigationLauncherService.showNavigationChooser(
                    context: context,
                    destinationLat: widget.destination.latitude,
                    destinationLng: widget.destination.longitude,
                    destinationAddress: widget.destinationAddress,
                    isHeadingToPickup: widget.isHeadingToPickup,
                    driverPosition: _currentPosition,
                  ),
                  child: const Icon(Icons.open_in_new_rounded),
                ),
                const SizedBox(height: 10),
                // Re-center on driver
                FloatingActionButton.small(
                  heroTag: 'recenter_nav_btn',
                  backgroundColor: _isAutoTracking ? AppColors.seseGold : topBannerBg,
                  foregroundColor: _isAutoTracking ? Colors.black : AppColors.seseGold,
                  tooltip: 'Re-center',
                  onPressed: () {
                    if (_currentPosition.latitude != 0) {
                      // ignore: discarded_futures
                      _mapController.recenterTo(_currentPosition, 17.0);
                    }
                  },
                  child: const Icon(Icons.my_location_rounded),
                ),
              ],
            ),
          ),

          // ── 4. Bottom Navigation Stats Bar ─────────────────────────────────
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: Container(
              // 16px gutters: nav metrics + actions span edge-to-edge.
              padding: const EdgeInsets.fromLTRB(16, 14, 16, 24),
              decoration: BoxDecoration(
                color: bottomBarBg,
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.15),
                    blurRadius: 10,
                    offset: const Offset(0, -2),
                  ),
                ],
              ),
              child: SafeArea(
                top: false,
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceAround,
                  children: [
                    _NavMetric(
                      label: 'ETA',
                      value: '$_etaMinutes min',
                      color: AppColors.seseGold,
                    ),
                    Container(width: 1, height: 32, color: Colors.grey.withValues(alpha: 0.3)),
                    _NavMetric(
                      label: 'DISTANCE',
                      value: '${_distanceRemainingKm.toStringAsFixed(1)} km',
                    ),
                    Container(width: 1, height: 32, color: Colors.grey.withValues(alpha: 0.3)),
                    _NavMetric(
                      label: 'SPEED',
                      value: '${_speedKmh.round()} km/h',
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _NavMetric extends StatelessWidget {
  final String label;
  final String value;
  final Color? color;

  const _NavMetric({
    required this.label,
    required this.value,
    this.color,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          label,
          style: Theme.of(context).textTheme.labelSmall?.copyWith(
                fontWeight: FontWeight.w600,
                letterSpacing: 0.6,
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
        ),
        const SizedBox(height: 2),
        Text(
          value,
          style: TextStyle(
            fontSize: 18,
            fontWeight: FontWeight.w800,
            color: color,
          ),
        ),
      ],
    );
  }
}
