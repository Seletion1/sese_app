import 'dart:async';

import 'package:flutter/material.dart';
import 'package:latlong2/latlong.dart';

import '../features/customer/services/location_service.dart';
import 'map_provider.dart';

/// Interactive Center Pin Map Widget driven by [SeseUniversalMap].
///
/// Features:
/// - Unifies Google Maps, Mapbox, and CartoDB through the centralized
///   map engine configuration.
/// - The pin remains **fixed at the exact center of the map viewport** layered
///   directly above the map in a [Stack].
/// - Listens to `onCameraMove`/`onCameraIdle` across all map engines.
/// - On camera idle (debounced), triggers reverse geocoding via
///   [LocationService.reverseGeocode].
class LocationPickerMap extends StatefulWidget {
  final LatLng initialCenter;
  final double initialZoom;
  final String? initialAddress;
  final void Function(LatLng position, String address)? onLocationChanged;

  const LocationPickerMap({
    super.key,
    required this.initialCenter,
    this.initialZoom = 15.0,
    this.initialAddress,
    this.onLocationChanged,
  });

  @override
  State<LocationPickerMap> createState() => _LocationPickerMapState();
}

class _LocationPickerMapState extends State<LocationPickerMap> {
  late final SeSeMapController _mapController;
  late LatLng _currentCenter;
  String _address = '';
  bool _isGeocoding = false;
  Timer? _debounceTimer;

  @override
  void initState() {
    super.initState();
    _mapController = SeSeMapController();
    _currentCenter = widget.initialCenter;
    _address = widget.initialAddress ?? '';
    _initializeUserLocation();
  }

  Future<void> _initializeUserLocation() async {
    try {
      final userLatLng = await LocationService.getCurrentLatLng();
      if (userLatLng != null && mounted) {
        _currentCenter = userLatLng;
        // ignore: discarded_futures
        _mapController.move(userLatLng, widget.initialZoom);
        if (_address.isEmpty) {
          _reverseGeocode(userLatLng);
        }
        widget.onLocationChanged?.call(userLatLng, _address);
      } else if (_address.isEmpty) {
        _reverseGeocode(_currentCenter);
      }
    } catch (e) {
      debugPrint('Location initialization error: $e');
      if (_address.isEmpty) {
        _reverseGeocode(_currentCenter);
      }
    }
  }

  @override
  void dispose() {
    _debounceTimer?.cancel();
    super.dispose();
  }

  void _onCameraMove(LatLng center) {
    _currentCenter = center;
  }

  void _onCameraIdle(LatLng center) {
    _currentCenter = center;
    _debounceTimer?.cancel();
    _debounceTimer = Timer(const Duration(milliseconds: 600), () {
      _reverseGeocode(_currentCenter);
    });
  }

  Future<void> _reverseGeocode(LatLng target) async {
    if (!mounted) return;
    setState(() => _isGeocoding = true);
    try {
      final addr = await LocationService.reverseGeocode(
        target.latitude,
        target.longitude,
      );
      if (!mounted) return;
      setState(() {
        _address = addr;
        _isGeocoding = false;
      });
      widget.onLocationChanged?.call(target, addr);
    } catch (e) {
      if (!mounted) return;
      setState(() => _isGeocoding = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    final Widget mapCanvas = SeseUniversalMap(
      mapController: _mapController,
      initialCenter: widget.initialCenter,
      initialZoom: widget.initialZoom,
      showMyLocation: true,
      myLocationButtonEnabled: false,
      showRecenterFab: true,
      onRecenterTap: () =>
          _mapController.move(widget.initialCenter, widget.initialZoom),
      onCameraMove: _onCameraMove,
      onCameraIdle: _onCameraIdle,
    );

    return ClipRRect(
      borderRadius: BorderRadius.circular(12),
      child: Stack(
        children: [
          mapCanvas,

          // Exact Center Pin Widget
          IgnorePointer(
            child: Center(
              child: Padding(
                padding: const EdgeInsets.only(bottom: 24.0),
                child: Icon(
                  Icons.location_pin,
                  size: 40,
                  color: Colors.red.shade700,
                ),
              ),
            ),
          ),

          // Address banner overlay
          Positioned(
            left: 12,
            right: 12,
            bottom: 12,
            child: Material(
              color: theme.colorScheme.surface.withValues(alpha: 0.92),
              borderRadius: BorderRadius.circular(8),
              elevation: 4,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                child: Row(
                  children: [
                    if (_isGeocoding)
                      const Padding(
                        padding: EdgeInsets.only(right: 8),
                        child: SizedBox(
                          width: 14,
                          height: 14,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        ),
                      )
                    else
                      Padding(
                        padding: const EdgeInsets.only(right: 8),
                        child: Icon(
                          Icons.place,
                          size: 16,
                          color: theme.colorScheme.primary,
                        ),
                      ),
                    Expanded(
                      child: Text(
                        _isGeocoding
                            ? 'Locating address...'
                            : _address.isEmpty
                                ? '${_currentCenter.latitude.toStringAsFixed(4)}, ${_currentCenter.longitude.toStringAsFixed(4)}'
                                : _address,
                        style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w500),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
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
