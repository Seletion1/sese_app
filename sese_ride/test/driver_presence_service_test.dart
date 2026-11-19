import 'package:flutter_test/flutter_test.dart';
import 'package:sese_ride/features/driver/services/driver_presence_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    DriverPresenceService.instance.forceUnsupported = true;
    DriverPresenceService.instance.isOnline = false;
    DriverPresenceService.instance.hasActiveTrip = false;
  });

  group('DriverPresenceService Tests', () {
    test('isOnline and hasActiveTrip state can be set and queried', () {
      final service = DriverPresenceService.instance;
      service.isOnline = true;
      service.setActiveTrip(true);
      expect(service.isOnline, isTrue);
      expect(service.hasActiveTrip, isTrue);

      service.isOnline = false;
      service.setActiveTrip(false);
      expect(service.isOnline, isFalse);
      expect(service.hasActiveTrip, isFalse);
    });

    test('forceUnsupported disables platform overlay checks safely', () {
      final service = DriverPresenceService.instance;
      service.forceUnsupported = true;
      expect(service.isAndroidOverlaySupported, isFalse);
      expect(service.isIos, isFalse);
    });

    test('bubble setting can be saved and read via SharedPreferences', () async {
      final service = DriverPresenceService.instance;
      expect(await service.isBubbleSettingEnabled(), isTrue);

      await service.setBubbleSettingEnabled(false);
      expect(await service.isBubbleSettingEnabled(), isFalse);

      await service.setBubbleSettingEnabled(true);
      expect(await service.isBubbleSettingEnabled(), isTrue);
    });

    test('onDriverOnline and onDriverOffline maintain state lifecycle', () async {
      final service = DriverPresenceService.instance;
      await service.onDriverOnline(driverId: 'driver_test_123');
      expect(service.isOnline, isTrue);

      service.setActiveTrip(true);
      expect(service.hasActiveTrip, isTrue);

      await service.onDriverOffline();
      expect(service.isOnline, isFalse);
      expect(service.hasActiveTrip, isFalse);
    });

    test('onDriverSignOut resets state cleanly', () async {
      final service = DriverPresenceService.instance;
      await service.onDriverOnline(driverId: 'driver_test_123');
      expect(service.isOnline, isTrue);

      await service.onDriverSignOut();
      expect(service.isOnline, isFalse);
    });
  });
}
