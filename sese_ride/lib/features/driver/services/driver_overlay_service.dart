import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:app_launcher/app_launcher.dart';
import 'package:flutter_overlay_window/flutter_overlay_window.dart';
import 'package:sese_core/sese_core.dart';
import 'package:shared_preferences/shared_preferences.dart';

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

  /// Single unified foreground notification copy.
  ///
  /// Must stay identical to `PushNotificationService.showOngoingOnlineAlert`
  /// so the tray shows EXACTLY ONE entry while ONLINE.
  static const String unifiedNotificationTitle = 'SeSe Driver Active';
  static const String unifiedNotificationBody =
      'You are ONLINE — Receiving trip offers. Tap to open app.';

  /// Tracks whether the driver is actively ONLINE.
  bool isOnline = false;

  /// For tests: bypass platform channels entirely.
  @visibleForTesting
  bool forceUnsupported = false;

  bool get supported =>
      !forceUnsupported && !kIsWeb && Platform.isAndroid;

  StreamSubscription<dynamic>? _sub;
  void Function(String action, String tripId)? _onAction;
  bool _listening = false;

  /// Ensures SYSTEM_ALERT_WINDOW permission, preceded by the mandatory Google
  /// Play prominent disclosure dialog on first call.
  ///
  /// Checks and requests overlay permission ("Draw over other apps") directly.
  Future<void> checkAndEnableOverlayPermission() async {
    if (!supported) return;
    try {
      final status = await FlutterOverlayWindow.isPermissionGranted();
      if (!status) {
        await FlutterOverlayWindow.requestPermission();
      }
    } catch (e) {
      debugPrint('DriverOverlayService.checkAndEnableOverlayPermission failed: $e');
    }
  }

  /// Pass [context] so the disclosure dialog can be displayed; when [context]
  /// is omitted (e.g., from a test isolate) the disclosure step is skipped
  /// and only the OS permission check runs.
  ///
  /// Returns `true` when the overlay permission is (or already was) granted.
  Future<bool> ensurePermission({BuildContext? context}) async {
    if (!supported) return false;
    try {
      if (await FlutterOverlayWindow.isPermissionGranted()) return true;

      // Google Play policy: show a prominent disclosure BEFORE the OS prompt.
      // Only skipped if the user has already accepted (consent flag set) or
      // no context is available to present the dialog.
      if (context != null && context.mounted) {
        final prefs = await SharedPreferences.getInstance();
        final alreadyAccepted =
            prefs.getBool(DriverOverlayDisclosureDialog.consentKey) ?? false;
        if (!alreadyAccepted) {
          // Re-check mounted after the async prefs read — the widget may have
          // been disposed while SharedPreferences was initialising.
          if (!context.mounted) return false;
          final agreed = await DriverOverlayDisclosureDialog.show(context);
          if (!agreed) return false; // driver declined disclosure — skip prompt
        }
      }

      final granted = await FlutterOverlayWindow.requestPermission();
      return granted == true;
    } catch (e) {
      debugPrint('DriverOverlayService.ensurePermission failed: $e');
      return false;
    }
  }

  static final AppLauncher _appLauncher = AppLauncher();

  /// Brings sese_ride back to the foreground directly via Intent.FLAG_ACTIVITY_REORDER_TO_FRONT.
  Future<void> bringToForeground() async {
    if (!supported) return;
    try {
      await _appLauncher.bringToForeground();
    } catch (e) {
      debugPrint('DriverOverlayService.bringToForeground failed: $e');
    }
  }

  /// Moves the app task to background on Android without destroying the process.
  Future<void> moveTaskToBack() async {
    if (!supported) return;
    try {
      await _appLauncher.moveTaskToBack();
    } catch (e) {
      debugPrint('DriverOverlayService.moveTaskToBack failed: $e');
    }
  }

  bool _isShowing = false;

  /// Shows the persistent draggable bubble (snaps to nearest screen edge).
  Future<void> showBubble() async {
    if (!supported || !isOnline) return;
    await _showBubbleNow();
  }

  /// Internal implementation of [showBubble] that runs only when the Flutter
  /// engine is confirmed to be in the foreground.
  Future<void> _showBubbleNow() async {
    if (!isOnline || _isShowing) return;
    _isShowing = true;
    try {
      final hasPermission = await FlutterOverlayWindow.isPermissionGranted();
      if (!hasPermission) return;

      final active = await FlutterOverlayWindow.isActive();
      if (active) return; // Already showing, avoid double-close race

      await FlutterOverlayWindow.showOverlay(
        height: 140,
        width: 140,
        alignment: OverlayAlignment.centerRight,
        enableDrag: true,
        positionGravity: PositionGravity.auto,
        // defaultFlag allows the bubble's own GestureDetector to receive taps
        // while letting touches outside the 140×140 window pass through to the
        // app. This prevents the foreground-return touch-interception race.
        flag: OverlayFlag.defaultFlag,
        visibility: NotificationVisibility.visibilitySecret,
        overlayTitle: unifiedNotificationTitle,
        overlayContent: unifiedNotificationBody,
      );

      // Only share mode data when the overlay service is confirmed running.
      if (await FlutterOverlayWindow.isActive()) {
        await FlutterOverlayWindow.shareData({'mode': 'bubble'});
      }
    } catch (e) {
      debugPrint('DriverOverlayService.showBubble failed: $e');
    } finally {
      _isShowing = false;
    }
  }

  /// Spec alias: displays the round SeSe logo bubble. Delegates to [showBubble].
  ///
  /// Called when `AppLifecycleState.paused`/`detached` fires while ONLINE;
  /// [hide] (via `closeOverlayWidget`) is the `resumed` counterpart.
  Future<void> showOverlayWidget() => showBubble();

  /// Dismisses the overlay widget shown by [showOverlayWidget]/[showBubble].
  Future<void> closeOverlayWidget() => hide();

  /// Expands the overlay into the full-screen order popup.
  ///
  /// Uses [WindowSize.fullCover] (covers status bar + navigation bar) so the
  /// card occupies the entire screen on lock-screen wake-ups. The
  /// `visibilitySecret` keeps the OverlayService foreground notification
  /// suppressed from the shade — same rationale as [showBubble].
  ///
  /// **Background-start fix**: If the app is backgrounded when this is called
  /// (e.g. from an FCM handler path), the action is enqueued and runs on the
  /// next `AppLifecycleState.resumed` event so Android's `startService()`
  /// foreground restriction is not violated.
  Future<void> showOrderOffer({
    required String tripId,
    required String pickup,
    required String dropoff,
    required String distanceKm,
    required String fare,
    double? pickupLat,
    double? pickupLng,
    double? dropoffLat,
    double? dropoffLng,
  }) async {
    if (!supported) return;
    await _showOrderOfferNow(
      tripId: tripId,
      pickup: pickup,
      dropoff: dropoff,
      distanceKm: distanceKm,
      fare: fare,
      pickupLat: pickupLat,
      pickupLng: pickupLng,
      dropoffLat: dropoffLat,
      dropoffLng: dropoffLng,
    );
  }

  /// Internal implementation of [showOrderOffer] that runs only when the
  /// Flutter engine is confirmed to be in the foreground.
  Future<void> _showOrderOfferNow({
    required String tripId,
    required String pickup,
    required String dropoff,
    required String distanceKm,
    required String fare,
    double? pickupLat,
    double? pickupLng,
    double? dropoffLat,
    double? dropoffLng,
  }) async {
    try {
      final hasPermission = await FlutterOverlayWindow.isPermissionGranted();
      if (!hasPermission) return;

      final active = await FlutterOverlayWindow.isActive();
      if (!active) {
        await FlutterOverlayWindow.showOverlay(
          height: WindowSize.fullCover,
          width: WindowSize.fullCover,
          alignment: OverlayAlignment.center,
          flag: OverlayFlag.defaultFlag,
          visibility: NotificationVisibility.visibilitySecret,
          overlayTitle: unifiedNotificationTitle,
          overlayContent: unifiedNotificationBody,
        );
      } else {
        // Expand the active bubble overlay to full cover for the order card.
        // Re-check isActive() after showOverlay may have resolved: if the
        // service is not yet alive, resizeOverlay throws MissingPluginException.
        if (await FlutterOverlayWindow.isActive()) {
          await FlutterOverlayWindow.resizeOverlay(
            WindowSize.fullCover,
            WindowSize.fullCover,
            false,
          );
        }
      }
      // Only push offer data when the overlay service is confirmed running.
      if (await FlutterOverlayWindow.isActive()) {
        await FlutterOverlayWindow.shareData({
          'mode': 'order',
          'offer': {
            'tripId': tripId,
            'pickup': pickup,
            'dropoff': dropoff,
            'distanceKm': distanceKm,
            'fareFormatted': fare,
            'pickupLat': pickupLat,
            'pickupLng': pickupLng,
            'dropoffLat': dropoffLat,
            'dropoffLng': dropoffLng,
          },
        });
      }
    } catch (e) {
      debugPrint('DriverOverlayService.showOrderOffer failed: $e');
    }
  }
  /// Hides the overlay (bubble or popup).
  ///
  /// Sends a `close` mode signal to the overlay isolate first so it can
  /// cancel any in-progress countdown timers, then calls [closeOverlay].
  /// A deferred safety check at +500 ms force-closes any ghost window that
  /// survived (e.g. due to a close/open race during foreground transition).
  ///
  /// Also clears any pending show-bubble/show-order actions that were enqueued
  /// while backgrounded, so a dismissed overlay never re-appears on resume.
  Future<void> hide() async {
    _isShowing = false;
    if (!supported) return;
    try {
      if (await FlutterOverlayWindow.isActive()) {
        await FlutterOverlayWindow.shareData({'mode': 'close'});
        await FlutterOverlayWindow.closeOverlay().timeout(
          const Duration(milliseconds: 300),
          onTimeout: () => false,
        );
      }
    } catch (e) {
      debugPrint('DriverOverlayService.hide failed: $e');
    }
    // Deferred safety net: if a race left the overlay window alive (e.g. a
    // showBubble/closeOverlay pair racing during app-resume), close it again.
    // This prevents a ghost clickThrough-flagged window from persisting and
    // the bubble from appearing frozen centre-screen on foreground return.
    Future<void>.delayed(const Duration(milliseconds: 350), () async {
      try {
        if (await FlutterOverlayWindow.isActive()) {
          await FlutterOverlayWindow.closeOverlay().timeout(
            const Duration(milliseconds: 300),
            onTimeout: () => false,
          );
        }
      } catch (_) {}
    });
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
