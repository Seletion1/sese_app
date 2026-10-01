import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_overlay_window/flutter_overlay_window.dart';

/// Main-isolate manager for the driver overlay window (Android only).
///
/// - Bubble: persistent draggable SeSe bubble while ONLINE + minimized.
/// - Order popup: full-screen background order card (6s countdown, atomic
///   ACCEPT/REJECT executed inside the overlay isolate).
/// - Overlay → app actions surface via [onAction] (`foreground`,
///   `accepted`, `rejected`, `expired`).
///
/// All methods are safe no-ops on non-Android platforms and when the
/// overlay permission is missing; failures never throw.
class DriverOverlayService {
  DriverOverlayService._();

  static final DriverOverlayService instance = DriverOverlayService._();

  /// For tests: bypass platform channels entirely.
  @visibleForTesting
  bool forceUnsupported = false;

  bool get supported =>
      !forceUnsupported && !kIsWeb && Platform.isAndroid;

  StreamSubscription<dynamic>? _sub;
  void Function(String action, String tripId)? _onAction;
  bool _listening = false;

  /// Ensures SYSTEM_ALERT_WINDOW permission (prompts the user when needed).
  /// Returns true when overlays may be shown.
  Future<bool> ensurePermission() async {
    if (!supported) return false;
    try {
      if (await FlutterOverlayWindow.isPermissionGranted()) return true;
      final granted = await FlutterOverlayWindow.requestPermission();
      return granted == true;
    } catch (e) {
      debugPrint('DriverOverlayService.ensurePermission failed: $e');
      return false;
    }
  }

  /// Shows the persistent draggable bubble (bottom-right edge).
  Future<void> showBubble() async {
    if (!supported) return;
    try {
      if (await FlutterOverlayWindow.isActive()) return;
      await FlutterOverlayWindow.showOverlay(
        height: 110,
        width: 110,
        alignment: OverlayAlignment.centerRight,
        enableDrag: true,
        positionGravity: PositionGravity.right,
        flag: OverlayFlag.defaultFlag,
        overlayTitle: 'SeSe driver bubble',
        overlayContent: 'Tap to return to SeSe',
      );
      await FlutterOverlayWindow.shareData({'mode': 'bubble'});
    } catch (e) {
      debugPrint('DriverOverlayService.showBubble failed: $e');
    }
  }

  /// Expands the overlay into the full-screen order popup.
  Future<void> showOrderOffer({
    required String tripId,
    required String pickup,
    required String dropoff,
    required String distanceKm,
    required String fare,
  }) async {
    if (!supported) return;
    try {
      if (!await FlutterOverlayWindow.isActive()) {
        await FlutterOverlayWindow.showOverlay(
          alignment: OverlayAlignment.center,
          flag: OverlayFlag.defaultFlag,
          overlayTitle: 'New order request',
          overlayContent: 'Pickup: $pickup',
        );
      }
      await FlutterOverlayWindow.shareData({
        'mode': 'order',
        'offer': {
          'tripId': tripId,
          'pickup': pickup,
          'dropoff': dropoff,
          'distanceKm': distanceKm,
          'fareFormatted': fare,
        },
      });
    } catch (e) {
      debugPrint('DriverOverlayService.showOrderOffer failed: $e');
    }
  }

  /// Hides the overlay (bubble or popup).
  Future<void> hide() async {
    if (!supported) return;
    try {
      if (await FlutterOverlayWindow.isActive()) {
        await FlutterOverlayWindow.shareData({'mode': 'close'});
        await FlutterOverlayWindow.closeOverlay();
      }
    } catch (e) {
      debugPrint('DriverOverlayService.hide failed: $e');
    }
  }

  /// Subscribes to overlay → app actions. Safe to call repeatedly.
  void listenActions(void Function(String action, String tripId) onAction) {
    _onAction = onAction;
    if (_listening || !supported) return;
    _listening = true;
    try {
      _sub = FlutterOverlayWindow.overlayListener.listen((dynamic event) {
        if (event is! Map) return;
        final map = Map<String, dynamic>.from(event);
        final action = (map['action'] ?? '').toString();
        if (action.isEmpty) return;
        _onAction?.call(action, (map['tripId'] ?? '').toString());
      });
    } catch (e) {
      debugPrint('DriverOverlayService.listenActions failed: $e');
    }
  }

  @visibleForTesting
  void dispose() {
    _sub?.cancel();
    _sub = null;
    _listening = false;
    _onAction = null;
  }
}
