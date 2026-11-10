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
  Stream<List<ActiveTrip>> userTripHistoryStream(String userId, {bool isDriver = false}) =>
      Stream.value(const []);

  @override
  Future<void> cancelTrip(String tripId, {String? reason, bool useCashSettlement = false}) async {
    cancelCalled = true;
    cancelReason = reason;
  }

  @override
  Future<void> confirmCashCancellation(String tripId, {bool cashCollected = true}) async {}

  String? cancelReason;

  @override
  Future<void> submitBid(String tripId, double offeredFare, {int? etaMinutes}) async {}

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
      tester.view.physicalSize = const Size(800, 2000);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);

      await tester.pumpWidget(
        MaterialApp(
          home: LiveTripScreen(tripId: 'trip-1', repository: repo),
        ),
      );
      await tester.pump(); // let the StreamBuilder subscribe
    }

    String statusText(WidgetTester tester) {
      final searchingFinder = find.byKey(const Key('live_trip_status'));
      if (searchingFinder.evaluate().isNotEmpty) {
        final banner = tester.widget<Container>(searchingFinder);
        final row = banner.child as Row;
        final text = (row.children[2] as Expanded).child as Text;
        return text.data ?? '';
      }
      final etaFinder = find.byKey(const Key('customer_driver_eta_card'));
      if (etaFinder.evaluate().isNotEmpty) {
        final container = tester.widget<Container>(etaFinder);
        final row = container.child as Row;
        final text = (row.children[2] as Expanded).child as Text;
        return text.data ?? '';
      }
      final acceptedFinder =
          find.byKey(const Key('customer_active_status_container'));
      if (acceptedFinder.evaluate().isNotEmpty) {
        final container = tester.widget<Container>(acceptedFinder);
        final row = container.child as Row;
        final text = (row.children[2] as Flexible).child as Text;
        return text.data ?? '';
      }
      return '';
    }

    testWidgets('SEARCHING shows searching status in bottom sheet', (tester) async {
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

      expect(find.textContaining('Adaeze'), findsWidgets);
      expect(find.textContaining('ABC-123-ZZ'), findsWidgets);
      expect(find.textContaining('Honda Accord'), findsWidgets);
      expect(
        find.byKey(const Key('customer_direct_call_icon')),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('customer_chat_icon')),
        findsOneWidget,
      );
    });

    testWidgets('missing trip shows recoverable empty state', (tester) async {
      await pumpLive(tester);
      repo.controller.add(null);
      await tester.pump();

      expect(find.text('Trip no longer available'), findsOneWidget);
    });

    testWidgets('cancel requires a reason, then calls the repository and exits',
        (tester) async {
      await pumpLive(tester);
      repo.controller.add(_trip(TripStatus.searchingDriver));
      await tester.pump();

      await tester.tap(find.text('Cancel trip'));
      await tester.pump();

      // Reason dialog appears; nothing is committed yet.
      expect(find.byKey(const Key('cancel_trip_dialog')), findsOneWidget);
      expect(repo.cancelCalled, isFalse);
      // Confirm is disabled until a reason is picked.
      expect(
        tester
            .widget<FilledButton>(
                find.byKey(const Key('cancel_trip_confirm_button')))
            .onPressed,
        isNull,
      );

      await tester.tap(find.byKey(const Key('cancel_reason_changed_my_mind')));
      await tester.pump();
      await tester.tap(find.byKey(const Key('cancel_trip_confirm_button')));
      await tester.pump();

      expect(repo.cancelCalled, isTrue);
      expect(repo.cancelReason, 'changed_my_mind');
    });

    testWidgets('dismissing the reason dialog cancels nothing', (tester) async {
      await pumpLive(tester);
      repo.controller.add(_trip(TripStatus.searchingDriver));
      await tester.pump();

      await tester.tap(find.text('Cancel trip'));
      await tester.pump();

      expect(find.byKey(const Key('cancel_trip_dialog')), findsOneWidget);
      await tester.tap(find.text('Keep trip'));
      await tester.pump();

      expect(repo.cancelCalled, isFalse);
      expect(find.byKey(const Key('cancel_trip_dialog')), findsNothing);
    });

    testWidgets('driver approach phase displays dynamic ETA card to pickup',
        (tester) async {
      await pumpLive(tester);
      // Trip accepted, driver at (6.55, 3.36), pickup at (6.5244, 3.3792)
      repo.controller.add(_trip(TripStatus.driverAccepted));
      await tester.pump();

      expect(find.byKey(const Key('customer_driver_eta_card')), findsOneWidget);
      expect(statusText(tester), contains('Driver arriving in'));
      expect(statusText(tester), contains('away'));
    });

    testWidgets('in-progress phase updates dynamic ETA card to dropoff',
        (tester) async {
      await pumpLive(tester);
      final inProgressTrip = ActiveTrip(
        tripId: 'trip-1',
        status: TripStatus.inProgress,
        customerId: 'c1',
        pickupLat: 6.5244,
        pickupLng: 3.3792,
        pickupAddress: 'Ikorodu, Lagos State',
        dropoffLat: 6.6018,
        dropoffLng: 3.3515,
        dropoffAddress: 'Ketu, Kosofe, Lagos State',
        driver: const DriverInfo(
          driverId: 'd1',
          fullName: 'Adaeze Okonkwo',
          rating: 4.8,
          phone: '+2348012345678',
          plateNumber: 'ABC-123-ZZ',
          vehicleModel: 'Honda Accord',
        ),
        driverLat: 6.55,
        driverLng: 3.36,
      );

      repo.controller.add(inProgressTrip);
      await tester.pump();

      expect(find.byKey(const Key('customer_driver_eta_card')), findsOneWidget);
      expect(statusText(tester), contains('In progress'));
      expect(statusText(tester), contains('min to drop-off'));
    });

    testWidgets('real-time driver location updates update ETA card dynamically',
        (tester) async {
      await pumpLive(tester);
      final initialTrip = _trip(TripStatus.driverAccepted);
      repo.controller.add(initialTrip);
      await tester.pump();

      final initialText = statusText(tester);
      expect(initialText, contains('Driver arriving in'));

      // Simulate driver moving closer to pickup (6.5250, 3.3795)
      final movedTrip = ActiveTrip(
        tripId: initialTrip.tripId,
        status: initialTrip.status,
        customerId: initialTrip.customerId,
        pickupLat: initialTrip.pickupLat,
        pickupLng: initialTrip.pickupLng,
        pickupAddress: initialTrip.pickupAddress,
        dropoffLat: initialTrip.dropoffLat,
        dropoffLng: initialTrip.dropoffLng,
        dropoffAddress: initialTrip.dropoffAddress,
        driver: initialTrip.driver,
        driverLat: 6.5250,
        driverLng: 3.3795,
      );

      repo.controller.add(movedTrip);
      await tester.pump();

      final updatedText = statusText(tester);
      expect(updatedText, contains('Driver arriving in'));
      expect(updatedText, isNot(equals(initialText)));
    });

    testWidgets('back button when isPushedFromDispatch is true pops minimize_to_home',
        (tester) async {
      OsmMapView.debugTileProviderOverride = BlankTileProvider();
      dynamic navResult;
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (ctx) => ElevatedButton(
              onPressed: () async {
                navResult = await Navigator.of(ctx).push(
                  MaterialPageRoute(
                    builder: (_) => LiveTripScreen(
                      tripId: 'trip-1',
                      repository: repo,
                      isPushedFromDispatch: true,
                    ),
                  ),
                );
              },
              child: const Text('Push'),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Push'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      repo.controller.add(_trip(TripStatus.searchingDriver));
      await tester.pump();

      // Tap back arrow in AppBar
      await tester.tap(find.byIcon(Icons.arrow_back));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));

      expect(navResult, equals('minimize_to_home'));
    });

    testWidgets('confirming cancel when isPushedFromDispatch is true pops cancelled',
        (tester) async {
      OsmMapView.debugTileProviderOverride = BlankTileProvider();
      dynamic navResult;
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (ctx) => ElevatedButton(
              onPressed: () async {
                navResult = await Navigator.of(ctx).push(
                  MaterialPageRoute(
                    builder: (_) => LiveTripScreen(
                      tripId: 'trip-1',
                      repository: repo,
                      isPushedFromDispatch: true,
                    ),
                  ),
                );
              },
              child: const Text('Push'),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Push'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      repo.controller.add(_trip(TripStatus.searchingDriver));
      await tester.pump();

      await tester.tap(find.text('Cancel trip'));
      await tester.pump();

      await tester.tap(find.byKey(const Key('cancel_reason_changed_my_mind')));
      await tester.pump();
      await tester.tap(find.byKey(const Key('cancel_trip_confirm_button')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      // Dismiss post-cancel feedback sheet if shown
      final skipFinder = find.text('Skip');
      if (skipFinder.evaluate().isNotEmpty) {
        await tester.tap(skipFinder);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));
      }

      expect(navResult, equals('cancelled'));
    });
  });
}
