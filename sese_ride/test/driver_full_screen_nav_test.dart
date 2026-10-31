import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sese_ride/features/driver/presentation/widgets/driver_active_trip_card.dart';
import 'package:sese_ride/features/driver/services/driver_streak_service.dart';
import 'package:sese_ride/features/trips/models/trip_models.dart';

class _MockStreakService implements DriverStreakService {
  @override
  Future<void> advanceTripStatus(String tripId, String nextStatus) async {}

  @override
  Future<void> cancelTrip(String tripId, {String? reason, bool useCashSettlement = false}) async {}

  @override
  Future<void> verifyDeliveryPin(String tripId, String pin) async {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  final testTrip = ActiveTrip(
    tripId: 'trip_nav_1',
    status: TripStatus.driverAccepted,
    customerId: 'cust_999',
    customerName: 'Micheal Bamiduro',
    customerPhone: '+2348012345678',
    pickupAddress: '34 Olafiloye St, Ikorodu',
    dropoffAddress: '5 Ikosi Road, Ketu',
    fareAmount: 5000,
    fareFormatted: '₦5,000',
    serviceType: 'send_item',
  );

  Widget makeTestableWidget(Widget child) {
    return MaterialApp(
      home: Scaffold(
        body: child,
      ),
    );
  }

  testWidgets('DriverActiveTripCard renders collapsed header title and list icon',
      (tester) async {
    final mockStreak = _MockStreakService();

    await tester.pumpWidget(
      makeTestableWidget(
        DriverActiveTripCard(
          trip: testTrip,
          streakService: mockStreak,
        ),
      ),
    );
    await tester.pumpAndSettle();

    // Verify collapsed header title ("Sender notified") is visible
    expect(find.text('Sender notified'), findsOneWidget);

    // Verify status subtitle is visible
    expect(
      find.text('Drive closer to the pickup location to start the waiting timer'),
      findsOneWidget,
    );

    // Verify list handle icon is rendered
    expect(find.byIcon(Icons.format_list_bulleted_rounded), findsOneWidget);
  });
}
