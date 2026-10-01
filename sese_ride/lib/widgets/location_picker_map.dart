import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import '../features/customer/services/location_service.dart';

/// Interactive Center Pin Map Widget with OpenStreetMap (flutter_map).
///
/// Features:
/// - OpenStreetMap rendered using [FlutterMap].
/// - The pin remains **fixed at the exact center of the map viewport** layered directly above the map in a [Stack].
/// - Listens to [MapOptions.onPositionChanged] with `hasGesture` to track camera center moves.
/// - On pan end / camera idle (debounced), triggers reverse geocoding against Nominatim / OpenStreetMap
///   API using `currentCenter` (LatLng) to fetch and display the human-readable address.
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
  late final MapController _mapController;
  late LatLng _currentCenter;
  String _address = '';
  bool _isGeocoding = false;
  Timer? _debounceTimer;

  @override
  void initState() {
    super.initState();
    _mapController = MapController();
    _currentCenter = widget.initialCenter;
    _address = widget.initialAddress ?? '';
    _initializeUserLocation();
  }

  Future<void> _initializeUserLocation() async {
    try {
      final userLatLng = await LocationService.getCurrentLatLng();
      if (userLatLng != null && mounted) {
        _currentCenter = userLatLng;
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
    _mapController.dispose();
    super.dispose();
  }

  void _onPositionChanged(MapCamera camera, bool hasGesture) {
    if (hasGesture) {
      _currentCenter = camera.center;
      _debounceTimer?.cancel();
      _debounceTimer = Timer(const Duration(milliseconds: 600), () {
        _reverseGeocode(_currentCenter);
      });
    }
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
    final isDark = theme.brightness == Brightness.dark;

    final tileUrl = isDark
        ? 'https://{s}.basemaps.cartocdn.com/dark_all/{z}/{x}/{y}.png'
        : 'https://tile.openstreetmap.org/{z}/{x}/{y}.png';

    return ClipRRect(
      borderRadius: BorderRadius.circular(12),
      child: Stack(
        children: [
          FlutterMap(
            mapController: _mapController,
            options: MapOptions(
              initialCenter: widget.initialCenter,
              initialZoom: widget.initialZoom,
              minZoom: 3,
              maxZoom: 19,
              onPositionChanged: _onPositionChanged,
            ),
            children: [
              TileLayer(
                urlTemplate: tileUrl,
                subdomains: const ['a', 'b', 'c', 'd'],
                userAgentPackageName: 'com.sese.ride',
              ),
              const RichAttributionWidget(
                attributions: [
                  TextSourceAttribution('© OpenStreetMap contributors'),
                ],
              ),
            ],
          ),

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
