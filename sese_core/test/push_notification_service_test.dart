import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sese_core/services/push_notification_service.dart';

void main() {
  group('Push channels', () {
    test('channel ids and sound resource are stable', () {
      expect(PushChannels.orders, 'sese_orders');
      expect(PushChannels.driverOffers, 'sese_driver_offers');
      expect(PushChannels.calls, 'sese_calls');
      expect(PushChannels.chat, 'sese_chat');
      expect(PushChannels.system, 'sese_system');
      expect(PushChannels.driverOnline, 'sese_driver_online');
      expect(PushChannels.broadcast, 'sese_high_priority_alerts');
      expect(PushChannels.alertSound, 'sese_alert_chime');
    });

    test('service calls are safe no-ops without Firebase', () async {
      // No Firebase/plugins in unit tests: every entry point must
      // catch internally and never throw.
      await PushNotificationService.init();
      expect(PushNotificationService.channelsReady, isFalse);
      expect(await PushNotificationService.token(), isNull);
      await PushNotificationService.subscribe('user_x');
      await PushNotificationService.unsubscribe('user_x');
      await PushNotificationService.showIncomingCallNotification(
        callId: 'call_123',
        callerId: 'user_caller',
        callerName: 'Test Caller',
      );
      await PushNotificationService.cancelIncomingCallNotification();
      // Token registration is best-effort: empty uid and missing Firebase
      // resolve to no-ops, never throws.
      await PushNotificationService.registerToken(uid: '');
      await PushNotificationService.registerToken(
          uid: 'user_x', country: 'NG');
    });
  });

  group('Driver offer heads-up formatting & guards', () {
    test('buildDriverOfferBanner formats fare, pickup, drop-off, and timeout',
        () {
      final now = DateTime.fromMillisecondsSinceEpoch(1700000000000);
      final banner = PushNotificationService.buildDriverOfferBanner(
        {
          'type': 'new_trip_offer',
          'tripId': 'trip_abc_123',
          'pickupAddress': 'Lekki Phase 1',
          'dropoffAddress': 'Victoria Island',
          'fare': '3500',
          'currency': 'NGN',
          'expiresAtMs': '${now.millisecondsSinceEpoch + 45000}',
        },
        now: now,
      );

      expect(banner, isNotNull);
      expect(banner!.title, 'New Order • ₦3500');
      expect(
        banner.body,
        'Pickup: Lekki Phase 1\nDrop-off: Victoria Island',
      );
      expect(banner.timeoutAfterMs, 45000);
      expect(banner.id, greaterThanOrEqualTo(0));
      expect(banner.id, equals('trip_abc_123'.hashCode & 0x7fffffff));
    });

    test('buildDriverOfferBanner returns null when offer is expired', () {
      final now = DateTime.fromMillisecondsSinceEpoch(1700000050000);
      final banner = PushNotificationService.buildDriverOfferBanner(
        {
          'type': 'new_trip_offer',
          'tripId': 'trip_expired',
          'pickupAddress': 'Ikeja',
          'dropoffAddress': 'Yaba',
          'fare': '2000',
          'expiresAtMs': '${now.millisecondsSinceEpoch - 1000}',
        },
        now: now,
      );

      expect(banner, isNull);
    });

    test('showFromMessage handles foreground suppression safely without plugins',
        () async {
      PushNotificationService.isAppInForeground = true;
      await PushNotificationService.showFromMessage(
        const RemoteMessage(
          data: {
            'type': 'new_trip_offer',
            'tripId': 'trip_fg_1',
            'fare': '4200',
            'pickupAddress': 'Surulere',
            'dropoffAddress': 'Ikoyi',
          },
        ),
      );
      PushNotificationService.isAppInForeground = false;
      await PushNotificationService.showFromMessage(
        const RemoteMessage(
          data: {
            'type': 'new_trip_offer',
            'tripId': 'trip_bg_1',
            'fare': '4200',
            'pickupAddress': 'Surulere',
            'dropoffAddress': 'Ikoyi',
          },
        ),
      );
    });
  });
}
