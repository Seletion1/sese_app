import 'package:flutter_test/flutter_test.dart';
import 'package:sese_core/services/push_notification_service.dart';

void main() {
  group('Push channels', () {
    test('channel ids and sound resource are stable', () {
      expect(PushChannels.orders, 'sese_orders');
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
      // Token registration is best-effort: empty uid and missing Firebase
      // resolve to no-ops, never throws.
      await PushNotificationService.registerToken(uid: '');
      await PushNotificationService.registerToken(
          uid: 'user_x', country: 'NG');
    });
  });
}
