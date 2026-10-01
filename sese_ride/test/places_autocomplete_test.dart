import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:sese_ride/features/customer/presentation/customer_dispatch_screen.dart';
import 'package:sese_ride/features/customer/services/location_service.dart';
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
    LocationService.resetTestSeams();
  });

  group('Interactive Places Autocomplete Dropdown', () {
    testWidgets('user maintains 100% control of text field while typing (no hijack)', (tester) async {
      LocationService.customSuggestionsProvider = (query) async {
        return [
          PlaceSuggestion(
            description: 'Ikosi Road, Ketu, Lagos',
            lat: 6.6018,
            lng: 3.3850,
          ),
          PlaceSuggestion(
            description: 'Ikosi-Ketu, Lagos',
            lat: 6.5980,
            lng: 3.3820,
          ),
          PlaceSuggestion(
            description: 'Ikosi, Epe, Lagos',
            lat: 6.5840,
            lng: 3.9800,
          ),
        ];
      };

      await tester.pumpWidget(
        const MaterialApp(
          home: CustomerDispatchScreen(
            initialPickupLatLng: LatLng(6.5244, 3.3792),
            initialPickupAddress: '14 Olafiranye street, Isawo, Lagos',
          ),
        ),
      );
      await tester.pumpAndSettle();

      final dropoffField = find.widgetWithText(TextField, 'Destination / Drop-off');
      expect(dropoffField, findsOneWidget);

      // User types "Ikosi"
      await tester.enterText(dropoffField, 'Ikosi');
      // Advance by debounce buffer (300ms)
      await tester.pump(const Duration(milliseconds: 350));
      await tester.pumpAndSettle();

      // 1. Text must NOT be hijacked or replaced by the first suggestion
      final editableText = tester.widget<EditableText>(find.descendant(
        of: dropoffField,
        matching: find.byType(EditableText),
      ));
      expect(editableText.controller.text, equals('Ikosi'));

      // 2. Suggestions dropdown must render all matching suggestions
      expect(find.text('Ikosi Road, Ketu, Lagos'), findsOneWidget);
      expect(find.text('Ikosi-Ketu, Lagos'), findsOneWidget);
      expect(find.text('Ikosi, Epe, Lagos'), findsOneWidget);
    });

    testWidgets('tapping a suggestion item populates text, locks lat/lng, and dismisses dropdown', (tester) async {
      LocationService.customSuggestionsProvider = (query) async {
        return [
          PlaceSuggestion(
            description: 'Ikosi Road, Ketu, Lagos',
            lat: 6.6018,
            lng: 3.3850,
          ),
          PlaceSuggestion(
            description: 'Ikosi-Ketu, Lagos',
            lat: 6.5980,
            lng: 3.3820,
          ),
        ];
      };

      LocationService.customRouteProvider = (pickup, dropoff) async {
        return [pickup, dropoff];
      };

      await tester.pumpWidget(
        const MaterialApp(
          home: CustomerDispatchScreen(
            initialPickupLatLng: LatLng(6.5244, 3.3792),
            initialPickupAddress: '14 Olafiranye street, Isawo, Lagos',
          ),
        ),
      );
      await tester.pumpAndSettle();

      final dropoffField = find.widgetWithText(TextField, 'Destination / Drop-off');
      await tester.enterText(dropoffField, 'Ikosi');
      await tester.pump(const Duration(milliseconds: 350));
      await tester.pumpAndSettle();

      expect(find.text('Ikosi Road, Ketu, Lagos'), findsOneWidget);

      // Next button should be disabled before selecting a suggestion with coordinates
      final nextButton = tester.widget<FilledButton>(
        find.widgetWithText(FilledButton, 'Next'),
      );
      expect(nextButton.onPressed, isNull);

      // Tap on the first suggestion
      await tester.tap(find.text('Ikosi Road, Ketu, Lagos'));
      await tester.pumpAndSettle();

      // Dropdown must be dismissed
      expect(find.text('Ikosi-Ketu, Lagos'), findsNothing);

      // Controller text must now be the selected suggestion
      final updatedEditable = tester.widget<EditableText>(find.descendant(
        of: dropoffField,
        matching: find.byType(EditableText),
      ));
      expect(updatedEditable.controller.text, equals('Ikosi Road, Ketu, Lagos'));

      // Check that Next button is now enabled
      final enabledNextButton = tester.widget<FilledButton>(
        find.widgetWithText(FilledButton, 'Next'),
      );
      expect(enabledNextButton.onPressed, isNotNull);
    });
  });
}
