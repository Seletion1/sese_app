import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
import 'package:sese_core/services/push_notification_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'firebase_options.dart';

/// Driver-side background FCM handler for `sese_ride`.
///
/// For incoming order pings (`new_trip_offer`, `trip_offer`, `direct_ping`,
/// `tier_ping`, `marketplace_broadcast`), this:
/// 1. Persists the payload to [SharedPreferences] for instant handoff.
/// 2. Fires the Play-Store-compliant heads-up notification with `Accept` and
///    `Decline` action buttons via [PushNotificationService.showFromMessage].
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

    // 2. Fire the native high-priority heads-up notification with audible
    //    chime and Accept / Decline action buttons.
    try {
      await PushNotificationService.showFromMessage(message);
      debugPrint(
          'driverBackgroundHandler: launched heads-up notification for trip ${message.data['tripId']}');
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
