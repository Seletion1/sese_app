import 'dart:async';

import 'package:flutter/material.dart';
import 'package:latlong2/latlong.dart';

import '../../../widgets/map_provider.dart';
import '../services/location_service.dart';

/// The value returned by [PickOnMapScreen] on success.
///
/// [latLng] is the map-centre the user dragged to; [address] is the
/// reverse-geocoded street address (may fall back to a raw lat/lng string
/// when every geocoding source fails — the caller should display it as-is
/// and proceed, because it is still a valid coordinate pair).
class PickOnMapResult {
  final LatLng latLng;
  final String address;
  final String targetType;

  const PickOnMapResult({
    required this.latLng,
    required this.address,
    this.targetType = 'destination',
  });
}

/// Full-screen interactive map that lets the user drag to any position and
/// confirm it as either the pickup or destination address.
///
/// The map moves freely under a fixed centre-pin overlay. Tapping "Confirm
/// Location" reverse-geocodes the current map centre via [LocationService.reverseGeocode]
/// (Google proxy → Nominatim fallback) and pops with a [PickOnMapResult].
///
/// Fully centralized: respects [MapConfigController] dynamically, rendering
/// Google Maps, Mapbox, or CartoDB based on global configuration.
class PickOnMapScreen extends StatefulWidget {
  /// Initial camera position, typically the user's last-known GPS fix so the
  /// map opens on their area, not the middle of the ocean.
  final LatLng initialCenter;

  /// Whether picking for 'pickup' or 'destination'. Defaults to 'destination'.
  final String targetType;

  const PickOnMapScreen({
    super.key,
    required this.initialCenter,
    this.targetType = 'destination',
  });

  @override
  State<PickOnMapScreen> createState() => _PickOnMapScreenState();
}

class _PickOnMapScreenState extends State<PickOnMapScreen> {
  late final SeSeMapController _mapController;

  /// Current centre of the map view, updated on every camera move.
  late LatLng _currentCenter;

  /// True while the reverse-geocode request is in flight.
  bool _geocoding = false;

  /// Debounce the reverse-geocode call so it fires 600ms after the user lifts
  /// their finger rather than on every frame during a pan gesture.
  Timer? _geocodeDebounce;

  /// Last successfully resolved address (shown in the bottom sheet so the
  /// user can see what place is under the pin without pressing Confirm).
  String _resolvedAddress = '';

  @override
  void initState() {
    super.initState();
    _mapController = SeSeMapController();
    _currentCenter = widget.initialCenter;
    // Kick off an initial geocode so the address label appears even before
    // the user pans — they see where the map opened to.
    _scheduleGeocode(_currentCenter);
  }

  @override
  void dispose() {
    _geocodeDebounce?.cancel();
    super.dispose();
  }

  // ── Geocoding ───────────────────────────────────────────────────────────────

  /// Schedules a 600ms-debounced reverse-geocode for [center].
  ///
  /// Cancels any pending request so rapid panning only triggers one call
  /// after the user settles on a position.
  void _scheduleGeocode(LatLng center) {
    _geocodeDebounce?.cancel();
    _geocodeDebounce = Timer(const Duration(milliseconds: 600), () {
      _reverseGeocode(center);
    });
  }

  Future<void> _reverseGeocode(LatLng center) async {
    if (!mounted) return;
    setState(() => _geocoding = true);
    try {
      final address = await LocationService.reverseGeocode(
        center.latitude,
        center.longitude,
      );
      if (!mounted) return;
      setState(() {
        _resolvedAddress = address;
        _geocoding = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _resolvedAddress =
            '${center.latitude.toStringAsFixed(5)}, ${center.longitude.toStringAsFixed(5)}';
        _geocoding = false;
      });
    }
  }

  // ── Confirm ─────────────────────────────────────────────────────────────────

  /// Resolves the final address (waits for any in-flight geocode to settle),
  /// then pops with the confirmed result.
  Future<void> _confirmLocation() async {
    _geocodeDebounce?.cancel();
    final center = _currentCenter;

    // If we have a fresh address from the last debounce already, use it.
    // Otherwise kick off a blocking geocode now to get a name before popping.
    String address = _resolvedAddress;
    if (address.isEmpty || _geocoding) {
      setState(() => _geocoding = true);
      try {
        address = await LocationService.reverseGeocode(
          center.latitude,
          center.longitude,
        );
      } catch (_) {
        address =
            '${center.latitude.toStringAsFixed(5)}, ${center.longitude.toStringAsFixed(5)}';
      }
      if (!mounted) return;
    }

    Navigator.of(context).pop(PickOnMapResult(
      latLng: center,
      address: address,
      targetType: widget.targetType,
    ));
  }

  // ── Build ───────────────────────────────────────────────────────────────────

  bool get _isPickup => widget.targetType == 'pickup';

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isPickup = _isPickup;
    final targetColor = isPickup ? Colors.green : (Colors.red.shade700);

    return Scaffold(
      appBar: AppBar(
        title: Text(
          isPickup
              ? 'Pin Drop — Pick Pickup Location'
              : 'Pin Drop — Pick Drop-off Location',
        ),
        leading: BackButton(onPressed: () => Navigator.of(context).pop()),
      ),
      body: Stack(
        children: [
          // ── Unified Map (Google Maps / Mapbox / CartoDB dynamic) ──────────────
          SeseUniversalMap(
            mapController: _mapController,
            initialCenter: widget.initialCenter,
            initialZoom: 16.0,
            showMyLocation: true,
            showRecenterFab: true,
            onRecenterTap: () =>
                _mapController.move(widget.initialCenter, 16.0),
            onCameraMove: (center) {
              if (center != _currentCenter) {
                _currentCenter = center;
              }
            },
            onCameraIdle: (center) {
              _currentCenter = center;
              _scheduleGeocode(center);
            },
          ),

          // ── Fixed centre-pin overlay ──────────────────────────────────────
          // The map moves underneath; the pin stays perfectly centred in the
          // viewport so the tip always indicates the selected coordinate.
          Center(
            child: IgnorePointer(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 10, vertical: 4),
                    decoration: BoxDecoration(
                      color: targetColor,
                      borderRadius: BorderRadius.circular(12),
                      boxShadow: const [
                        BoxShadow(
                          color: Colors.black26,
                          blurRadius: 4,
                          offset: Offset(0, 2),
                        ),
                      ],
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          isPickup ? Icons.trip_origin : Icons.location_on,
                          size: 12,
                          color: Colors.white,
                        ),
                        const SizedBox(width: 4),
                        Text(
                          isPickup ? 'Pickup Point' : 'Drop-off Point',
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 11,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 2),
                  Icon(
                    Icons.location_on,
                    size: 48,
                    color: targetColor,
                    shadows: const [
                      Shadow(
                        color: Colors.black38,
                        blurRadius: 8,
                        offset: Offset(0, 2),
                      ),
                    ],
                  ),
                  // Tiny transparent spacer so the pin tip lands exactly on
                  // the map point.
                  const SizedBox(height: 48),
                ],
              ),
            ),
          ),

          // ── Bottom address panel + Confirm button ─────────────────────────
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: SafeArea(
              top: false,
              child: Container(
                padding: EdgeInsets.fromLTRB(
                    16, 16, 16, MediaQuery.viewInsetsOf(context).bottom + 16),
                decoration: BoxDecoration(
                  color: theme.colorScheme.surface,
                  borderRadius:
                      const BorderRadius.vertical(top: Radius.circular(20)),
                  boxShadow: const [
                    BoxShadow(
                      color: Colors.black26,
                      blurRadius: 12,
                      offset: Offset(0, -2),
                    ),
                  ],
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // Drag handle
                    Center(
                      child: Container(
                        width: 40,
                        height: 4,
                        margin: const EdgeInsets.only(bottom: 12),
                        decoration: BoxDecoration(
                          color: theme.colorScheme.outlineVariant,
                          borderRadius: BorderRadius.circular(2),
                        ),
                      ),
                    ),
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Icon(
                          isPickup ? Icons.trip_origin : Icons.location_on,
                          color: targetColor,
                          size: 20,
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: _geocoding
                              ? const Padding(
                                  padding: EdgeInsets.symmetric(vertical: 2),
                                  child: LinearProgressIndicator(),
                                )
                              : Text(
                                  _resolvedAddress.isEmpty
                                      ? (isPickup
                                          ? 'Drag the map to select pickup location'
                                          : 'Drag the map to select drop-off location')
                                      : _resolvedAddress,
                                  style: theme.textTheme.bodyMedium,
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis,
                                ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 16),
                    SizedBox(
                      width: double.infinity,
                      child: FilledButton.icon(
                        key: const Key('pick_on_map_confirm_button'),
                        onPressed: _geocoding ? null : _confirmLocation,
                        icon: const Icon(Icons.check_circle_outline),
                        label: Text(
                          isPickup
                              ? 'Confirm Pickup Location'
                              : 'Confirm Drop-off Location',
                        ),
                        style: FilledButton.styleFrom(
                          backgroundColor:
                              isPickup ? Colors.green.shade700 : null,
                          padding: const EdgeInsets.symmetric(vertical: 14),
                        ),
                      ),
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
