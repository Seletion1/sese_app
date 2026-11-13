import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:app_launcher/app_launcher.dart';
import 'package:flutter_overlay_window/flutter_overlay_window.dart';
import 'package:sese_core/sese_core.dart';
import 'package:shared_preferences/shared_preferences.dart';

// ---------------------------------------------------------------------------
// _OverlayLifecycleObserver — internal WidgetsBindingObserver that drains
// the pending action queue when the Flutter engine transitions to `resumed`.
// ---------------------------------------------------------------------------
class _OverlayLifecycleObserver extends WidgetsBindingObserver {
  _OverlayLifecycleObserver(this._service);
  final DriverOverlayService _service;

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _service._drainPendingActions();
    }
  }
}

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

  // ---------------------------------------------------------------------------
  // Deferred action queue — Android 8+ background start-service fix.
  //
  // `showOverlay()` internally calls `startService()`, which Android 8.0+
  // (API 26+) rejects with `IllegalStateException: Not allowed to start
  // service` when the calling process is not in the foreground. The simple
  // `_waitForForeground()` poll is insufficient when:
  //   • the caller itself triggers `moveTaskToBack()` immediately before the
  //     overlay call (driver_home_shell back-press path), or
  //   • `didChangeAppLifecycleState(paused)` fires synchronously and the
  //     overlay call races with the OS background classification.
  //
  // Fix: register a [WidgetsBindingObserver] once and drain queued actions
  // the first time `AppLifecycleState.resumed` fires after they were queued.
  // ---------------------------------------------------------------------------

  /// Overlay actions waiting for the next `AppLifecycleState.resumed` event.
  final List<Future<void> Function()> _pendingActions = [];

  _OverlayLifecycleObserver? _lifecycleObserver;

  /// Installs the lifecycle observer if not already registered.
  ///
  /// Safe to call multiple times; subsequent calls are no-ops.
  void _ensureObserver() {
    if (_lifecycleObserver != null) return;
    _lifecycleObserver = _OverlayLifecycleObserver(this);
    WidgetsBinding.instance.addObserver(_lifecycleObserver!);
  }

  /// Drains and executes all pending overlay actions in FIFO order.
  ///
  /// Called by [_OverlayLifecycleObserver] on `AppLifecycleState.resumed`.
  /// Each action is wrapped in its own try/catch so a single failure does
  /// not block subsequent actions in the queue.
  Future<void> _drainPendingActions() async {
    if (_pendingActions.isEmpty) return;
    final actions = List<Future<void> Function()>.from(_pendingActions);
    _pendingActions.clear();
    for (final action in actions) {
      try {
        await action();
      } catch (e) {
        debugPrint('DriverOverlayService._drainPendingActions: action failed: $e');
      }
    }
  }

  /// Returns `true` when the Flutter engine is currently in the foreground
  /// (`AppLifecycleState.resumed`).
  bool get _isInForeground =>
      WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed;

  /// Runs [action] immediately if the app is currently in the foreground,
  /// otherwise enqueues it to execute on the next `AppLifecycleState.resumed`
  /// event and returns immediately.
  ///
  /// This is the Android 8+ background-safe entry-point for all
  /// `showOverlay()` / `closeOverlay()` calls that may originate from
  /// lifecycle callbacks or push-notification paths where the Flutter process
  /// is not guaranteed to be in the foreground.
  Future<void> _enqueueOrRun(Future<void> Function() action) async {
    if (_isInForeground) {
      await action();
    } else {
      _ensureObserver();
      _pendingActions.add(action);
      if (kDebugMode) {
        debugPrint(
          'DriverOverlayService: app is backgrounded — overlay action queued '
          '(queue length: ${_pendingActions.length}).',
        );
      }
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
  ///
  /// **Touch-interception fix**: When transitioning from a full-cover order
  /// popup (which uses [OverlayFlag.defaultFlag] to receive taps) back to the
  /// bubble, we must close and re-open the overlay window rather than
  /// just resizing it. Android does not update `WindowManager.LayoutParams.flags`
  /// on a live window via `flutter_overlay_window`'s resize API, so the bubble
  /// would retain `defaultFlag` and intercept ALL touches delivered to the app —
  /// the visible symptom is the app freezing with the bubble stuck centre-screen.
  /// Re-showing from scratch guarantees a fresh window with [OverlayFlag.defaultFlag].
  ///
  /// **Background-start fix**: If called while the app is not in the foreground
  /// (e.g. from [didChangeAppLifecycleState] paused or the driver_home_shell
  /// back-press path that calls [moveTaskToBack] immediately beforehand), the
  /// action is enqueued via [_enqueueOrRun] and executes on the next
  /// `AppLifecycleState.resumed` event, avoiding the Android 8+
  /// `IllegalStateException: Not allowed to start service` crash.
  Future<void> showBubble() async {
    if (!supported) return;
    await _enqueueOrRun(_showBubbleNow);
  }

  /// Internal implementation of [showBubble] that runs only when the Flutter
  /// engine is confirmed to be in the foreground.
  Future<void> _showBubbleNow() async {
    try {
      final hasPermission = await FlutterOverlayWindow.isPermissionGranted();
      if (!hasPermission) return;

      // Always close then re-open to guarantee the window is created with
      // OverlayFlag.defaultFlag (clickThrough-compatible). A plain resizeOverlay()
      // call does NOT change the flags of an already-live window, so a bubble
      // that follows a full-cover order popup retains defaultFlag and intercepts
      // all touches — causing the frozen-UI / bubble-stuck-centre-screen bug.
      final active = await FlutterOverlayWindow.isActive();
      if (active) {
        try {
          await FlutterOverlayWindow.closeOverlay();
        } catch (_) {}
        // Brief yield so the Android WindowManager removes the old window
        // before we request a new one on the same surface.
        await Future<void>.delayed(const Duration(milliseconds: 80));
      }

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
    await _enqueueOrRun(() => _showOrderOfferNow(
          tripId: tripId,
          pickup: pickup,
          dropoff: dropoff,
          distanceKm: distanceKm,
          fare: fare,
          pickupLat: pickupLat,
          pickupLng: pickupLng,
          dropoffLat: dropoffLat,
          dropoffLng: dropoffLng,
        ));
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
    // Discard any queued show-bubble / show-order actions — the driver has
    // explicitly come back to foreground so the in-app UI takes over.
    _pendingActions.clear();
    if (!supported) return;
    try {
      if (await FlutterOverlayWindow.isActive()) {
        await FlutterOverlayWindow.shareData({'mode': 'close'});
        await FlutterOverlayWindow.closeOverlay();
      }
    } catch (e) {
      debugPrint('DriverOverlayService.hide failed: $e');
    }
    // Deferred safety net: if a race left the overlay window alive (e.g. a
    // showBubble/closeOverlay pair racing during app-resume), close it again.
    // This prevents a ghost clickThrough-flagged window from persisting and
    // the bubble from appearing frozen centre-screen on foreground return.
    Future<void>.delayed(const Duration(milliseconds: 500), () async {
      try {
        if (await FlutterOverlayWindow.isActive()) {
          await FlutterOverlayWindow.closeOverlay();
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
    if (_lifecycleObserver != null) {
      WidgetsBinding.instance.removeObserver(_lifecycleObserver!);
      _lifecycleObserver = null;
    }
    _pendingActions.clear();
  }
}
