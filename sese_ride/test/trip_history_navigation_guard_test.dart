import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sese_ride/features/trips/models/bid_models.dart';
import 'package:sese_ride/features/trips/models/trip_models.dart';
import 'package:sese_ride/features/trips/presentation/customer_trips_screen.dart';
import 'package:sese_ride/features/trips/presentation/live_trip_screen.dart';
import 'package:sese_ride/features/trips/services/trip_service.dart';
import 'package:sese_ride/widgets/osm_map_view.dart';

class _FakeTripRepo implements TripRepository {
  final List<ActiveTrip> historyTrips;

  _FakeTripRepo({this.historyTrips = const []});

  @override
  Future<String> createTrip(TripDraft draft) async => 'trip-1';

  @override
  Stream<ActiveTrip?> tripStream(String tripId) {
    final match = historyTrips.firstWhere(
      (t) => t.tripId == tripId,
      orElse: () => ActiveTrip(
        tripId: tripId,
        status: TripStatus.searchingDriver,
        customerId: 'customer_123',
        pickupAddress: 'Lagos',
        dropoffAddress: 'Ikeja',
      ),
    );
    return Stream.value(match);
  }

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
  Future<void> reassignTrip(String tripId, {double? newFare}) async {}

  @override
  Future<void> keepSearchingTrip(String tripId) async {}

  @override
  Stream<List<BidModel>> bidsStream(String tripId) => Stream.value(const []);

  @override
  Stream<BidModel?> activeDriverBidStream(String driverId) =>
      Stream.value(null);

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

  group('Trip History Navigation Guard Tests', () {
    testWidgets(
        'Driver tapping skipped/unassigned order in trip history opens read-only summary sheet, NOT LiveTripScreen',
        (tester) async {
      tester.view.physicalSize = const Size(800, 2000);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);

      final skippedTrip = ActiveTrip(
        tripId: 'skipped_order_1',
        status: TripStatus.searchingDriver,
        customerId: 'customer_abc',
        pickupAddress: 'Victoria Island, Lagos',
        dropoffAddress: 'Lekki Phase 1, Lagos',
        fareAmount: 3500,
        fareFormatted: '₦3,500',
        rejections: const [
          {
            'driverId': 'driver_456',
            'action': 'skipped',
            'timestamp': 1700000000000,
          }
        ],
      );

      final fakeRepo = _FakeTripRepo(historyTrips: [skippedTrip]);

      await tester.pumpWidget(
        MaterialApp(
          home: CustomerTripsScreen(
            customerId: 'driver_456',
            isDriver: true,
            tripRepository: fakeRepo,
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Verify card renders
      expect(find.text('Victoria Island, Lagos'), findsOneWidget);
      expect(find.text('View Details'), findsOneWidget);
      expect(find.text('Track Live'), findsNothing);

      // Tap on the skipped trip card
      await tester.tap(find.text('Victoria Island, Lagos'));
      await tester.pumpAndSettle();

      // Verify static read-only modal opens
      expect(find.text('Trip Details'), findsOneWidget);
      expect(find.text('Skipped by Driver'), findsWidgets);
      expect(find.text('Dispatch Audit Log'), findsOneWidget);

      // Verify LiveTripScreen is NOT pushed (interactive controls are absent)
      expect(find.byKey(const Key('boost_fare_pencil_button')), findsNothing);
      expect(find.text('Cancel trip'), findsNothing);
    });

    testWidgets(
        'Driver tapping actively assigned live trip in history navigates to LiveTripScreen',
        (tester) async {
      tester.view.physicalSize = const Size(800, 2000);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);

      final activeTrip = ActiveTrip(
        tripId: 'active_order_1',
        status: TripStatus.driverAccepted,
        customerId: 'customer_xyz',
        pickupAddress: 'Ikeja, Lagos',
        dropoffAddress: 'Yaba, Lagos',
        fareAmount: 2500,
        fareFormatted: '₦2,500',
        driver: const DriverInfo(
          driverId: 'driver_456',
          fullName: 'Me Driver',
          phone: '08012345678',
        ),
      );

      final fakeRepo = _FakeTripRepo(historyTrips: [activeTrip]);

      await tester.pumpWidget(
        MaterialApp(
          home: CustomerTripsScreen(
            customerId: 'driver_456',
            isDriver: true,
            tripRepository: fakeRepo,
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Verify card renders "Track Live"
      expect(find.text('Ikeja, Lagos'), findsOneWidget);
      expect(find.text('Track Live'), findsOneWidget);

      // Tap on active trip card
      await tester.tap(find.text('Ikeja, Lagos'));
      await tester.pumpAndSettle();

      // Verify LiveTripScreen is pushed
      expect(find.byType(LiveTripScreen), findsOneWidget);
    });

    testWidgets(
        'Driver tapping cancelled trip in history opens read-only summary sheet, NOT LiveTripScreen',
        (tester) async {
      tester.view.physicalSize = const Size(800, 2000);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);

      final cancelledTrip = ActiveTrip(
        tripId: 'cancelled_order_1',
        status: TripStatus.cancelled,
        customerId: 'customer_123',
        pickupAddress: 'Surulere, Lagos',
        dropoffAddress: 'Ajah, Lagos',
        fareAmount: 4000,
        cancellationSource: 'customer',
      );

      final fakeRepo = _FakeTripRepo(historyTrips: [cancelledTrip]);

      await tester.pumpWidget(
        MaterialApp(
          home: CustomerTripsScreen(
            customerId: 'driver_456',
            isDriver: true,
            tripRepository: fakeRepo,
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Surulere, Lagos'), findsOneWidget);
      expect(find.text('View Details'), findsOneWidget);

      await tester.tap(find.text('Surulere, Lagos'));
      await tester.pumpAndSettle();

      expect(find.text('Trip Details'), findsOneWidget);
      expect(find.text('Cancelled by Customer'), findsWidgets);
      expect(find.byType(LiveTripScreen), findsNothing);
    });

    testWidgets(
        'Driver tapping skipped order in history opens read-only summary modal with zero interactive controls',
        (tester) async {
      tester.view.physicalSize = const Size(800, 2000);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);

      final unassignedSearchingTrip = ActiveTrip(
        tripId: 'unassigned_searching_1',
        status: TripStatus.searchingDriver,
        customerId: 'customer_999',
        pickupAddress: 'Yaba Market, Lagos',
        dropoffAddress: 'Maryland, Lagos',
        fareAmount: 2000,
        rejections: const [
          {
            'driverId': 'driver_456',
            'action': 'skipped',
            'timestamp': 1700000000000,
          }
        ],
      );

      final fakeRepo = _FakeTripRepo(historyTrips: [unassignedSearchingTrip]);

      await tester.pumpWidget(
        MaterialApp(
          home: CustomerTripsScreen(
            customerId: 'driver_456',
            isDriver: true,
            tripRepository: fakeRepo,
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Verify View Details tap opens read-only summary sheet
      expect(find.text('Yaba Market, Lagos'), findsOneWidget);
      expect(find.text('View Details'), findsOneWidget);

      await tester.tap(find.text('Yaba Market, Lagos'));
      await tester.pumpAndSettle();

      expect(find.text('Trip Details'), findsOneWidget);
      expect(find.text('Skipped by Driver'), findsWidgets);

      // Verify interactive controls are absent
      expect(find.byKey(const Key('boost_fare_pencil_button')), findsNothing);
      expect(find.text('Cancel trip'), findsNothing);
    });
  });
}
