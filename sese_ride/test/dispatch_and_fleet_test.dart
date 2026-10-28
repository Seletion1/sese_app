import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:sese_core/sese_core.dart';
import 'package:sese_ride/features/customer/presentation/customer_dispatch_screen.dart';
import 'package:sese_ride/features/customer/services/fare_service.dart';
import 'package:sese_ride/features/customer/services/location_service.dart';
import 'package:sese_ride/features/trips/models/bid_models.dart';
import 'package:sese_ride/features/trips/models/trip_models.dart';
import 'package:sese_ride/features/trips/services/trip_service.dart';
import 'package:sese_ride/features/driver/presentation/driver_dashboard_screen.dart';
import 'package:sese_ride/features/driver/presentation/driver_fleet_screen.dart';
import 'package:sese_ride/features/driver/presentation/online_verification_shield_modal.dart';
import 'package:sese_ride/widgets/osm_map_view.dart';
import 'package:sese_ride/features/driver/services/driver_fleet_service.dart';

/// Deterministic zero-trust backend: canned server fares, no network.
class _FakeFareBackend implements FareBackend {
  @override
  Future<Map<String, dynamic>> callCalculateFare(
      Map<String, dynamic> payload) async {
    if (payload['serviceType'] == 'ride') {
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
          'tierId': 'car',
          'name': 'Car / Sedan',
          'isRecommended': false,
          'fareFormatted': '₦3,200.00',
          'fareAmount': 3200.0,
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

/// Fake live-dispatch backend: instant trip creation, static snapshots.
class _FakeTripRepository implements TripRepository {
  @override
  Future<String> createTrip(TripDraft draft) async => 'trip-test-1';

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
  Stream<List<ActiveTrip>> userTripHistoryStream(String userId, {bool isDriver = false}) =>
      Stream.value(const []);

  @override
  Future<void> cancelTrip(String tripId, {String? reason, bool useCashSettlement = false}) async {}

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

/// Fixed in-memory fleet for dashboard flow tests (bypasses Firestore).
class _FixedFleetService extends DriverFleetService {
  final List<VehicleModel> vehicles;
  _FixedFleetService(this.vehicles);

  @override
  Future<List<VehicleModel>> getDriverFleet(String driverId) async =>
      vehicles.where((v) => v.driverId == driverId).toList();

  @override
  Stream<List<VehicleModel>> streamDriverFleet(String driverId) =>
      Stream.value(
          vehicles.where((v) => v.driverId == driverId).toList());
}

void main() {
  group('Customer Dispatch Workflow', () {
    const pickupPos = LatLng(6.5244, 3.3792);
    const dropoffPos = LatLng(6.6018, 3.3515);

    setUp(() {
      OsmMapView.debugTileProviderOverride = BlankTileProvider();
      LocationService.customRouteProvider =
          (pickup, dropoff) async => [pickup, dropoff];
      LocationService.customSearchProvider = (_) async => null;
    });

    tearDown(() {
      OsmMapView.debugTileProviderOverride = null;
      LocationService.resetTestSeams();
    });

    Future<void> pumpBooking(
      WidgetTester tester, {
      int initialModeIndex = 0,
      String? focusedTitle,
      String? pickupAddress,
      LatLng? pickupLatLng,
      String? dropoffAddress,
      LatLng? dropoffLatLng,
    }) async {
      await tester.pumpWidget(
        MaterialApp(
          home: CustomerDispatchScreen(
            initialConfig: RegionConfig.globalDefault(),
            initialModeIndex: initialModeIndex,
            focusedTitle: focusedTitle,
            fareService: FareService(_FakeFareBackend()),
            initialPickupAddress: pickupAddress,
            initialPickupLatLng: pickupLatLng,
            initialDropoffAddress: dropoffAddress,
            initialDropoffLatLng: dropoffLatLng,
            // Secondary contact numbers (empty passes; valid ones ride along).
            initialPickupPhone: '08012345678',
            initialDropoffPhone: '08087654321',
            tripRepository: _FakeTripRepository(),
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    Future<void> tapNext(WidgetTester tester) async {
      // The Stepper builds one controls row per step and long content can
      // push the active row below the fold: scroll every enabled candidate
      // into view, then tap the one that is actually hit-testable.
      final all = find.widgetWithText(FilledButton, 'Next');
      for (var i = 0; i < all.evaluate().length; i++) {
        if (tester.widget<FilledButton>(all.at(i)).enabled) {
          await tester.ensureVisible(all.at(i));
          await tester.pumpAndSettle();
        }
      }
      final visible =
          find.widgetWithText(FilledButton, 'Next').hitTestable();
      for (var i = 0; i < visible.evaluate().length; i++) {
        if (tester.widget<FilledButton>(visible.at(i)).enabled) {
          await tester.tap(visible.at(i));
          await tester.pumpAndSettle();
          return;
        }
      }
      fail('No enabled Next button found');
    }

    testWidgets('Next stays disabled until drop-off resolves', (tester) async {
      await pumpBooking(
        tester,
        pickupAddress: 'Test Pickup, Lagos',
        pickupLatLng: pickupPos,
      );

      final nextBtn =
          find.widgetWithText(FilledButton, 'Next').first;
      expect(nextBtn, findsOneWidget);
      expect(tester.widget<FilledButton>(nextBtn).enabled, isFalse);

      // Selecting a resolvable destination enables Next (drop-off coords
      // lock only on explicit suggestion tap — typing alone resolves nothing).
      LocationService.customSuggestionsProvider = (_) async => [
        PlaceSuggestion(
          description: 'Ikeja City Mall, Lagos',
          lat: dropoffPos.latitude,
          lng: dropoffPos.longitude,
        ),
      ];
      await tester.enterText(
        find.widgetWithText(TextField, 'Where to?'),
        'Ikeja City Mall',
      );
      // Advance past the quiet 300 ms debounce (pumpAndSettle alone does
      // not wait out timers with no scheduled frames), then settle.
      await tester.pump(const Duration(milliseconds: 900));
      await tester.pumpAndSettle();

      // Suggestion appears but Next is still disabled until user taps it.
      expect(find.text('Ikeja City Mall, Lagos'), findsOneWidget);
      expect(tester.widget<FilledButton>(nextBtn).enabled, isFalse);

      await tester.tap(find.text('Ikeja City Mall, Lagos'));
      await tester.pumpAndSettle();

      expect(tester.widget<FilledButton>(nextBtn).enabled, isTrue);
    });

    testWidgets(
        'Package Delivery preselects Motorcycle (recommended) and broadcasts to server fares',
        (tester) async {
      await pumpBooking(
        tester,
        pickupAddress: 'Test Pickup, Lagos',
        pickupLatLng: pickupPos,
        dropoffAddress: 'Test Dropoff, Lagos',
        dropoffLatLng: dropoffPos,
      );

      // Step 1 shows the inline route map once both ends resolve.
      expect(find.text('Test Pickup, Lagos'), findsOneWidget);

      // Advance to vehicle selection (server fares load via fake backend).
      await tapNext(tester);

      // All 6 delivery vehicle types appear with server fares (incl. Car / Sedan per Fleet Scope Matrix).
      expect(find.text('Bicycle'), findsWidgets);
      expect(find.text('Tricycle (Keke)'), findsOneWidget);
      expect(find.text('Car / Sedan'), findsOneWidget);
      expect(find.text('Van'), findsOneWidget);
      expect(find.text('Truck'), findsOneWidget);
      expect(find.text('₦1,850.00'), findsWidgets);

      // Motorcycle is pre-selected and badged as recommended.
      expect(find.text('Recommended'), findsOneWidget);
      expect(find.text('1 selected'), findsOneWidget);

      // Opt into an additional larger category (scroll into view: the
      // taller route-map preview can push vehicle cards below the fold).
      await tester.ensureVisible(find.text('Bicycle'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Bicycle'));
      await tester.pumpAndSettle();
      expect(find.text('2 selected'), findsOneWidget);

      // Review step shows the server-authoritative fare table.
      await tapNext(tester);
      expect(find.text('Fare by Vehicle Type'), findsOneWidget);

      // Confirm & Broadcast books the trip. Bicycle is selected for a
      // 14.2 km trip, so the Smart Distance Warning appears first; confirming
      // anyway dispatches to the live tracker. The live banner spinner
      // animates forever, so use fixed pumps after tapping.
      final confirmBtn =
          find.widgetWithText(FilledButton, 'Confirm & Broadcast');
      await tester.ensureVisible(confirmBtn);
      await tester.pumpAndSettle();
      await tester.tap(confirmBtn);
      await tester.pumpAndSettle();

      expect(find.text('Long-Distance Warning'), findsOneWidget);
      await tester.tap(find.widgetWithText(TextButton, 'Confirm Anyway'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));

      expect(find.text('Live Trip'), findsOneWidget);
      expect(find.textContaining('Searching for nearby'), findsOneWidget);
      expect(find.text('Confirm & Broadcast'), findsNothing);
    });

    testWidgets('Ride-Hailing workflow shows ONLY Car / Sedan tiers',
        (tester) async {
      await pumpBooking(
        tester,
        initialModeIndex: 1,
        pickupAddress: 'Test Pickup, Lagos',
        pickupLatLng: pickupPos,
        dropoffAddress: 'Test Dropoff, Lagos',
        dropoffLatLng: dropoffPos,
      );

      await tapNext(tester);

      // Passenger Car Tiers are shown with server fares.
      expect(find.text('Passenger Car Tiers'), findsWidgets);
      expect(find.text('Standard / Comfort'), findsWidgets);
      expect(find.text('Executive / Premium'), findsOneWidget);
      expect(find.text('Luxe / Super'), findsOneWidget);
      expect(find.text('₦4,010.00'), findsWidgets);

      // Verify non-car delivery vehicles do NOT appear in ride hailing.
      expect(find.text('Bicycle'), findsNothing);
      expect(find.text('Motorcycle'), findsNothing);
      expect(find.text('Tricycle (Keke)'), findsNothing);
      expect(find.text('Van'), findsNothing);
      expect(find.text('Truck'), findsNothing);

      // Review + confirm the ride with the server fare.
      await tapNext(tester);
      expect(find.text('Fare Summary'), findsOneWidget);

      final confirmBtn =
          find.widgetWithText(FilledButton, 'Confirm & Book Ride');
      await tester.ensureVisible(confirmBtn);
      await tester.pumpAndSettle();
      await tester.tap(confirmBtn);
      // Confirm navigates directly to the live tracker (no intermediate
      // dialog); the live banner spinner animates forever, so use fixed
      // pumps after tapping.
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));

      expect(find.text('Live Trip'), findsOneWidget);
      expect(find.textContaining('Searching for nearby'), findsOneWidget);
      expect(find.text('Confirm & Book Ride'), findsNothing);
    });
  });

  group('Driver Fleet & Online Verification Shield', () {
    // The dashboard now renders a full-screen OSM map canvas: stub tiles
    // so widget tests never touch the network (same pattern as the
    // dispatch/map groups elsewhere in this file).
    setUp(() {
      OsmMapView.debugTileProviderOverride = BlankTileProvider();
    });

    tearDown(() {
      OsmMapView.debugTileProviderOverride = null;
    });

    testWidgets('Header pill shows pure GO ONLINE text (never vehicle details)',
        (tester) async {
      final service = DriverFleetService();

      await tester.pumpWidget(
        MaterialApp(
          home: DriverDashboardScreen(
            fleetService: service,
            driverId: 'unverified_driver',
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Exact label: no year/make/model/plate suffix is ever appended.
      expect(find.text('GO ONLINE'), findsOneWidget);
    });

    testWidgets(
        'Single approved vehicle goes online in 1 tap (snapshot modal skipped)',
        (tester) async {
      final approvedVeh = VehicleModel(
        id: 'solo_1',
        driverId: 'solo_driver',
        category: VehicleCategory.motorcycle,
        tier: RideTier.comfort,
        make: 'Bajaj',
        model: 'Pulsar 220',
        year: 2023,
        licensePlate: 'AGL874QM',
        color: 'Black',
        verificationStatus: VehicleVerificationStatus.approved,
        createdAt: DateTime.now(),
        updatedAt: DateTime.now(),
      );
      final service = _FixedFleetService([approvedVeh]);

      await tester.pumpWidget(
        MaterialApp(
          home: DriverDashboardScreen(
            fleetService: service,
            driverId: 'solo_driver',
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Pure label even with an active fleet.
      expect(find.text('GO ONLINE'), findsOneWidget);

      await tester.tap(find.byKey(const Key('power_toggle')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      await tester.pump(const Duration(milliseconds: 500));

      // The pre-online shield (vehicle select + live snapshot) is skipped:
      // no modal appears for a single-vehicle fleet. The tap flows straight
      // to the server handshake (which stays offline in tests, surfacing a
      // SnackBar instead of flipping online).
      expect(find.text('Pre-Online Security Shield'), findsNothing);
      expect(find.text('Live Vehicle & Plate Snapshot'), findsNothing);
    });
    testWidgets('Driver Dashboard blocks Go Online when no verified vehicles exist', (tester) async {
      // Mock service with no vehicles
      final emptyService = DriverFleetService();

      await tester.pumpWidget(
        MaterialApp(
          home: DriverDashboardScreen(
            fleetService: emptyService,
            driverId: 'unverified_driver',
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Driver is OFFLINE initially (compact GO ONLINE pill, no prompt)
      expect(find.textContaining('GO ONLINE'), findsOneWidget);

      // One tap goes online immediately — no confirmation sheet. With no
      // verified vehicles, the strict guard blocks access instead.
      await tester.tap(find.byKey(const Key('power_toggle')));
      await tester.pumpAndSettle();

      // Strict Verification Guard dialog should appear blocking access
      expect(find.text('Account Verification Required'), findsOneWidget);
      expect(
          find.textContaining(
              'drivers cannot go online or receive orders until vehicle registration and verification are complete'),
          findsOneWidget);
    });

    testWidgets('Driver with verified fleet undergoes pre-online vehicle selection & live snapshot', (tester) async {
      final service = DriverFleetService();
      // Register an approved vehicle
      final approvedVeh = VehicleModel(
        id: 'approved_1',
        driverId: 'test_driver',
        category: VehicleCategory.car,
        tier: RideTier.premium,
        make: 'Honda',
        model: 'Accord',
        year: 2017,
        licensePlate: 'ABC-999-ZZ',
        color: 'Blue',
        verificationStatus: VehicleVerificationStatus.approved,
        createdAt: DateTime.now(),
        updatedAt: DateTime.now(),
      );

      VehicleModel? verifiedSessionVehicle;

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: OnlineVerificationShieldModal(
              verifiedVehicles: [approvedVeh],
              fleetService: service,
              driverId: 'test_driver',
              captureOverride: () async =>
                  XFile('/tmp/test_verification_${DateTime.now().millisecondsSinceEpoch}.jpg'),
              onVerificationPassed: (veh) {
                verifiedSessionVehicle = veh;
              },
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Verify Pre-Online Security Shield modal is presented
      expect(find.text('Pre-Online Security Shield'), findsOneWidget);
      expect(find.textContaining('ABC-999-ZZ'), findsOneWidget);

      // Tap continue to live camera snapshot
      await tester.tap(find.text('Continue to Live Photo Verification'));
      await tester.pumpAndSettle();

      // Verify Live Vehicle & Plate Snapshot viewfinder is active
      expect(find.text('Live Vehicle & Plate Snapshot'), findsOneWidget);
      expect(find.textContaining('Strict Security Guard: Live camera capture only'), findsOneWidget);
      expect(find.text('LIVE SENSOR ACTIVE'), findsOneWidget);

      // Two-step flow: Capture -> Verify & Go Online (gallery never offered)
      await tester.tap(find.text('Capture Live Snapshot'));
      await tester.pump(); // Start camera intent
      await tester.pump(const Duration(milliseconds: 500));
      // pumpAndSettle would hang on the CircularProgressIndicator animation; use fixed pumps
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pump(const Duration(milliseconds: 100));

      // Synthetic capture in test env populates preview; now verify
      expect(find.text('Verify & Go Online'), findsOneWidget);
      await tester.tap(find.text('Verify & Go Online'));
      await tester.pump(); // Start upload overlay
      await tester.pump(const Duration(milliseconds: 200));
      // Allow async verification (Firestore offline + storage dummy) to complete and dialog to pop
      await tester.pump(const Duration(milliseconds: 500));
      await tester.pump(const Duration(milliseconds: 500));

      // Verification passed callback should have received the vehicle
      expect(verifiedSessionVehicle, isNotNull);
      expect(verifiedSessionVehicle!.licensePlate, 'ABC-999-ZZ');
    });

    testWidgets('DriverFleetScreen registers with strict validation and pending status', (tester) async {
      final service = DriverFleetService();

      Future<XFile> fakePick({required ImageSource source}) async =>
          XFile('/tmp/fake_upload.jpg');
      Future<String> fakeUpload(
              {required String docType, required String localPath}) async =>
          'https://example.com/$docType.jpg';

      await tester.pumpWidget(
        MaterialApp(
          home: DriverFleetScreen(
            fleetService: service,
            driverId: 'test_driver',
            pickImage: fakePick,
            uploadDocument: fakeUpload,
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('My Vehicle Fleet'), findsOneWidget);
      // The registration form lives behind the Add Vehicle action, not inline.
      expect(find.text('Register New Vehicle to Fleet'), findsNothing);

      await tester.tap(find.byKey(const Key('add_vehicle_fab')));
      await tester.pumpAndSettle();

      expect(find.text('Register New Vehicle to Fleet'), findsOneWidget);

      // Register CTA starts disabled: fields begin empty.
      final registerBtn =
          find.widgetWithText(FilledButton, 'Register Vehicle to Fleet');
      expect(tester.widget<FilledButton>(registerBtn).enabled, isFalse);

      // Fill make/model/year/color/plate via dropdowns.
      Future<void> pick(String field, String option) async {
        final dd = find.widgetWithText(
            DropdownButtonFormField<String>, field);
        await tester.ensureVisible(dd);
        await tester.tap(dd);
        await tester.pumpAndSettle();
        await tester.tap(find.text(option).last);
        await tester.pumpAndSettle();
      }

      await pick('Vehicle Make', 'Toyota');
      await pick('Vehicle Model', 'Corolla');
      await pick('Manufacture Year', '${DateTime.now().year}');
      await pick('Color', 'Silver');
      await tester.enterText(
        find.widgetWithText(TextField, 'License Plate Number'),
        'LAG-734-XY',
      );
      await tester.pumpAndSettle();

      // Auto-assigned tier preview appears once the year is valid.
      expect(
          find.textContaining('Auto-Assigned Ride-Hailing Tier'), findsOneWidget);

      // Upload every required slot via Camera (faked).
      for (final label in [
        'Vehicle License',
        'Insurance Certificate',
        'Front View',
        'Rear View',
        'Driver Side',
        'Passenger Side',
        'Interior / Dashboard',
      ]) {
        final chip =
            find.widgetWithText(ActionChip, 'Upload $label');
        await tester.ensureVisible(chip);
        await tester.tap(chip);
        await tester.pumpAndSettle();
        await tester.tap(find.text('Take Photo (Camera)'));
        await tester.pumpAndSettle();
        expect(find.text('$label (Attached)'), findsOneWidget);
      }

      // CTA enables; registering shows the Strict Verification Guard.
      expect(tester.widget<FilledButton>(registerBtn).enabled, isTrue);
      await tester.ensureVisible(registerBtn);
      await tester.tap(registerBtn);
      await tester.pumpAndSettle();

      expect(find.text('Vehicle Registered'), findsOneWidget);
      expect(find.textContaining('PENDING VERIFICATION'), findsOneWidget);
    });
  });

  group('Send / Receive auto-location mapping', () {
    // Agbede, Ikorodu stand-in for the recipient's GPS fix.
    const gpsPos = LatLng(6.6123, 3.1234);
    const gpsAddress = 'Agbede, Ikorodu, Lagos';

    setUp(() {
      OsmMapView.debugTileProviderOverride = BlankTileProvider();
      LocationService.customPositionProvider = () async => gpsPos;
      LocationService.customReverseGeocodeProvider =
          (_, _) async => gpsAddress;
      LocationService.customRouteProvider =
          (pickup, dropoff) async => [pickup, dropoff];
      LocationService.customSearchProvider = (_) async => null;
    });

    tearDown(() {
      OsmMapView.debugTileProviderOverride = null;
      LocationService.resetTestSeams();
    });

    Future<void> pumpFlow(WidgetTester tester, String title) async {
      await tester.pumpWidget(
        MaterialApp(
          home: CustomerDispatchScreen(
            initialConfig: RegionConfig.globalDefault(),
            initialModeIndex: 0, // delivery
            showModeSelector: false,
            focusedTitle: title,
            fareService: FareService(_FakeFareBackend()),
            initialPickupPhone: '08012345678',
            initialDropoffPhone: '08087654321',
            tripRepository: _FakeTripRepository(),
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    TextField fieldByLabel(WidgetTester tester, String label) =>
        tester.widget<TextField>(find.widgetWithText(TextField, label));

    testWidgets(
        'Receive Item maps GPS fix to drop-off, leaves pickup empty and focused',
        (tester) async {
      await pumpFlow(tester, 'Receive Item');

      // Recipient's location is the delivery destination; pickup is unknown.
      expect(
        fieldByLabel(tester, 'Destination / Drop-off').controller?.text,
        gpsAddress,
      );
      expect(
        fieldByLabel(tester, 'Pickup Location').controller?.text,
        isEmpty,
      );

      // Pickup is focused so the keyboard is ready for the pickup address.
      expect(
        fieldByLabel(tester, 'Pickup Location').focusNode?.hasFocus,
        isTrue,
      );

      // The Sending/Receiving toggle highlights Receiving Package.
      final toggle = tester.widget<SegmentedButton<bool>>(
        find.byWidgetPredicate((w) => w is SegmentedButton<bool>),
      );
      expect(toggle.selected, {true});
    });

    testWidgets('Send Item maps GPS fix to pickup and focuses drop-off',
        (tester) async {
      await pumpFlow(tester, 'Send Item');

      expect(
        fieldByLabel(tester, 'Pickup Location').controller?.text,
        gpsAddress,
      );
      expect(
        fieldByLabel(tester, 'Destination / Drop-off').controller?.text,
        isEmpty,
      );

      expect(
        fieldByLabel(tester, 'Destination / Drop-off').focusNode?.hasFocus,
        isTrue,
      );
    });
  });
}
