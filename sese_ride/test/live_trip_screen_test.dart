import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sese_ride/features/trips/models/bid_models.dart';
import 'package:sese_ride/features/trips/models/trip_models.dart';
import 'package:sese_ride/features/trips/presentation/live_trip_screen.dart';
import 'package:sese_ride/features/trips/services/trip_service.dart';
import 'package:sese_ride/widgets/osm_map_view.dart';

/// Controllable fake: tests push status snapshots through [controller].
class _FakeTripRepository implements TripRepository {
  final StreamController<ActiveTrip?> controller =
      StreamController<ActiveTrip?>.broadcast();
  bool cancelCalled = false;

  @override
  Future<String> createTrip(TripDraft draft) async => 'trip-1';

  @override
  Stream<ActiveTrip?> tripStream(String tripId) => controller.stream;

  @override
  Stream<List<ActiveTrip>> activeTripsStream(String customerId) =>
      Stream.value(const []);

  @override
  Future<void> cancelTrip(String tripId) async {
    cancelCalled = true;
  }

  @override
  Future<void> submitBid(String tripId, double offeredFare, {int? etaMinutes}) async {}

  @override
  Future<void> rejectBid(String tripId, String driverId) async {}

  @override
  Future<void> acceptBid(String tripId, String driverId) async {}

  @override
  Future<void> increaseTripFare(String tripId, double newFare) async {}

  @override
  Stream<List<BidModel>> bidsStream(String tripId) => Stream.value(const []);
}

ActiveTrip _trip(TripStatus status, {int declines = 0}) => ActiveTrip(
      tripId: 'trip-1',
      status: status,
      customerId: 'c1',
      pickupLat: 6.5244,
      pickupLng: 3.3792,
      pickupAddress: 'Ikorodu, Lagos State',
      pickupPhone: '08161561592',
      dropoffLat: 6.6018,
      dropoffLng: 3.3515,
      dropoffAddress: 'Ketu, Kosofe, Lagos State',
      dropoffPhone: '07080286030',
      declineCount: declines,
      driver: status == TripStatus.driverAccepted
          ? const DriverInfo(
              driverId: 'd1',
              fullName: 'Adaeze Okonkwo',
              rating: 4.8,
              phone: '+2348012345678',
              plateNumber: 'ABC-123-ZZ',
              vehicleModel: 'Honda Accord',
            )
          : null,
      driverLat: status == TripStatus.driverAccepted ? 6.55 : null,
      driverLng: status == TripStatus.driverAccepted ? 3.36 : null,
    );

void main() {
  group('LiveTripScreen state machine', () {
    late _FakeTripRepository repo;

    setUp(() {
      OsmMapView.debugTileProviderOverride = BlankTileProvider();
      repo = _FakeTripRepository();
    });

    tearDown(() {
      OsmMapView.debugTileProviderOverride = null;
      repo.controller.close();
    });

    Future<void> pumpLive(WidgetTester tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: LiveTripScreen(tripId: 'trip-1', repository: repo),
        ),
      );
      await tester.pump(); // let the StreamBuilder subscribe
    }

    String statusText(WidgetTester tester) {
      final banner =
          tester.widget<Container>(find.byKey(const Key('live_trip_status')));
      // Banner Row -> Expanded -> Text.
      final row = banner.child as Row;
      final text = (row.children[2] as Expanded).child as Text;
      return text.data ?? '';
    }

    testWidgets('SEARCHING shows animated broadcast banner', (tester) async {
      await pumpLive(tester);
      repo.controller.add(_trip(TripStatus.searchingDriver));
      await tester.pump();

      expect(statusText(tester),
          contains('Searching for nearby available drivers'));
      expect(find.text('Adaeze Okonkwo'), findsNothing);
    });

    testWidgets('repeat search after decline shows recovery message',
        (tester) async {
      await pumpLive(tester);
      repo.controller.add(_trip(TripStatus.searchingDriver, declines: 1));
      await tester.pump();

      expect(statusText(tester), contains("didn't accept"));
      expect(statusText(tester), contains('Looking for available drivers'));
    });

    testWidgets('WAITING shows driver-connected banner', (tester) async {
      await pumpLive(tester);
      repo.controller.add(_trip(TripStatus.waitingForAcceptance));
      await tester.pump();

      expect(statusText(tester), contains('Driver connected'));
      expect(statusText(tester), contains('Waiting for driver to accept'));
    });

    testWidgets('ACCEPTED pops the driver sheet with actions', (tester) async {
      await pumpLive(tester);
      repo.controller.add(_trip(TripStatus.driverAccepted));
      await tester.pump();

      expect(statusText(tester), contains('on the way to pickup'));
      expect(find.text('Adaeze Okonkwo'), findsOneWidget);
      expect(find.text('4.8'), findsOneWidget);
      expect(find.text('ABC-123-ZZ · Honda Accord'), findsOneWidget);
      expect(
        find.widgetWithText(FilledButton, 'Call'),
        findsOneWidget,
      );
      expect(
        find.widgetWithText(OutlinedButton, 'Message'),
        findsOneWidget,
      );
    });

    testWidgets('missing trip shows recoverable empty state', (tester) async {
      await pumpLive(tester);
      repo.controller.add(null);
      await tester.pump();

      expect(find.text('Trip no longer available'), findsOneWidget);
    });

    testWidgets('cancel calls the repository and exits', (tester) async {
      await pumpLive(tester);
      repo.controller.add(_trip(TripStatus.searchingDriver));
      await tester.pump();

      await tester.ensureVisible(
          find.widgetWithText(OutlinedButton, 'Cancel trip'));
      await tester.pump();
      await tester.tap(find.widgetWithText(OutlinedButton, 'Cancel trip'));
      await tester.pump();

      expect(repo.cancelCalled, isTrue);
    });
  });
}
