import 'package:flutter_test/flutter_test.dart';
import 'package:sese_core/services/push_notification_service.dart';

void main() {
  group('Push channels', () {
    test('channel ids and sound resource are stable', () {
      expect(PushChannels.orders, 'sese_orders');
      expect(PushChannels.chat, 'sese_chat');
      expect(PushChannels.system, 'sese_system');
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
      await PushNotificationService.showReturnToAppAlert();
    });
  });
}
