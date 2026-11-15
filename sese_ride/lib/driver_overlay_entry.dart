import 'dart:async';

import 'package:app_launcher/app_launcher.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_overlay_window/flutter_overlay_window.dart';
import 'package:latlong2/latlong.dart';
import 'package:sese_core/sese_core.dart';
import 'package:shared_preferences/shared_preferences.dart';

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
    _restorePendingOffer();
    _sub = FlutterOverlayWindow.overlayListener.listen((dynamic event) {
      if (event is! Map) return;
      final map = Map<String, dynamic>.from(event);
      if (!mounted) return;
      final newMode = (map['mode'] ?? 'closed').toString();
      setState(() {
        _mode = newMode;
        final offer = map['offer'];
        _offer = offer is Map ? Map<String, dynamic>.from(offer) : const {};
      });
      if (newMode == 'close' || newMode == 'closed') {
        _closeOverlayNow();
      }
    });
  }

  Future<void> _restorePendingOffer() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString('pending_offer_payload');
      if (raw != null && raw.isNotEmpty) {
        final out = <String, String>{};
        for (final part in raw.split('&')) {
          final i = part.indexOf('=');
          if (i < 0) continue;
          out[Uri.decodeComponent(part.substring(0, i))] =
              Uri.decodeComponent(part.substring(i + 1));
        }
        final tripId = out['tripId'] ?? '';
        if (tripId.isNotEmpty && mounted) {
          setState(() {
            _mode = 'order';
            _offer = out;
          });
        }
      }
    } catch (_) {}
  }

  Future<void> _closeOverlayNow() async {
    try {
      if (await FlutterOverlayWindow.isActive()) {
        await FlutterOverlayWindow.closeOverlay().timeout(
          const Duration(milliseconds: 300),
          onTimeout: () => false,
        );
      }
    } catch (_) {}
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
    Widget content;
    if (_mode == 'order' && _offer.isNotEmpty) {
      content = _OverlayOrderCard(
        offer: _offer,
        firebaseReady: () => _firebaseReady,
        onDismiss: () {
          if (mounted) {
            setState(() {
              _mode = 'bubble';
              _offer = const {};
            });
          }
          unawaited(FlutterOverlayWindow.resizeOverlay(140, 140, true));
          unawaited(FlutterOverlayWindow.updateFlag(OverlayFlag.defaultFlag));
        },
      );
    } else if (_mode == 'bubble') {
      content = const _OverlayBubble();
    } else {
      content = const SizedBox.shrink();
    }

    return MaterialApp(
      debugShowCheckedModeBanner: false,
      home: content,
    );
  }
}

/// Persistent draggable SeSe bubble (shown while ONLINE + minimized).
///
/// Circular floating widget: round SeSe logo face with thin gold border and
/// elevation/shadow, freely draggable along screen edges (drag handling is
/// owned by the overlay window). Single tap brings `sese_ride` back to the
/// foreground and dismisses the bubble.
class OverlayBubble extends StatelessWidget {
  const OverlayBubble({super.key});

  Future<void> _requestForeground() async {
    try {
      await AppLauncher().bringToForeground();
    } catch (e) {
      debugPrint('OverlayBubble bringToForeground failed: $e');
    }
    try {
      await FlutterOverlayWindow.shareData(
          {'action': 'foreground', 'tripId': ''});
    } catch (_) {}
    try {
      if (await FlutterOverlayWindow.isActive()) {
        await FlutterOverlayWindow.closeOverlay().timeout(
          const Duration(milliseconds: 300),
          onTimeout: () => false,
        );
      }
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

typedef _OverlayBubble = OverlayBubble;

/// Full-screen background order popup with 30s countdown, interactive OpenStreetMap route
/// preview, audio/haptic alerts, and atomic ACCEPT / DECLINE execution.
class OverlayOrderCard extends StatefulWidget {
  final Map<String, dynamic> offer;
  final bool Function() firebaseReady;
  final VoidCallback? onDismiss;

  const OverlayOrderCard({
    super.key,
    required this.offer,
    required this.firebaseReady,
    this.onDismiss,
  });

  @override
  State<OverlayOrderCard> createState() => _OverlayOrderCardState();
}

typedef _OverlayOrderCard = OverlayOrderCard;

class _OverlayOrderCardState extends State<OverlayOrderCard> {
  final MapController _mapController = MapController();
  static const int _countdownSec = 30;
  int _remaining = _countdownSec;
  Timer? _timer;
  Timer? _vibrateTimer;
  bool _busy = false;
  bool _dismissed = false;

  String get _tripId => (widget.offer['tripId'] ?? '').toString();

  @override
  void initState() {
    super.initState();
    _startAlerts();
    _timer = Timer.periodic(const Duration(seconds: 1), (t) {
      if (!mounted || _dismissed) {
        t.cancel();
        return;
      }
      if (_remaining <= 1) {
        t.cancel();
        if (mounted) setState(() => _remaining = 0);
        _expire();
        return;
      }
      if (mounted) setState(() => _remaining--);
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
      if (await FlutterOverlayWindow.isActive()) {
        await FlutterOverlayWindow.closeOverlay().timeout(
          const Duration(milliseconds: 300),
          onTimeout: () => false,
        );
      }
    } catch (_) {}
  }

  /// Instantly dismisses overlay on countdown reaching 0s and informs backend in background.
  Future<void> _expire() async {
    if (_dismissed) return;
    if (mounted) {
      setState(() => _dismissed = true);
    } else {
      _dismissed = true;
    }
    _stopAlerts();

    // Immediately notify UI and close overlay window so card vanishes without lingering.
    widget.onDismiss?.call();
    unawaited(_close());

    unawaited(_share({'action': 'expired', 'tripId': _tripId}));
    try {
      if (widget.firebaseReady()) {
        unawaited(
          FirebaseFunctions.instance
              .httpsCallable('declineTrip')
              .call({'tripId': _tripId, 'action': 'skipped'})
              .then<void>((_) {})
              .catchError((e) {
                debugPrint('Overlay expire declineTrip error: $e');
              }),
        );
      }
    } catch (_) {}
  }

  /// Instantly dismisses overlay on Decline tap without waiting for network.
  Future<void> _decline() async {
    if (_busy || _dismissed) return;
    if (mounted) {
      setState(() {
        _busy = true;
        _dismissed = true;
      });
    } else {
      _busy = true;
      _dismissed = true;
    }
    _stopAlerts();

    // Immediately notify UI and close overlay window with 0 delay.
    widget.onDismiss?.call();
    unawaited(_close());

    unawaited(_share({'action': 'rejected', 'tripId': _tripId}));
    try {
      if (widget.firebaseReady()) {
        unawaited(
          FirebaseFunctions.instance
              .httpsCallable('declineTrip')
              .call({'tripId': _tripId, 'action': 'rejected'})
              .then<void>((_) {})
              .catchError((e) {
                debugPrint('Overlay declineTrip error: $e');
              }),
        );
      }
    } catch (_) {}
  }

  /// Handles Accept tap:
  /// - On low balance: immediately dismisses overlay, brings app to foreground,
  ///   and triggers the low balance top up prompt.
  /// - On success: immediately dismisses overlay, brings app to foreground to live trip.
  /// - On error: immediately dismisses overlay and opens app.
  Future<void> _accept() async {
    if (_busy || _dismissed) return;
    setState(() => _busy = true);
    _stopAlerts();

    try {
      if (!widget.firebaseReady()) {
        throw StateError('Backend unavailable.');
      }
      await FirebaseFunctions.instance
          .httpsCallable('acceptTrip')
          .call({'tripId': _tripId, 'action': 'accepted'});

      if (mounted) {
        setState(() => _dismissed = true);
      } else {
        _dismissed = true;
      }
      widget.onDismiss?.call();
      await _share({'action': 'accepted', 'tripId': _tripId});

      // Bring app to full foreground immediately on Accept so driver sees active ride.
      await DriverOverlayService.instance.bringToForeground();
      await _close();
    } catch (e) {
      debugPrint('overlay acceptTrip failed: $e');
      final errorStr = e.toString().toLowerCase();
      final isLowBalance = errorStr.contains('balance is low') ||
          errorStr.contains('top up') ||
          errorStr.contains('insufficient');

      if (mounted) {
        setState(() => _dismissed = true);
      } else {
        _dismissed = true;
      }
      widget.onDismiss?.call();
      await _close();

      if (isLowBalance) {
        // Driver tapped Accept with insufficient wallet balance:
        // Dismiss overlay immediately, notify app, and bring to foreground for top up prompt.
        await _share({'action': 'low_balance', 'tripId': _tripId});
        await DriverOverlayService.instance.bringToForeground();
      } else {
        await _share({'action': 'error', 'tripId': _tripId, 'error': e.toString()});
        await DriverOverlayService.instance.bringToForeground();
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_dismissed) return const SizedBox.shrink();
    final o = widget.offer;
    final fare = (o['fareFormatted'] ?? '').toString().isNotEmpty
        ? o['fareFormatted'].toString()
        : '₦${o['fareAmount'] ?? '—'}';

    final double? pLat = safeNum(o['pickupLat'])?.toDouble();
    final double? pLng = safeNum(o['pickupLng'])?.toDouble();
    final double? dLat = safeNum(o['dropoffLat'])?.toDouble();
    final double? dLng = safeNum(o['dropoffLng'])?.toDouble();

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
                _detailRow(Icons.my_location, 'Pickup', (o['pickupAddress'] ?? o['pickup'] ?? '').toString(), Colors.greenAccent),
                _detailRow(Icons.location_on, 'Drop-off', (o['dropoffAddress'] ?? o['dropoff'] ?? '').toString(), Colors.redAccent),
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

                const SizedBox(height: 16),

                // Action Buttons: DECLINE vs ACCEPT
                Row(
                  children: [
                    Expanded(
                      child: OutlinedButton(
                        onPressed: (_busy || _dismissed) ? null : _decline,
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
                        onPressed: (_busy || _dismissed) ? null : _accept,
                        style: ElevatedButton.styleFrom(
                          backgroundColor: const Color(0xFFF2A900),
                          foregroundColor: Colors.black,
                          padding: const EdgeInsets.symmetric(vertical: 14),
                          elevation: 4,
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(12),
                          ),
                        ),
                        child: Text(
                          _busy ? 'Working…' : 'Accept for $fare',
                          style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
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

