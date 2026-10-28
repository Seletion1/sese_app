import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sese_ride/features/driver/presentation/widgets/driver_active_trip_card.dart';
import 'package:sese_ride/features/driver/services/driver_streak_service.dart';
import 'package:sese_ride/features/trips/models/trip_models.dart';

class _FakeStreakService implements DriverStreakService {
  String? lastAdvancedTripId;
  String? lastAdvancedNextStatus;

  @override
  Future<void> advanceTripStatus(String tripId, String nextStatus) async {
    lastAdvancedTripId = tripId;
    lastAdvancedNextStatus = nextStatus;
  }

  @override
  Future<void> cancelTrip(String tripId, {String? reason, bool useCashSettlement = false}) async {}

  @override
  Future<void> verifyDeliveryPin(String tripId, String pin) async {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  final testTrip = ActiveTrip(
    tripId: 'trip_123',
    status: TripStatus.inProgress,
    customerId: 'cust_456',
    customerName: 'Bamiduro Micheal',
    customerPhone: '+2348012345678',
    pickupAddress: '32 Olafiranye St, Ikorodu',
    dropoffAddress: '5 Ikosi Road, Ketu',
    fareAmount: 4126,
    fareFormatted: '₦4,126',
    paymentMethod: 'wallet',
    serviceType: 'ride',
    vehicleCategory: 'motorcycle',
  );

  Widget makeTestableWidget(Widget child) {
    return MaterialApp(
      home: Scaffold(
        body: child,
      ),
    );
  }

  testWidgets('DriverActiveTripCard shows first name only, 3 action icons, and price-only subtitle',
      (tester) async {
    final fakeStreak = _FakeStreakService();

    await tester.pumpWidget(
      makeTestableWidget(
        DriverActiveTripCard(
          trip: testTrip,
          streakService: fakeStreak,
        ),
      ),
    );
    await tester.pumpAndSettle();

    // 1. Verify First Name only ("Bamiduro", not "Bamiduro Micheal")
    expect(find.text('Bamiduro'), findsOneWidget);
    expect(find.text('Bamiduro Micheal'), findsNothing);

    // 2. Verify "In Progress" status badge is removed from header
    expect(find.text('In Progress'), findsNothing);

    // 3. Verify vehicle category ("Motorcycle • ") is completely removed from subtitle
    expect(find.textContaining('Motorcycle'), findsNothing);
    expect(find.textContaining('₦4,126'), findsOneWidget);

    // 4. Verify 3 inline action icons are present
    expect(find.byKey(const Key('driver_direct_call_icon')), findsOneWidget);
    expect(find.byKey(const Key('driver_inapp_call_icon')), findsOneWidget);
    expect(find.byKey(const Key('driver_chat_icon')), findsOneWidget);

    // 5. Verify Slide-to-Action button is rendered with stage label
    expect(find.byKey(const Key('driver_slide_action_button')), findsOneWidget);
    expect(find.text('Slide to Complete Trip'), findsOneWidget);
  });

  testWidgets('Call Contact Sheet shows clean options with no bulky header text',
      (tester) async {
    final fakeStreak = _FakeStreakService();

    await tester.pumpWidget(
      makeTestableWidget(
        DriverActiveTripCard(
          trip: testTrip,
          streakService: fakeStreak,
        ),
      ),
    );
    await tester.pumpAndSettle();

    // Tap In-App Call icon
    await tester.tap(find.byKey(const Key('driver_inapp_call_icon')));
    await tester.pumpAndSettle();

    // Verify bulky header text is NOT present
    expect(find.text('Call Contact'), findsNothing);
    expect(find.text('Tap to connect with contact'), findsNothing);

    // Verify target option tile is shown with first name
    expect(find.byKey(const Key('call_target_option_0')), findsOneWidget);
    expect(find.textContaining('Bamiduro'), findsAtLeastNWidgets(1));
  });

  testWidgets('Slide-to-Action slider triggers stage advancement when dragged across track',
      (tester) async {
    final fakeStreak = _FakeStreakService();

    await tester.pumpWidget(
      makeTestableWidget(
        DriverActiveTripCard(
          trip: testTrip,
          streakService: fakeStreak,
        ),
      ),
    );
    await tester.pumpAndSettle();

    // Perform horizontal drag on slide track
    await tester.drag(
      find.byKey(const Key('slide_to_action_track')),
      const Offset(700, 0),
    );
    await tester.pumpAndSettle();

    // Verify advanceTripStatus was invoked for COMPLETED
    expect(fakeStreak.lastAdvancedTripId, 'trip_123');
    expect(fakeStreak.lastAdvancedNextStatus, 'COMPLETED');
  });
}
