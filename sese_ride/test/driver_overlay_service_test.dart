import 'package:flutter_test/flutter_test.dart';
import 'package:sese_ride/features/driver/services/driver_overlay_service.dart';

void main() {
  group('DriverOverlayService (unsupported platform seam)', () {
    test('all calls are safe no-ops when unsupported', () async {
      final svc = DriverOverlayService.instance;
      svc.forceUnsupported = true;
      addTearDown(() => svc.dispose());

      expect(svc.supported, isFalse);
      expect(await svc.ensurePermission(), isFalse);
      await svc.showBubble();
      await svc.showOrderOffer(
        tripId: 't1',
        pickup: 'A',
        dropoff: 'B',
        distanceKm: '1.0',
        fare: '₦100',
      );
      await svc.hide();
      var called = false;
      svc.listenActions((_, _) => called = true);
      expect(called, isFalse);
    });
  });
}
