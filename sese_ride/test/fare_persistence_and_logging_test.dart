import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sese_ride/features/trips/models/bid_models.dart';
import 'package:sese_ride/features/trips/models/trip_models.dart';
import 'package:sese_ride/features/trips/presentation/customer_trips_screen.dart';
import 'package:sese_ride/features/trips/services/trip_service.dart';

class MockTripRepository implements TripRepository {
  final List<ActiveTrip> trips;
  MockTripRepository(this.trips);

  @override
  Stream<List<ActiveTrip>> userTripHistoryStream(String userId, {bool isDriver = false}) {
    return Stream.value(trips);
  }

  @override
  Stream<List<ActiveTrip>> activeTripsStream(String customerId) => Stream.value([]);

  @override
  Future<String> createTrip(TripDraft draft) async => 'trip-mock-1';

  @override
  Future<void> cancelTrip(String tripId, {String? reason, bool useCashSettlement = false}) async {}

  @override
  Future<void> submitBid(String tripId, double offeredFare, {int? etaMinutes}) async {}

  @override
  Future<void> acceptBid(String tripId, String bidId) async {}

  @override
  Future<void> rejectBid(String tripId, String bidId) async {}

  @override
  Stream<ActiveTrip?> tripStream(String tripId) => Stream.value(trips.isNotEmpty ? trips.first : null);

  @override
  Stream<List<BidModel>> bidsStream(String tripId) => Stream.value([]);

  @override
  Future<void> increaseTripFare(String tripId, double newFare) async {}

  @override
  Future<void> keepSearchingTrip(String tripId) async {}
}

void main() {
  group('Fare Customization Persistence in TripDraft', () {
    test('TripDraft retains proposedFare and customTierFares in map conversion', () {
      const draft = TripDraft(
        customerId: 'cust_123',
        pickupLat: 6.5,
        pickupLng: 3.3,
        pickupAddress: 'Ikorodu',
        pickupPhone: '08012345678',
        dropoffLat: 6.6,
        dropoffLng: 3.4,
        dropoffAddress: 'Ketu',
        dropoffPhone: '08087654321',
        serviceType: 'send_item',
        selectedTiers: ['motorcycle'],
        fareToken: 'token_123',
        distanceKm: 17.5,
        durationMins: 39,
        proposedFare: 4500.0,
        customTierFares: {'motorcycle': 4500.0},
      );

      final map = draft.toMap();
      expect(map['proposedFare'], 4500.0);
      expect(map['customTierFares'], {'motorcycle': 4500.0});
    });
  });

  group('Accurate Trip Lifecycle & Cancellation Logging UI', () {
    testWidgets('Customer sees "Cancelled by You" when customer cancelled', (tester) async {
      final trip = ActiveTrip.fromMap('t1', {
        'status': 'CANCELLED',
        'customerId': 'cust_1',
        'cancellationSource': 'customer',
        'fareAmount': 4500.0,
        'fareFormatted': '₦4,500',
        'serviceType': 'send_item',
        'pickup': {'address': 'Ikorodu'},
        'dropoff': {'address': 'Ketu'},
      });

      await tester.pumpWidget(
        MaterialApp(
          home: CustomerTripsScreen(
            customerId: 'cust_1',
            isDriver: false,
            tripRepository: MockTripRepository([trip]),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Cancelled by You'), findsOneWidget);
    });

    testWidgets('Driver sees "Cancelled by Customer" when customer cancelled', (tester) async {
      final trip = ActiveTrip.fromMap('t2', {
        'status': 'CANCELLED',
        'customerId': 'cust_1',
        'driverId': 'driver_1',
        'cancellationSource': 'customer',
        'fareAmount': 4200.0,
        'fareFormatted': '₦4,200',
        'serviceType': 'send_item',
        'pickup': {'address': 'Ikorodu'},
        'dropoff': {'address': 'Ketu'},
      });

      await tester.pumpWidget(
        MaterialApp(
          home: CustomerTripsScreen(
            customerId: 'driver_1',
            isDriver: true,
            tripRepository: MockTripRepository([trip]),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Cancelled by Customer'), findsOneWidget);
      expect(find.text('Cancelled by You'), findsNothing);
    });

    testWidgets('Displays "Rejected" badge for rejected pings/offers', (tester) async {
      final trip = ActiveTrip.fromMap('t3', {
        'status': 'REJECTED',
        'customerId': 'cust_1',
        'cancellationSource': 'driver_declined',
        'fareAmount': 3000.0,
        'serviceType': 'ride',
      });

      await tester.pumpWidget(
        MaterialApp(
          home: CustomerTripsScreen(
            customerId: 'driver_1',
            isDriver: true,
            tripRepository: MockTripRepository([trip]),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Rejected'), findsOneWidget);
    });

    testWidgets('Displays "Ignored" badge for expired pings', (tester) async {
      final trip = ActiveTrip.fromMap('t4', {
        'status': 'IGNORED',
        'customerId': 'cust_1',
        'cancellationSource': 'ping_expired',
        'fareAmount': 3500.0,
        'serviceType': 'send_item',
      });

      await tester.pumpWidget(
        MaterialApp(
          home: CustomerTripsScreen(
            customerId: 'driver_1',
            isDriver: true,
            tripRepository: MockTripRepository([trip]),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Ignored'), findsOneWidget);
    });
  });
}
