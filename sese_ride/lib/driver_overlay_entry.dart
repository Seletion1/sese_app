import 'dart:async';

import 'package:app_launcher/app_launcher.dart';
import 'package:flutter/material.dart';
import 'package:flutter_overlay_window/flutter_overlay_window.dart';
import 'package:sese_core/sese_core.dart';

/// Overlay-window entry point for the policy-compliant floating quick-return bubble (Android-only).
///
/// Declared with `@pragma('vm:entry-point')` so Flutter's Dart compiler does not tree-shake it.
/// Runs inside the secondary FlutterEngine managed by [OverlayService].
///
/// Policy & Compliance Guarantees:
/// 1. Compact 88x88 circular floating bubble that does not obstruct system navigation.
/// 2. Zero ads, zero deceptive overlays, zero popups.
/// 3. One-tap quick return: Tapping the bubble immediately calls [AppLauncher.bringToForeground]
///    to restore the main `sese_ride` app and dismisses the floating overlay.
/// 4. Easy dismissal: The bubble includes a quick-dismiss target and can be closed at any time.
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
  StreamSubscription<dynamic>? _overlaySub;

  @override
  void initState() {
    super.initState();
    _overlaySub = FlutterOverlayWindow.overlayListener.listen((dynamic event) {
      if (event is! Map) return;
      final map = Map<String, dynamic>.from(event);
      if (map['action'] == 'close') {
        _dismissBubble();
      }
    });
  }

  @override
  void dispose() {
    _overlaySub?.cancel();
    super.dispose();
  }

  Future<void> _dismissBubble() async {
    try {
      if (await FlutterOverlayWindow.isActive()) {
        await FlutterOverlayWindow.closeOverlay();
      }
    } catch (e) {
      debugPrint('DriverOverlayApp: closeOverlay failed: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      home: OverlayBubble(onDismiss: _dismissBubble),
    );
  }
}

/// Compact circular floating bubble.
class OverlayBubble extends StatefulWidget {
  final VoidCallback? onDismiss;

  const OverlayBubble({super.key, this.onDismiss});

  @override
  State<OverlayBubble> createState() => _OverlayBubbleState();
}

class _OverlayBubbleState extends State<OverlayBubble> {
  bool _showDismissTarget = false;

  Future<void> _requestForeground() async {
    try {
      // Restore sese_ride Activity to the foreground
      await AppLauncher().bringToForeground();
    } catch (e) {
      debugPrint('OverlayBubble: bringToForeground failed: $e');
    }

    try {
      // Notify main isolate and close the overlay window
      await FlutterOverlayWindow.shareData({'action': 'foreground'});
      if (await FlutterOverlayWindow.isActive()) {
        await FlutterOverlayWindow.closeOverlay();
      }
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.transparent,
      body: SafeArea(
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // Circular Floating Bubble
              Material(
                color: Colors.transparent,
                child: InkWell(
                  borderRadius: BorderRadius.circular(44),
                  onTap: _requestForeground,
                  onLongPress: () {
                    setState(() => _showDismissTarget = !_showDismissTarget);
                  },
                  child: Container(
                    height: 84,
                    width: 84,
                    decoration: BoxDecoration(
                      color: const Color(0xFF1E1E24),
                      shape: BoxShape.circle,
                      border: Border.all(
                        color: AppColors.seseGold,
                        width: 2.5,
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
                      child: SeSeLogo(size: 52),
                    ),
                  ),
                ),
              ),

              // Dismiss 'X' Button (shown on long-press or tap toggle)
              if (_showDismissTarget) ...[
                const SizedBox(height: 6),
                GestureDetector(
                  onTap: () {
                    widget.onDismiss?.call();
                  },
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                    decoration: BoxDecoration(
                      color: Colors.black87,
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: Colors.white24, width: 1),
                    ),
                    child: const Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.close, color: Colors.white70, size: 14),
                        SizedBox(width: 4),
                        Text(
                          'Hide',
                          style: TextStyle(
                            color: Colors.white,
                            fontSize: 11,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
