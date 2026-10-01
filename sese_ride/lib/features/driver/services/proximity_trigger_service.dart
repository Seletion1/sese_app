import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:geolocator/geolocator.dart';
import 'package:latlong2/latlong.dart';

import '../../customer/services/location_service.dart';
import '../../trips/models/trip_models.dart';
import 'driver_streak_service.dart';

/// Live proximity zone of the driver relative to the trip pickup.
enum ProximityZone {
  /// Outside all trigger radii.
  approaching,

  /// Inside the arrival radius; the 5s auto-arrival countdown is running.
  arrivalCountdown,

  /// Trip is arrived and the driver left the pickup area (departed).
  departed,
}

/// Snapshot emitted on every evaluated position fix.
class ProximityUpdate {
  /// Best-estimate road-aware distance to pickup in meters.
  final double distanceM;

  /// Whether this fix came from a mocked provider (GPS spoofing).
  final bool isMocked;

  final ProximityZone zone;

  const ProximityUpdate({
    required this.distanceM,
    required this.isMocked,
    required this.zone,
  });
}

/// Live proximity triggers for an assigned trip (auto-arrival +
/// departure protection) with telemetry mock-location guarding.
///
/// Distance math is live on every GPS fix:
/// - Primary: haversine great-circle distance to the pickup.
/// - Refined: OSRM route polyline (`LocationService.fetchRoutePolyline`
///   driver → pickup, remaining road distance along the polyline) whenever
///   the driver is within 2km and the cached route is older than 30s —
///   so triggers follow roads, not straight vectors.
///
/// Triggers:
/// - Auto-arrival (100m–500m): entering the 500m arrival radius starts a
///   5s countdown ("Auto-arriving at pickup..."); leaving cancels it.
///   Expiry fires [onArrive] (caller advances to DRIVER_ARRIVED).
/// - Departure protection (500m–1km): once arrived, leaving 500m+ from
///   pickup fires [onAutoStart] for pre-paid trips ([ActiveTrip.isPrepaidTrip])
///   or [onPaymentBlock] for cash/split/unknown trips (caller sirens +
///   asks payment confirmation; only an explicit confirm may start).
///
/// Mock Location Guard: fixes with `isMocked == true` are flagged
/// ([ProximityUpdate.isMocked], [mockDetected]) and never sent as
/// heartbeats — the server `updateDriverLocation` callable rejects mocked
/// fixes independently, so spoofed telemetry cannot move the trip.
class ProximityTriggerService {
  /// Radius (m) that arms the auto-arrival countdown.
  final double arrivalRadiusM;

  /// Distance (m) from pickup that counts as departed (500m–1km band).
  final double departureRadiusM;

  /// Auto-arrival countdown length.
  final Duration arrivalCountdown;

  /// Heartbeat throttle for `updateDriverLocation`.
  final Duration heartbeatInterval;

  /// OSRM route refresh throttle / refine gate.
  final Duration routeRefreshInterval;
  final double routeRefineGateM;

  /// Test seam: inject a fake position stream. Defaults to the device GPS.
  final Stream<Position> Function()? positionStreamFactory;

  final void Function()? onArrive;
  final void Function()? onAutoStart;
  final void Function()? onPaymentBlock;

  StreamSubscription<Position>? _sub;
  Timer? _arrivalTimer;
  Timer? _heartbeatTimer;
  Position? _lastFix;
  List<LatLng>? _cachedRoute;
  DateTime? _routeFetchedAt;
  TripStatus? _tripStatus;
  ActiveTrip? _trip;
  bool _arriveFired = false;
  bool _departFired = false;
  bool _disposed = false;

  final _updates = StreamController<ProximityUpdate>.broadcast();
  ProximityUpdate? _latest;

  ProximityTriggerService({
    this.arrivalRadiusM = 500,
    this.departureRadiusM = 500,
    this.arrivalCountdown = const Duration(seconds: 5),
    this.heartbeatInterval = const Duration(seconds: 10),
    this.routeRefreshInterval = const Duration(seconds: 30),
    this.routeRefineGateM = 2000,
    this.positionStreamFactory,
    this.onArrive,
    this.onAutoStart,
    this.onPaymentBlock,
  });

  /// Latest evaluated snapshot (null before the first fix).
  ProximityUpdate? get latest => _latest;

  /// True once any mocked fix has been observed.
  bool get mockDetected => _mockSeen;
  bool _mockSeen = false;

  /// True while the 5s auto-arrival countdown is ticking.
  bool get countdownActive => _arrivalTimer?.isActive == true;

  Stream<ProximityUpdate> get updates => _updates.stream;

  /// Great-circle distance in meters (pure, unit-testable).
  static double haversineM(
      double lat1, double lng1, double lat2, double lng2) {
    const r = 6371000.0;
    double rad(double d) => d * math.pi / 180;
    final dLat = rad(lat2 - lat1);
    final dLng = rad(lng2 - lng1);
    final a = math.sin(dLat / 2) * math.sin(dLat / 2) +
        math.cos(rad(lat1)) *
            math.cos(rad(lat2)) *
            math.sin(dLng / 2) *
            math.sin(dLng / 2);
    final c = 2 * math.atan2(math.sqrt(a), math.sqrt(1 - a));
    return r * c;
  }

  /// Starts tracking [trip]: position stream + heartbeats + triggers.
  /// Safe to call once; [stop] first to retarget.
  void start({
    required ActiveTrip trip,
    required DriverStreakService streakService,
  }) {
    _trip = trip;
    _tripStatus = trip.status;
    final pickup = LatLng(trip.pickupLat, trip.pickupLng);
    Stream<Position> stream;
    try {
      stream = positionStreamFactory != null
          ? positionStreamFactory!.call()
          : Geolocator.getPositionStream();
    } catch (e) {
      debugPrint('ProximityTriggerService: no position stream: $e');
      return;
    }
    _sub = stream.listen(
      (fix) => _onFix(fix, pickup, trip.tripId, streakService),
      onError: (Object e) =>
          debugPrint('ProximityTriggerService position error: $e'),
    );
    // Heartbeat timer is armed lazily on the first real fix
    // (_ensureHeartbeat): no position ever means nothing to report, and
    // this keeps widget tests (no GPS) free of pending timers.
  }

  /// Keeps trigger gating in sync with the trip snapshot (call on rebuild).
  void noteTrip(ActiveTrip trip) {
    final wasArrived = _tripStatus == TripStatus.driverArrived;
    _trip = trip;
    _tripStatus = trip.status;
    // Reset departure firing if the trip left the arrived state.
    if (wasArrived && trip.status != TripStatus.driverArrived) {
      _departFired = false;
    }
  }

  Future<void> _onFix(
    Position fix,
    LatLng pickup,
    String tripId,
    DriverStreakService streakService,
  ) async {
    if (_disposed) return;
    _lastFix = fix;
    if (fix.isMocked) {
      _mockSeen = true;
      _emit(ProximityUpdate(
        distanceM: _latest?.distanceM ?? double.infinity,
        isMocked: true,
        zone: _latest?.zone ?? ProximityZone.approaching,
      ));
      // Withhold the heartbeat: spoofed fixes must never move the trip.
      // The server callable rejects mocked fixes independently.
      return;
    }
    _ensureHeartbeat(streakService);
    var distanceM = haversineM(
        fix.latitude, fix.longitude, pickup.latitude, pickup.longitude);
    final refined = await _refinedDistanceM(fix, pickup);
    if (refined != null) distanceM = refined;

    final status = _tripStatus;
    var zone = ProximityZone.approaching;
    if (status == TripStatus.driverAccepted ||
        status == TripStatus.driverArriving) {
      if (distanceM <= arrivalRadiusM) {
        zone = ProximityZone.arrivalCountdown;
        _armArrivalCountdown();
      } else {
        _cancelArrivalCountdown();
      }
    } else {
      _cancelArrivalCountdown();
    }

    if (status == TripStatus.driverArrived &&
        distanceM >= departureRadiusM &&
        !_departFired) {
      _departFired = true;
      zone = ProximityZone.departed;
      final prepaid = _trip?.isPrepaidTrip ?? false;
      if (prepaid) {
        onAutoStart?.call();
      } else {
        onPaymentBlock?.call();
      }
    }
    _emit(ProximityUpdate(
        distanceM: distanceM, isMocked: false, zone: zone));
  }

  /// OSRM refinement: remaining road distance along the driver→pickup
  /// route polyline. Cached 30s; haversine stands in on any failure.
  Future<double?> _refinedDistanceM(Position fix, LatLng pickup) async {
    try {
      final crowM = haversineM(
          fix.latitude, fix.longitude, pickup.latitude, pickup.longitude);
      if (crowM > routeRefineGateM) return null;
      final now = DateTime.now();
      final stale = _routeFetchedAt == null ||
          now.difference(_routeFetchedAt!) > routeRefreshInterval;
      if (stale || _cachedRoute == null) {
        final points = await LocationService.fetchRoutePolyline(
          LatLng(fix.latitude, fix.longitude),
          pickup,
        ).timeout(const Duration(seconds: 10));
        if (points.length >= 2) {
          _cachedRoute = points;
          _routeFetchedAt = now;
        }
      }
      final route = _cachedRoute;
      if (route == null || route.length < 2) return null;
      double total = 0;
      for (var i = 0; i < route.length - 1; i++) {
        total += haversineM(route[i].latitude, route[i].longitude,
            route[i + 1].latitude, route[i + 1].longitude);
      }
      return total;
    } catch (_) {
      return null;
    }
  }

  void _armArrivalCountdown() {
    if (_arriveFired || countdownActive) return;
    _arrivalTimer = Timer(arrivalCountdown, () {
      if (_disposed || _arriveFired) return;
      _arriveFired = true;
      onArrive?.call();
    });
  }

  void _cancelArrivalCountdown() {
    _arrivalTimer?.cancel();
    _arrivalTimer = null;
  }

  void _ensureHeartbeat(DriverStreakService streakService) {
    _heartbeatTimer ??= Timer.periodic(
        heartbeatInterval, (_) => _sendHeartbeat(streakService));
  }

  Future<void> _sendHeartbeat(DriverStreakService streakService) async {
    final fix = _lastFix;
    final trip = _trip;
    if (_disposed || fix == null || trip == null || fix.isMocked) return;
    try {
      await streakService.reportDriverLocation(
        tripId: trip.tripId,
        lat: fix.latitude,
        lng: fix.longitude,
        isMocked: false,
      );
    } catch (_) {
      // Best-effort: the next tick retries; audio/UI never blocks.
    }
  }

  void _emit(ProximityUpdate update) {
    _latest = update;
    if (!_updates.isClosed) _updates.add(update);
  }

  Future<void> stop() async {
    _cancelArrivalCountdown();
    _heartbeatTimer?.cancel();
    _heartbeatTimer = null;
    await _sub?.cancel();
    _sub = null;
  }

  Future<void> dispose() async {
    _disposed = true;
    await stop();
    await _updates.close();
  }
}
