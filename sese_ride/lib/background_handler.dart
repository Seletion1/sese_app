import 'package:app_launcher/app_launcher.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
import 'package:sese_core/services/push_notification_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Driver-side background FCM handler for `sese_ride`.
///
/// For incoming order pings (`trip_offer`, `direct_ping`, `tier_ping`,
/// `marketplace_broadcast`), this:
/// 1. Persists the payload to [SharedPreferences] for instant handoff.
/// 2. Fires the high-priority full-screen intent notification via
///    [PushNotificationService.showFromMessage] (for audio alert & lockscreen banner).
/// 3. Directly brings `MainActivity` to the foreground via [AppLauncher.bringToForeground],
///    popping up the full-screen order sheet (`IncomingOfferSheet`) instantly over the
///    home screen or whatever app the driver is using.
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

    // 2. Fire the native high-priority full-screen intent notification as audible
    //    alert & lock-screen banner.
    try {
      await PushNotificationService.showFromMessage(message);
      debugPrint(
          'driverBackgroundHandler: launched fullScreenIntent notification for trip ${message.data['tripId']}');
    } catch (e) {
      debugPrint(
          'driverBackgroundHandler: showFromMessage fullScreenIntent failed: $e');
    }

    // 3. Immediately launch MainActivity to the foreground over any active app or home screen!
    try {
      final brought = await AppLauncher().bringToForeground(
        extras: {
          'tripId': (message.data['tripId'] ?? '').toString(),
          'type': type,
        },
      );
      debugPrint(
          'driverBackgroundHandler: brought MainActivity to foreground ($brought) for trip ${message.data['tripId']}');
    } catch (e) {
      debugPrint(
          'driverBackgroundHandler: bringToForeground error: $e');
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
