import 'package:flutter_test/flutter_test.dart';
import 'package:sese_ride/features/trips/models/trip_models.dart';

void main() {
  group('TripStatus parsing', () {
    test('parses every wire value round-trip', () {
      for (final s in TripStatus.values) {
        if (s == TripStatus.unknown) continue;
        expect(tripStatusFromString(s.wireValue), s);
      }
    });

    test('unknown strings fall back to unknown', () {
      expect(tripStatusFromString(null), TripStatus.unknown);
      expect(tripStatusFromString(''), TripStatus.unknown);
      expect(tripStatusFromString('FLYING'), TripStatus.unknown);
    });
  });

  group('ActiveTrip', () {
    test('isLive is false only for terminal states', () {
      expect(
        const ActiveTrip(
          tripId: 't',
          status: TripStatus.searchingDriver,
          customerId: 'c',
        ).isLive,
        isTrue,
      );
      expect(
        const ActiveTrip(
          tripId: 't',
          status: TripStatus.driverAccepted,
          customerId: 'c',
        ).isLive,
        isTrue,
      );
      expect(
        const ActiveTrip(
          tripId: 't',
          status: TripStatus.completed,
          customerId: 'c',
        ).isLive,
        isFalse,
      );
      expect(
        const ActiveTrip(
          tripId: 't',
          status: TripStatus.cancelled,
          customerId: 'c',
        ).isLive,
        isFalse,
      );
    });

    test('fromMap reads nested pickup/dropoff/driver payloads', () {
      final trip = ActiveTrip.fromMap('trip-7', {
        'status': 'DRIVER_ACCEPTED',
        'customerId': 'cust-1',
        'serviceType': 'ride',
        'pickup': {
          'lat': 6.5,
          'lng': 3.3,
          'address': 'Ikorodu, Lagos State',
          'phone': '08161561592',
        },
        'dropoff': {
          'lat': 6.6,
          'lng': 3.4,
          'address': 'Ketu, Kosofe, Lagos State',
          'phone': '07080286030',
        },
        'selectedTiers': ['comfort', 'premium'],
        'declineCount': 1,
        'driver': {
          'driverId': 'd1',
          'fullName': 'Adaeze Okonkwo',
          'rating': 4.8,
          'phone': '+2348012345678',
          'plateNumber': 'ABC-123-ZZ',
          'vehicleModel': 'Honda Accord',
        },
        'driverLocation': {'lat': 6.55, 'lng': 3.36},
      });

      expect(trip.status, TripStatus.driverAccepted);
      expect(trip.pickupPhone, '08161561592');
      expect(trip.dropoffAddress, 'Ketu, Kosofe, Lagos State');
      expect(trip.tierIds, ['comfort', 'premium']);
      expect(trip.declineCount, 1);
      expect(trip.driver?.fullName, 'Adaeze Okonkwo');
      expect(trip.driver?.vehicleLabel, 'ABC-123-ZZ · Honda Accord');
      expect(trip.driverLat, 6.55);
      expect(trip.isLive, isTrue);
    });

    test('fromMap tolerates missing optional sections', () {
      final trip = ActiveTrip.fromMap('trip-8', {
        'status': 'SEARCHING_DRIVER',
        'customerId': 'cust-1',
      });

      expect(trip.status, TripStatus.searchingDriver);
      expect(trip.driver, isNull);
      expect(trip.driverLat, isNull);
      expect(trip.pickupPhone, isEmpty);
      // Booker line defaults empty on pre-migration trips (driver card
      // falls back to the pickup contact, then to in-app chat).
      expect(trip.customerPhone, isEmpty);
    });

    test('fromMap reads the booker lifeline number', () {
      final trip = ActiveTrip.fromMap('trip-9', {
        'status': 'DRIVER_ACCEPTED',
        'customerId': 'cust-1',
        'customerPhone': '+2348012345678',
        'pickup': {'lat': 6.5, 'lng': 3.3, 'phone': ''},
        'dropoff': {'lat': 6.6, 'lng': 3.4, 'phone': ''},
      });

      expect(trip.customerPhone, '+2348012345678');
      expect(trip.pickupPhone, isEmpty);
      expect(trip.dropoffPhone, isEmpty);
    });

    test('parses REJECTED and IGNORED statuses correctly', () {
      final tripRejected = ActiveTrip.fromMap('trip-rej', {
        'status': 'REJECTED',
        'customerId': 'cust-1',
        'cancellationSource': 'driver_declined',
      });
      expect(tripRejected.status, TripStatus.rejected);
      expect(tripRejected.isLive, isFalse);

      final tripIgnored = ActiveTrip.fromMap('trip-ign', {
        'status': 'IGNORED',
        'customerId': 'cust-1',
        'cancellationSource': 'ping_expired',
      });
      expect(tripIgnored.status, TripStatus.ignored);
      expect(tripIgnored.isLive, isFalse);
    });
  });

  group('DriverInfo', () {
    test('vehicleLabel omits blanks', () {
      expect(
        const DriverInfo(driverId: 'd', fullName: 'D', phone: 'p')
            .vehicleLabel,
        isEmpty,
      );
      expect(
        const DriverInfo(
          driverId: 'd',
          fullName: 'D',
          phone: 'p',
          plateNumber: 'ABC-1',
        ).vehicleLabel,
        'ABC-1',
      );
    });
  });

  group('TripDraft', () {
    test('toMap carries contact phones for the callable', () {
      final map = const TripDraft(
        customerId: 'c1',
        pickupLat: 6.5,
        pickupLng: 3.3,
        pickupAddress: 'A',
        pickupPhone: '08161561592',
        dropoffLat: 6.6,
        dropoffLng: 3.4,
        dropoffAddress: 'B',
        dropoffPhone: '07080286030',
        serviceType: 'ride',
        selectedTiers: ['comfort'],
        fareToken: 'tok',
        distanceKm: 10,
        durationMins: 20,
      ).toMap();

      expect(map['pickupPhone'], '08161561592');
      expect(map['dropoffPhone'], '07080286030');
      expect((map['pickup'] as Map)['phone'], '08161561592');
      expect((map['dropoff'] as Map)['phone'], '07080286030');
    });
  });
}
