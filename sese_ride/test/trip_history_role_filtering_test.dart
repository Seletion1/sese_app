import 'package:flutter_test/flutter_test.dart';
import 'package:sese_ride/features/trips/models/trip_models.dart';
import 'package:sese_ride/features/wallet/earnings_service.dart';

void main() {
  group('Trip History Role Segregation & Sorting Tests', () {
    final now = DateTime.now();

    final customerTrip = ActiveTrip(
      tripId: 't_cust_1',
      status: TripStatus.completed,
      customerId: 'user_123',
      driver: const DriverInfo(
        driverId: 'other_driver',
        fullName: 'Driver Bob',
        phone: '123',
      ),
      createdAt: now.subtract(const Duration(days: 3)),
      completedAt: now.subtract(const Duration(hours: 1)),
    );

    final driverTrip = ActiveTrip(
      tripId: 't_driver_1',
      status: TripStatus.completed,
      customerId: 'other_customer',
      driver: const DriverInfo(
        driverId: 'user_123',
        fullName: 'Me Driver',
        phone: '456',
      ),
      createdAt: now.subtract(const Duration(days: 2)),
      completedAt: now,
    );

    final selfTripAsDriver = ActiveTrip(
      tripId: 't_self_1',
      status: TripStatus.completed,
      customerId: 'user_123',
      driver: const DriverInfo(
        driverId: 'user_123',
        fullName: 'Self Driver',
        phone: '789',
      ),
      createdAt: now.subtract(const Duration(days: 1)),
      completedAt: now.subtract(const Duration(minutes: 30)),
    );

    test('Customer Mode History includes only customer-booked trips and excludes driver-fulfilled trips', () {
      final allTrips = [customerTrip, driverTrip, selfTripAsDriver];

      // Simulate customer mode stream filtering logic
      final customerTrips = allTrips.where((trip) =>
          trip.customerId == 'user_123' &&
          trip.driver?.driverId != 'user_123' &&
          trip.driverId != 'user_123').toList();

      expect(customerTrips.length, equals(1));
      expect(customerTrips.first.tripId, equals('t_cust_1'));
    });

    test('Driver Mode History includes only driver-fulfilled trips and excludes customer-booked trips', () {
      final allTrips = [customerTrip, driverTrip, selfTripAsDriver];

      // Simulate driver mode stream filtering logic
      final driverTrips = allTrips.where((trip) {
        if (trip.customerId == 'user_123') return false;
        final isAssigned = trip.driver?.driverId == 'user_123' || trip.driverId == 'user_123';
        if (trip.status == TripStatus.completed && !isAssigned) return false;
        return isAssigned;
      }).toList();

      expect(driverTrips.length, equals(1));
      expect(driverTrips.first.tripId, equals('t_driver_1'));
    });

    test('Trips are correctly ordered by latestActivityDate descending', () {
      final earlierTrip = ActiveTrip(
        tripId: 'earlier',
        status: TripStatus.completed,
        customerId: 'user_123',
        createdAt: now.subtract(const Duration(days: 10)),
        completedAt: now.subtract(const Duration(days: 2)),
      );

      final recentTrip = ActiveTrip(
        tripId: 'recent',
        status: TripStatus.completed,
        customerId: 'user_123',
        createdAt: now.subtract(const Duration(days: 15)),
        completedAt: now,
      );

      final trips = [earlierTrip, recentTrip];
      trips.sort((a, b) => b.latestActivityDate.compareTo(a.latestActivityDate));

      expect(trips.first.tripId, equals('recent'));
      expect(trips.last.tripId, equals('earlier'));
    });

    test('TripEarning.fromTrip maps completed trip earnings correctly', () {
      final earning = TripEarning.fromTrip(driverTrip);
      expect(earning.tripId, equals('t_driver_1'));
      expect(earning.completedAt, equals(driverTrip.completedAt));
    });
  });
}
