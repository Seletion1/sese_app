import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:sese_ride/features/customer/services/location_service.dart';
import 'package:sese_ride/features/driver/presentation/widgets/driver_active_trip_card.dart';
import 'package:sese_ride/features/driver/services/driver_streak_service.dart';
import 'package:sese_ride/features/trips/models/trip_models.dart';
import 'package:sese_ride/widgets/osm_map_view.dart';

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
  group('Navigation Telemetry & Turn-by-Turn Dynamic Guidance Tests', () {
    test('LocationService.calculateRemainingRouteDistanceM calculates true polyline distance', () {
      final route = [
        const LatLng(6.5244, 3.3792), // Point 1
        const LatLng(6.5300, 3.3792), // Point 2 (North ~620m)
        const LatLng(6.5300, 3.3850), // Point 3 (East ~640m)
      ];

      final dist = LocationService.calculateRemainingRouteDistanceM(
        const LatLng(6.5244, 3.3792),
        route,
      );

      // Distance should be ~1260m (not straight line ~890m)
      expect(dist, greaterThan(1100));
      expect(dist, lessThan(1400));
    });

    test('RouteStep.formatDynamicInstruction outputs precise turn guidance and distance thresholds', () {
      const stepRight = RouteStep(
        location: LatLng(6.5300, 3.3792),
        instruction: 'Turn right onto Broad St',
        maneuverType: 'turn',
        maneuverModifier: 'right',
      );

      // Dist > 25m: "In 150m, turn right onto Broad St"
      final dynamic150 = stepRight.formatDynamicInstruction(150);
      expect(dynamic150, equals('In 150m, turn right onto Broad St'));

      // Dist > 1km: "In 1.5km, turn right onto Broad St"
      final dynamic1500 = stepRight.formatDynamicInstruction(1500);
      expect(dynamic1500, equals('In 1.5km, turn right onto Broad St'));

      // Dist < 25m: "Turn right onto Broad St" (immediate action)
      final immediate = stepRight.formatDynamicInstruction(18);
      expect(immediate, equals('Turn right onto Broad St'));

      const stepArrive = RouteStep(
        location: LatLng(6.5400, 3.3800),
        instruction: 'Arrive at destination',
        maneuverType: 'arrive',
      );

      // Arrive distance > 30m
      expect(stepArrive.formatDynamicInstruction(200), equals('In 200m, arrive at destination'));

      // Arrive distance < 30m
      expect(stepArrive.formatDynamicInstruction(15), equals('Arriving at destination'));
    });

    test('SeSeMapController.computeBottomCenterTarget shifts target northward to lock driver at bottom-center', () {
      const driverPos = LatLng(6.5244, 3.3792);
      final offsetTarget = SeSeMapController.computeBottomCenterTarget(driverPos, 17.0);

      // Target latitude must be greater than driver latitude (shifts viewpoint north, driver renders at bottom-center)
      expect(offsetTarget.latitude, greaterThan(driverPos.latitude));
      expect(offsetTarget.longitude, closeTo(driverPos.longitude, 0.00001));
    });

    test('SeSeMapController.computeBottomCenterTarget shifts target ahead along dynamic travel bearing', () {
      const driverPos = LatLng(6.5244, 3.3792);

      // East heading (90 degrees): camera center shifts eastward
      final eastTarget = SeSeMapController.computeBottomCenterTarget(driverPos, 17.0, bearing: 90.0);
      expect(eastTarget.longitude, greaterThan(driverPos.longitude));
      expect(eastTarget.latitude, closeTo(driverPos.latitude, 0.0001));

      // South heading (180 degrees): camera center shifts southward
      final southTarget = SeSeMapController.computeBottomCenterTarget(driverPos, 17.0, bearing: 180.0);
      expect(southTarget.latitude, lessThan(driverPos.latitude));
      expect(southTarget.longitude, closeTo(driverPos.longitude, 0.0001));

      // West heading (270 degrees): camera center shifts westward
      final westTarget = SeSeMapController.computeBottomCenterTarget(driverPos, 17.0, bearing: 270.0);
      expect(westTarget.longitude, lessThan(driverPos.longitude));
      expect(westTarget.latitude, closeTo(driverPos.latitude, 0.0001));
    });

    test('LocationService.calculateBearing accurately resolves cardinal directions', () {
      const origin = LatLng(6.5244, 3.3792);
      const northPoint = LatLng(6.5344, 3.3792);
      const eastPoint = LatLng(6.5244, 3.3892);
      const southPoint = LatLng(6.5144, 3.3792);
      const westPoint = LatLng(6.5244, 3.3692);

      expect(LocationService.calculateBearing(origin, northPoint), closeTo(0.0, 1.0));
      expect(LocationService.calculateBearing(origin, eastPoint), closeTo(90.0, 1.0));
      expect(LocationService.calculateBearing(origin, southPoint), closeTo(180.0, 1.0));
      expect(LocationService.calculateBearing(origin, westPoint), closeTo(270.0, 1.0));
    });

    test('Speedometer GPS speed conversion correctly converts m/s to km/h', () {
      const speedMps = 13.8889; // ~50 km/h
      final speedKmh = (speedMps * 3.6).round();
      expect(speedKmh, equals(50));

      const stationaryMps = 0.0;
      final stationaryKmh = (stationaryMps * 3.6).round();
      expect(stationaryKmh, equals(0));
    });

    testWidgets('DriverActiveTripCard renders live route telemetry HUD in collapsed strip',
        (tester) async {
      final mockStreak = _MockStreakService();

      final activeTrip = ActiveTrip(
        tripId: 'trip_nav_live_1',
        status: TripStatus.inProgress,
        customerId: 'cust_live',
        customerName: 'Micheal Bamiduro',
        customerPhone: '+2348012345678',
        pickupAddress: 'Pickup Spot',
        dropoffAddress: '5 Ikosi Road, Ketu',
        dropoffLat: 6.6000,
        dropoffLng: 3.3800,
        fareAmount: 4000,
        serviceType: 'motorcycle',
      );

      final routePoints = [
        const LatLng(6.5800, 3.3800),
        const LatLng(6.5900, 3.3800),
        const LatLng(6.6000, 3.3800),
      ];

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: DriverActiveTripCard(
              trip: activeTrip,
              streakService: mockStreak,
              driverPosition: const LatLng(6.5800, 3.3800),
              routePoints: routePoints,
              currentSpeedKmh: 45.0,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Verify "Trip in progress" title is rendered
      expect(find.text('Trip in progress'), findsOneWidget);

      // Verify "Head toward destination address" subtitle is rendered
      expect(find.text('Head toward destination address'), findsOneWidget);

      // Verify telemetry strip is rendered with live metrics
      expect(find.byKey(const Key('hud_bottom_telemetry_strip')), findsOneWidget);

      // Verify distance label format e.g. "km" or "m"
      expect(find.textContaining('km'), findsWidgets);

      // Verify duration format e.g. "min"
      expect(find.textContaining('min'), findsWidgets);
    });
  });
}
