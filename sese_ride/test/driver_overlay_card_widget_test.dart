import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sese_ride/driver_overlay_entry.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final dummyOffer = {
    'tripId': 'trip_test_123',
    'pickup': '34 Olafiloye St, Ikorodu',
    'dropoff': '15 Ikorodu Rd, Ojota',
    'distanceKm': '19.4',
    'fareFormatted': '₦4,200',
    'pickupLat': 6.6190,
    'pickupLng': 3.5100,
    'dropoffLat': 6.5800,
    'dropoffLng': 3.3700,
  };

  testWidgets('OverlayOrderCard renders offer details and buttons correctly', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: OverlayOrderCard(
            offer: dummyOffer,
            firebaseReady: () => false,
          ),
        ),
      ),
    );

    expect(find.text('Incoming Trip Request'), findsOneWidget);
    expect(find.text('34 Olafiloye St, Ikorodu'), findsOneWidget);
    expect(find.text('15 Ikorodu Rd, Ojota'), findsOneWidget);
    expect(find.text('19.4 km'), findsOneWidget);
    expect(find.text('₦4,200'), findsOneWidget);
    expect(find.text('DECLINE'), findsOneWidget);
    expect(find.text('ACCEPT'), findsOneWidget);
  });

  testWidgets('Tapping DECLINE immediately invokes onDismiss and dismisses UI', (tester) async {
    var dismissed = false;

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: OverlayOrderCard(
            offer: dummyOffer,
            firebaseReady: () => false,
            onDismiss: () => dismissed = true,
          ),
        ),
      ),
    );

    expect(find.text('DECLINE'), findsOneWidget);
    await tester.tap(find.text('DECLINE'));
    await tester.pump();

    expect(dismissed, isTrue);
    // UI immediately collapses into SizedBox.shrink()
    expect(find.text('DECLINE'), findsNothing);
    expect(find.text('Incoming Trip Request'), findsNothing);
  });

  testWidgets('Countdown hitting 0s immediately triggers onDismiss without lingering', (tester) async {
    var dismissed = false;

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: OverlayOrderCard(
            offer: dummyOffer,
            firebaseReady: () => false,
            onDismiss: () => dismissed = true,
          ),
        ),
      ),
    );

    // Initial state: card visible with 30s
    expect(find.text('30s'), findsOneWidget);

    // Fast-forward 30 seconds
    await tester.pump(const Duration(seconds: 30));
    await tester.pump();

    expect(dismissed, isTrue);
    expect(find.text('Incoming Trip Request'), findsNothing);
  });
}
