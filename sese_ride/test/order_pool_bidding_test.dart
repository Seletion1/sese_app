import 'package:flutter_test/flutter_test.dart';
import 'package:sese_ride/features/driver/presentation/widgets/order_pool_sheet.dart';

void main() {
  setUp(() {
    OrderPoolSession.clear();
  });

  tearDown(() {
    OrderPoolSession.clear();
  });

  group('OrderPoolSession Persistent Dismissal', () {
    test('isDismissed returns false initially for active order', () {
      expect(OrderPoolSession.isDismissed('trip_123'), isFalse);
    });

    test('dismiss adds tripId to session cache so isDismissed returns true', () {
      OrderPoolSession.dismiss('trip_123');
      expect(OrderPoolSession.isDismissed('trip_123'), isTrue);
      expect(OrderPoolSession.isDismissed('trip_456'), isFalse);
    });

    test('restore removes tripId from session cache (Undo action)', () {
      OrderPoolSession.dismiss('trip_123');
      expect(OrderPoolSession.isDismissed('trip_123'), isTrue);

      OrderPoolSession.restore('trip_123');
      expect(OrderPoolSession.isDismissed('trip_123'), isFalse);
    });

    test('clear resets all dismissed orders', () {
      OrderPoolSession.dismiss('trip_123');
      OrderPoolSession.dismiss('trip_456');

      OrderPoolSession.clear();

      expect(OrderPoolSession.isDismissed('trip_123'), isFalse);
      expect(OrderPoolSession.isDismissed('trip_456'), isFalse);
    });
  });
}
