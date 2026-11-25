import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sese_ride/features/trips/models/bid_models.dart';
import 'package:sese_ride/features/trips/models/trip_models.dart';
import 'package:sese_ride/features/trips/presentation/customer_bid_overlay.dart';
import 'package:sese_ride/features/trips/presentation/live_trip_screen.dart';
import 'package:sese_ride/features/trips/services/trip_service.dart';
import 'package:sese_ride/widgets/osm_map_view.dart';

class _FakeOverlayTripRepo implements TripRepository {
  final activeTripsController = StreamController<List<ActiveTrip>>.broadcast();
  final bidsController = StreamController<List<BidModel>>.broadcast();

  String? acceptedTripId;
  String? acceptedDriverId;
  String? rejectedTripId;
  String? rejectedDriverId;

  @override
  Future<String> createTrip(TripDraft draft) async => 'trip-101';

  @override
  Stream<ActiveTrip?> tripStream(String tripId) => Stream.value(
        ActiveTrip(
          tripId: tripId,
          customerId: 'cust-101',
          status: TripStatus.bidding,
          fareAmount: 5000,
          pickupAddress: 'Pickup Point',
          dropoffAddress: 'Dropoff Point',
        ),
      );

  @override
  Stream<List<ActiveTrip>> activeTripsStream(String customerId) =>
      activeTripsController.stream;

  @override
  Stream<List<ActiveTrip>> userTripHistoryStream(String userId,
          {bool isDriver = false}) =>
      Stream.value(const []);

  @override
  Future<void> cancelTrip(String tripId,
      {String? reason, bool useCashSettlement = false}) async {}

  @override
  Future<void> confirmCashCancellation(String tripId,
      {bool cashCollected = true}) async {}

  @override
  Future<void> respondDropoffApproval(String tripId,
      {required bool approved, bool timeout = false}) async {}

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
  Future<void> reassignTrip(String tripId, {double? newFare}) async {}

  @override
  Future<void> keepSearchingTrip(String tripId) async {}

  @override
  Stream<List<BidModel>> bidsStream(String tripId) => bidsController.stream;

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

  testWidgets(
      'CustomerBidOverlay pops up in front of screen on incoming driver bid, renders details, and handles Accept/Reject',
      (tester) async {
    final repo = _FakeOverlayTripRepo();

    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(
          useMaterial3: false,
          splashFactory: InkRipple.splashFactory,
        ),
        home: Scaffold(
          body: CustomerBidOverlay(
            userId: 'cust-101',
            tripRepository: repo,
            child: const Center(child: Text('Underlying Screen Content')),
          ),
        ),
      ),
    );

    await tester.pump();
    expect(find.text('Underlying Screen Content'), findsOneWidget);
    expect(find.text('NEW DRIVER OFFER'), findsNothing);

    // Emit active searching/bidding trip for customer
    repo.activeTripsController.add([
      const ActiveTrip(
        tripId: 'trip-101',
        customerId: 'cust-101',
        status: TripStatus.bidding,
        fareAmount: 5100,
        pickupAddress: '34 Olafiloye St',
        dropoffAddress: '18 Adebayo Mokuolu St',
      ),
    ]);
    await tester.pump();

    // Emit pending driver bid
    final bid = BidModel(
      bidId: 'driver-777',
      tripId: 'trip-101',
      driverId: 'driver-777',
      driverName: 'Bamiduro Micheal',
      photoUrl: '',
      rating: 5.0,
      offeredFare: 5400,
      fareFormatted: '₦5,400',
      etaMinutes: 1,
      status: BidStatus.pending,
      vehicleModel: 'Bajaj Pulsar 220',
      plateNumber: 'AGL874QM',
      isVerifiedDriver: true,
      expiresAt: DateTime.now().add(const Duration(seconds: 15)),
      bidCountdownSeconds: 15,
    );

    repo.bidsController.add([bid]);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    // Compact floating card appears over the underlying content
    expect(find.text('Bamiduro Micheal'), findsOneWidget);
    expect(find.text('₦5,400'), findsOneWidget);
    expect(find.text('Accept'), findsOneWidget);
    expect(find.text('Reject'), findsOneWidget);

    // Tap Accept button
    await tester.tap(find.text('Accept'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    expect(repo.acceptedTripId, equals('trip-101'));
    expect(repo.acceptedDriverId, equals('driver-777'));
    expect(find.byType(LiveTripScreen), findsOneWidget);
  });

  testWidgets('CustomerBidOverlay handles Reject action correctly',
      (tester) async {
    final repo = _FakeOverlayTripRepo();

    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(
          useMaterial3: false,
          splashFactory: InkRipple.splashFactory,
        ),
        home: Scaffold(
          body: CustomerBidOverlay(
            userId: 'cust-101',
            tripRepository: repo,
            child: const Center(child: Text('Underlying Screen Content')),
          ),
        ),
      ),
    );

    await tester.pump();

    repo.activeTripsController.add([
      const ActiveTrip(
        tripId: 'trip-101',
        customerId: 'cust-101',
        status: TripStatus.bidding,
        fareAmount: 5100,
      ),
    ]);
    await tester.pump();

    final bid = BidModel(
      bidId: 'driver-777',
      tripId: 'trip-101',
      driverId: 'driver-777',
      driverName: 'Bamiduro Micheal',
      offeredFare: 5400,
      status: BidStatus.pending,
      expiresAt: DateTime.now().add(const Duration(seconds: 15)),
    );

    repo.bidsController.add([bid]);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.text('Bamiduro Micheal'), findsOneWidget);

    // Tap Reject button
    await tester.tap(find.text('Reject'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    expect(repo.rejectedTripId, equals('trip-101'));
    expect(repo.rejectedDriverId, equals('driver-777'));
  });

  testWidgets(
      'CustomerBidOverlay constrains multiple simultaneous bids to a scrollable 45%-height ListView and clears remaining bids on Accept',
      (tester) async {
    final repo = _FakeOverlayTripRepo();

    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(
          useMaterial3: false,
          splashFactory: InkRipple.splashFactory,
        ),
        home: Scaffold(
          body: CustomerBidOverlay(
            userId: 'cust-101',
            tripRepository: repo,
            child: const Center(child: Text('Underlying Screen Content')),
          ),
        ),
      ),
    );
    await tester.pump();

    repo.activeTripsController.add([
      const ActiveTrip(
        tripId: 'trip-101',
        customerId: 'cust-101',
        status: TripStatus.bidding,
        fareAmount: 3300,
        pickupAddress: '10 Olafiranye St',
        dropoffAddress: '15 Ikorodu Rd',
      ),
    ]);
    await tester.pump();

    final now = DateTime.now();
    final bids = [
      for (int i = 1; i <= 5; i++)
        BidModel(
          bidId: 'driver-$i',
          tripId: 'trip-101',
          driverId: 'driver-$i',
          driverName: 'Driver $i',
          offeredFare: 3400 + (i * 100.0),
          fareFormatted: '₦${3400 + (i * 100)}',
          status: BidStatus.pending,
          expiresAt: now.add(Duration(seconds: 20 + i)),
          bidCountdownSeconds: 30,
        ),
    ];

    repo.bidsController.add(bids);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    // Scrollable ListView is present and constrained to 45% of screen height
    expect(find.byType(ListView), findsOneWidget);
    final listRenderBox = tester.renderObject<RenderBox>(find.byType(ListView));
    final screenHeight = tester.view.physicalSize.height / tester.view.devicePixelRatio;
    expect(listRenderBox.size.height, lessThanOrEqualTo(screenHeight * 0.45 + 1.0));

    // First bid is visible; tapping Accept clears all remaining bids immediately
    expect(find.text('Driver 1'), findsOneWidget);
    await tester.tap(find.text('Accept').first);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    expect(repo.acceptedTripId, equals('trip-101'));
    expect(repo.acceptedDriverId, equals('driver-1'));
    // All remaining bid cards for trip-101 were cleared
    expect(find.text('Driver 2'), findsNothing);
    expect(find.text('Driver 5'), findsNothing);
  });

  testWidgets(
      'LiveTripScreen bottom sheet does not render duplicate inline driver bid cards',
      (tester) async {
    final repo = _FakeOverlayTripRepo();

    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(
          useMaterial3: false,
          splashFactory: InkRipple.splashFactory,
        ),
        home: LiveTripScreen(
          tripId: 'trip-101',
          repository: repo,
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    // Emit a pending bid on the repo
    repo.bidsController.add([
      BidModel(
        bidId: 'driver-777',
        tripId: 'trip-101',
        driverId: 'driver-777',
        driverName: 'Bamiduro Micheal (Seletion)',
        offeredFare: 3500,
        fareFormatted: '₦3500',
        status: BidStatus.pending,
        expiresAt: DateTime.now().add(const Duration(seconds: 30)),
      ),
    ]);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    // No inline bid header or duplicate bid card inside the LiveTripScreen sheet
    expect(find.textContaining('offered a fare'), findsNothing);
    expect(find.text('Bamiduro Micheal (Seletion)'), findsNothing);
  });
}
