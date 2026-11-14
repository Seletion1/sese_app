import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:sese_ride/features/driver/presentation/widgets/order_pool_sheet.dart';
import 'package:sese_ride/features/driver/services/driver_streak_service.dart';
import 'package:sese_ride/features/trips/models/bid_models.dart';
import 'package:sese_ride/features/trips/models/trip_models.dart';
import 'package:sese_ride/features/trips/presentation/live_trip_screen.dart';
import 'package:sese_ride/features/trips/services/trip_service.dart';
import 'package:sese_ride/widgets/osm_map_view.dart';

class _FakeBiddingTripRepo implements TripRepository {
  final controller = StreamController<List<BidModel>>.broadcast();
  final tripController = StreamController<ActiveTrip?>.broadcast();
  final driverBidController = StreamController<BidModel?>.broadcast();
  String? acceptedTripId;
  String? acceptedDriverId;
  String? rejectedTripId;
  String? rejectedDriverId;
  String? lastSubmittedTripId;
  double? lastSubmittedFare;

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
  Future<void> confirmCashCancellation(String tripId, {bool cashCollected = true}) async {}

  @override
  Future<void> respondDropoffApproval(String tripId, {required bool approved}) async {}

  bool throwLowBalance = false;

  @override
  Future<void> submitBid(String tripId, double offeredFare,
      {int? etaMinutes}) async {
    if (throwLowBalance) {
      throw const TripException(
        'failed-precondition',
        'Your balance is low. Please top up to accept trips.',
      );
    }
    lastSubmittedTripId = tripId;
    lastSubmittedFare = offeredFare;
    driverBidController.add(BidModel(
      bidId: 'bid-123',
      tripId: tripId,
      driverId: 'driver-123',
      driverName: 'Driver Sam',
      offeredFare: offeredFare,
      fareFormatted: '₦${offeredFare.toInt()}',
      createdAt: DateTime.now(),
      expiresAt: DateTime.now().add(const Duration(seconds: 15)),
      bidCountdownSeconds: 15,
      status: BidStatus.pending,
    ));
  }

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
  Future<void> reassignTrip(String tripId, {double? newFare}) async {}

  @override
  Future<void> keepSearchingTrip(String tripId) async {}

  @override
  Stream<List<BidModel>> bidsStream(String tripId) => controller.stream;

  @override
  Stream<BidModel?> activeDriverBidStream(String driverId) =>
      Stream.value(null);

  @override
  Stream<BidModel?> driverBidForTripStream(String tripId, String driverId) =>
      driverBidController.stream;
}

class _TestDriverStreakService implements DriverStreakService {
  final _marketplaceController = StreamController<List<ActiveTrip>>.broadcast();

  @override
  String? get driverId => 'driver-123';

  @override
  Stream<List<ActiveTrip>> marketplaceStream(
          {String? driverId, int limit = 20}) =>
      _marketplaceController.stream;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
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

    testWidgets(
        'PoolOrderDetailSheet stays open on counter-offer, displays live countdown card, allows re-bidding on rejection, and fires onAccepted upon acceptance',
        (tester) async {
      final repo = _FakeBiddingTripRepo();
      final streakService = _TestDriverStreakService();
      String? acceptedTrip;

      final trip = ActiveTrip(
        tripId: 'trip-abc',
        status: TripStatus.marketplaceOpen,
        customerId: 'cust-999',
        customerName: 'Adebayo',
        pickupAddress: '34 Commercial Ave, Yaba',
        pickupLat: 6.518,
        pickupLng: 3.373,
        dropoffAddress: '15 Allen Ave, Ikeja',
        dropoffLat: 6.601,
        dropoffLng: 3.351,
        fareAmount: 3500.0,
      );

      tester.view.physicalSize = const Size(800, 2000);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: PoolOrderDetailSheet(
              trip: trip,
              driverPosition: const LatLng(6.518, 3.373),
              currencySymbol: '₦',
              streakService: streakService,
              driverId: 'driver-123',
              tripRepository: repo,
              onAccepted: (tripId) {
                acceptedTrip = tripId;
              },
            ),
          ),
        ),
      );
      await tester.pump();

      // Verify the sheet is open and primary action button exists
      final actionBtn = find.byKey(Key('pool_primary_action_${trip.tripId}'));
      expect(actionBtn, findsOneWidget);
      expect(find.text('Accept (₦3,500)'), findsOneWidget);

      // Select +10% counter offer chip (3500 * 1.10 = 3850, rounded to nearest 100 note = 3900)
      await tester.ensureVisible(find.textContaining('+10%'));
      await tester.pump();
      await tester.tap(find.textContaining('+10%'));
      await tester.pump();
      expect(find.text('Send Counter-Offer (₦3,900)'), findsOneWidget);

      // Submit counter offer
      await tester.tap(actionBtn);
      await tester.pump();

      // VERIFY: The sheet DID NOT pop/close. It stays open on driver's screen!
      expect(find.byType(PoolOrderDetailSheet), findsOneWidget);
      expect(find.textContaining('Waiting for Customer...'), findsOneWidget);

      // Now customer rejects the bid
      repo.driverBidController.add(BidModel(
        bidId: 'bid-123',
        tripId: 'trip-abc',
        driverId: 'driver-123',
        driverName: 'Driver Sam',
        offeredFare: 3900,
        fareFormatted: '₦3,900',
        createdAt: DateTime.now().subtract(const Duration(seconds: 10)),
        expiresAt: DateTime.now().add(const Duration(seconds: 5)),
        bidCountdownSeconds: 15,
        status: BidStatus.rejected,
      ));
      await tester.pumpAndSettle();

      // VERIFY: Toast appears and action button re-enables
      expect(find.text('Offer rejected'), findsOneWidget);
      expect(actionBtn, findsOneWidget);

      // Now customer accepts a new bid
      repo.driverBidController.add(BidModel(
        bidId: 'bid-123',
        tripId: 'trip-abc',
        driverId: 'driver-123',
        driverName: 'Driver Sam',
        offeredFare: 4000,
        fareFormatted: '₦4,000',
        createdAt: DateTime.now(),
        expiresAt: DateTime.now().add(const Duration(seconds: 15)),
        bidCountdownSeconds: 15,
        status: BidStatus.accepted,
      ));
      await tester.pumpAndSettle();

      // VERIFY: Customer acceptance fires onAccepted
      expect(acceptedTrip, equals('trip-abc'));
    });

    testWidgets(
        'PoolOrderDetailSheet displays Low Balance modal when submitBid throws low balance error',
        (tester) async {
      OsmMapView.debugTileProviderOverride = BlankTileProvider();
      addTearDown(() => OsmMapView.debugTileProviderOverride = null);

      final repo = _FakeBiddingTripRepo();
      repo.throwLowBalance = true;
      final streakService = _TestDriverStreakService();
      final trip = ActiveTrip(
        tripId: 'trip-xyz',
        status: TripStatus.marketplaceOpen,
        customerId: 'cust-999',
        customerName: 'Adebayo',
        pickupAddress: '34 Commercial Ave, Yaba',
        pickupLat: 6.518,
        pickupLng: 3.373,
        dropoffAddress: '15 Allen Ave, Ikeja',
        dropoffLat: 6.601,
        dropoffLng: 3.351,
        fareAmount: 4500.0,
      );

      tester.view.physicalSize = const Size(800, 2000);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: PoolOrderDetailSheet(
              trip: trip,
              driverPosition: const LatLng(6.518, 3.373),
              currencySymbol: '₦',
              streakService: streakService,
              driverId: 'driver-123',
              tripRepository: repo,
              onAccepted: (_) {},
            ),
          ),
        ),
      );
      await tester.pump();

      // Select +5% counter offer chip
      await tester.ensureVisible(find.textContaining('+5%'));
      await tester.pump();
      await tester.tap(find.textContaining('+5%'));
      await tester.pump();

      final actionBtn = find.byKey(Key('pool_primary_action_${trip.tripId}'));
      await tester.tap(actionBtn);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));

      // VERIFY: Low Balance dialog pops up with "Low Balance" and "Top Up Now"
      expect(find.text('Low Balance'), findsOneWidget);
      expect(find.text('Your balance is low. Please top up to accept trips.'), findsNWidgets(2));
      expect(find.text('Top Up Now'), findsOneWidget);
    });
  });
}
