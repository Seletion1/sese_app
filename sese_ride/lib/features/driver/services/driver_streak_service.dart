import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:flutter/foundation.dart';
import 'package:sese_core/sese_core.dart';

import '../../trips/models/trip_models.dart';

/// Thrown when a driver trip action (accept/decline/arrive/cancel) fails.
/// Always carries a [userMessage] safe to show in a SnackBar.
class DriverStreakException implements Exception {
  final String code;
  final String userMessage;

  const DriverStreakException(this.code, this.userMessage);

  @override
  String toString() => 'DriverStreakException($code): $userMessage';
}

/// Transport seam for driver trip-action callables (unit-testable).
abstract class DriverStreakBackend {
  Future<Map<String, dynamic>> callAcceptTrip(String tripId);
  Future<Map<String, dynamic>> callDeclineTrip(String tripId);
  Future<Map<String, dynamic>> callAdvanceTripStatus(
    String tripId,
    String status,
  );
  Future<Map<String, dynamic>> callCancelTrip(String tripId);
  Future<Map<String, dynamic>> callVerifyDeliveryPin(
    String tripId,
    String pin,
  );
  Future<Map<String, dynamic>> callReportDriverLocation(
    String tripId,
    double lat,
    double lng,
    bool isMocked,
  );
}

class _FunctionsDriverStreakBackend implements DriverStreakBackend {
  FirebaseFunctions get _fn => FirebaseFunctions.instance;

  Future<Map<String, dynamic>> _call(
    String name,
    Map<String, dynamic> data,
  ) async {
    final result = await _fn.httpsCallable(name).call(data);
    final raw = result.data;
    if (raw is Map) return Map<String, dynamic>.from(raw);
    return const {};
  }

  @override
  Future<Map<String, dynamic>> callAcceptTrip(String tripId) =>
      _call('acceptTrip', {'tripId': tripId});

  @override
  Future<Map<String, dynamic>> callDeclineTrip(String tripId) =>
      _call('declineTrip', {'tripId': tripId});

  @override
  Future<Map<String, dynamic>> callAdvanceTripStatus(
    String tripId,
    String status,
  ) => _call('advanceTripStatus', {'tripId': tripId, 'status': status});

  @override
  Future<Map<String, dynamic>> callCancelTrip(String tripId) =>
      _call('cancelTrip', {'tripId': tripId});

  @override
  Future<Map<String, dynamic>> callVerifyDeliveryPin(
    String tripId,
    String pin,
  ) =>
      _call('verifyDeliveryPin', {'tripId': tripId, 'pin': pin});

  @override
  Future<Map<String, dynamic>> callReportDriverLocation(
    String tripId,
    double lat,
    double lng,
    bool isMocked,
  ) =>
      _call('updateDriverLocation', {
        'tripId': tripId,
        'lat': lat,
        'lng': lng,
        'isMocked': isMocked,
      });
}

/// Live data + actions for the Daily Commission Streak system.
///
/// - Streams come from Firestore (`driver_streaks/{driverId}`, `trips`
///   pings/assignments, `system_configs/global_default`).
/// - Mutations go through the server-authoritative callables in
///   functions/src/trips.ts; the client never writes streak state.
/// - Constructing this service never touches Firebase (lazy getters only).
class DriverStreakService {
  final FirebaseFirestore? _firestore;
  final DriverStreakBackend? _backend;

  DriverStreakService({this._firestore, this._backend});

  FirebaseFirestore? get _db {
    try {
      return _firestore ?? FirebaseFirestore.instance;
    } catch (_) {
      return null;
    }
  }

  DriverStreakBackend get _ops => _backend ?? _FunctionsDriverStreakBackend();

  /// Real-time streak card for [driverId]. Emits a default (inactive-safe)
  /// state when Firestore is unavailable so widgets keep rendering.
  ///
  /// A denied listen (signed out, or [driverId] is not the current user —
  /// `driver_streaks` is owner-read-only) resolves to the default state and
  /// ENDS the stream instead of retrying forever, so the device log and
  /// battery are spared the permission-denied hot loop.
  Stream<DriverStreakState> streakStream(String driverId) {
    final fallback = DriverStreakState(driverId: driverId);
    final db = _db;
    if (db == null || driverId.isEmpty) {
      return Stream.value(fallback);
    }
    return db
        .collection('driver_streaks')
        .doc(driverId)
        .snapshots()
        .map(
          (doc) => DriverStreakState.fromMap(driverId, doc.data() ?? const {}),
        )
        .handleError((Object _) => fallback);
  }

  /// Tier 1 exclusive ping for [driverId].
  ///
  /// Single-field query (the WAITING status is filtered client-side) so no
  /// composite index is required. A denied listen resolves to null and
  /// ends instead of retrying forever.
  Stream<ActiveTrip?> pingStream(String driverId) {
    final db = _db;
    if (db == null || driverId.isEmpty) return Stream.value(null);
    return db
        .collection('trips')
        .where('pingDriverId', isEqualTo: driverId)
        .limit(5)
        .snapshots()
        .map((snap) {
          for (final d in snap.docs) {
            final trip = ActiveTrip.fromMap(d.id, d.data());
            if (trip.status == TripStatus.waitingForAcceptance) return trip;
          }
          return null;
        })
        .handleError((Object _) => null);
  }

  /// Tier 2 simultaneous pings for [driverId]. Single-field
  /// array-contains query (the WAITING status is filtered client-side, same
  /// as [pingStream]) so no composite index is required. Denied reads end
  /// as empty.
  Stream<List<ActiveTrip>> tier2PingStream(String driverId) {
    final db = _db;
    if (db == null || driverId.isEmpty) {
      return Stream.value(const <ActiveTrip>[]);
    }
    return db
        .collection('trips')
        .where('pingDriverIds', arrayContains: driverId)
        .limit(10)
        .snapshots()
        .map(
          (snap) => snap.docs
              .map((d) => ActiveTrip.fromMap(d.id, d.data()))
              .where((t) => t.status == TripStatus.waitingForAcceptance)
              .toList(),
        )
        .handleError((Object _) => const <ActiveTrip>[]);
  }

  /// Tier 3 marketplace broadcast (open to all nearby online drivers).
  ///
  /// Covers BOTH pool statuses so Stage 3 orders render no matter which
  /// marker the dispatcher wrote: `MARKETPLACE_OPEN` (broadcast) and
  /// `MARKETPLACE_LIST` (ignored / rejected / timed-out orders recycled
  /// into the 3km–5km outer-radius pool). Single-field `whereIn` — no
  /// composite index required. Denied reads end as empty.
  Stream<List<ActiveTrip>> marketplaceStream({int limit = 20}) {
    final db = _db;
    if (db == null) return Stream.value(const <ActiveTrip>[]);
    return db
        .collection('trips')
        .where(
          'status',
          whereIn: const ['MARKETPLACE_OPEN', 'MARKETPLACE_LIST'],
        )
        .limit(limit)
        .snapshots()
        .map(
          (snap) =>
              snap.docs.map((d) => ActiveTrip.fromMap(d.id, d.data())).toList(),
        )
        .handleError((Object _) => const <ActiveTrip>[]);
  }

  /// Driver's currently assigned live trip, if any. Single-field query on
  /// the nested driver id with client-side live filtering (no composite
  /// index required). A denied listen resolves to null and ends instead
  /// of retrying forever.
  Stream<ActiveTrip?> activeTripStream(String driverId) {
    final db = _db;
    if (db == null || driverId.isEmpty) return Stream.value(null);
    return db
        .collection('trips')
        .where('driver.driverId', isEqualTo: driverId)
        .limit(10)
        .snapshots()
        .map((snap) {
          for (final d in snap.docs) {
            final trip = ActiveTrip.fromMap(d.id, d.data());
            if (trip.isLive) return trip;
          }
          return null;
        })
        .handleError((Object _) => null);
  }

  /// Platform streak tunables (wait threshold, grand award). Falls back to
  /// model defaults when Firestore is unavailable. A denied listen (e.g.
  /// signed out — `system_configs` requires authentication) resolves to
  /// defaults and ends instead of retrying forever.
  Stream<DailyStreakConfig> streakConfigStream() {
    const fallback = DailyStreakConfig();
    final db = _db;
    if (db == null) {
      return Stream.value(fallback);
    }
    return db
        .collection('system_configs')
        .doc('global_default')
        .snapshots()
        .map(
          (doc) => DailyStreakConfig.fromMap(
            (doc.data()?['dailyStreakConfig'] as Map<String, dynamic>?),
          ),
        )
        .handleError((Object _) => fallback);
  }

  Future<void> acceptTrip(String tripId) =>
      _guard(() => _ops.callAcceptTrip(tripId));

  /// Rejecting an incoming request breaks the streak (server-enforced).
  Future<void> declineTrip(String tripId) =>
      _guard(() => _ops.callDeclineTrip(tripId));

  /// Advances DRIVER_ACCEPTED → DRIVER_ARRIVING → DRIVER_ARRIVED →
  /// IN_PROGRESS → COMPLETED along the server chain.
  Future<void> advanceTripStatus(String tripId, String status) =>
      _guard(() => _ops.callAdvanceTripStatus(tripId, status));

  /// Cancels the assigned trip. The server decides streak protection
  /// (customer cancel / arrived + waited no-show are protected).
  Future<void> cancelTrip(String tripId) =>
      _guard(() => _ops.callCancelTrip(tripId));

  /// Submits the recipient's 4-digit delivery PIN to complete a delivery.
  /// The server verifies the code and settles through the normal completion
  /// path; wrong codes throw with a user-safe message.
  Future<void> verifyDeliveryPin(String tripId, String pin) =>
      _guard(() => _ops.callVerifyDeliveryPin(tripId, pin));

  /// GPS heartbeat for the live trip (powers the customer marker +
  /// proximity triggers). Mocked fixes are rejected server-side; the
  /// caller should withhold spoofed fixes and surface a warning instead.
  Future<void> reportDriverLocation({
    required String tripId,
    required double lat,
    required double lng,
    required bool isMocked,
  }) =>
      _guard(
          () => _ops.callReportDriverLocation(tripId, lat, lng, isMocked));

  Future<void> _guard(Future<Map<String, dynamic>> Function() call) async {
    try {
      await call();
    } on FirebaseFunctionsException catch (e) {
      debugPrint('DriverStreakService ${e.code}: ${e.message}');
      throw DriverStreakException(e.code, _mapError(e.code, e.message));
    } catch (e) {
      debugPrint('DriverStreakService error: $e');
      if (e is DriverStreakException) rethrow;
      throw const DriverStreakException(
        'network-error',
        'Could not reach the dispatch server. Check your connection.',
      );
    }
  }

  static String _mapError(String code, String? message) {
    switch (code) {
      case 'unauthenticated':
        return 'Your session has expired. Please sign in again.';
      case 'failed-precondition':
        return message ?? 'This trip can no longer be changed.';
      case 'deadline-exceeded':
        return 'This request already expired. It counts as a miss.';
      case 'not-found':
        return 'Trip not found. It may have been cancelled.';
      default:
        return message ?? 'Dispatch action failed. Please try again.';
    }
  }
}
