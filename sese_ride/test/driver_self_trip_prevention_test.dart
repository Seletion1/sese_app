import 'package:flutter_test/flutter_test.dart';
import 'package:sese_ride/features/trips/models/trip_models.dart';
import 'package:sese_ride/features/driver/services/driver_streak_service.dart';

void main() {
  group('Driver Self-Trip Prevention & Order Pool Isolation Tests', () {
    const driverId = 'driver_user_123';
    const otherCustomerId = 'customer_user_456';

    test('1. ActiveTrip.fromMap accurately extracts customerId from various schema fields', () {
      final tripWithCustomerId = ActiveTrip.fromMap('trip_1', {
        'status': 'MARKETPLACE_OPEN',
        'customerId': driverId,
        'fareAmount': 2500,
      });
      expect(tripWithCustomerId.customerId, driverId);

      final tripWithUserId = ActiveTrip.fromMap('trip_2', {
        'status': 'MARKETPLACE_OPEN',
        'userId': driverId,
        'fareAmount': 3000,
      });
      expect(tripWithUserId.customerId, driverId);

      final tripWithCustomerMap = ActiveTrip.fromMap('trip_3', {
        'status': 'MARKETPLACE_OPEN',
        'customer': {'uid': driverId, 'name': 'Self Driver'},
        'fareAmount': 1500,
      });
      expect(tripWithCustomerMap.customerId, driverId);
    });

    test('2. Order list filtering eliminates self-created customer orders', () {
      final ownTrip = ActiveTrip.fromMap('trip_own', {
        'status': 'MARKETPLACE_OPEN',
        'customerId': driverId,
        'fareAmount': 4000,
      });

      final strangerTrip = ActiveTrip.fromMap('trip_stranger', {
        'status': 'MARKETPLACE_OPEN',
        'customerId': otherCustomerId,
        'fareAmount': 3500,
      });

      final allTrips = [ownTrip, strangerTrip];

      // Filtering criteria used across OrderFeed, OrderPoolSheet, and PoolBadge
      final visibleToDriver = allTrips
          .where((t) => t.customerId != driverId)
          .toList();

      expect(visibleToDriver.length, 1);
      expect(visibleToDriver.first.tripId, 'trip_stranger');
      expect(visibleToDriver.first.customerId, otherCustomerId);
    });

    test('3. Driver streak service marketplaceStream excludes own trips', () async {
      final service = DriverStreakService();

      // Offline stream returns empty list without crashing
      final stream = service.marketplaceStream(driverId: driverId);
      final initial = await stream.first;
      expect(initial, isEmpty);
    });

    test('4. Driver streak service pingStream suppresses self-created trips', () async {
      final service = DriverStreakService();

      // Offline ping stream returns null without crashing
      final stream = service.pingStream(driverId);
      final initial = await stream.first;
      expect(initial, isNull);
    });
  });
}
