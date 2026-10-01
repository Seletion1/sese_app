import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import 'package:latlong2/latlong.dart';
import 'package:sese_core/sese_core.dart';

import '../../../widgets/osm_map_view.dart';
import 'customer_dispatch_screen.dart';

/// Main customer home view: full-screen OpenStreetMap view with a blue-dot
/// position marker, a re-center button, and a bottom action sheet with
/// Book Ride / Send Item / Receive Item entry cards.
///
/// Tapping a card pushes the booking flow ([CustomerDispatchScreen]) in the
/// matching mode; this widget itself stays a lightweight map entry point.
class CustomerHomeMapScreen extends StatefulWidget {
  final AppUser? user;
  final VoidCallback? onSignOut;

  /// Test seam: seed map position without touching platform location APIs.
  final LatLng? initialPosition;

  const CustomerHomeMapScreen({
    super.key,
    this.user,
    this.onSignOut,
    this.initialPosition,
  });

  @override
  State<CustomerHomeMapScreen> createState() => _CustomerHomeMapScreenState();
}

class _CustomerHomeMapScreenState extends State<CustomerHomeMapScreen> {
  static const Color _brandAmber = Color(0xFFFFB800);

  late LatLng _position;
  final SeSeMapController _mapController = SeSeMapController();

  @override
  void initState() {
    super.initState();
    _position =
        widget.initialPosition ?? const LatLng(6.5244, 3.3792); // Lagos
    _resolvePosition();
  }

  /// Best-effort platform fix for map centering. Never throws: falls back
  /// to the seeded default when location is unavailable.
  Future<void> _resolvePosition() async {
    try {
      final enabled = await Geolocator.isLocationServiceEnabled();
      if (!enabled) return;
      var permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
      }
      if (permission == LocationPermission.denied ||
          permission == LocationPermission.deniedForever) {
        return;
      }
      final pos = await Geolocator.getCurrentPosition();
      if (!mounted) return;
      setState(() {
        _position = LatLng(pos.latitude, pos.longitude);
      });
      _mapController.move(_position, 15.0);
    } catch (_) {
      // No platform location (e.g. widget tests) — keep seeded default.
    }
  }

  void _openBooking({required int modeIndex, required String title}) {
    // Every card opens a focused page without the mode toggle:
    // Book Ride -> ride-hailing only; Send/Receive Item -> delivery only.
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => CustomerDispatchScreen(
          user: widget.user,
          initialModeIndex: modeIndex,
          showModeSelector: false,
          focusedTitle: title,
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
                  child: OsmMapView(
                    mapController: _mapController,
                    initialCenter: _position,
                    initialZoom: 15.0,
                    markers: [
                      OsmMapView.pin(point: _position, color: Colors.blue),
                    ],
                  ),
                ),
                Positioned(
                  right: 16,
                  bottom: 16,
                  child: Material(
                    shape: const CircleBorder(),
                    elevation: 4,
                    color: Colors.white,
                    child: InkWell(
                      key: const Key('recenter_button'),
                      customBorder: const CircleBorder(),
                      onTap: () {
                        _mapController.move(_position, 15.0);
                      },
                      child: const Padding(
                        padding: EdgeInsets.all(14),
                        child: Icon(
                          Icons.gps_fixed,
                          color: Colors.green,
                          size: 28,
                        ),
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
      padding: const EdgeInsets.fromLTRB(20, 10, 20, 24),
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
                  icon: const Icon(
                    Icons.directions_car_filled,
                    color: _brandAmber,
                    size: 44,
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
                  icon: Container(
                    width: 44,
                    height: 44,
                    decoration: BoxDecoration(
                      color: _brandAmber,
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: const Icon(
                      Icons.arrow_upward_rounded,
                      color: Colors.white,
                      size: 28,
                    ),
                  ),
                  title: 'Send Item',
                  subtitle: 'Courier delivery',
                  onTap: () => _openBooking(modeIndex: 0, title: 'Send Item'),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: _ActionCard(
                  icon: Container(
                    width: 44,
                    height: 44,
                    decoration: BoxDecoration(
                      color: _brandAmber,
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: const Icon(
                      Icons.arrow_downward_rounded,
                      color: Colors.white,
                      size: 28,
                    ),
                  ),
                  title: 'Receive Item',
                  subtitle: 'Package pickup',
                  onTap: () =>
                      _openBooking(modeIndex: 0, title: 'Receive Item'),
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
