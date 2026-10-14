import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:sese_core/sese_core.dart';
import 'package:sese_ride/features/customer/presentation/customer_dispatch_screen.dart';
import 'package:sese_ride/features/customer/services/fare_service.dart';
import 'package:sese_ride/features/customer/services/location_service.dart';
import 'package:sese_ride/widgets/osm_map_view.dart';
import 'package:sese_ride/features/trips/models/bid_models.dart';
import 'package:sese_ride/features/trips/models/trip_models.dart';
import 'package:sese_ride/features/trips/services/trip_service.dart';

/// Deterministic zero-trust backend: canned ride fares, no network.
class _FakeRideBackend implements FareBackend {
  @override
  Future<Map<String, dynamic>> callCalculateFare(
      Map<String, dynamic> payload) async {
    return {
      'distanceKm': 14.2,
      'durationMins': 35,
      'tiers': [
        {
          'tierId': 'comfort',
          'name': 'Standard / Comfort',
          'isRecommended': true,
          'fareFormatted': '₦4,010.00',
          'fareAmount': 4010.0,
        },
        {
          'tierId': 'premium',
          'name': 'Executive / Premium',
          'isRecommended': false,
          'fareFormatted': '₦5,200.00',
          'fareAmount': 5200.0,
        },
        {
          'tierId': 'luxe',
          'name': 'Luxe / Super',
          'isRecommended': false,
          'fareFormatted': '₦7,800.00',
          'fareAmount': 7800.0,
        },
      ],
      'fareToken': 'test-fare-token',
    };
  }
}

/// Fake live-dispatch backend: instant trip creation, static snapshots.
class _FakeTripRepository implements TripRepository {
  TripDraft? lastDraft;

  @override
  Future<String> createTrip(TripDraft draft) async {
    lastDraft = draft;
    return 'trip-test-1';
  }

  @override
  Stream<ActiveTrip?> tripStream(String tripId) => Stream.value(ActiveTrip(
        tripId: tripId,
        status: TripStatus.searchingDriver,
        customerId: 'test-customer',
      ));

  @override
  Stream<List<ActiveTrip>> activeTripsStream(String customerId) =>
      Stream.value(const []);

  @override
  Future<void> cancelTrip(String tripId, {String? reason}) async {}

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

void main() {
  group('isValidNigerianPhoneNumber', () {
    test('accepts local 11-digit numbers with mobile prefixes', () {
      expect(isValidNigerianPhoneNumber('08012345678'), isTrue);
      expect(isValidNigerianPhoneNumber('08101234567'), isTrue);
      expect(isValidNigerianPhoneNumber('07051234567'), isTrue);
      expect(isValidNigerianPhoneNumber('09031234567'), isTrue);
      expect(isValidNigerianPhoneNumber('09151234567'), isTrue);
    });

    test('accepts international format with and without plus', () {
      expect(isValidNigerianPhoneNumber('+2348012345678'), isTrue);
      expect(isValidNigerianPhoneNumber('2348012345678'), isTrue);
      expect(isValidNigerianPhoneNumber('+234 803 123 4567'), isTrue);
    });

    test('tolerates spaces, dashes and parentheses', () {
      expect(isValidNigerianPhoneNumber('0801-234-5678'), isTrue);
      expect(isValidNigerianPhoneNumber('(080) 1234 5678'), isTrue);
    });

    test('rejects empty, short, wrong-prefix and non-numeric input', () {
      expect(isValidNigerianPhoneNumber(null), isFalse);
      expect(isValidNigerianPhoneNumber(''), isFalse);
      expect(isValidNigerianPhoneNumber('08012345'), isFalse);
      expect(isValidNigerianPhoneNumber('05012345678'), isFalse);
      expect(isValidNigerianPhoneNumber('080123456789'), isFalse);
      expect(isValidNigerianPhoneNumber('+15551234567'), isFalse);
      expect(isValidNigerianPhoneNumber('not-a-number'), isFalse);
    });
  });

  group('isOptionalNigerianPhoneNumber', () {
    test('accepts empty (no secondary contact)', () {
      expect(isOptionalNigerianPhoneNumber(null), isTrue);
      expect(isOptionalNigerianPhoneNumber(''), isTrue);
      expect(isOptionalNigerianPhoneNumber('   '), isTrue);
    });

    test('still rejects malformed non-empty entries', () {
      expect(isOptionalNigerianPhoneNumber('12345'), isFalse);
      expect(isOptionalNigerianPhoneNumber('not-a-number'), isFalse);
      expect(isOptionalNigerianPhoneNumber('+15551234567'), isFalse);
    });

    test('accepts valid numbers', () {
      expect(isOptionalNigerianPhoneNumber('08012345678'), isTrue);
      expect(isOptionalNigerianPhoneNumber('+2348012345678'), isTrue);
    });
  });

  group('nationalDisplayDigits', () {
    test('strips hardcoded country prefixes for the phone box', () {
      // The widget renders its own +234 selector prefix — seeding the box
      // with E.164 would duplicate it (`+234 +23481...`).
      expect(nationalDisplayDigits('+2348012345678'), '8012345678');
      expect(nationalDisplayDigits('+234 801 234 5678'), '8012345678');
      expect(nationalDisplayDigits('2348012345678'), '8012345678');
      expect(nationalDisplayDigits('08012345678'), '08012345678');
      expect(nationalDisplayDigits(null), isEmpty);
      expect(nationalDisplayDigits(''), isEmpty);
    });
  });

  group('Step 3 contact phone fields (Book a Ride)', () {
    const pickupPos = LatLng(6.5244, 3.3792);
    const dropoffPos = LatLng(6.6018, 3.3515);

    setUp(() {
      OsmMapView.debugTileProviderOverride = BlankTileProvider();
      LocationService.customRouteProvider =
          (pickup, dropoff) async => [pickup, dropoff];
    });

    tearDown(() {
      OsmMapView.debugTileProviderOverride = null;
      LocationService.resetTestSeams();
    });

    Future<void> pumpBooking(
      WidgetTester tester, {
      AppUser? user,
      String? pickupPhone,
      String? dropoffPhone,
      _FakeTripRepository? tripRepository,
    }) async {
      await tester.pumpWidget(
        MaterialApp(
          home: CustomerDispatchScreen(
            initialConfig: RegionConfig.globalDefault(),
            user: user,
            initialModeIndex: 1, // ride-hailing → Confirm & Book Ride
            fareService: FareService(_FakeRideBackend()),
            initialPickupAddress: 'Test Pickup, Lagos',
            initialPickupLatLng: pickupPos,
            initialDropoffAddress: 'Test Dropoff, Lagos',
            initialDropoffLatLng: dropoffPos,
            initialPickupPhone: pickupPhone,
            initialDropoffPhone: dropoffPhone,
            tripRepository: tripRepository ?? _FakeTripRepository(),
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    /// Advances Step 1 → Step 2 → Step 3 via enabled Next buttons.
    Future<void> goToStep3(WidgetTester tester) async {
      for (var step = 0; step < 2; step++) {
        final all = find.widgetWithText(FilledButton, 'Next');
        var tapped = false;
        for (var i = 0; i < all.evaluate().length; i++) {
          if (tester.widget<FilledButton>(all.at(i)).onPressed != null) {
            await tester.ensureVisible(all.at(i));
            await tester.pumpAndSettle();
          }
        }
        final visible =
            find.widgetWithText(FilledButton, 'Next').hitTestable();
        for (var i = 0; i < visible.evaluate().length; i++) {
          if (tester.widget<FilledButton>(visible.at(i)).onPressed != null) {
            await tester.tap(visible.at(i));
            await tester.pumpAndSettle();
            tapped = true;
            break;
          }
        }
        expect(tapped, isTrue, reason: 'Step ${step + 1} Next must tap');
      }
    }

    FilledButton confirmButton(WidgetTester tester) =>
        tester.widget<FilledButton>(
          find.widgetWithText(FilledButton, 'Confirm & Book Ride'),
        );

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

    testWidgets('ride tiers support multi-select broadcast', (tester) async {
      await pumpBooking(tester);
      await goToStep2(tester);

      expect(find.text('Passenger Car Tiers'), findsWidgets);
      expect(find.text('1 selected'), findsOneWidget);
      // Checkboxes render in server order: comfort, premium, luxe.
      expect(find.byType(Checkbox), findsNWidgets(3));

      Future<void> tapCheckbox(int index) async {
        final box = find.byType(Checkbox).at(index);
        await tester.ensureVisible(box);
        await tester.pumpAndSettle();
        await tester.tap(box);
        await tester.pumpAndSettle();
      }

      // Check an additional tier → broadcast set grows.
      await tapCheckbox(1); // premium
      expect(find.text('2 selected'), findsOneWidget);

      // Uncheck one → back to a single tier.
      await tapCheckbox(0); // comfort
      expect(find.text('1 selected'), findsOneWidget);

      // The last remaining tier cannot be unchecked.
      await tapCheckbox(1); // premium is now the only selection
      expect(
        find.text('At least one ride tier must be selected.'),
        findsOneWidget,
      );
      expect(find.text('1 selected'), findsOneWidget);
    });

    testWidgets('review shows tagged sections with phone fields', (
      tester,
    ) async {
      await pumpBooking(tester);
      await goToStep3(tester);

      expect(find.text('Pickup Location'), findsOneWidget);
      expect(find.text('Drop-off Location'), findsOneWidget);
      expect(find.text('Test Pickup, Lagos'), findsWidgets);
      expect(find.text('Test Dropoff, Lagos'), findsWidgets);
      expect(
        find.widgetWithText(
            TextFormField, 'Pickup Phone Number (Optional)'),
        findsOneWidget,
      );
      expect(
        find.widgetWithText(
            TextFormField, 'Drop-off Contact Phone Number (Optional)'),
        findsOneWidget,
      );
    });

    testWidgets('confirm stays enabled with empty phones (optional contacts)', (
      tester,
    ) async {
      await pumpBooking(tester);
      await goToStep3(tester);

      // Both empty → enabled: no secondary contact is a valid booking.
      expect(confirmButton(tester).onPressed, isNotNull);

      // A malformed non-empty entry still blocks, with an inline error.
      await tester.enterText(
        find.widgetWithText(
            TextFormField, 'Drop-off Contact Phone Number (Optional)'),
        '12345',
      );
      await tester.pumpAndSettle();
      expect(confirmButton(tester).onPressed, isNull);
      expect(find.textContaining('valid phone'), findsWidgets);

      // Clearing it re-enables; valid entries keep it enabled.
      await tester.enterText(
        find.widgetWithText(
            TextFormField, 'Drop-off Contact Phone Number (Optional)'),
        '',
      );
      await tester.enterText(
        find.widgetWithText(
            TextFormField, 'Pickup Phone Number (Optional)'),
        '08012345678',
      );
      await tester.pumpAndSettle();
      expect(confirmButton(tester).onPressed, isNotNull);
    });

    testWidgets('pickup phone pre-fills from the signed-in user', (
      tester,
    ) async {
      final user = AppUser(
        uid: 'u1',
        fullName: 'Test User',
        email: 'test@example.com',
        phoneNumber: '08012345678',
        role: UserRole.customer,
        createdAt: DateTime(2024),
      );
      await pumpBooking(tester, user: user);
      await goToStep3(tester);

      final field = tester.widget<TextFormField>(
        find.widgetWithText(
            TextFormField, 'Pickup Phone Number (Optional)'),
      );
      expect(field.controller?.text, '08012345678');

      // Drop-off starts empty and stays editable.
      final dropField = tester.widget<TextFormField>(
        find.widgetWithText(
            TextFormField, 'Drop-off Contact Phone Number (Optional)'),
      );
      expect(dropField.controller?.text ?? '', isEmpty);
    });

    testWidgets('E.164 profile numbers pre-fill without a doubled prefix', (
      tester,
    ) async {
      final user = AppUser(
        uid: 'u1',
        fullName: 'Test User',
        email: 'test@example.com',
        // Stored E.164: the box must show national digits only, since the
        // selector already renders +234 (`+234 +23481...` regression).
        phoneNumber: '+2348012345678',
        role: UserRole.customer,
        createdAt: DateTime(2024),
      );
      await pumpBooking(tester, user: user);
      await goToStep3(tester);

      final field = tester.widget<TextFormField>(
        find.widgetWithText(
            TextFormField, 'Pickup Phone Number (Optional)'),
      );
      final text = field.controller?.text ?? '';
      expect(text.startsWith('+'), isFalse);
      expect(text, endsWith('8012345678'));
    });

    testWidgets('confirm dispatches the trip with both contact numbers',
        (tester) async {
      final repo = _FakeTripRepository();
      await pumpBooking(
        tester,
        pickupPhone: '08012345678',
        dropoffPhone: '08087654321',
        tripRepository: repo,
      );
      await goToStep3(tester);

      expect(confirmButton(tester).onPressed, isNotNull);
      final btn = find.widgetWithText(FilledButton, 'Confirm & Book Ride');
      await tester.ensureVisible(btn);
      await tester.pumpAndSettle();
      await tester.tap(btn);
      // Confirm navigates directly to the live tracker (no intermediate
      // dialog); the banner spinner animates forever, so use fixed pumps.
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));

      // Draft carries both contact numbers (suffix match: E.164 prefix
      // depends on the test-env country default).
      expect(repo.lastDraft, isNotNull);
      expect(repo.lastDraft!.pickupPhone, endsWith('8012345678'));
      expect(repo.lastDraft!.dropoffPhone, endsWith('8087654321'));
      // Live tracker shows the searching banner; the wizard is gone.
      expect(find.text('Live Trip'), findsOneWidget);
      expect(find.textContaining('Searching for nearby'), findsOneWidget);
      expect(find.text('Confirm & Book Ride'), findsNothing);
    });
  });
}
