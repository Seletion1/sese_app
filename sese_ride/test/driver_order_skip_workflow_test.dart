import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:sese_ride/features/driver/presentation/widgets/incoming_offer_sheet.dart';
import 'package:sese_ride/features/driver/services/driver_streak_service.dart';
import 'package:sese_ride/features/trips/models/trip_models.dart';
import 'package:sese_ride/widgets/osm_map_view.dart';

class _FakeStreakService implements DriverStreakService {
  final List<Map<String, dynamic>> declineCalls = [];
  Completer<void>? declineCompleter;
  bool shouldThrow = false;

  @override
  Future<void> declineTrip(String tripId, {String action = 'rejected'}) async {
    declineCalls.add({'tripId': tripId, 'action': action});
    if (declineCompleter != null) {
      await declineCompleter!.future;
    }
    if (shouldThrow) {
      throw const DriverStreakException('network-error', 'Network unavailable');
    }
  }

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

  Widget wrapWithNavigator(Widget child) {
    return MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (context) {
            return ElevatedButton(
              onPressed: () {
                Navigator.of(context).push(
                  MaterialPageRoute(builder: (_) => child),
                );
              },
              child: const Text('Open Sheet'),
            );
          },
        ),
      ),
    );
  }

  group('Driver Order Skip Workflow Tests', () {
    testWidgets('Manual Skip pops IncomingOfferSheet instantly without waiting for declineTrip network call', (tester) async {
      final fakeStreak = _FakeStreakService();
      // Simulate slow network response for declineTrip
      fakeStreak.declineCompleter = Completer<void>();

      final trip = ActiveTrip(
        tripId: 'trip_skip_1',
        status: TripStatus.waitingForAcceptance,
        customerId: 'c1',
        customerName: 'Customer One',
        pickupAddress: '10 Allen Ave, Ikeja',
        dropoffAddress: '25 Victoria Island, Lagos',
        pickupLat: 6.6018,
        pickupLng: 3.3515,
        dropoffLat: 6.4281,
        dropoffLng: 3.4219,
        fareAmount: 4500,
        fareFormatted: '₦4,500',
        paymentMethod: 'cash',
        serviceType: 'ride',
        vehicleCategory: 'car',
      );

      await tester.pumpWidget(
        wrapWithNavigator(
          IncomingOfferSheet(
            trip: trip,
            streakTag: 'Streak Active',
            currencySymbol: '₦',
            driverPosition: const LatLng(6.6000, 3.3500),
            streakService: fakeStreak,
            driverId: 'd1',
          ),
        ),
      );

      // Open sheet via Navigator
      await tester.tap(find.text('Open Sheet'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      // Verify IncomingOfferSheet is displayed
      expect(find.byType(IncomingOfferSheet), findsOneWidget);
      expect(find.byKey(const Key('skip_offer_button')), findsOneWidget);

      // Tap 'Skip offer' button
      await tester.tap(find.byKey(const Key('skip_offer_button')));
      await tester.pumpAndSettle(); // Settle route pop transition

      // Verify the sheet is instantly popped from the route stack (0ms response)
      expect(find.byType(IncomingOfferSheet), findsNothing);

      // Verify declineTrip was dispatched in background with action: 'skipped'
      expect(fakeStreak.declineCalls.length, equals(1));
      expect(fakeStreak.declineCalls.first['tripId'], equals('trip_skip_1'));
      expect(fakeStreak.declineCalls.first['action'], equals('skipped'));

      // Unblock the slow network completer
      fakeStreak.declineCompleter!.complete();
      await tester.pump();
    });

    testWidgets('Network failure during skip does not resurrect or freeze UI', (tester) async {
      final fakeStreak = _FakeStreakService();
      fakeStreak.shouldThrow = true; // Simulate network error on declineTrip

      final trip = ActiveTrip(
        tripId: 'trip_skip_net_err',
        status: TripStatus.waitingForAcceptance,
        customerId: 'c2',
        customerName: 'Customer Two',
        pickupAddress: 'Broad St, Lagos Island',
        dropoffAddress: 'Marina, Lagos Island',
        pickupLat: 6.4500,
        pickupLng: 3.3900,
        dropoffLat: 6.4550,
        dropoffLng: 3.3950,
        fareAmount: 2000,
        fareFormatted: '₦2,000',
        paymentMethod: 'cash',
        serviceType: 'ride',
        vehicleCategory: 'car',
      );

      await tester.pumpWidget(
        wrapWithNavigator(
          IncomingOfferSheet(
            trip: trip,
            streakTag: 'Streak Active',
            currencySymbol: '₦',
            driverPosition: const LatLng(6.4490, 3.3890),
            streakService: fakeStreak,
            driverId: 'd1',
          ),
        ),
      );

      await tester.tap(find.text('Open Sheet'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      expect(find.byType(IncomingOfferSheet), findsOneWidget);

      // Tap 'Skip offer' button
      await tester.tap(find.byKey(const Key('skip_offer_button')));
      await tester.pumpAndSettle();

      // UI pops cleanly despite network error in background
      expect(find.byType(IncomingOfferSheet), findsNothing);
      expect(fakeStreak.declineCalls.length, equals(1));
    });

    testWidgets('Automatic offer countdown expiration pops UI immediately and fires skip in background', (tester) async {
      final fakeStreak = _FakeStreakService();

      final trip = ActiveTrip(
        tripId: 'trip_expire_1',
        status: TripStatus.waitingForAcceptance,
        customerId: 'c3',
        customerName: 'Customer Three',
        pickupAddress: 'Ikorodu Road, Yaba',
        dropoffAddress: 'Maryland, Lagos',
        pickupLat: 6.5100,
        pickupLng: 3.3700,
        dropoffLat: 6.5700,
        dropoffLng: 3.3600,
        fareAmount: 3000,
        fareFormatted: '₦3,000',
        paymentMethod: 'cash',
        serviceType: 'ride',
        vehicleCategory: 'car',
      );

      await tester.pumpWidget(
        wrapWithNavigator(
          IncomingOfferSheet(
            trip: trip,
            streakTag: 'Streak Active',
            currencySymbol: '₦',
            driverPosition: const LatLng(6.5000, 3.3700),
            streakService: fakeStreak,
            driverId: 'd1',
          ),
        ),
      );

      await tester.tap(find.text('Open Sheet'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      expect(find.byType(IncomingOfferSheet), findsOneWidget);

      // Fast forward countdown timer past offer window (20s)
      await tester.pump(const Duration(seconds: 21));
      await tester.pumpAndSettle(); // Complete pop animation

      // Verify IncomingOfferSheet is popped automatically
      expect(find.byType(IncomingOfferSheet), findsNothing);

      // Verify declineTrip was invoked with action: 'skipped'
      expect(fakeStreak.declineCalls.length, equals(1));
      expect(fakeStreak.declineCalls.first['tripId'], equals('trip_expire_1'));
      expect(fakeStreak.declineCalls.first['action'], equals('skipped'));
    });
  });
}
