import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_overlay_window/flutter_overlay_window.dart';
import 'package:sese_core/services/push_notification_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Driver-side background FCM handler for `sese_ride`.
///
/// For incoming order pings (`trip_offer`, `direct_ping`, `tier_ping`,
/// `marketplace_broadcast`) this fires the `flutter_overlay_window`
/// full-screen order card **DIRECTLY** — no passive banner notification is
/// shown. The driver sees the full Accept/Reject UI immediately, like an
/// incoming phone call, without having to tap anything.
///
/// **Why no banner for orders?**
/// A standard heads-up notification requires the driver to tap before
/// anything happens. Order pings are time-sensitive (30-second countdown)
/// and must behave like an incoming call.
///
/// **Android FCM temporary whitelist**
/// When a high-priority FCM data message arrives, Android grants the app
/// a brief foreground-service whitelist (~10 seconds) even when the process
/// is in the background. We use that window to call
/// `FlutterOverlayWindow.showOverlay()` + `shareData()`, which starts the
/// overlay foreground service and renders the order card over any active app
/// or the lock screen — exactly like a call UI.
///
/// **Payload persistence for cold-start**
/// The enriched offer data is also written to SharedPreferences so that if
/// the app process was fully killed before the overlay engine started, the
/// foreground isolate can consume it on the next launch via
/// [PushNotificationService.consumePendingOfferPayload].
///
/// **Fallback path**
/// When the overlay permission is missing or the overlay launch fails
/// (e.g. SYSTEM_ALERT_WINDOW not granted), the method falls back to a
/// [PushNotificationService.showFromMessage] full-screen-intent notification
/// so the driver is still alerted via the lock-screen intent.
///
/// Must remain a top-level function; registered via
/// [PushNotificationService.init] `backgroundMessageHandler` parameter.
@pragma('vm:entry-point')
Future<void> driverBackgroundHandler(RemoteMessage message) async {
  final type = (message.data['type'] ?? '').toString();
  const offerTypes = {
    'trip_offer',
    'direct_ping',
    'tier_ping',
    'marketplace_broadcast',
  };
  final isOffer = offerTypes.contains(type);

  if (isOffer) {
    // ── Path A: Driver order ping ─────────────────────────────────────────
    // 1. Persist payload so the main isolate can consume it on cold-start
    //    or on the next resume without a Firestore round-trip.
    try {
      final prefs = await SharedPreferences.getInstance();
      final entries = message.data.entries
          .map((e) =>
              '${Uri.encodeComponent(e.key)}=${Uri.encodeComponent(e.value.toString())}')
          .join('&');
      await prefs.setString('pending_offer_payload', entries);
      debugPrint(
          'driverBackgroundHandler: persisted offer payload (trip: ${message.data['tripId']})');
    } catch (e) {
      debugPrint(
          'driverBackgroundHandler: payload persist failed (non-fatal): $e');
    }

    // 2. Try to fire the overlay full-screen order card directly.
    //    Android's FCM temporary whitelist allows startForegroundService()
    //    for ~10 s after a high-priority data message; the overlay plugin
    //    uses startForegroundService() internally, so this succeeds here
    //    even when backgrounded.
    try {
      final hasPermission = await FlutterOverlayWindow.isPermissionGranted();
      if (hasPermission) {
        // Check if the overlay service is already live (bubble was showing).
        final active = await FlutterOverlayWindow.isActive();
        if (!active) {
          await FlutterOverlayWindow.showOverlay(
            height: WindowSize.fullCover,
            width: WindowSize.fullCover,
            alignment: OverlayAlignment.center,
            flag: OverlayFlag.defaultFlag,
            visibility: NotificationVisibility.visibilityPublic,
            overlayTitle: 'SeSe Driver — New Order',
            overlayContent: 'Incoming order request. Review and accept now.',
          );
        } else {
          // Expand existing bubble (e.g. the floating dot) to full-cover for
          // the order card.
          await FlutterOverlayWindow.resizeOverlay(
              WindowSize.fullCover, WindowSize.fullCover, false);
        }

        // Push the enriched offer data to the overlay engine so the order
        // card renders immediately with pickup/dropoff addresses, fare, and
        // countdown without waiting for a Firestore stream.
        final d = message.data;
        await FlutterOverlayWindow.shareData({
          'mode': 'order',
          'offer': {
            'tripId': d['tripId'] ?? '',
            'pickup': d['pickupAddress'] ?? '',
            'dropoff': d['dropoffAddress'] ?? '',
            'distanceKm': d['distanceKm'] ?? '',
            'fareFormatted': d['fareFormatted'] ?? d['fareAmount'] ?? '',
            'pickupLat': double.tryParse(d['pickupLat'] ?? ''),
            'pickupLng': double.tryParse(d['pickupLng'] ?? ''),
            'dropoffLat': double.tryParse(d['dropoffLat'] ?? ''),
            'dropoffLng': double.tryParse(d['dropoffLng'] ?? ''),
          },
        });
        debugPrint(
            'driverBackgroundHandler: overlay order card launched for trip ${d['tripId']}');
        // Overlay is live — no banner notification needed.
        return;
      }
    } catch (e) {
      debugPrint(
          'driverBackgroundHandler: overlay launch failed, falling back to notification: $e');
    }

    // 3. Fallback: overlay permission missing or overlay launch failed.
    //    Show the standard full-screen-intent notification so the driver is
    //    still alerted (banner + lock-screen full-screen on screen-off).
    try {
      await PushNotificationService.showFromMessage(message);
    } catch (e) {
      debugPrint(
          'driverBackgroundHandler: fallback showFromMessage failed: $e');
    }
    return;
  }

  // ── Path B: Non-order messages (chat, system, broadcast) ─────────────────
  // Standard local notification — no overlay needed.
  try {
    await PushNotificationService.showFromMessage(message);
  } catch (e) {
    debugPrint('driverBackgroundHandler: showFromMessage failed: $e');
  }
}
