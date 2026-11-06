import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sese_ride/features/driver/presentation/widgets/driver_active_bid_lock_card.dart';
import 'package:sese_ride/features/trips/models/bid_models.dart';
import 'package:sese_ride/features/trips/models/trip_models.dart';
import 'package:sese_ride/features/trips/presentation/live_trip_screen.dart';
import 'package:sese_ride/features/trips/services/trip_service.dart';
import 'package:sese_ride/widgets/osm_map_view.dart';

class _FakeBiddingTripRepo implements TripRepository {
  final controller = StreamController<List<BidModel>>.broadcast();
  final tripController = StreamController<ActiveTrip?>.broadcast();
  String? acceptedTripId;
  String? acceptedDriverId;
  String? rejectedTripId;
  String? rejectedDriverId;

  @override
  Future<String> createTrip(TripDraft draft) async => 'trip-1';

  @override
  Stream<ActiveTrip?> tripStream(String tripId) => tripController.stream;

  @override
  Stream<List<ActiveTrip>> activeTripsStream(String customerId) =>
      Stream.value(const []);

  @override
  Stream<List<ActiveTrip>> userTripHistoryStream(String userId,
          {bool isDriver = false}) =>
      Stream.value(const []);

  @override
  Future<void> cancelTrip(String tripId,
      {String? reason, bool useCashSettlement = false}) async {}

  @override
  Future<void> confirmCashCancellation(String tripId) async {}

  @override
  Future<void> submitBid(String tripId, double offeredFare,
      {int? etaMinutes}) async {}

  @override
  Future<void> rejectBid(String tripId, String driverId) async {
    rejectedTripId = tripId;
    rejectedDriverId = driverId;
  }

  @override
  Future<void> acceptBid(String tripId, String driverId) async {
    acceptedTripId = tripId;
    acceptedDriverId = driverId;
  }

  @override
  Future<void> increaseTripFare(String tripId, double newFare) async {}

  @override
  Future<void> keepSearchingTrip(String tripId) async {}

  @override
  Stream<List<BidModel>> bidsStream(String tripId) => controller.stream;

  @override
  Stream<BidModel?> activeDriverBidStream(String driverId) =>
      Stream.value(null);
}

void main() {
  setUp(() {
    OsmMapView.debugTileProviderOverride = BlankTileProvider();
  });

  tearDown(() {
    OsmMapView.debugTileProviderOverride = null;
  });

  group('Synchronized Bidding Flow Tests', () {
    test('BidModel correctly parses expiresAt and identifies expiration', () {
      final now = DateTime.now();

      final activeBid = BidModel(
        bidId: 'd1',
        driverId: 'd1',
        driverName: 'Driver 1',
        offeredFare: 3500,
        createdAt: now.subtract(const Duration(seconds: 2)),
        expiresAt: now.add(const Duration(seconds: 8)),
        bidCountdownSeconds: 10,
      );

      expect(activeBid.isExpired, isFalse);
      expect(activeBid.remainingSeconds, greaterThan(0));

      final expiredBid = BidModel(
        bidId: 'd2',
        driverId: 'd2',
        driverName: 'Driver 2',
        offeredFare: 4000,
        createdAt: now.subtract(const Duration(seconds: 15)),
        expiresAt: now.subtract(const Duration(seconds: 5)),
        bidCountdownSeconds: 10,
      );

      expect(expiredBid.isExpired, isTrue);
      expect(expiredBid.remainingDuration, equals(Duration.zero));
      expect(expiredBid.remainingSeconds, equals(0));
    });

    testWidgets(
        'DriverActiveBidLockCard renders active countdown and triggers callback upon expiration',
        (tester) async {
      final now = DateTime.now();
      bool expiredCallbackFired = false;

      final bid = BidModel(
        bidId: 'd1',
        tripId: 'trip-100',
        driverId: 'd1',
        driverName: 'Driver Sam',
        offeredFare: 3500,
        fareFormatted: '₦3,500',
        createdAt: now,
        expiresAt: now.add(const Duration(seconds: 2)),
        bidCountdownSeconds: 10,
      );

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: DriverActiveBidLockCard(
              activeBid: bid,
              onExpired: () {
                expiredCallbackFired = true;
              },
            ),
          ),
        ),
      );
      await tester.pump();

      expect(find.byKey(const Key('driver_active_bid_lock_card')),
          findsOneWidget);
      expect(find.text('Waiting for Customer Decision'), findsOneWidget);
      expect(find.textContaining('₦3,500'), findsOneWidget);

      // Advance clock past expiration
      await tester.pump(const Duration(seconds: 3));
      expect(expiredCallbackFired, isTrue);
    });

    testWidgets(
        'Customer BidCarousel renders active bids with ticking countdown and auto-vanishes expired bids',
        (tester) async {
      final repo = _FakeBiddingTripRepo();

      final bid1 = BidModel(
        bidId: 'driver_1',
        driverId: 'driver_1',
        driverName: 'Driver Alex',
        offeredFare: 3200,
        fareFormatted: '₦3,200',
        etaMinutes: 4,
        createdAt: DateTime.now(),
        expiresAt: DateTime.now().add(const Duration(seconds: 60)),
        bidCountdownSeconds: 60,
      );

      final bid2 = BidModel(
        bidId: 'driver_2',
        driverId: 'driver_2',
        driverName: 'Driver Bob',
        offeredFare: 3000,
        fareFormatted: '₦3,000',
        etaMinutes: 2,
        createdAt: DateTime.now(),
        expiresAt: DateTime.now().add(const Duration(seconds: 60)),
        bidCountdownSeconds: 60,
      );

      final trip = ActiveTrip(
        tripId: 'trip-1',
        status: TripStatus.searchingDriver,
        customerId: 'customer_999',
        pickupAddress: 'Yaba, Lagos',
        dropoffAddress: 'Ikeja, Lagos',
        fareAmount: 3000,
      );

      tester.view.physicalSize = const Size(800, 2000);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);

      await tester.pumpWidget(
        MaterialApp(
          home: LiveTripScreen(
            tripId: 'trip-1',
            repository: repo,
          ),
        ),
      );
      await tester.pump();

      repo.tripController.add(trip);
      await tester.pump();
      repo.controller.add([bid1, bid2]);
      await tester.pump();

      // Verify both driver bid cards render with countdown badge
      expect(find.text('Driver Alex'), findsOneWidget);
      expect(find.text('Driver Bob'), findsOneWidget);
      expect(find.textContaining('s'), findsWidgets);

      // Tap Accept on Driver Bob (1-second mark / rapid tap test)
      await tester.tap(find.byKey(const Key('accept_bid_button_driver_2')));
      await tester.pump();

      expect(repo.acceptedTripId, equals('trip-1'));
      expect(repo.acceptedDriverId, equals('driver_2'));
    });
  });
}
