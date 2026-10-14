import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:sese_ride/features/customer/presentation/customer_dispatch_screen.dart';
import 'package:sese_ride/features/customer/presentation/customer_home_map_screen.dart';

import 'package:sese_ride/features/customer/services/location_service.dart';
import 'package:sese_ride/widgets/map_provider.dart';
import 'package:sese_ride/widgets/osm_map_view.dart';

void main() {
  setUp(() {
    OsmMapView.debugTileProviderOverride = BlankTileProvider();
    LocationService.customPositionProvider = () async => const LatLng(6.5244, 3.3792);
    LocationService.customReverseGeocodeProvider =
        (lat, lng) async => '14 Olafiranye street, Isawo, Lagos';
  });

  tearDown(() {
    OsmMapView.debugTileProviderOverride = null;
    LocationService.customPositionProvider = null;
    LocationService.customReverseGeocodeProvider = null;
  });

  group('CustomerHomeMapScreen (map-first home)', () {
    Future<void> pumpHome(WidgetTester tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: CustomerHomeMapScreen(
            initialPosition: LatLng(6.5244, 3.3792),
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    testWidgets('renders Google map, recenter button and 3 action cards',
        (tester) async {
      await pumpHome(tester);

      // Renderer-agnostic: tile tests force the placeholder container via
      // debugTileProviderOverride, so assert the policy map view itself.
      expect(find.byType(SeSeMapView), findsOneWidget);
      expect(find.byKey(const Key('recenter_button')), findsOneWidget);
      expect(find.text('Book Ride'), findsOneWidget);
      expect(find.text("Let's get moving"), findsOneWidget);
      expect(find.text('Send Item'), findsOneWidget);
      expect(find.text('Courier delivery'), findsOneWidget);
      expect(find.text('Receive Item'), findsOneWidget);
      expect(find.text('Package pickup'), findsOneWidget);
    });

    testWidgets('Book Ride opens ride-hailing booking page in step-by-step mode', (tester) async {
      await pumpHome(tester);

      await tester.tap(find.text('Book Ride'));
      await tester.pumpAndSettle();

      // Focused ride page: Title is 'Book a Ride', Step 1 is active.
      expect(find.text('Book a Ride'), findsOneWidget);
      expect(find.text('Enter Locations'), findsOneWidget);
      expect(find.text('Where to?'), findsOneWidget);
      expect(find.text('Package Delivery'), findsNothing);
    });

    testWidgets('Send Item opens delivery booking page in step-by-step mode', (tester) async {
      await pumpHome(tester);

      await tester.tap(find.text('Send Item'));
      await tester.pumpAndSettle();

      expect(find.widgetWithText(AppBar, 'Send Item'), findsOneWidget);
      expect(find.text('Enter Locations'), findsOneWidget);
      expect(find.text('Where to?'), findsOneWidget);
      expect(find.text('Package Delivery'), findsNothing);
      expect(find.text('Ride-Hailing'), findsNothing);
    });

    testWidgets('Receive Item opens receive delivery page in step-by-step mode', (tester) async {
      await pumpHome(tester);

      await tester.tap(find.text('Receive Item'));
      await tester.pumpAndSettle();

      expect(find.widgetWithText(AppBar, 'Receive Item'), findsOneWidget);
      expect(find.text('Enter Locations'), findsOneWidget);
      expect(find.text('Where to?'), findsOneWidget);
      expect(find.text('Package Delivery'), findsNothing);
      expect(find.text('Ride-Hailing'), findsNothing);
      // Toggle seeded from the entry route: Receiving Package highlighted.
      final toggle = tester.widget<SegmentedButton<bool>>(
        find.byWidgetPredicate((w) => w is SegmentedButton<bool>),
      );
      expect(toggle.selected, {true});
    });

    testWidgets('pickup defaults to location and drop-off is empty with Where to?',
        (tester) async {
      await tester.pumpWidget(
        const MaterialApp(home: CustomerDispatchScreen()),
      );
      await tester.pumpAndSettle();

      // Drop-off hint text
      expect(find.text('Where to?'), findsOneWidget);
      // Re-detect location button
      expect(find.byIcon(Icons.my_location), findsOneWidget);

      final pickupField = find.widgetWithText(TextField, 'Pickup Location');
      expect(pickupField, findsOneWidget);

      await tester.enterText(pickupField, '14 Olafiranye street, Isawo, Lagos');
      await tester.pump();
      expect(find.text('14 Olafiranye street, Isawo, Lagos'), findsOneWidget);
    });
  });
}
