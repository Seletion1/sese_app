import 'package:flutter_test/flutter_test.dart';
import 'package:sese_ride/features/driver/services/driver_overlay_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('DriverOverlayService Tests', () {
    test('isOnline state can be set and queried', () {
      final service = DriverOverlayService.instance;
      service.isOnline = true;
      expect(service.isOnline, isTrue);

      service.isOnline = false;
      expect(service.isOnline, isFalse);
    });

    test('listenActions registers callback safely', () {
      final service = DriverOverlayService.instance;
      String? receivedAction;
      String? receivedTripId;
      service.listenActions((action, tripId) {
        receivedAction = action;
        receivedTripId = tripId;
      });

      // Verification of clean listener registration
      expect(service.isOnline, isFalse);
      expect(receivedAction, isNull);
      expect(receivedTripId, isNull);
    });
  });
}
