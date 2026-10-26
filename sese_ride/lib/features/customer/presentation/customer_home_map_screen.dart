import 'dart:async';

import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import 'package:latlong2/latlong.dart';
import 'package:sese_core/sese_core.dart';

import '../../../widgets/map_provider.dart';
import '../../notifications/notification_inbox_screen.dart';
import '../../trips/models/trip_models.dart';
import '../../trips/presentation/live_trip_screen.dart';
import '../../trips/services/trip_service.dart';
import 'customer_dispatch_screen.dart';

/// Main customer home view: full-screen Google Maps view with a blue-dot
/// position marker, a re-center button, and a bottom action sheet with
/// Book Ride / Send Item / Receive Item entry cards.
///
/// Tapping a card pushes the booking flow ([CustomerDispatchScreen]) in the
/// matching mode; this widget itself stays a lightweight map entry point.
class CustomerHomeMapScreen extends StatefulWidget {
  final AppUser? user;
  final VoidCallback? onSignOut;
  final TripRepository? tripRepository;

  /// Test seam: seed map position without touching platform location APIs.
  final LatLng? initialPosition;

  const CustomerHomeMapScreen({
    super.key,
    this.user,
    this.onSignOut,
    this.tripRepository,
    this.initialPosition,
  });

  @override
  State<CustomerHomeMapScreen> createState() => _CustomerHomeMapScreenState();
}

class _CustomerHomeMapScreenState extends State<CustomerHomeMapScreen> {
  static const Color _brandAmber = Color(0xFFFFB800);

  TripRepository get _tripRepo =>
      widget.tripRepository ?? FirestoreTripRepository();

  late LatLng _position;
  final SeSeMapController _mapController = SeSeMapController();

  /// Live GPS subscription feeding the blue dot + camera follow. Cancelled
  /// in dispose; never throws (platform absence keeps the seeded default).
  StreamSubscription<Position>? _positionSub;

  @override
  void initState() {
    super.initState();
    _position =
        widget.initialPosition ?? const LatLng(6.5244, 3.3792); // Lagos
    _resolvePosition();
  }

  @override
  void dispose() {
    _positionSub?.cancel();
    super.dispose();
  }

  /// Best-effort platform fix for map centering. Never throws: falls back
  /// to the seeded default when location is unavailable.
  Future<void> _resolvePosition() async {
    try {
      final enabled = await Geolocator.isLocationServiceEnabled();
      if (!enabled) return;
      var permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        if (mounted) {
          final agreed = await ProminentLocationDisclosureDialog.showForeground(
            context,
            userId: widget.user?.uid,
          );
          if (!agreed) return;
        }
        permission = await Geolocator.requestPermission();
      }
      if (permission == LocationPermission.denied ||
          permission == LocationPermission.deniedForever) {
        return;
      }
      // Request the highest-accuracy fix the device can provide.
      // Without explicit locationSettings the platform defaults to
      // LocationAccuracy.medium (~100 m), which causes the blue dot and
      // initial pickup pin to land on a road centroid far from the true
      // position.  bestForNavigation uses GPS + sensor fusion and gives
      // sub-10 m accuracy on modern hardware; the 8 s limit prevents an
      // indefinite stall on devices where GPS takes long to acquire.
      final pos = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.bestForNavigation,
          timeLimit: Duration(seconds: 8),
        ),
      );
      if (!mounted) return;
      setState(() {
        _position = LatLng(pos.latitude, pos.longitude);
      });
      // Zoom 16 shows roughly 200 m per side — tight enough to confirm the
      // pin is on the correct building, not just the correct street block.
      _mapController.move(_position, 16.0);
      // Continuous fixes from here on: the blue dot tracks the ground truth
      // and the camera follows until the user pans (see SeSeMapController).
      // Best-effort — a dead stream simply leaves the one-shot fix in place.
      try {
        await _positionSub?.cancel();
        _positionSub = Geolocator.getPositionStream(
          locationSettings: const LocationSettings(
            accuracy: LocationAccuracy.bestForNavigation,
            distanceFilter: 5,
          ),
        ).listen((fix) {
          if (!mounted) return;
          setState(() {
            _position = LatLng(fix.latitude, fix.longitude);
          });
        });
      } catch (_) {}
    } catch (_) {
      // No platform location (e.g. widget tests) — keep seeded default.
    }
  }

  void _openBooking(
      {required int modeIndex, required String title, bool isReceiving = false}) {
    // Every card opens a focused page without the mode toggle:
    // Book Ride -> ride-hailing only; Send/Receive Item -> delivery only.
    // The Receive Item card passes the delivery direction so the location
    // picker opens with "Receiving Package" highlighted, GPS in drop-off,
    // and focus on pickup.
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => CustomerDispatchScreen(
          user: widget.user,
          initialModeIndex: modeIndex,
          showModeSelector: false,
          focusedTitle: title,
          isReceiving: isReceiving,
          initialPickupLatLng: _position,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    // No drawer / hamburger menu: Trips, Home, and Profile live in the
    // shell's bottom navigation bar; account actions moved to Profile.
    return Scaffold(
      body: Column(
        children: [
          Expanded(
            child: Stack(
              children: [
                Positioned.fill(
                  child: SeSeMapView(
                    // Initial customer browsing: Google Maps with native blue dot.
                    mapContext: MapContext.browsing,
                    mapController: _mapController,
                    initialCenter: _position,
                    // 16.0 matches the zoom used after the high-accuracy GPS
                    // fix lands, so the map never jumps when re-centering.
                    initialZoom: 16.0,
                    showMyLocation: true,
                    myLocationButtonEnabled: false,
                    showRecenterFab: true,
                    // Google-style overlay standard: fixed center dot +
                    // bottom-right target button on every engine.
                    showCenterBlueDot: true,
                    recenterBottom: 16,
                    recenterRight: 16,
                    // Re-engages GPS follow AND snaps back (bare move() would
                    // track once without restoring follow state).
                    userLocation: _position,
                    onRecenterTap: () =>
                        _mapController.recenterTo(_position, 16.0),
                    markers: const [],
                  ),
                ),
                // Real-time active order synchronization across customer devices.
                if (widget.user != null)
                  Positioned(
                    top: 0,
                    left: 16,
                    right: 68, // Leave clearance for notification bell button on the right
                    child: SafeArea(
                      child: Padding(
                        padding: const EdgeInsets.only(top: 8),
                        child: StreamBuilder<List<ActiveTrip>>(
                          stream: _tripRepo.activeTripsStream(widget.user!.uid),
                          builder: (context, snapshot) {
                            final activeTrips =
                                (snapshot.data ?? []).where((t) => t.isLive).toList();
                            if (activeTrips.isEmpty) return const SizedBox.shrink();
                            if (activeTrips.length > 1) {
                              return _buildMultiActiveTripFloatingPills(activeTrips);
                            }
                            return _buildActiveTripFloatingPill(activeTrips.first);
                          },
                        ),
                      ),
                    ),
                  ),
                // Notification bell: top-right over the map canvas.
                Positioned(
                  top: 0,
                  right: 8,
                  child: SafeArea(
                    child: Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: Material(
                        shape: const CircleBorder(),
                        elevation: 4,
                        color: Colors.white,
                        child: NotificationBellButton(
                            uid: widget.user?.uid ?? ''),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
          _buildActionSheet(),
        ],
      ),
    );
  }

  int _activePillIndex = 0;

  Widget _buildMultiActiveTripFloatingPills(List<ActiveTrip> activeTrips) {
    if (_activePillIndex >= activeTrips.length) {
      _activePillIndex = 0;
    }
    final currentTrip = activeTrips[_activePillIndex];
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _buildActiveTripFloatingPill(currentTrip),
        const SizedBox(height: 4),
        Center(
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
            decoration: BoxDecoration(
              color: (isDark ? Colors.black : Colors.white).withValues(alpha: 0.85),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: Colors.amber.shade700.withValues(alpha: 0.5)),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                GestureDetector(
                  onTap: () {
                    setState(() {
                      _activePillIndex =
                          (_activePillIndex - 1 + activeTrips.length) %
                              activeTrips.length;
                    });
                  },
                  child: const Icon(Icons.arrow_left, size: 18),
                ),
                Text(
                  '${_activePillIndex + 1} of ${activeTrips.length} active',
                  style: const TextStyle(fontSize: 10, fontWeight: FontWeight.bold),
                ),
                GestureDetector(
                  onTap: () {
                    setState(() {
                      _activePillIndex =
                          (_activePillIndex + 1) % activeTrips.length;
                    });
                  },
                  child: const Icon(Icons.arrow_right, size: 18),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildActiveTripFloatingPill(ActiveTrip trip) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;

    final isSearching = trip.status == TripStatus.searchingDriver ||
        trip.status == TripStatus.waitingForAcceptance ||
        trip.status == TripStatus.bidding ||
        trip.status == TripStatus.marketplaceOpen ||
        trip.status == TripStatus.driverPinged;

    final String statusText;
    final Color badgeColor;
    switch (trip.status) {
      case TripStatus.driverAccepted:
      case TripStatus.driverArriving:
        statusText = 'Driver En Route';
        badgeColor = const Color(0xFF2E7D32); // green
        break;
      case TripStatus.driverArrived:
        statusText = 'Driver Arrived';
        badgeColor = const Color(0xFF2E7D32);
        break;
      case TripStatus.inProgress:
        statusText = 'Trip In Progress';
        badgeColor = const Color(0xFF1976D2); // blue
        break;
      case TripStatus.needsCustomerAction:
        statusText = 'Action Needed: Boost Fare';
        badgeColor = Colors.orange.shade800;
        break;
      case TripStatus.searchingDriver:
      default:
        statusText = 'Searching for driver...';
        badgeColor = const Color(0xFFE5A93C); // gold/amber
        break;
    }

    return Material(
      key: const Key('active_trip_sync_pill'),
      elevation: 6,
      borderRadius: BorderRadius.circular(30),
      color: isDark ? const Color(0xFF1E1E1E) : Colors.white,
      child: InkWell(
        borderRadius: BorderRadius.circular(30),
        onTap: () {
          Navigator.of(context).push(
            MaterialPageRoute(
              builder: (_) => LiveTripScreen(
                tripId: trip.tripId,
                repository: _tripRepo,
              ),
            ),
          );
        },
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (isSearching) ...[
                const SizedBox(
                  width: 12,
                  height: 12,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    valueColor: AlwaysStoppedAnimation<Color>(Color(0xFFE5A93C)),
                  ),
                ),
                const SizedBox(width: 8),
              ] else ...[
                Container(
                  width: 10,
                  height: 10,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: badgeColor,
                    boxShadow: [
                      BoxShadow(
                        color: badgeColor.withValues(alpha: 0.5),
                        blurRadius: 6,
                        spreadRadius: 2,
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
              ],
              Icon(
                trip.serviceType == 'send_item' ||
                        trip.serviceType == 'receive_item'
                    ? Icons.local_shipping
                    : Icons.directions_car,
                size: 16,
                color: _brandAmber,
              ),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  statusText,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    fontWeight: FontWeight.bold,
                    fontSize: 12.5,
                  ),
                ),
              ),
              const SizedBox(width: 6),
              Text(
                'Track',
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.bold,
                  color: isDark
                      ? const Color(0xFFFFD54F)
                      : const Color(0xFFB78103),
                ),
              ),
              const Icon(
                Icons.arrow_forward_ios_rounded,
                size: 12,
                color: Color(0xFFB78103),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildActionSheet() {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final sheetBg = theme.colorScheme.surface;
    final handleColor = isDark ? Colors.grey.shade700 : Colors.grey.shade300;

    return Container(
      decoration: BoxDecoration(
        color: sheetBg,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
        boxShadow: [
          BoxShadow(
            color: isDark ? Colors.black54 : Colors.black12,
            blurRadius: 12,
            offset: const Offset(0, -4),
          ),
        ],
      ),
      // 16px gutters so the action cards span edge-to-edge on phones.
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Center(
            child: Container(
              width: 56,
              height: 5,
              decoration: BoxDecoration(
                color: handleColor,
                borderRadius: BorderRadius.circular(3),
              ),
            ),
          ),
          const SizedBox(height: 16),
          Row(
            children: [
              Expanded(
                child: _ActionCard(
                  icon: const VehicleIllustration(
                    art: VehicleArt.sedan,
                    height: 44,
                  ),
                  title: 'Book Ride',
                  subtitle: "Let's get moving",
                  onTap: () =>
                      _openBooking(modeIndex: 1, title: 'Book a Ride'),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: _ActionCard(
                  icon: const VehicleIllustration(
                    art: VehicleArt.packageSend,
                    height: 44,
                  ),
                  title: 'Send Item',
                  subtitle: 'Courier delivery',
                  onTap: () => _openBooking(modeIndex: 0, title: 'Send Item'),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: _ActionCard(
                  icon: const VehicleIllustration(
                    art: VehicleArt.packageReceive,
                    height: 44,
                  ),
                  title: 'Receive Item',
                  subtitle: 'Package pickup',
                  onTap: () => _openBooking(
                      modeIndex: 0, title: 'Receive Item', isReceiving: true),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _ActionCard extends StatelessWidget {
  final Widget icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  const _ActionCard({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final cardBg = isDark
        ? theme.colorScheme.surfaceContainerHighest
        : const Color(0xFFF1F5F9);
    final textColor = theme.colorScheme.onSurface;
    final subtitleColor = theme.textTheme.bodySmall?.color ?? Colors.grey;

    return Material(
      color: cardBg,
      borderRadius: BorderRadius.circular(16),
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 20, horizontal: 8),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              icon,
              const SizedBox(height: 12),
              Text(
                title,
                style: TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.bold,
                  color: textColor,
                ),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 4),
              Text(
                subtitle,
                style: TextStyle(
                  fontSize: 12,
                  color: subtitleColor,
                ),
                textAlign: TextAlign.center,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
