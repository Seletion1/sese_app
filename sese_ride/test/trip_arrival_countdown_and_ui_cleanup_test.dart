import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sese_ride/widgets/osm_map_view.dart';
import 'package:sese_ride/features/driver/presentation/widgets/driver_active_trip_card.dart';
import 'package:sese_ride/features/driver/services/driver_streak_service.dart';
import 'package:sese_ride/features/trips/models/trip_models.dart';
import 'package:sese_ride/features/trips/presentation/live_trip_screen.dart';
import 'package:sese_ride/features/trips/services/trip_service.dart';

class _FakeStreakService implements DriverStreakService {
  @override
  Future<void> advanceTripStatus(String tripId, String nextStatus) async {}

  @override
  Future<void> cancelTrip(String tripId, {String? reason, bool useCashSettlement = false}) async {}

  @override
  Future<void> confirmCashCancellation(String tripId) async {}

  @override
  Future<void> verifyDeliveryPin(String tripId, String pin) async {}

  @override
  Future<void> skipDeliveryPin(String tripId) async {}

  @override
  Future<void> recordDropoffArrival(String tripId) async {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeTripRepo implements TripRepository {
  final controller = StreamController<ActiveTrip?>.broadcast();

  @override
  Stream<ActiveTrip?> tripStream(String tripId) => controller.stream;

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

  Widget wrapWidget(Widget child) {
    return MaterialApp(
      home: MediaQuery(
        data: const MediaQueryData(size: Size(800, 1400)),
        child: Scaffold(
          body: SizedBox(
            height: 1400,
            width: 800,
            child: child,
          ),
        ),
      ),
    );
  }

  group('Driver Screen Countdown, Menu Cleanup & Professional Copywriting', () {
    testWidgets(
        'Pickup arrival renders live countdown badge, removes 3-line menu icon, and hides drop-off rule text',
        (tester) async {
      final now = DateTime.now();
      // Arrived 2 minutes ago -> 8:00 remaining
      final arrivedTrip = ActiveTrip(
        tripId: 'trip_pickup',
        status: TripStatus.driverArrived,
        customerId: 'c1',
        customerName: 'Bamiduro',
        pickupAddress: '34 Olafiloye St, Ikorodu',
        dropoffAddress: '18 Adebayo Mokuolu St, Anthony',
        fareAmount: 5200,
        fareFormatted: '₦5,200',
        paymentMethod: 'cash',
        serviceType: 'ride',
        vehicleCategory: 'motorcycle',
        arrivedAt: now.subtract(const Duration(minutes: 2)),
        cashToCollect: 4200,
        collectAt: 'pickup',
      );

      final fakeStreak = _FakeStreakService();

      await tester.pumpWidget(
        wrapWidget(
          DriverActiveTripCard(
            trip: arrivedTrip,
            streakService: fakeStreak,
            waitThresholdMinutes: 10,
          ),
        ),
      );
      await tester.pumpAndSettle();

      // 1. Verify 3-line menu icon is removed
      expect(find.byIcon(Icons.format_list_bulleted_rounded), findsNothing);

      // 2. Verify countdown badge is rendered
      expect(find.byKey(const Key('driver_arrival_countdown_badge')), findsOneWidget);
      final badgeFinder = find.descendant(
        of: find.byKey(const Key('driver_arrival_countdown_badge')),
        matching: find.byType(Text),
      );
      expect(badgeFinder, findsOneWidget);
      final badgeText = tester.widget<Text>(badgeFinder).data ?? '';
      expect(badgeText, matches(RegExp(r'^\d+:\d{2}$')));

      // 3. Verify static rule text "Drop-off revealed once ride starts" is hidden
      expect(find.text('Drop-off revealed once ride starts'), findsNothing);

      // 4. Verify polite and professional cash prompt
      expect(
        find.text('Kindly collect ₦4,200 cash payment from the sender before departure.'),
        findsOneWidget,
      );
    });

    testWidgets(
        'Pickup arrival transitions to Paid Waiting badge once 10-minute countdown expires',
        (tester) async {
      final now = DateTime.now();
      // Arrived 12 minutes ago (2 minutes into paid waiting)
      final paidWaitingTrip = ActiveTrip(
        tripId: 'trip_paid_wait',
        status: TripStatus.driverArrived,
        customerId: 'c1',
        customerName: 'Bamiduro',
        pickupAddress: '34 Olafiloye St, Ikorodu',
        dropoffAddress: '18 Adebayo Mokuolu St, Anthony',
        fareAmount: 5200,
        fareFormatted: '₦5,200',
        paymentMethod: 'cash',
        serviceType: 'ride',
        vehicleCategory: 'motorcycle',
        arrivedAt: now.subtract(const Duration(minutes: 12)),
        cashToCollect: 4200,
        collectAt: 'pickup',
      );

      final fakeStreak = _FakeStreakService();

      await tester.pumpWidget(
        wrapWidget(
          DriverActiveTripCard(
            trip: paidWaitingTrip,
            streakService: fakeStreak,
            waitThresholdMinutes: 10,
          ),
        ),
      );
      await tester.pumpAndSettle();

      // 1. Countdown badge is replaced by paid waiting badge
      expect(find.byKey(const Key('driver_arrival_countdown_badge')), findsNothing);
      expect(find.byKey(const Key('driver_paid_waiting_badge')), findsOneWidget);
      expect(find.textContaining('Paid Wait +2:'), findsOneWidget);
      expect(find.textContaining('₦40'), findsOneWidget);

      // 2. Header subtitle updates to indicate paid waiting active
      expect(
        find.text('Paid waiting active • Customer billed for wait time'),
        findsOneWidget,
      );
    });

    testWidgets(
        'Drop-off arrival renders live countdown badge when in-progress and dropoffArrivedAt is set',
        (tester) async {
      final now = DateTime.now();
      // Arrived at drop-off 3 minutes ago
      final dropoffTrip = ActiveTrip(
        tripId: 'trip_dropoff',
        status: TripStatus.inProgress,
        customerId: 'c1',
        customerName: 'Bamiduro',
        pickupAddress: '34 Olafiloye St, Ikorodu',
        dropoffAddress: '18 Adebayo Mokuolu St, Anthony',
        fareAmount: 5200,
        fareFormatted: '₦5,200',
        paymentMethod: 'cash',
        serviceType: 'ride',
        vehicleCategory: 'motorcycle',
        dropoffArrivedAt: now.subtract(const Duration(minutes: 3)),
      );

      final fakeStreak = _FakeStreakService();

      await tester.pumpWidget(
        wrapWidget(
          DriverActiveTripCard(
            trip: dropoffTrip,
            streakService: fakeStreak,
            waitThresholdMinutes: 10,
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Header indicates drop-off arrival
      expect(find.text('Arrived at drop-off'), findsOneWidget);
      expect(find.byKey(const Key('driver_arrival_countdown_badge')), findsOneWidget);
      final dropoffBadgeFinder = find.descendant(
        of: find.byKey(const Key('driver_arrival_countdown_badge')),
        matching: find.byType(Text),
      );
      expect(dropoffBadgeFinder, findsOneWidget);
      final dropoffBadgeText = tester.widget<Text>(dropoffBadgeFinder).data ?? '';
      expect(dropoffBadgeText, matches(RegExp(r'^\d+:\d{2}$')));

      // Drop-off address is displayed when in progress
      expect(find.text('18 Adebayo Mokuolu St, Anthony'), findsOneWidget);
    });
  });

  group('Customer Screen Duplicate Plate Removal & Matching Live Countdown', () {
    testWidgets(
        'Customer Live Trip screen shows plate beside price/vehicle, removes duplicate under driver name, and displays live countdown',
        (tester) async {
      tester.view.physicalSize = const Size(800, 2000);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);

      final now = DateTime.now();
      const driver = DriverInfo(
        driverId: 'd1',
        fullName: 'Bamiduro Micheal',
        rating: 5.0,
        phone: '+2348012345678',
        plateNumber: 'AGL874QM',
        vehicleModel: 'Bajaj Boxer',
        isVerifiedDriver: true,
      );

      // Driver arrived 1 minute ago -> ~9:00 remaining
      final trip = ActiveTrip(
        tripId: 't1',
        status: TripStatus.driverArrived,
        customerId: 'c1',
        pickupAddress: '34 Olafiloye St, Ikorodu',
        dropoffAddress: '18 Adebayo Mokuolu St, Anthony',
        fareAmount: 5200,
        fareFormatted: '₦5,200',
        driver: driver,
        arrivedAt: now.subtract(const Duration(minutes: 1)),
      );

      final repo = _FakeTripRepo();

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: LiveTripScreen(
              tripId: 't1',
              repository: repo,
            ),
          ),
        ),
      );
      await tester.pump();
      repo.controller.add(trip);
      await tester.pump();

      // 1. Plate number appears once in the primary vehicle line beside fare
      // driver.vehicleLabel is "AGL874QM · Bajaj Boxer"
      expect(find.text('AGL874QM · Bajaj Boxer'), findsOneWidget);

      // 2. Duplicate plate under the driver name ('  ·  AGL874QM') is removed
      expect(find.text('  ·  AGL874QM'), findsNothing);

      // 3. Customer matching countdown appears under the driver name
      expect(find.byKey(const Key('customer_arrival_countdown_text')), findsOneWidget);
      final customerBadgeText = tester.widget<Text>(find.byKey(const Key('customer_arrival_countdown_text'))).data ?? '';
      expect(customerBadgeText, matches(RegExp(r'^\d+:\d{2}$')));
    });

    testWidgets(
        'Customer Live Trip screen displays paid waiting indicator once 10-minute wait expires',
        (tester) async {
      tester.view.physicalSize = const Size(800, 2000);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);

      final now = DateTime.now();
      const driver = DriverInfo(
        driverId: 'd1',
        fullName: 'Bamiduro Micheal',
        rating: 5.0,
        phone: '+2348012345678',
        plateNumber: 'AGL874QM',
        vehicleModel: 'Bajaj Boxer',
        isVerifiedDriver: true,
      );

      // Driver arrived 13 minutes ago -> paid waiting
      final trip = ActiveTrip(
        tripId: 't1',
        status: TripStatus.driverArrived,
        customerId: 'c1',
        pickupAddress: '34 Olafiloye St, Ikorodu',
        dropoffAddress: '18 Adebayo Mokuolu St, Anthony',
        fareAmount: 5200,
        fareFormatted: '₦5,200',
        driver: driver,
        arrivedAt: now.subtract(const Duration(minutes: 13)),
      );

      final repo = _FakeTripRepo();

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: LiveTripScreen(
              tripId: 't1',
              repository: repo,
            ),
          ),
        ),
      );
      await tester.pump();
      repo.controller.add(trip);
      await tester.pump();

      // 1. Countdown is replaced by paid waiting text
      expect(find.byKey(const Key('customer_arrival_countdown_text')), findsNothing);
      expect(find.byKey(const Key('customer_paid_waiting_text')), findsOneWidget);
      expect(find.textContaining('Paid wait (+3:'), findsOneWidget);

      // 2. Settle Waiting Fee & Cancel button appears at bottom of sheet
      expect(find.byKey(const Key('customer_settle_cancel_button')), findsOneWidget);
    });
  });
}
