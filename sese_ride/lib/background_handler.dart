import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
import 'package:sese_core/services/push_notification_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Driver-side background FCM handler for `sese_ride`.
///
/// For incoming order pings (`trip_offer`, `direct_ping`, `tier_ping`,
/// `marketplace_broadcast`), this triggers a WhatsApp-style native full-screen
/// intent notification via [PushNotificationService.showFromMessage].
///
/// **Full-Screen Intent Behavior**
/// When a high-priority FCM data message arrives while the device is locked
/// or the app is in the background:
/// 1. Android launches `MainActivity` over keyguard / lock-screen via
///    `useFullScreenIntent` + `showWhenLocked` + `turnScreenOn`.
/// 2. `MainActivity` brings the main Flutter engine into focus.
/// 3. The driver dashboard immediately mounts and presents the unified
///    in-app `IncomingOfferSheet` (`Screenshot_20261115_012554.jpg`).
///
/// **Payload persistence for cold-start**
/// The offer data is written to SharedPreferences so that if the app process
/// was killed, the main isolate can consume it on cold-start via
/// [PushNotificationService.consumePendingOfferPayload].
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
    // 1. Persist payload so the main isolate can consume it on cold-start
    //    or on the next resume without waiting for a Firestore round-trip.
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

    // 2. Fire the native high-priority full-screen intent notification.
    //    Wakes device screen and launches MainActivity directly into focus.
    try {
      await PushNotificationService.showFromMessage(message);
      debugPrint(
          'driverBackgroundHandler: launched fullScreenIntent notification for trip ${message.data['tripId']}');
    } catch (e) {
      debugPrint(
          'driverBackgroundHandler: showFromMessage fullScreenIntent failed: $e');
    }
    return;
  }

  // ── Path B: Non-order messages (chat, system, broadcast) ─────────────────
  try {
    await PushNotificationService.showFromMessage(message);
  } catch (e) {
    debugPrint('driverBackgroundHandler: showFromMessage failed: $e');
  }
}
