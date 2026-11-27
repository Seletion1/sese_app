import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:sese_core/sese_core.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'driver_wake_service.dart';

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

  /// True on Android when the native `FloatingBubbleService` (`SYSTEM_ALERT_WINDOW`)
  /// is supported. Never invoked on iOS or Web.
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
      await DriverWakeService.instance.setBubbleEnabled(enabled);
      if (!enabled) {
        await hideBubble();
      }
    } catch (e) {
      debugPrint('DriverPresenceService setBubbleSettingEnabled failed: $e');
    }
  }

  /// Safely checks `Settings.canDrawOverlays` on Android.
  Future<bool> hasOverlayPermission() async {
    if (!isAndroidOverlaySupported) return false;
    return DriverWakeService.instance.canDrawOverlays();
  }

  /// Shows the prominent disclosure dialog first, then opens Android's
  /// `ACTION_MANAGE_OVERLAY_PERMISSION` settings if accepted.
  Future<bool> requestOverlayPermissionWithDisclosure(
      BuildContext context) async {
    if (!isAndroidOverlaySupported) return false;
    final alreadyGranted = await hasOverlayPermission();
    if (alreadyGranted) return true;
    if (!context.mounted) return false;

    final agreed = await DriverOverlayDisclosureDialog.show(context);
    if (!agreed) return false;

    await DriverWakeService.instance.openOverlaySettings();
    return hasOverlayPermission();
  }

  /// Handles app transition to background (`paused`, `hidden`, or `detached`).
  Future<void> onAppBackgrounded() async {
    if (!isOnline && !hasActiveTrip) {
      await hideBubble();
      return;
    }
    if (isAndroidOverlaySupported) {
      final enabled = await isBubbleSettingEnabled();
      if (enabled && await hasOverlayPermission()) {
        await showBubble();
      }
    }
  }

  /// Handles app return to foreground (`resumed`).
  Future<void> onAppForegrounded() async {
    await hideBubble();
  }

  /// Shows the native floating SeSe bubble if permitted and online.
  Future<void> showBubble() async {
    if (!isAndroidOverlaySupported) return;
    await DriverWakeService.instance.showFloatingBubble();
  }

  /// Hides the native floating SeSe bubble immediately.
  Future<void> hideBubble() async {
    if (!isAndroidOverlaySupported) return;
    await DriverWakeService.instance.hideFloatingBubble();
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
