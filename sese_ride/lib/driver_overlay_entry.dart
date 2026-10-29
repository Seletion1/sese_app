import 'dart:async';

import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_overlay_window/flutter_overlay_window.dart';
import 'package:latlong2/latlong.dart';
import 'package:sese_core/sese_core.dart';

import 'features/driver/services/driver_overlay_service.dart';
import 'firebase_options.dart';

/// Overlay-window entry point (background/system-window isolate).
///
/// Declared with `@pragma('vm:entry-point')` and referenced from the main
/// isolate so tree-shaking keeps it. Two modes, driven by
/// `FlutterOverlayWindow.shareData` from the main app:
///
/// - `{'mode': 'bubble'}` — persistent draggable SeSe bubble (driver ONLINE
///   + app minimized). Gold border (#F2A900) circular badge with SeSe logo.
///   Tap brings sese_ride directly to foreground via Intent.FLAG_ACTIVITY_REORDER_TO_FRONT.
/// - `{'mode': 'order', 'offer': {...}}` — full-screen background order
///   popup (pickup, drop-off, distance, fare, interactive map, 30s countdown) with
///   ACCEPT / DECLINE that call the atomic `acceptTrip` / `declineTrip`
///   callables directly from this isolate.
/// - `{'mode': 'close'}` — dismiss.
@pragma('vm:entry-point')
void overlayMain() {
  runApp(const _DriverOverlayApp());
}

class _DriverOverlayApp extends StatefulWidget {
  const _DriverOverlayApp();

  @override
  State<_DriverOverlayApp> createState() => _DriverOverlayAppState();
}

class _DriverOverlayAppState extends State<_DriverOverlayApp> {
  String _mode = 'bubble';
  Map<String, dynamic> _offer = const {};
  StreamSubscription<dynamic>? _sub;
  bool _firebaseReady = false;

  @override
  void initState() {
    super.initState();
    _initFirebase();
    _sub = FlutterOverlayWindow.overlayListener.listen((dynamic event) {
      if (event is! Map) return;
      final map = Map<String, dynamic>.from(event);
      if (!mounted) return;
      setState(() {
        _mode = (map['mode'] ?? 'bubble').toString();
        final offer = map['offer'];
        _offer = offer is Map ? Map<String, dynamic>.from(offer) : const {};
      });
    });
  }

  Future<void> _initFirebase() async {
    try {
      await Firebase.initializeApp(
        options: DefaultFirebaseOptions.currentPlatform,
      );
      _firebaseReady = true;
    } catch (e) {
      debugPrint('overlayMain: Firebase init failed: $e');
    }
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      home: _mode == 'order' && _offer.isNotEmpty
          ? _OverlayOrderCard(
              offer: _offer,
              firebaseReady: () => _firebaseReady,
            )
          : const _OverlayBubble(),
    );
  }
}

/// Persistent draggable SeSe bubble (shown while ONLINE + minimized).
///
/// Circular floating widget: round SeSe logo face with thin gold border and
/// elevation/shadow, freely draggable along screen edges (drag handling is
/// owned by the overlay window). Single tap brings `sese_ride` back to the
/// foreground and dismisses the bubble.
class _OverlayBubble extends StatelessWidget {
  const _OverlayBubble();

  Future<void> _requestForeground() async {
    // Notify the main isolate first so it can hide state + foreground the
    // app even if the direct channel call below is unavailable in this
    // background isolate.
    try {
      await FlutterOverlayWindow.shareData(
          {'action': 'foreground', 'tripId': ''});
    } catch (_) {}
    try {
      await DriverOverlayService.instance.bringToForeground();
    } catch (_) {}
    try {
      await FlutterOverlayWindow.closeOverlay();
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.transparent,
      body: SafeArea(
        child: Center(
          child: Material(
            color: Colors.transparent,
            child: InkWell(
              borderRadius: BorderRadius.circular(44),
              onTap: _requestForeground,
              child: Container(
                height: 88,
                width: 88,
                decoration: BoxDecoration(
                  color: const Color(0xFF1E1E1E),
                  shape: BoxShape.circle,
                  border: Border.all(
                    color: const Color(0xFFF2A900),
                    width: 2,
                  ),
                  boxShadow: const [
                    BoxShadow(
                      color: Colors.black54,
                      blurRadius: 10,
                      offset: Offset(0, 4),
                    ),
                  ],
                ),
                child: const Center(
                  child: SeSeLogo(size: 56),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Full-screen background order popup with 30s countdown, interactive OpenStreetMap route
/// preview, audio/haptic alerts, and atomic ACCEPT / DECLINE execution.
class _OverlayOrderCard extends StatefulWidget {
  final Map<String, dynamic> offer;
  final bool Function() firebaseReady;

  const _OverlayOrderCard({required this.offer, required this.firebaseReady});

  @override
  State<_OverlayOrderCard> createState() => _OverlayOrderCardState();
}

class _OverlayOrderCardState extends State<_OverlayOrderCard> {
  final MapController _mapController = MapController();
  static const int _countdownSec = 30;
  int _remaining = _countdownSec;
  Timer? _timer;
  Timer? _vibrateTimer;
  bool _busy = false;
  String? _result;

  String get _tripId => (widget.offer['tripId'] ?? '').toString();

  @override
  void initState() {
    super.initState();
    _startAlerts();
    _timer = Timer.periodic(const Duration(seconds: 1), (t) {
      if (!mounted) return;
      if (_remaining <= 1) {
        t.cancel();
        _expire();
        return;
      }
      setState(() => _remaining--);
    });
  }

  void _startAlerts() {
    AppSoundService.instance.playIncomingOrderAlert();
    HapticFeedback.vibrate();
    _vibrateTimer = Timer.periodic(const Duration(milliseconds: 1500), (_) {
      HapticFeedback.vibrate();
    });
  }

  void _stopAlerts() {
    AppSoundService.instance.stopIncomingOrderAlert();
    _vibrateTimer?.cancel();
    _vibrateTimer = null;
  }

  @override
  void dispose() {
    _stopAlerts();
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _share(Map<String, dynamic> data) async {
    try {
      await FlutterOverlayWindow.shareData(data);
    } catch (_) {}
  }

  Future<void> _close() async {
    _stopAlerts();
    try {
      await FlutterOverlayWindow.closeOverlay();
    } catch (_) {}
  }

  Future<void> _expire() async {
    _stopAlerts();
    await _share({'action': 'expired', 'tripId': _tripId});
    await _close();
  }

  Future<void> _act(String callable, String action) async {
    if (_busy) return;
    setState(() => _busy = true);
    _stopAlerts();
    try {
      if (!widget.firebaseReady()) {
        throw StateError('Backend unavailable.');
      }
      await FirebaseFunctions.instance
          .httpsCallable(callable)
          .call({'tripId': _tripId});
      await _share({'action': action, 'tripId': _tripId});
      // Bring app to full foreground immediately on both Accept and Reject per spec
      await DriverOverlayService.instance.bringToForeground();
      if (mounted) {
        setState(() => _result =
            action == 'accepted' ? 'Trip Accepted! Opening app…' : 'Trip Declined. Opening app…');
      }
      await Future.delayed(const Duration(milliseconds: 300));
      await _close();
    } catch (e) {
      debugPrint('overlay $callable failed: $e');
      if (mounted) {
        setState(() {
          _busy = false;
          _result = 'Action failed — open the app to retry.';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final o = widget.offer;
    final fare = (o['fareFormatted'] ?? '').toString().isNotEmpty
        ? o['fareFormatted'].toString()
        : '₦${o['fareAmount'] ?? '—'}';

    final double? pLat = (o['pickupLat'] as num?)?.toDouble();
    final double? pLng = (o['pickupLng'] as num?)?.toDouble();
    final double? dLat = (o['dropoffLat'] as num?)?.toDouble();
    final double? dLng = (o['dropoffLng'] as num?)?.toDouble();

    final pickupPoint = pLat != null && pLng != null ? LatLng(pLat, pLng) : null;
    final dropoffPoint = dLat != null && dLng != null ? LatLng(dLat, dLng) : null;

    LatLng mapCenter = const LatLng(9.0765, 7.3986); // Nigeria center default
    if (pickupPoint != null && dropoffPoint != null) {
      mapCenter = LatLng(
        (pickupPoint.latitude + dropoffPoint.latitude) / 2,
        (pickupPoint.longitude + dropoffPoint.longitude) / 2,
      );
    } else if (pickupPoint != null) {
      mapCenter = pickupPoint;
    } else if (dropoffPoint != null) {
      mapCenter = dropoffPoint;
    }

    final double progress = _remaining / _countdownSec;

    return Material(
      color: Colors.black.withValues(alpha: 0.82),
      child: SafeArea(
        child: Center(
          child: Container(
            margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
            padding: const EdgeInsets.all(18),
            decoration: BoxDecoration(
              color: const Color(0xFF1E1E1E),
              borderRadius: BorderRadius.circular(24),
              border: Border.all(color: const Color(0xFFF2A900), width: 1.5),
              boxShadow: const [
                BoxShadow(color: Colors.black87, blurRadius: 16, offset: Offset(0, 6)),
              ],
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // Header + 30s Countdown
                Row(
                  children: [
                    const SeSeLogo(size: 38),
                    const SizedBox(width: 10),
                    const Expanded(
                      child: Text(
                        'Incoming Trip Request',
                        style: TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.bold,
                          color: Colors.white,
                        ),
                      ),
                    ),
                    Stack(
                      alignment: Alignment.center,
                      children: [
                        SizedBox(
                          width: 44,
                          height: 44,
                          child: CircularProgressIndicator(
                            value: progress,
                            strokeWidth: 3.5,
                            backgroundColor: Colors.white12,
                            valueColor: AlwaysStoppedAnimation<Color>(
                              _remaining <= 5 ? Colors.redAccent : const Color(0xFFF2A900),
                            ),
                          ),
                        ),
                        Text(
                          '${_remaining}s',
                          style: TextStyle(
                            color: _remaining <= 5 ? Colors.redAccent : Colors.white,
                            fontWeight: FontWeight.bold,
                            fontSize: 13,
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
                const SizedBox(height: 14),

                // Interactive Route Map Preview
                ClipRRect(
                  borderRadius: BorderRadius.circular(16),
                  child: SizedBox(
                    height: 140,
                    child: Stack(
                      children: [
                        FlutterMap(
                          mapController: _mapController,
                          options: MapOptions(
                            initialCenter: mapCenter,
                            initialZoom: pickupPoint != null && dropoffPoint != null ? 12 : 14,
                            interactionOptions: const InteractionOptions(
                              flags: InteractiveFlag.all,
                            ),
                          ),
                          children: [
                            TileLayer(
                              // Managed config (Hub-driven provider chain),
                              // full Voyager spec: subdomains + retina `{r}`.
                              urlTemplate: MapConfigController.instance.currentConfig.resolveTileUrl(),
                              subdomains: const ['a', 'b', 'c', 'd'],
                              userAgentPackageName: 'com.sesetech.sese_ride',
                              retinaMode: true,
                            ),
                            if (pickupPoint != null && dropoffPoint != null)
                              PolylineLayer(
                                polylines: [
                                  Polyline(
                                    points: [pickupPoint, dropoffPoint],
                                    strokeWidth: 4.5,
                                    color: const Color(0xFFF2A900),
                                  ),
                                ],
                              ),
                            MarkerLayer(
                              markers: [
                                // Live Driver/User Blue Dot Position
                                Marker(
                                  point: mapCenter,
                                  width: 28,
                                  height: 28,
                                  child: Container(
                                    decoration: BoxDecoration(
                                      shape: BoxShape.circle,
                                      color: const Color(0xFF4285F4).withValues(alpha: 0.25),
                                      border: Border.all(
                                        color: const Color(0xFF4285F4).withValues(alpha: 0.5),
                                        width: 1.5,
                                      ),
                                    ),
                                    child: Center(
                                      child: Container(
                                        width: 14,
                                        height: 14,
                                        decoration: BoxDecoration(
                                          shape: BoxShape.circle,
                                          color: const Color(0xFF4285F4),
                                          border: Border.all(color: Colors.white, width: 2),
                                        ),
                                      ),
                                    ),
                                  ),
                                ),
                                if (pickupPoint != null)
                                  Marker(
                                    point: pickupPoint,
                                    width: 32,
                                    height: 32,
                                    child: const Icon(
                                      Icons.location_on_rounded,
                                      color: Colors.greenAccent,
                                      size: 26,
                                    ),
                                  ),
                                if (dropoffPoint != null)
                                  Marker(
                                    point: dropoffPoint,
                                    width: 32,
                                    height: 32,
                                    child: const Icon(
                                      Icons.location_on_rounded,
                                      color: Colors.redAccent,
                                      size: 26,
                                    ),
                                  ),
                              ],
                            ),
                          ],
                        ),
                        // One-Touch Camera Recenter Button
                        Positioned(
                          right: 8,
                          bottom: 8,
                          child: GestureDetector(
                            onTap: () {
                              _mapController.move(
                                mapCenter,
                                pickupPoint != null && dropoffPoint != null ? 12 : 14,
                              );
                            },
                            child: Container(
                              padding: const EdgeInsets.all(6),
                              decoration: BoxDecoration(
                                color: Colors.black.withValues(alpha: 0.7),
                                shape: BoxShape.circle,
                                border: Border.all(color: Colors.white38),
                              ),
                              child: const Icon(Icons.my_location, color: Colors.white, size: 18),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 14),

                // Trip Details
                _detailRow(Icons.my_location, 'Pickup', (o['pickup'] ?? '').toString(), Colors.greenAccent),
                _detailRow(Icons.location_on, 'Drop-off', (o['dropoff'] ?? '').toString(), Colors.redAccent),
                Row(
                  children: [
                    Expanded(
                      child: _detailRow(Icons.route, 'Distance', '${o['distanceKm'] ?? '—'} km', const Color(0xFFF2A900)),
                    ),
                    Expanded(
                      child: _detailRow(Icons.payments_rounded, 'Est. Fare', fare, const Color(0xFFF2A900)),
                    ),
                  ],
                ),

                if (_result != null) ...[
                  const SizedBox(height: 8),
                  Text(
                    _result!,
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      color: Color(0xFFF2A900),
                      fontWeight: FontWeight.w600,
                      fontSize: 14,
                    ),
                  ),
                ],
                const SizedBox(height: 16),

                // Action Buttons: DECLINE vs ACCEPT
                Row(
                  children: [
                    Expanded(
                      child: OutlinedButton(
                        onPressed: _busy ? null : () => _act('declineTrip', 'rejected'),
                        style: OutlinedButton.styleFrom(
                          foregroundColor: Colors.redAccent,
                          side: const BorderSide(color: Colors.redAccent, width: 1.5),
                          padding: const EdgeInsets.symmetric(vertical: 14),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(12),
                          ),
                        ),
                        child: const Text(
                          'DECLINE',
                          style: TextStyle(fontWeight: FontWeight.bold, fontSize: 15),
                        ),
                      ),
                    ),
                    const SizedBox(width: 14),
                    Expanded(
                      child: ElevatedButton(
                        onPressed: _busy ? null : () => _act('acceptTrip', 'accepted'),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: Colors.green.shade600,
                          foregroundColor: Colors.white,
                          padding: const EdgeInsets.symmetric(vertical: 14),
                          elevation: 4,
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(12),
                          ),
                        ),
                        child: Text(
                          _busy ? 'Working…' : 'ACCEPT',
                          style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 15),
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _detailRow(IconData icon, String label, String value, Color iconColor) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 18, color: iconColor),
          const SizedBox(width: 8),
          SizedBox(
            width: 65,
            child: Text(
              label,
              style: const TextStyle(fontSize: 12, color: Colors.grey),
            ),
          ),
          Expanded(
            child: Text(
              value.isEmpty ? '—' : value,
              style: const TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: Colors.white,
              ),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }
}

