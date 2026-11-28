import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
import 'package:sese_core/services/push_notification_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'firebase_options.dart';

import 'features/driver/services/driver_wake_service.dart';

/// Driver-side background FCM handler for `sese_ride`.
///
/// For incoming order pings (`new_trip_offer`, `trip_offer`, `direct_ping`,
/// `tier_ping`, `marketplace_broadcast`), this:
/// 1. Checks if the driver is actively ONLINE. Drops the ping if offline.
/// 2. Persists the payload to [SharedPreferences] for instant handoff.
/// 3. Checks system overlay permission (`SYSTEM_ALERT_WINDOW`). If granted, the
///    overlay/wake window handles presentation without stacking a duplicate
///    notification banner over it. If not granted, posts the heads-up banner as fallback.
@pragma('vm:entry-point')
Future<void> driverBackgroundHandler(RemoteMessage message) async {
  final type = (message.data['type'] ?? '').toString();
  const offerTypes = {
    'new_trip_offer',
    'trip_offer',
    'direct_ping',
    'tier_ping',
    'marketplace_broadcast',
  };
  final isOffer = offerTypes.contains(type);

  if (isOffer) {
    // 0. Strict Offline Gate: Drivers who are offline must NEVER receive/pop offer alerts.
    try {
      final prefs = await SharedPreferences.getInstance();
      final onlineSession = prefs.getString('driver_online_session');
      final explicitOnline = prefs.getBool('driver_is_online');
      final isOffline = onlineSession == null && explicitOnline == false;
      if (isOffline) {
        debugPrint(
            'driverBackgroundHandler: driver is OFFLINE. Dropping incoming offer ping.');
        return;
      }
    } catch (_) {}

    // 1. Persist payload so the main isolate or overlay can consume it
    //    without waiting for a Firestore round-trip.
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

    // 2. Smart Presentation: Check overlay permission.
    // If overlay permission is granted, the overlay/wake window displays the order card.
    // Suppress the duplicate heads-up notification banner to avoid stacking alerts.
    final canOverlay = await DriverWakeService.instance.canDrawOverlays();
    if (canOverlay) {
      debugPrint(
          'driverBackgroundHandler: overlay permission granted. Displaying overlay directly; suppressed duplicate notification banner.');
      return;
    }

    // 3. Fallback: If overlay permission is missing, post the high-priority notification banner.
    try {
      await PushNotificationService.showFromMessage(message);
      debugPrint(
          'driverBackgroundHandler: launched fallback heads-up notification for trip ${message.data['tripId']}');
    } catch (e) {
      debugPrint(
          'driverBackgroundHandler: showFromMessage heads-up alert failed: $e');
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

/// Background action handler for local notification buttons (`Decline`) when
/// the driver taps an action without bringing the app UI to the foreground.
@pragma('vm:entry-point')
Future<void> driverNotificationActionBackgroundHandler(
  NotificationResponse response,
) async {
  final actionId = response.actionId;
  if (actionId != 'decline_offer' && actionId != 'decline_order') {
    return;
  }
  final payload = response.payload;
  if (payload == null || payload.isEmpty) return;

  String tripId = '';
  try {
    final data = Uri.splitQueryString(payload);
    tripId = (data['tripId'] ?? '').trim();
  } catch (_) {}
  if (tripId.isEmpty) return;

  try {
    if (Firebase.apps.isEmpty) {
      await Firebase.initializeApp(
        options: DefaultFirebaseOptions.currentPlatform,
      );
    }
    await FirebaseFunctions.instance
        .httpsCallable('declineTrip')
        .call(<String, dynamic>{
      'tripId': tripId,
      'action': 'rejected',
    });
    final prefs = await SharedPreferences.getInstance();
    final pending = prefs.getString('pending_offer_payload');
    if (pending != null && pending.contains(tripId)) {
      await prefs.remove('pending_offer_payload');
    }
  } catch (e) {
    debugPrint(
        'driverNotificationActionBackgroundHandler: declineTrip failed: $e');
  }
}
