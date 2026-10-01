import 'dart:async';

import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_overlay_window/flutter_overlay_window.dart';
import 'package:sese_core/sese_core.dart';

import 'firebase_options.dart';

/// Overlay-window entry point (background/system-window isolate).
///
/// Declared with `@pragma('vm:entry-point')` and referenced from the main
/// isolate so tree-shaking keeps it. Two modes, driven by
/// `FlutterOverlayWindow.shareData` from the main app:
///
/// - `{'mode': 'bubble'}` — persistent draggable SeSe bubble (driver ONLINE
///   + app minimized). Tap requests foreground (overlay closes; the main
///   isolate raises a return-to-app alert).
/// - `{'mode': 'order', 'offer': {...}}` — full-screen background order
///   popup (pickup, drop-off, distance, fare, live 6s countdown) with
///   ACCEPT / REJECT that call the atomic `acceptTrip` / `declineTrip`
///   callables directly from this isolate — no main-app launch needed.
/// - `{'mode': 'close'}` — dismiss.
///
/// Overlay → main messages: `{'action': 'foreground' | 'accepted' |
/// 'rejected' | 'expired', 'tripId': ...}`.
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
          : _OverlayBubble(),
    );
  }
}

/// Persistent draggable SeSe bubble (shown while ONLINE + minimized).
class _OverlayBubble extends StatelessWidget {
  Future<void> _requestForeground() async {
    try {
      await FlutterOverlayWindow.shareData({'action': 'foreground'});
    } catch (_) {}
    try {
      await FlutterOverlayWindow.closeOverlay();
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: GestureDetector(
        onTap: _requestForeground,
        child: Container(
          width: 76,
          height: 76,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: const Color(0xFF121212),
            border: Border.all(color: const Color(0xFFFFB300), width: 3),
            boxShadow: const [
              BoxShadow(color: Colors.black54, blurRadius: 8),
            ],
          ),
          padding: const EdgeInsets.all(8),
          child: const SeSeLogo(size: 60),
        ),
      ),
    );
  }
}

/// Full-screen background order popup with live 6s countdown and atomic
/// ACCEPT / REJECT executed from this isolate.
class _OverlayOrderCard extends StatefulWidget {
  final Map<String, dynamic> offer;
  final bool Function() firebaseReady;

  const _OverlayOrderCard({required this.offer, required this.firebaseReady});

  @override
  State<_OverlayOrderCard> createState() => _OverlayOrderCardState();
}

class _OverlayOrderCardState extends State<_OverlayOrderCard> {
  static const int _countdownSec = 6;
  int _remaining = _countdownSec;
  Timer? _timer;
  bool _busy = false;
  String? _result;

  String get _tripId => (widget.offer['tripId'] ?? '').toString();

  @override
  void initState() {
    super.initState();
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

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _share(Map<String, dynamic> data) async {
    try {
      await FlutterOverlayWindow.shareData(data);
    } catch (_) {}
  }

  Future<void> _close() async {
    try {
      await FlutterOverlayWindow.closeOverlay();
    } catch (_) {}
  }

  Future<void> _expire() async {
    await _share({'action': 'expired', 'tripId': _tripId});
    await _close();
  }

  Future<void> _act(String callable, String action) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      if (!widget.firebaseReady()) {
        throw StateError('Backend unavailable.');
      }
      await FirebaseFunctions.instance
          .httpsCallable(callable)
          .call({'tripId': _tripId});
      await _share({'action': action, 'tripId': _tripId});
      if (mounted) {
        setState(() => _result =
            action == 'accepted' ? 'Order accepted!' : 'Order rejected.');
      }
      await Future.delayed(const Duration(milliseconds: 800));
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
    return Material(
      color: Colors.black.withValues(alpha: 0.75),
      child: SafeArea(
        child: Center(
          child: Container(
            margin: const EdgeInsets.all(20),
            padding: const EdgeInsets.all(20),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(20),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    const SeSeLogo(size: 40),
                    const SizedBox(width: 10),
                    const Expanded(
                      child: Text('New order request',
                          style: TextStyle(
                              fontSize: 18, fontWeight: FontWeight.bold)),
                    ),
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 10, vertical: 4),
                      decoration: BoxDecoration(
                        color: _remaining <= 2
                            ? Colors.red.shade700
                            : Colors.orange.shade700,
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Text('${_remaining}s',
                          style: const TextStyle(
                              color: Colors.white,
                              fontWeight: FontWeight.bold)),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                _row(Icons.my_location, 'Pickup',
                    (o['pickup'] ?? '').toString()),
                _row(Icons.location_on, 'Drop-off',
                    (o['dropoff'] ?? '').toString()),
                _row(Icons.route, 'Distance',
                    '${o['distanceKm'] ?? '—'} km'),
                _row(Icons.payments, 'Fare', fare),
                if (_result != null) ...[
                  const SizedBox(height: 10),
                  Text(_result!,
                      textAlign: TextAlign.center,
                      style: const TextStyle(fontWeight: FontWeight.w600)),
                ],
                const SizedBox(height: 14),
                Row(
                  children: [
                    Expanded(
                      child: OutlinedButton(
                        onPressed: _busy
                            ? null
                            : () => _act('declineTrip', 'rejected'),
                        style: OutlinedButton.styleFrom(
                            foregroundColor: Colors.red,
                            padding:
                                const EdgeInsets.symmetric(vertical: 14)),
                        child: const Text('REJECT'),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: FilledButton(
                        onPressed: _busy
                            ? null
                            : () => _act('acceptTrip', 'accepted'),
                        style: FilledButton.styleFrom(
                            backgroundColor: Colors.green.shade700,
                            padding:
                                const EdgeInsets.symmetric(vertical: 14)),
                        child: Text(_busy ? 'Working…' : 'ACCEPT'),
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

  Widget _row(IconData icon, String label, String value) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 18, color: Colors.orange.shade800),
          const SizedBox(width: 8),
          SizedBox(
              width: 70,
              child: Text(label,
                  style: const TextStyle(
                      fontSize: 12, color: Colors.grey))),
          Expanded(
            child: Text(value.isEmpty ? '—' : value,
                style: const TextStyle(
                    fontSize: 13, fontWeight: FontWeight.w600)),
          ),
        ],
      ),
    );
  }
}
