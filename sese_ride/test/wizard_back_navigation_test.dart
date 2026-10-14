import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:sese_core/sese_core.dart';
import 'package:sese_ride/features/customer/presentation/customer_dispatch_screen.dart';
import 'package:sese_ride/features/customer/services/fare_service.dart';
import 'package:sese_ride/features/customer/services/location_service.dart';
import 'package:sese_ride/widgets/osm_map_view.dart';

/// Deterministic zero-trust backend: canned delivery fares, no network.
class _FakeFareBackend implements FareBackend {
  @override
  Future<Map<String, dynamic>> callCalculateFare(
    Map<String, dynamic> payload,
  ) async {
    return {
      'distanceKm': 14.2,
      'durationMins': 35,
      'tiers': [
        {
          'tierId': 'bicycle',
          'name': 'Bicycle',
          'isRecommended': false,
          'fareFormatted': '₦950.00',
          'fareAmount': 950.0,
        },
        {
          'tierId': 'motorcycle',
          'name': 'Motorcycle',
          'isRecommended': true,
          'fareFormatted': '₦1,850.00',
          'fareAmount': 1850.0,
        },
        {
          'tierId': 'tricycle',
          'name': 'Tricycle (Keke)',
          'isRecommended': false,
          'fareFormatted': '₦2,400.00',
          'fareAmount': 2400.0,
        },
        {
          'tierId': 'van',
          'name': 'Van',
          'isRecommended': false,
          'fareFormatted': '₦6,500.00',
          'fareAmount': 6500.0,
        },
        {
          'tierId': 'truck',
          'name': 'Truck',
          'isRecommended': false,
          'fareFormatted': '₦12,000.00',
          'fareAmount': 12000.0,
        },
      ],
      'fareToken': 'test-fare-token',
    };
  }
}

void main() {
  group('Wizard back navigation (Book a Ride / Send Item / Receive Item)', () {
    const pickupPos = LatLng(6.5244, 3.3792);
    const dropoffPos = LatLng(6.6018, 3.3515);

    setUp(() {
      OsmMapView.debugTileProviderOverride = BlankTileProvider();
      LocationService.customRouteProvider = (pickup, dropoff) async => [
        pickup,
        dropoff,
      ];
    });

    tearDown(() {
      OsmMapView.debugTileProviderOverride = null;
      LocationService.resetTestSeams();
    });

    Future<void> pumpBooking(WidgetTester tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: CustomerDispatchScreen(
            initialConfig: RegionConfig.globalDefault(),
            fareService: FareService(_FakeFareBackend()),
            initialPickupAddress: 'Test Pickup, Lagos',
            initialPickupLatLng: pickupPos,
            initialDropoffAddress: 'Test Dropoff, Lagos',
            initialDropoffLatLng: dropoffPos,
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    /// Advances Step 1 → Step 2 via the enabled Next button.
    Future<void> goToStep2(WidgetTester tester) async {
      final all = find.widgetWithText(FilledButton, 'Next');
      for (var i = 0; i < all.evaluate().length; i++) {
        if (tester.widget<FilledButton>(all.at(i)).onPressed != null) {
          await tester.ensureVisible(all.at(i));
          await tester.pumpAndSettle();
        }
      }
      final visible = find.widgetWithText(FilledButton, 'Next').hitTestable();
      for (var i = 0; i < visible.evaluate().length; i++) {
        if (tester.widget<FilledButton>(visible.at(i)).onPressed != null) {
          await tester.tap(visible.at(i));
          await tester.pumpAndSettle();
          return;
        }
      }
      fail('No enabled Next button found');
    }

    bool isOnStep2() =>
        // The internal Back button renders on steps 2+ only (step 1 has
        // none) — mode-agnostic step detection without phantom strings.
        find.widgetWithText(OutlinedButton, 'Back').evaluate().isNotEmpty;

    // NOTE: runtime type is PopScope<Object>, so a raw byType(PopScope)
    // finder misses it — match with an `is` predicate instead.
    PopScope wizardPopScope(WidgetTester tester) =>
        tester.widget(
              find.byWidgetPredicate((w) => w is PopScope),
            )
            as PopScope;

    /// Step 1 is active when its location fields are visible, no internal
    /// Back button exists, and system pop is allowed again.
    ///
    /// (The Stepper keeps visited step content mounted behind a fade, so
    /// assertions must not rely on Step 2 text disappearing.)
    void expectOnStep1(WidgetTester tester) {
      expect(
        find.widgetWithText(TextField, 'Destination / Drop-off'),
        findsOneWidget,
      );
      expect(find.widgetWithText(OutlinedButton, 'Back'), findsNothing);
      expect(wizardPopScope(tester).canPop, isTrue);
    }

    testWidgets('AppBar back arrow steps back instead of popping the route', (
      tester,
    ) async {
      await pumpBooking(tester);
      await goToStep2(tester);
      expect(isOnStep2(), isTrue);

      // System pop must be vetoed on Step 2.
      expect(wizardPopScope(tester).canPop, isFalse);

      // AppBar arrow steps back to Step 1 — route stays on screen.
      await tester.tap(find.byType(BackButton));
      await tester.pumpAndSettle();

      expectOnStep1(tester);
    });

    testWidgets('internal Back button steps back instead of popping', (
      tester,
    ) async {
      await pumpBooking(tester);
      await goToStep2(tester);
      expect(isOnStep2(), isTrue);

      await tester.ensureVisible(find.widgetWithText(OutlinedButton, 'Back'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(OutlinedButton, 'Back'));
      await tester.pumpAndSettle();

      expectOnStep1(tester);
    });

    testWidgets('system back steps back on Step 2, pops on Step 1', (
      tester,
    ) async {
      await pumpBooking(tester);
      await goToStep2(tester);
      expect(isOnStep2(), isTrue);

      // System back on Step 2: vetoed pop → step back, route stays.
      await tester.pageBack();
      await tester.pumpAndSettle();
      expectOnStep1(tester);

      // System back on Step 1: allowed pop → route exits.
      await tester.pageBack();
      await tester.pumpAndSettle();
      expect(
        find.widgetWithText(TextField, 'Destination / Drop-off'),
        findsNothing,
      );
    });
  });
}
