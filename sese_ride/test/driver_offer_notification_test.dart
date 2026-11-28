import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sese_core/services/push_notification_service.dart';
import 'package:sese_ride/background_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('Driver offer background handlers', () {
    test('driverBackgroundHandler persists new_trip_offer payload', () async {
      SharedPreferences.setMockInitialValues({
        'driver_online_session': 'session_test_123',
      });
      const message = RemoteMessage(
        data: {
          'type': 'new_trip_offer',
          'tripId': 'trip_bg_test_1',
          'pickupAddress': 'Admiralty Way',
          'dropoffAddress': 'Ozumba Mbadiwe',
          'fare': '3800',
          'currency': 'NGN',
          'expiresAtMs': '9999999999999',
        },
      );

      await driverBackgroundHandler(message);

      final prefs = await SharedPreferences.getInstance();
      final pending = prefs.getString('pending_offer_payload');
      expect(pending, isNotNull);
      expect(pending, contains('tripId=trip_bg_test_1'));
      expect(pending, contains('type=new_trip_offer'));
    });

    test('driverBackgroundHandler drops offer payload when driver is offline', () async {
      SharedPreferences.setMockInitialValues({
        'driver_is_online': false,
      });
      const message = RemoteMessage(
        data: {
          'type': 'new_trip_offer',
          'tripId': 'trip_bg_offline',
        },
      );

      await driverBackgroundHandler(message);

      final prefs = await SharedPreferences.getInstance();
      final pending = prefs.getString('pending_offer_payload');
      expect(pending, isNull);
    });

    test(
        'driverNotificationActionBackgroundHandler ignores non-decline actions and degrades safely without Firebase',
        () async {
      SharedPreferences.setMockInitialValues({});
      await driverNotificationActionBackgroundHandler(
        const NotificationResponse(
          notificationResponseType:
              NotificationResponseType.selectedNotificationAction,
          actionId: 'accept_offer',
          payload: 'tripId=trip_123&type=new_trip_offer',
        ),
      );
      await driverNotificationActionBackgroundHandler(
        const NotificationResponse(
          notificationResponseType:
              NotificationResponseType.selectedNotificationAction,
          actionId: 'decline_offer',
          payload: 'tripId=trip_123&type=new_trip_offer',
        ),
      );
    });
  });
}
