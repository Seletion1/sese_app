import 'package:flutter_test/flutter_test.dart';
import 'package:sese_ride/features/driver/presentation/widgets/order_pool_sheet.dart';
import 'package:sese_ride/features/trips/models/trip_models.dart';

ActiveTrip _makeTrip({
  required String tripId,
  double fareAmount = 5200.0,
  double pickupLat = 6.5244,
  double pickupLng = 3.3792,
  String pickupAddress = '34 Olafiloye St',
  double dropoffLat = 6.6018,
  double dropoffLng = 3.3515,
  String dropoffAddress = '18 Adebayo Mokuolu St',
  DateTime? updatedAt,
  bool fareBoosted = false,
  int boostPercent = 0,
}) {
  return ActiveTrip(
    tripId: tripId,
    status: TripStatus.marketplaceOpen,
    customerId: 'cust_1',
    serviceType: 'delivery',
    pickupLat: pickupLat,
    pickupLng: pickupLng,
    pickupAddress: pickupAddress,
    dropoffLat: dropoffLat,
    dropoffLng: dropoffLng,
    dropoffAddress: dropoffAddress,
    tierIds: const ['comfort'],
    distanceKm: 27.6,
    durationMins: 46,
    fareAmount: fareAmount,
    updatedAt: updatedAt,
    fareBoosted: fareBoosted,
    boostPercent: boostPercent,
  );
}

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

  group('OrderPoolSession Conditional Re-appearance on Order Modification', () {
    test('unmodified trip remains hidden throughout driver session', () {
      final trip = _makeTrip(tripId: 'trip_100', fareAmount: 5200.0);
      OrderPoolSession.dismissTrip(trip);

      final sameTrip = _makeTrip(tripId: 'trip_100', fareAmount: 5200.0);
      expect(OrderPoolSession.isDismissedTrip(sameTrip), isTrue);
    });

    test('re-appears when customer boosts offer fare', () {
      final original = _makeTrip(tripId: 'trip_101', fareAmount: 5200.0);
      OrderPoolSession.dismissTrip(original);
      expect(OrderPoolSession.isDismissedTrip(original), isTrue);

      final boosted = _makeTrip(
        tripId: 'trip_101',
        fareAmount: 6000.0,
        fareBoosted: true,
        boostPercent: 15,
      );

      // Evaluating modified trip auto-restores it
      expect(OrderPoolSession.isDismissedTrip(boosted), isFalse);
      // Subsequent check confirms it's no longer dismissed
      expect(OrderPoolSession.isDismissed('trip_101'), isFalse);
    });

    test('re-appears when customer modifies pickup/dropoff route parameters', () {
      final original = _makeTrip(
        tripId: 'trip_102',
        dropoffAddress: '18 Adebayo Mokuolu St',
      );
      OrderPoolSession.dismissTrip(original);
      expect(OrderPoolSession.isDismissedTrip(original), isTrue);

      final updatedRoute = _makeTrip(
        tripId: 'trip_102',
        dropoffAddress: '25 Ikeja Way',
        dropoffLat: 6.5900,
      );

      expect(OrderPoolSession.isDismissedTrip(updatedRoute), isFalse);
      expect(OrderPoolSession.isDismissed('trip_102'), isFalse);
    });

    test('re-appears when trip updatedAt is updated after dismissal', () {
      final t0 = DateTime(2026, 11, 2, 10, 0);
      final original = _makeTrip(tripId: 'trip_103', updatedAt: t0);
      OrderPoolSession.dismissTrip(original);
      expect(OrderPoolSession.isDismissedTrip(original), isTrue);

      final t1 = DateTime(2026, 11, 2, 10, 5);
      final updatedTrip = _makeTrip(tripId: 'trip_103', updatedAt: t1);

      expect(OrderPoolSession.isDismissedTrip(updatedTrip), isFalse);
      expect(OrderPoolSession.isDismissed('trip_103'), isFalse);
    });

    test('re-appears when initial updatedAt was null and is set on modification', () {
      final original = _makeTrip(tripId: 'trip_104', updatedAt: null);
      OrderPoolSession.dismissTrip(original);
      expect(OrderPoolSession.isDismissedTrip(original), isTrue);

      final t1 = DateTime(2026, 11, 2, 10, 5);
      final updatedTrip = _makeTrip(tripId: 'trip_104', updatedAt: t1);

      expect(OrderPoolSession.isDismissedTrip(updatedTrip), isFalse);
      expect(OrderPoolSession.isDismissed('trip_104'), isFalse);
    });
  });
}
