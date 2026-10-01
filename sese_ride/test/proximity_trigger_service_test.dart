import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:geolocator/geolocator.dart';
import 'package:sese_ride/features/driver/services/driver_streak_service.dart';
import 'package:sese_ride/features/driver/services/proximity_trigger_service.dart';
import 'package:sese_ride/features/trips/models/trip_models.dart';

/// Records heartbeat callables instead of hitting Cloud Functions.
class _RecordingStreakService extends DriverStreakService {
  int heartbeatCalls = 0;
  bool lastIsMocked = false;

  @override
  Future<void> reportDriverLocation({
    required String tripId,
    required double lat,
    required double lng,
    required bool isMocked,
  }) async {
    heartbeatCalls++;
    lastIsMocked = isMocked;
  }
}

Position _fix(double lat, double lng, {bool mocked = false}) => Position(
      latitude: lat,
      longitude: lng,
      timestamp: DateTime.now(),
      accuracy: 5,
      altitude: 0,
      altitudeAccuracy: 0,
      heading: 0,
      headingAccuracy: 0,
      speed: 0,
      speedAccuracy: 0,
      isMocked: mocked,
    );

ActiveTrip _trip({
  TripStatus status = TripStatus.driverArriving,
  String paymentMethod = 'cash',
}) =>
    ActiveTrip(
      tripId: 'trip-1',
      status: status,
      customerId: 'cust-1',
      pickupLat: 6.5244,
      pickupLng: 3.3792,
      dropoffLat: 6.6018,
      dropoffLng: 3.3515,
      fareAmount: 2500,
      paymentMethod: paymentMethod,
    );

void main() {
  group('haversineM', () {
    test('equator degree is ~111km', () {
      final m = ProximityTriggerService.haversineM(0, 0, 0, 1);
      expect(m, closeTo(111195, 500));
    });

    test('same point is zero', () {
      expect(ProximityTriggerService.haversineM(6.5, 3.3, 6.5, 3.3), 0);
    });
  });

  group('isPrepaidTrip', () {
    test('prepaid rails auto-start eligible', () {
      for (final method in ['prepaid', 'wallet', 'card', 'paystack', 'online']) {
        expect(_trip(paymentMethod: method).isPrepaidTrip, isTrue,
            reason: method);
      }
    });

    test('cash/split/unknown blocked', () {
      for (final method in ['cash', 'split', '', 'bank-transfer']) {
        expect(_trip(paymentMethod: method).isPrepaidTrip, isFalse,
            reason: method);
      }
    });
  });

  group('auto-arrival countdown', () {
    test('fires onArrive after 5s inside 500m', () async {
      final fixes = StreamController<Position>();
      addTearDown(fixes.close);
      final backend = _RecordingStreakService();
      var arrived = false;
      final svc = ProximityTriggerService(
        arrivalCountdown: const Duration(milliseconds: 60),
        heartbeatInterval: const Duration(hours: 1),
        routeRefineGateM: 0, // haversine only (no OSRM in unit tests)
        positionStreamFactory: () => fixes.stream,
        onArrive: () => arrived = true,
      );
      addTearDown(svc.dispose);
      svc.start(
        trip: _trip(),
        streakService: backend,
      );
      // ~70m from pickup — inside the 100m–500m trigger band.
      fixes.add(_fix(6.5249, 3.3797));
      await Future.delayed(const Duration(milliseconds: 200));
      expect(arrived, isTrue);
    });

    test('leaving the zone cancels the countdown', () async {
      final fixes = StreamController<Position>();
      addTearDown(fixes.close);
      final backend = _RecordingStreakService();
      var arrived = false;
      final svc = ProximityTriggerService(
        arrivalCountdown: const Duration(milliseconds: 150),
        heartbeatInterval: const Duration(hours: 1),
        routeRefineGateM: 0,
        positionStreamFactory: () => fixes.stream,
        onArrive: () => arrived = true,
      );
      addTearDown(svc.dispose);
      svc.start(
        trip: _trip(),
        streakService: backend,
      );
      fixes.add(_fix(6.5249, 3.3797));
      await Future.delayed(const Duration(milliseconds: 30));
      // Drive 5km away before expiry.
      fixes.add(_fix(6.57, 3.42));
      await Future.delayed(const Duration(milliseconds: 250));
      expect(arrived, isFalse);
    });
  });

  group('departure protection', () {
    test('prepaid trip auto-starts past 500m', () async {
      final fixes = StreamController<Position>();
      addTearDown(fixes.close);
      final backend = _RecordingStreakService();
      var started = false;
      var blocked = false;
      final svc = ProximityTriggerService(
        heartbeatInterval: const Duration(hours: 1),
        routeRefineGateM: 0,
        positionStreamFactory: () => fixes.stream,
        onAutoStart: () => started = true,
        onPaymentBlock: () => blocked = true,
      );
      addTearDown(svc.dispose);
      svc.start(
        trip: _trip(
            status: TripStatus.driverArrived, paymentMethod: 'wallet'),
        streakService: backend,
      );
      fixes.add(_fix(6.53, 3.385)); // ~1.2km from pickup
      await Future.delayed(const Duration(milliseconds: 150));
      expect(started, isTrue);
      expect(blocked, isFalse);
    });

    test('cash trip blocks with payment gate', () async {
      final fixes = StreamController<Position>();
      addTearDown(fixes.close);
      final backend = _RecordingStreakService();
      var started = false;
      var blocked = false;
      final svc = ProximityTriggerService(
        heartbeatInterval: const Duration(hours: 1),
        routeRefineGateM: 0,
        positionStreamFactory: () => fixes.stream,
        onAutoStart: () => started = true,
        onPaymentBlock: () => blocked = true,
      );
      addTearDown(svc.dispose);
      svc.start(
        trip: _trip(status: TripStatus.driverArrived, paymentMethod: 'cash'),
        streakService: backend,
      );
      fixes.add(_fix(6.53, 3.385));
      await Future.delayed(const Duration(milliseconds: 150));
      expect(started, isFalse);
      expect(blocked, isTrue);
    });
  });

  group('mock location guard', () {
    test('spoofed fixes flagged and never sent as heartbeat', () async {
      final fixes = StreamController<Position>();
      addTearDown(fixes.close);
      final backend = _RecordingStreakService();
      final svc = ProximityTriggerService(
        heartbeatInterval: const Duration(milliseconds: 50),
        routeRefineGateM: 0,
        positionStreamFactory: () => fixes.stream,
      );
      addTearDown(svc.dispose);
      svc.start(
        trip: _trip(),
        streakService: backend,
      );
      fixes.add(_fix(6.5249, 3.3797, mocked: true));
      await Future.delayed(const Duration(milliseconds: 200));
      expect(svc.mockDetected, isTrue);
      expect(svc.latest?.isMocked, isTrue);
      expect(backend.heartbeatCalls, 0);
    });
  });
}
