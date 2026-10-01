import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:sese_ride/features/customer/services/location_service.dart';
import 'package:sese_ride/features/driver/presentation/widgets/order_feed.dart';
import 'package:sese_ride/features/driver/services/driver_streak_service.dart';
import 'package:sese_ride/features/trips/models/trip_models.dart';

/// Controllable dispatch backend: canned Tier 1 / Tier 2 / Tier 3 snapshots.
class _FakeDispatchService extends DriverStreakService {
  final _ping = StreamController<ActiveTrip?>.broadcast();
  final _tier2 = StreamController<List<ActiveTrip>>.broadcast();
  final _market = StreamController<List<ActiveTrip>>.broadcast();

  @override
  Stream<ActiveTrip?> pingStream(String driverId) => _ping.stream;

  @override
  Stream<List<ActiveTrip>> tier2PingStream(String driverId) => _tier2.stream;

  @override
  Stream<List<ActiveTrip>> marketplaceStream({int limit = 20}) =>
      _market.stream;

  Future<void> close() async {
    await _ping.close();
    await _tier2.close();
    await _market.close();
  }
}

ActiveTrip _trip(String id, {TripStatus status = TripStatus.marketplaceOpen}) {
  return ActiveTrip(
    tripId: id,
    status: status,
    customerId: 'cust-$id',
    serviceType: 'ride',
    pickupLat: 6.5244,
    pickupLng: 3.3792,
    pickupAddress: 'Pickup $id',
    dropoffLat: 6.6018,
    dropoffLng: 3.3515,
    dropoffAddress: 'Dropoff $id',
    tierIds: const ['comfort'],
    distanceKm: 10.8,
    durationMins: 25,
    fareAmount: 2500,
  );
}

Future<void> _pumpFeed(WidgetTester tester, _FakeDispatchService svc) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: Column(
          children: [
            const SizedBox(height: 52), // status pill placeholder
            Expanded(
              child: OrderFeed(
                driverId: 'driver-1',
                driverPosition: const LatLng(6.5244, 3.3792),
                currencySymbol: '₦',
                streakTag: 'Streak Rate: 12.5% Fee',
                streakService: svc,
                isOnline: true,
              ),
            ),
            const SizedBox(height: 60), // streak banner placeholder
          ],
        ),
      ),
    ),
  );
}

void main() {
  setUp(() {
    LocationService.customRouteProvider = (pickup, dropoff) async => [
      pickup,
      dropoff,
    ];
  });

  tearDown(() {
    LocationService.resetTestSeams();
  });

  group('OrderFeed cascading dispatch', () {
    testWidgets('merges Tier 1/2/3 with exclusive offers first', (
      tester,
    ) async {
      // Tall viewport so every card lays out (ListView builds lazily).
      tester.view.physicalSize = const Size(800, 3000);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      final svc = _FakeDispatchService();
      addTearDown(svc.close);
      await _pumpFeed(tester, svc);

      svc._ping.add(_trip('t1', status: TripStatus.waitingForAcceptance));
      svc._tier2.add([_trip('t2', status: TripStatus.waitingForAcceptance)]);
      svc._market.add([_trip('m1'), _trip('m2')]);
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('order_card_t1')), findsOneWidget);
      expect(find.byKey(const Key('order_card_t2')), findsOneWidget);
      expect(find.byKey(const Key('order_card_m1')), findsOneWidget);
      expect(find.byKey(const Key('order_card_m2')), findsOneWidget);

      // Exclusive Tier 1 offer renders above the marketplace broadcast.
      final t1y = tester.getTopLeft(find.byKey(const Key('order_card_t1'))).dy;
      final m1y = tester.getTopLeft(find.byKey(const Key('order_card_m1'))).dy;
      expect(t1y, lessThan(m1y));
    });

    testWidgets('order card shows fare, per-km, A/B addresses and Accept', (
      tester,
    ) async {
      final svc = _FakeDispatchService();
      addTearDown(svc.close);
      await _pumpFeed(tester, svc);

      svc._ping.add(null);
      svc._tier2.add(const []);
      svc._market.add([_trip('m9')]);
      await tester.pumpAndSettle();

      expect(find.text('₦2,500'), findsOneWidget);
      expect(find.textContaining('/km'), findsOneWidget);
      expect(find.text('Pickup m9'), findsOneWidget);
      expect(find.text('Dropoff m9'), findsOneWidget);
      expect(find.text('Accept'), findsOneWidget);
    });

    testWidgets('floating pill appears when new offers arrive while scrolled', (
      tester,
    ) async {
      final svc = _FakeDispatchService();
      addTearDown(svc.close);
      await _pumpFeed(tester, svc);

      final initial = List.generate(10, (i) => _trip('m$i'));
      svc._ping.add(null);
      svc._tier2.add(const []);
      svc._market.add(initial);
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('show_new_requests_pill')), findsNothing);

      // Scroll to the bottom, then land one more offer.
      final state = tester.state<OrderFeedState>(find.byType(OrderFeed));
      state.scrollController.jumpTo(
        state.scrollController.position.maxScrollExtent,
      );
      await tester.pumpAndSettle();

      svc._market.add([...initial, _trip('m10')]);
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('show_new_requests_pill')), findsOneWidget);
      expect(find.text('Show new request'), findsOneWidget);

      // Tapping the pill jumps back to the top and dismisses it.
      await tester.tap(find.byKey(const Key('show_new_requests_pill')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('show_new_requests_pill')), findsNothing);
    });

    testWidgets('empty feed shows radar searching state while online', (
      tester,
    ) async {
      final svc = _FakeDispatchService();
      addTearDown(svc.close);
      await _pumpFeed(tester, svc);

      svc._ping.add(null);
      svc._tier2.add(const []);
      svc._market.add(const []);
      // No pumpAndSettle: the radar ripple repeats forever by design.
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      expect(find.byKey(const Key('marketplace_empty_state')), findsOneWidget);
      expect(find.text('Searching for available orders...'), findsOneWidget);
      expect(find.byIcon(Icons.radar), findsOneWidget);
    });

    testWidgets('first pooled order replaces the empty state', (tester) async {
      final svc = _FakeDispatchService();
      addTearDown(svc.close);
      await _pumpFeed(tester, svc);

      svc._ping.add(null);
      svc._tier2.add(const []);
      svc._market.add(const []);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.byKey(const Key('marketplace_empty_state')), findsOneWidget);

      svc._market.add([_trip('m1')]);
      // Past the 350ms AnimatedSwitcher cross-fade (no settle: radar ticks).
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));

      expect(find.byKey(const Key('marketplace_empty_state')), findsNothing);
      expect(find.byKey(const Key('order_card_m1')), findsOneWidget);
    });
  });
}
