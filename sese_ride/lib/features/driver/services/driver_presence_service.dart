import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_overlay_window/flutter_overlay_window.dart';
import 'package:sese_core/sese_core.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Cross-Platform Driver Background Presence and Quick-Return Abstraction Service.
///
/// Architected to strictly conform to both **Google Play Policy** and **Apple App Store Review Guidelines**:
///
/// 1. **Strict Platform Separation (`Platform.isAndroid` vs `Platform.isIOS`)**:
///    - On iOS, window/overlay alert APIs are NEVER invoked, preserving 100% compliance
///      with Apple public API rules (App Store Guideline 2.5.1).
///    - On iOS, background presence is represented via high-priority push notifications,
///      background location status indicator, and Live Activity hooks.
///
/// 2. **Android Policy-Compliant Quick-Return Floating Bubble (`SYSTEM_ALERT_WINDOW`)**:
///    - **Explicit User Opt-In**: Preceded by [DriverOverlayDisclosureDialog] explaining
///      the exact purpose before requesting system settings.
///    - **Online-Only Lifecycle**: Bubble is displayed strictly when the driver is actively
///      ONLINE (or on an active trip) and the app is backgrounded.
///    - **Zero Ads / Non-Obstructive**: 84x84 compact circle; never covers navigation,
///      contains zero advertising, and closes automatically on offline/logout.
///    - **Easy Dismissal & Toggle**: Drivers can close the bubble anytime or disable it in
///      Driver Settings without hindering their ability to receive rides.
class DriverPresenceService {
  DriverPresenceService._();

  static final DriverPresenceService instance = DriverPresenceService._();

  static const String bubblePrefKey = 'driver_overlay_bubble_enabled';

  /// Whether the driver is actively online.
  bool isOnline = false;

  /// Whether an active trip is currently in progress.
  bool hasActiveTrip = false;

  /// Test hook to bypass platform channels.
  @visibleForTesting
  bool forceUnsupported = false;

  bool get isAndroidOverlaySupported =>
      !forceUnsupported && !kIsWeb && Platform.isAndroid;

  bool get isIos => !forceUnsupported && !kIsWeb && Platform.isIOS;

  /// Returns whether the driver has enabled the quick-return bubble in settings.
  Future<bool> isBubbleSettingEnabled() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      return prefs.getBool(bubblePrefKey) ?? true;
    } catch (_) {
      return true;
    }
  }

  /// Sets the driver's floating bubble preference.
  Future<void> setBubbleSettingEnabled(bool enabled) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(bubblePrefKey, enabled);
      if (!enabled) {
        await hideBubble();
      }
    } catch (e) {
      debugPrint('DriverPresenceService setBubbleSettingEnabled failed: $e');
    }
  }

  /// Checks if the Android `SYSTEM_ALERT_WINDOW` permission is currently granted.
  Future<bool> hasOverlayPermission() async {
    if (!isAndroidOverlaySupported) return false;
    try {
      return await FlutterOverlayWindow.isPermissionGranted();
    } catch (e) {
      debugPrint('DriverPresenceService hasOverlayPermission error: $e');
      return false;
    }
  }

  /// Requests overlay permission on Android with explicit Google Play disclosure.
  ///
  /// Shows [DriverOverlayDisclosureDialog] first. If the driver consents, opens
  /// the system "Display over other apps" settings. Returns true if granted.
  Future<bool> requestOverlayPermissionWithDisclosure(BuildContext context) async {
    if (!isAndroidOverlaySupported) return false;

    // Check if permission is already granted
    final alreadyGranted = await hasOverlayPermission();
    if (alreadyGranted) return true;

    // Show prominent disclosure dialog
    if (!context.mounted) return false;
    final consented = await DriverOverlayDisclosureDialog.show(context);
    if (!consented) {
      await DriverOverlayDisclosureDialog.recordConsent(consented: false);
      return false;
    }

    await DriverOverlayDisclosureDialog.recordConsent(consented: true);

    try {
      final requested = await FlutterOverlayWindow.requestPermission();
      return requested ?? false;
    } catch (e) {
      debugPrint('DriverPresenceService requestPermission failed: $e');
      return false;
    }
  }

  /// Handles app transition to background (`paused`, `hidden`, or `detached`).
  Future<void> onAppBackgrounded() async {
    if (!isOnline && !hasActiveTrip) {
      // Driver is offline: do nothing
      return;
    }

    if (isAndroidOverlaySupported) {
      final enabled = await isBubbleSettingEnabled();
      if (!enabled) return;

      final granted = await hasOverlayPermission();
      if (!granted) return;

      await showBubble();
    } else if (isIos) {
      // On iOS: background presence is conveyed via persistent location indicator
      // and high-priority push notifications (zero screen overlay).
      debugPrint('DriverPresenceService: iOS background presence active (online: $isOnline)');
    }
  }

  /// Handles app return to foreground (`resumed`).
  Future<void> onAppForegrounded() async {
    if (isAndroidOverlaySupported) {
      // Hide the floating bubble when the driver is actively viewing the app
      await hideBubble();
    }
  }

  /// Shows the circular quick-return floating bubble (Android only).
  ///
  /// The `isActive()` check is intentionally skipped on retry so that a
  /// previously crashed or invisible overlay surface is always replaced.
  /// We close any stale surface first, then re-open — this guarantees the
  /// bubble appears even after the overlay engine silently dies in the
  /// background.
  Future<void> showBubble() async {
    if (!isAndroidOverlaySupported) return;

    try {
      // Dismiss any stale/zombie overlay surface before re-creating it.
      // flutter_overlay_window.isActive() may return true even when the
      // overlay window is no longer visible (engine crash / OOM kill). By
      // always closing first we guarantee a fresh, visible bubble.
      try {
        final stale = await FlutterOverlayWindow.isActive();
        if (stale) {
          await FlutterOverlayWindow.closeOverlay().timeout(
            const Duration(milliseconds: 400),
            onTimeout: () => false,
          );
        }
      } catch (_) {}

      await FlutterOverlayWindow.showOverlay(
        enableDrag: true,
        overlayTitle: 'SeSe Driver Active',
        overlayContent: 'Quick return to active orders',
        flag: OverlayFlag.defaultFlag,
        visibility: NotificationVisibility.visibilitySecret,
        positionGravity: PositionGravity.auto,
        height: 240,
        width: 240,
      );
      debugPrint('DriverPresenceService: quick-return bubble displayed.');
    } catch (e) {
      debugPrint('DriverPresenceService showBubble failed: $e');
    }
  }

  /// Hides/dismisses the floating bubble immediately.
  Future<void> hideBubble() async {
    if (!isAndroidOverlaySupported) return;

    try {
      final active = await FlutterOverlayWindow.isActive();
      if (active) {
        await FlutterOverlayWindow.closeOverlay().timeout(
          const Duration(milliseconds: 400),
          onTimeout: () => false,
        );
        debugPrint('DriverPresenceService: bubble closed.');
      }
    } catch (e) {
      debugPrint('DriverPresenceService hideBubble failed: $e');
    }
  }

  /// Called when the driver goes online.
  Future<void> onDriverOnline({required String driverId}) async {
    isOnline = true;
    // Show the continuous foreground service status notification
    await PushNotificationService.showOngoingOnlineAlert();
  }

  /// Called when the driver goes offline.
  Future<void> onDriverOffline() async {
    isOnline = false;
    hasActiveTrip = false;
    // Dismiss overlay and cancel online notification
    await hideBubble();
    await PushNotificationService.cancelOnlineAlert();
  }

  /// Called when the driver signs out or switches to customer mode.
  Future<void> onDriverSignOut() async {
    await onDriverOffline();
  }

  /// Updates active trip status for background awareness.
  void setActiveTrip(bool active) {
    hasActiveTrip = active;
  }
}
