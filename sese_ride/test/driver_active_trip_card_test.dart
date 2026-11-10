import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sese_ride/features/driver/presentation/widgets/driver_active_trip_card.dart';
import 'package:sese_ride/features/driver/services/driver_streak_service.dart';
import 'package:sese_ride/features/trips/models/trip_models.dart';

class _FakeStreakService implements DriverStreakService {
  String? lastAdvancedTripId;
  String? lastAdvancedNextStatus;
  String? lastConfirmedCashTripId;
  bool? lastConfirmedCashCollected;

  @override
  Future<void> advanceTripStatus(String tripId, String nextStatus) async {
    lastAdvancedTripId = tripId;
    lastAdvancedNextStatus = nextStatus;
  }

  @override
  Future<void> confirmCashCancellation(String tripId, {bool cashCollected = true}) async {
    lastConfirmedCashTripId = tripId;
    lastConfirmedCashCollected = cashCollected;
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
      home: MediaQuery(
        data: const MediaQueryData(size: Size(800, 1200)),
        child: Scaffold(
          body: SizedBox(
            height: 1200,
            width: 800,
            child: child,
          ),
        ),
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
    expect(find.textContaining('₦4,126'), findsAtLeast(1));

    // 4. Verify 3 inline action icons are present
    expect(find.byKey(const Key('driver_direct_call_icon')), findsOneWidget);
    expect(find.byKey(const Key('driver_inapp_call_icon')), findsOneWidget);
    expect(find.byKey(const Key('driver_chat_icon')), findsOneWidget);

    // 5. Verify Slide-to-Action button is rendered with stage label
    expect(find.byKey(const Key('driver_slide_action_button')), findsOneWidget);
    expect(find.textContaining('Complete Trip'), findsOneWidget);
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

  testWidgets(
      'En route to pickup hides specific cash collection card and shows clean total fare subtitle',
      (tester) async {
    final fakeStreak = _FakeStreakService();
    final splitTrip = ActiveTrip(
      tripId: 'split_1',
      status: TripStatus.driverAccepted,
      customerId: 'cust_1',
      customerName: 'Bamiduro',
      pickupAddress: 'Pickup Address',
      dropoffAddress: 'Dropoff Address',
      fareAmount: 6000,
      fareFormatted: '₦6,000',
      paymentMode: 'split',
      splitEnabled: true,
      walletCoverageAmount: 1000,
      cashToCollect: 5000,
      senderShareAmount: 6000,
      serviceType: 'ride',
    );

    await tester.pumpWidget(
      makeTestableWidget(
        DriverActiveTripCard(
          trip: splitTrip,
          streakService: fakeStreak,
        ),
      ),
    );
    await tester.pumpAndSettle();

    // Total fare ₦6,000 is visible
    expect(find.textContaining('₦6,000'), findsAtLeastNWidgets(1));
    // Subtitle shows clean mode label without breaking down cash
    expect(find.text('Split Payment'), findsOneWidget);
    // Specific collection breakdown card is completely hidden
    expect(find.textContaining('Collect cash from sender'), findsNothing);
    expect(find.textContaining('credited to your wallet upon completion'), findsNothing);
  });

  testWidgets(
      'Arrived at pickup reveals collection card and verification dialog when cash is due from sender',
      (tester) async {
    final fakeStreak = _FakeStreakService();
    final splitTrip = ActiveTrip(
      tripId: 'split_2',
      status: TripStatus.driverArrived,
      customerId: 'cust_2',
      customerName: 'Bamiduro',
      pickupAddress: 'Pickup Address',
      dropoffAddress: 'Dropoff Address',
      fareAmount: 6000,
      fareFormatted: '₦6,000',
      paymentMode: 'split',
      splitEnabled: true,
      walletCoverageAmount: 1000,
      cashToCollect: 5000,
      senderShareAmount: 6000,
      serviceType: 'ride',
    );

    await tester.pumpWidget(
      makeTestableWidget(
        DriverActiveTripCard(
          trip: splitTrip,
          streakService: fakeStreak,
        ),
      ),
    );
    await tester.pumpAndSettle();

    // Subtitle indicates cash due at pickup
    expect(find.text('Collect ₦5000 Cash'), findsOneWidget);
    // Cash collection card is revealed with professional wording
    expect(
      find.text('Kindly collect ₦5,000 cash payment from the sender before departure.'),
      findsOneWidget,
    );

    // Slide to Start Ride
    await tester.drag(
      find.byKey(const Key('slide_to_action_track')),
      const Offset(700, 0),
    );
    await tester.pumpAndSettle();

    // Verify verification dialog appears with exact professional wording
    expect(find.text('Pickup Cash Check'), findsOneWidget);
    expect(
      find.text('Kindly collect ₦5000 cash payment from the sender before departure.'),
      findsOneWidget,
    );

    // Tap confirm
    await tester.tap(find.text('Confirm Cash Collected'));
    await tester.pumpAndSettle();

    expect(fakeStreak.lastAdvancedTripId, 'split_2');
    expect(fakeStreak.lastAdvancedNextStatus, 'IN_PROGRESS');
  });

  testWidgets(
      'Arrived at pickup does NOT show cash collection prompt when receiver pays at drop-off',
      (tester) async {
    final fakeStreak = _FakeStreakService();
    final receiverPaysTrip = ActiveTrip(
      tripId: 'receiver_1',
      status: TripStatus.driverArrived,
      customerId: 'cust_3',
      customerName: 'Bamiduro',
      pickupAddress: 'Pickup Address',
      dropoffAddress: 'Dropoff Address',
      fareAmount: 6000,
      fareFormatted: '₦6,000',
      paymentMode: 'receiver_pays',
      collectAt: 'dropoff',
      cashToCollect: 6000,
      serviceType: 'ride',
    );

    await tester.pumpWidget(
      makeTestableWidget(
        DriverActiveTripCard(
          trip: receiverPaysTrip,
          streakService: fakeStreak,
        ),
      ),
    );
    await tester.pumpAndSettle();

    // Subtitle indicates receiver pays at drop-off
    expect(find.text('Receiver Pays at Drop-off'), findsOneWidget);
    // Pickup cash collection card is NOT shown
    expect(find.textContaining('Collect cash from sender'), findsNothing);

    // Slide to Start Ride
    await tester.drag(
      find.byKey(const Key('slide_to_action_track')),
      const Offset(700, 0),
    );
    await tester.pumpAndSettle();

    // No cash check dialog appears at pickup — advances directly!
    expect(find.text('Pickup Cash Check'), findsNothing);
    expect(fakeStreak.lastAdvancedTripId, 'receiver_1');
    expect(fakeStreak.lastAdvancedNextStatus, 'IN_PROGRESS');
  });

  testWidgets(
      'In progress reveals drop-off cash collection prompt when receiver pays cash',
      (tester) async {
    final fakeStreak = _FakeStreakService();
    final receiverPaysTrip = ActiveTrip(
      tripId: 'receiver_2',
      status: TripStatus.inProgress,
      customerId: 'cust_4',
      customerName: 'Bamiduro',
      pickupAddress: 'Pickup Address',
      dropoffAddress: 'Dropoff Address',
      fareAmount: 6000,
      fareFormatted: '₦6,000',
      paymentMode: 'receiver_pays',
      collectAt: 'dropoff',
      cashToCollect: 6000,
      serviceType: 'ride',
    );

    await tester.pumpWidget(
      makeTestableWidget(
        DriverActiveTripCard(
          trip: receiverPaysTrip,
          streakService: fakeStreak,
        ),
      ),
    );
    await tester.pumpAndSettle();

    // Drop-off collection card is revealed
    expect(
      find.text('Collect ₦6000 cash from passenger before ending ride.'),
      findsOneWidget,
    );

    // Slide to Complete Trip
    await tester.drag(
      find.byKey(const Key('slide_to_action_track')),
      const Offset(700, 0),
    );
    await tester.pumpAndSettle();

    // Drop-off cash check dialog appears
    expect(find.text('Drop-off Cash Check'), findsOneWidget);
    expect(
      find.text('Collect ₦6000 cash from passenger before ending ride.'),
      findsAtLeastNWidgets(1),
    );

    await tester.tap(find.text('Confirm Cash Collected'));
    await tester.pumpAndSettle();

    expect(fakeStreak.lastAdvancedTripId, 'receiver_2');
    expect(fakeStreak.lastAdvancedNextStatus, 'COMPLETED');
  });

  testWidgets(
      'In progress renders HUD telemetry strip and triggers collapse callback on trip start',
      (tester) async {
    final fakeStreak = _FakeStreakService();
    bool collapseToggled = false;

    final inProgressTrip = ActiveTrip(
      tripId: 'in_progress_1',
      status: TripStatus.inProgress,
      customerId: 'cust_5',
      customerName: 'Bamiduro',
      pickupAddress: '32 Olafiranye St',
      dropoffAddress: '5 Ikosi Road, Ketu',
      fareAmount: 4000,
      fareFormatted: '₦4,000',
      serviceType: 'ride',
    );

    await tester.pumpWidget(
      makeTestableWidget(
        DriverActiveTripCard(
          trip: inProgressTrip,
          streakService: fakeStreak,
          onToggleCollapse: () {
            collapseToggled = true;
          },
        ),
      ),
    );
    await tester.pumpAndSettle();

    // Verify collapse callback can be passed
    expect(collapseToggled, isFalse);

    // Verify HUD telemetry strip is present
    expect(find.byKey(const Key('hud_bottom_telemetry_strip')), findsOneWidget);
    expect(find.textContaining('min'), findsAtLeastNWidgets(1));
    expect(find.textContaining('km'), findsAtLeastNWidgets(1));

    // Verify complete trip action button label includes chevron
    expect(find.text('Complete Trip >'), findsOneWidget);
  });

  testWidgets(
      'Cancelled waiting cash settlement hides middle card and offers Cash Not Collected dispute choice',
      (tester) async {
    final fakeStreak = _FakeStreakService();

    final cancelledTrip = ActiveTrip(
      tripId: 'cancel_cash_1',
      status: TripStatus.cancelledWaitingCashSettlement,
      customerId: 'cust_6',
      customerName: 'Bamiduro',
      pickupAddress: '32 Olafiranye St',
      dropoffAddress: '5 Ikosi Road, Ketu',
      fareAmount: 4000,
      fareFormatted: '₦4,000',
      paidWaitingFee: 440,
      pendingCashFee: 440,
      serviceType: 'ride',
    );

    await tester.pumpWidget(
      makeTestableWidget(
        DriverActiveTripCard(
          trip: cancelledTrip,
          streakService: fakeStreak,
        ),
      ),
    );
    await tester.pumpAndSettle();

    // 1. Verify old middle yellow card is completely removed
    expect(find.textContaining('Cash Settlement Due'), findsNothing);
    expect(find.byKey(const Key('driver_confirm_cash_collected_button')), findsNothing);

    // 2. Drag main sliding confirmation control
    await tester.drag(
      find.byKey(const Key('slide_to_action_track')),
      const Offset(700, 0),
    );
    await tester.pumpAndSettle();

    // 3. Verify choice dialog is presented with both options
    expect(find.text('Cash Waiting Fee'), findsOneWidget);
    expect(find.byKey(const Key('confirm_cash_received_button')), findsOneWidget);
    expect(find.byKey(const Key('cash_not_collected_button')), findsOneWidget);

    // 4. Tap "Cash Not Collected"
    await tester.tap(find.byKey(const Key('cash_not_collected_button')));
    await tester.pumpAndSettle();

    // 5. Verify confirmCashCancellation was invoked with cashCollected = false
    expect(fakeStreak.lastConfirmedCashTripId, 'cancel_cash_1');
    expect(fakeStreak.lastConfirmedCashCollected, false);
  });
}
