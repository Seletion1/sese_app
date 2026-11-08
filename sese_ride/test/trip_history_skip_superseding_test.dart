import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sese_ride/features/trips/models/bid_models.dart';
import 'package:sese_ride/features/trips/models/trip_models.dart';
import 'package:sese_ride/features/trips/presentation/customer_trips_screen.dart';
import 'package:sese_ride/features/trips/services/trip_service.dart';
import 'package:sese_ride/widgets/osm_map_view.dart';

class _FakeTripRepo implements TripRepository {
  final List<ActiveTrip> historyTrips;

  _FakeTripRepo({this.historyTrips = const []});

  @override
  Future<String> createTrip(TripDraft draft) async => 'trip-1';

  @override
  Stream<ActiveTrip?> tripStream(String tripId) => Stream.value(null);

  @override
  Stream<List<ActiveTrip>> activeTripsStream(String customerId) =>
      Stream.value(const []);

  @override
  Stream<List<ActiveTrip>> userTripHistoryStream(String userId,
          {bool isDriver = false}) =>
      Stream.value(historyTrips);

  @override
  Future<void> cancelTrip(String tripId,
      {String? reason, bool useCashSettlement = false}) async {}

  @override
  Future<void> confirmCashCancellation(String tripId) async {}

  @override
  Future<void> submitBid(String tripId, double offeredFare,
      {int? etaMinutes}) async {}

  @override
  Future<void> rejectBid(String tripId, String driverId) async {}

  @override
  Future<void> acceptBid(String tripId, String driverId) async {}

  @override
  Future<void> increaseTripFare(String tripId, double newFare) async {}

  @override
  Future<void> keepSearchingTrip(String tripId) async {}

  @override
  Stream<List<BidModel>> bidsStream(String tripId) => Stream.value(const []);

  @override
  Stream<BidModel?> activeDriverBidStream(String driverId) => Stream.value(null);

  @override
  Stream<BidModel?> driverBidForTripStream(String tripId, String driverId) =>
      Stream.value(null);
}

void main() {
  setUp(() {
    OsmMapView.debugTileProviderOverride = BlankTileProvider();
  });

  tearDown(() {
    OsmMapView.debugTileProviderOverride = null;
  });

  group('Trip History Skip Superseding & State Tracking Tests', () {
    test('ActiveTrip model parses and supersedes preliminary skip upon completion', () {
      final completedTripRaw = {
        'status': 'COMPLETED',
        'customerId': 'customer_1',
        'driverId': 'driver_99',
        'driver': {
          'driverId': 'driver_99',
          'fullName': 'Bamidele Driver',
        },
        'fareAmount': 4400,
        'cancellationSource': 'skipped_by_driver', // Stale pre-acceptance skip source in raw doc
        'rejections': [
          {
            'driverId': 'driver_99',
            'action': 'skipped',
            'timestamp': 1700000000000,
            'superseded': true,
          }
        ],
        'pickup': {'address': '34 Olafiloye St, Ikorodu'},
        'dropoff': {'address': '15 Ikosi Rd, Oregun, Ikeja'},
      };

      final trip = ActiveTrip.fromMap('order_123', completedTripRaw);

      // Model sanity checks
      expect(trip.status, TripStatus.completed);
      expect(trip.cancellationSource, isNull,
          reason: 'cancellationSource must be sanitized to null for completed trips');
      expect(trip.driverRejectionAction('driver_99'), isNull,
          reason: 'Rejection action must resolve to null when driver completed the trip');
      expect(trip.isDriverSkipped('driver_99'), isFalse);
      expect(trip.isDriverRejected('driver_99'), isFalse);
    });

    testWidgets(
        'Driver Trips History renders Completed (not Skipped by Driver) for re-claimed completed trip',
        (tester) async {
      tester.view.physicalSize = const Size(800, 2000);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);

      // This trip matches the exact user bug:
      // Initial skip logged in rejections, then claimed from pool and completed.
      final reClaimedCompletedTrip = ActiveTrip(
        tripId: 'pkg_order_nov8',
        status: TripStatus.completed,
        customerId: 'customer_1',
        driver: const DriverInfo(
          driverId: 'driver_me',
          fullName: 'Michael Driver',
          phone: '08012345678',
        ),
        pickupAddress: '34 Olafiloye St, Ikorodu, Lagos',
        dropoffAddress: '15 Ikosi Rd, Oregun, Ikeja',
        fareAmount: 4400,
        fareFormatted: '₦4,400',
        serviceType: 'delivery',
        rejections: const [
          {
            'driverId': 'driver_me',
            'action': 'skipped',
            'timestamp': 1700000000000,
            'superseded': true,
          }
        ],
      );

      final fakeRepo = _FakeTripRepo(historyTrips: [reClaimedCompletedTrip]);

      await tester.pumpWidget(
        MaterialApp(
          home: CustomerTripsScreen(
            customerId: 'driver_me',
            isDriver: true,
            tripRepository: fakeRepo,
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Card must render "Completed" with zero occurrences of "Skipped by Driver" on the main feed
      expect(find.text('34 Olafiloye St, Ikorodu, Lagos'), findsOneWidget);
      expect(find.text('Completed'), findsOneWidget);
      expect(find.text('Skipped by Driver'), findsNothing);

      // Tap card to open trip summary modal
      await tester.tap(find.text('34 Olafiloye St, Ikorodu, Lagos'));
      await tester.pumpAndSettle();

      // Details sheet header badge must also render "Completed"
      expect(find.text('Trip Details'), findsOneWidget);
      expect(find.text('Completed'), findsWidgets);

      // Audit log in sheet should show the superseded skip clearly
      expect(find.text('Dispatch Audit Log'), findsOneWidget);
      expect(find.text('Skipped by Driver (Superseded)'), findsOneWidget);
    });

    testWidgets(
        'Standalone uncompleted skipped trip still displays Skipped by Driver',
        (tester) async {
      tester.view.physicalSize = const Size(800, 2000);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);

      final standaloneSkippedTrip = ActiveTrip(
        tripId: 'pkg_order_standalone',
        status: TripStatus.searchingDriver,
        customerId: 'customer_2',
        pickupAddress: '34 Olafiloye St, Ikorodu, Lagos',
        dropoffAddress: '15 Ikosi Rd, Oregun, Ikeja',
        fareAmount: 4950,
        fareFormatted: '₦4,950',
        serviceType: 'delivery',
        rejections: const [
          {
            'driverId': 'driver_me',
            'action': 'skipped',
            'timestamp': 1700000000000,
          }
        ],
      );

      final fakeRepo = _FakeTripRepo(historyTrips: [standaloneSkippedTrip]);

      await tester.pumpWidget(
        MaterialApp(
          home: CustomerTripsScreen(
            customerId: 'driver_me',
            isDriver: true,
            tripRepository: fakeRepo,
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Standalone skipped trip must render "Skipped by Driver"
      expect(find.text('Skipped by Driver'), findsOneWidget);
      expect(find.text('Completed'), findsNothing);
    });
  });
}
