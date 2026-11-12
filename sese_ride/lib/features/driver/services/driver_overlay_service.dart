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

  /// Waits for the Flutter engine to be in the [AppLifecycleState.resumed]
  /// state before returning, up to [timeout].
  ///
  /// Android 8.0+ (API 26+) blocks `startService()` calls issued from a
  /// background process — the OS throws `IllegalStateException: Not allowed
  /// to start service`. `flutter_overlay_window` calls `startService()`
  /// internally inside `showOverlay()`. Calling this helper right before any
  /// `showOverlay()` / `resizeOverlay()` invocation guarantees the app has
  /// fully resumed and is classified as a foreground process by Android before
  /// the native overlay service start is attempted.
  ///
  /// The 100 ms poll interval is intentionally coarse: resuming from background
  /// normally completes within 200–600 ms on mid-range Android devices. 20
  /// iterations × 100 ms = 2 s hard ceiling before we give up and proceed
  /// anyway (the subsequent `showOverlay` will still throw on Android < 26 if
  /// truly backgrounded, but those exceptions are silently caught).
  Future<void> _waitForForeground({
    Duration timeout = const Duration(seconds: 2),
  }) async {
    if (!supported) return;
    final deadline = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(deadline)) {
      final state = WidgetsBinding.instance.lifecycleState;
      if (state == AppLifecycleState.resumed) return;
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
  }

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

  /// Shows the persistent draggable bubble (snaps to nearest screen edge).
  ///
  /// `PositionGravity.auto` snaps to whichever edge (left or right) the
  /// bubble is closest to when the user releases it — previous `right` only
  /// snapped to the right edge.
  ///
  /// `NotificationVisibility.visibilitySecret` (the plugin default) keeps the
  /// `OverlayService` foreground notification hidden from the shade, so the
  /// only notification the driver ever sees while ONLINE is the single
  /// unified "SeSe Driver Active" tray item posted by
  /// [PushNotificationService.showOngoingOnlineAlert].
  ///
  /// The overlay title/content mirror that unified tray item so no second,
  /// differently-worded entry can appear on OEMs that still surface the
  /// service notification.
  Future<void> showBubble() async {
    if (!supported) return;
    try {
      final hasPermission = await FlutterOverlayWindow.isPermissionGranted();
      if (!hasPermission) return;

      // Android 8.0+ forbids startService() from a background process.
      // Wait until the Flutter engine is resumed before touching the overlay
      // service so the OS classifies us as a foreground process.
      await _waitForForeground();

      final active = await FlutterOverlayWindow.isActive();
      if (!active) {
        await FlutterOverlayWindow.showOverlay(
          height: 140,
          width: 140,
          alignment: OverlayAlignment.centerRight,
          enableDrag: true,
          positionGravity: PositionGravity.auto,
          flag: OverlayFlag.defaultFlag,
          visibility: NotificationVisibility.visibilitySecret,
          overlayTitle: unifiedNotificationTitle,
          overlayContent: unifiedNotificationBody,
        );
      } else {
        // If already active (e.g. returning from fullCover order popup or
        // previous state), resize back to lightweight 140×140 bubble and
        // re-enable dragging. Guard with isActive() re-check: if showOverlay
        // above raced and left the service not running yet, resizeOverlay
        // would throw MissingPluginException on the channel.
        if (await FlutterOverlayWindow.isActive()) {
          await FlutterOverlayWindow.resizeOverlay(140, 140, true);
        }
      }
      // Only share mode data when the overlay service is confirmed running.
      if (await FlutterOverlayWindow.isActive()) {
        await FlutterOverlayWindow.shareData({'mode': 'bubble'});
      }
    } catch (e) {
      debugPrint('DriverOverlayService.showBubble failed: $e');
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
    try {
      final hasPermission = await FlutterOverlayWindow.isPermissionGranted();
      if (!hasPermission) return;

      // Android 8.0+ forbids startService() from a background process.
      // Wait until the Flutter engine is fully resumed before attempting to
      // start the overlay service, ensuring we are classified as foreground.
      await _waitForForeground();

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
