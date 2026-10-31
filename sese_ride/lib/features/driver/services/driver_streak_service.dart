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
  Future<Map<String, dynamic>> callAcceptTrip(String tripId, {String? sessionId});
  Future<Map<String, dynamic>> callDeclineTrip(String tripId);
  Future<Map<String, dynamic>> callAdvanceTripStatus(
    String tripId,
    String status,
  );
  Future<Map<String, dynamic>> callCancelTrip(String tripId, {String? reason});
  Future<Map<String, dynamic>> callVerifyDeliveryPin(
    String tripId,
    String pin,
  );

  /// Skips the 4-digit delivery PIN after the recipient is unreachable for
  /// 10 minutes. The server enforces the time gate; the client must have
  /// already shown the liability warning dialog before calling this.
  Future<Map<String, dynamic>> callSkipDeliveryPin(String tripId);

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
  Future<Map<String, dynamic>> callAcceptTrip(String tripId, {String? sessionId}) =>
      _call('acceptTrip', {
        'tripId': tripId,
        'sessionId': ?sessionId,
      });

  @override
  Future<Map<String, dynamic>> callDeclineTrip(String tripId) =>
      _call('declineTrip', {'tripId': tripId});

  @override
  Future<Map<String, dynamic>> callAdvanceTripStatus(
    String tripId,
    String status,
  ) => _call('advanceTripStatus', {'tripId': tripId, 'status': status});

  @override
  Future<Map<String, dynamic>> callCancelTrip(String tripId, {String? reason}) =>
      _call('cancelTrip', {
        'tripId': tripId,
        if (reason != null && reason.isNotEmpty) 'reason': reason,
      });

  @override
  Future<Map<String, dynamic>> callVerifyDeliveryPin(
    String tripId,
    String pin,
  ) =>
      _call('verifyDeliveryPin', {'tripId': tripId, 'pin': pin});

  @override
  /// Invokes the `skipDeliveryPin` server callable. The server validates that
  /// 10 minutes have elapsed since `IN_PROGRESS` and marks the trip as
  /// `deliveryPinSkipped: true` with a full audit entry.
  Future<Map<String, dynamic>> callSkipDeliveryPin(String tripId) =>
      _call('skipDeliveryPin', {'tripId': tripId});

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

  /// Multi-device active session ID. Forwarded to `acceptTrip` when set
  /// to ensure only the currently active session can accept incoming trips.
  String? activeSessionId;

  /// The active driver's UID.
  String? driverId;

  DriverStreakService({this._firestore, this._backend, this.driverId});

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
            // Filter out self-booked customer trips
            if (trip.status == TripStatus.waitingForAcceptance &&
                trip.customerId != driverId) {
              return trip;
            }
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
              .where((t) =>
                  t.status == TripStatus.waitingForAcceptance &&
                  t.customerId != driverId)
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
  Stream<List<ActiveTrip>> marketplaceStream({
    String? driverId,
    int limit = 20,
  }) {
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
          (snap) => snap.docs
              .map((d) => ActiveTrip.fromMap(d.id, d.data()))
              .where((t) => driverId == null || driverId.isEmpty || t.customerId != driverId)
              .toList(),
        )
        .handleError((Object _) => const <ActiveTrip>[]);
  }

  /// Driver's currently assigned live trip, if any.
  ///
  /// Queries by `driver.driverId` so Firestore Security Rules permit the read
  /// for the assigned driver. Does NOT limit to 10 oldest docs so past
  /// completed trips never hide the active live trip.
  Stream<ActiveTrip?> activeTripStream(String driverId) {
    final db = _db;
    if (db == null || driverId.isEmpty) return Stream.value(null);
    return db
        .collection('trips')
        .where('driver.driverId', isEqualTo: driverId)
        .snapshots()
        .map((snap) {
          for (final d in snap.docs) {
            final trip = ActiveTrip.fromMap(d.id, d.data());
            // Filter out self-booked customer trips (role-based isolation)
            if (trip.isLive && trip.customerId != driverId) return trip;
          }
          return null;
        })
        .handleError((Object err) {
          debugPrint('activeTripStream error: $err');
          return null;
        });
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

  Future<void> acceptTrip(String tripId, {String? sessionId}) =>
      _guard(() => _ops.callAcceptTrip(tripId, sessionId: sessionId ?? activeSessionId));

  /// Rejecting an incoming request breaks the streak (server-enforced).
  Future<void> declineTrip(String tripId) =>
      _guard(() => _ops.callDeclineTrip(tripId));

  /// Advances DRIVER_ACCEPTED → DRIVER_ARRIVING → DRIVER_ARRIVED →
  /// IN_PROGRESS → COMPLETED along the server chain.
  Future<void> advanceTripStatus(String tripId, String status) =>
      _guard(() => _ops.callAdvanceTripStatus(tripId, status));

  /// Cancels the assigned trip. The server decides streak protection
  /// (customer cancel / arrived + waited no-show are protected). [reason]
  /// is a [CancelTripDialog] code, audited server-side like the customer
  /// path; unknown codes land as `other`.
  Future<void> cancelTrip(String tripId, {String? reason}) =>
      _guard(() => _ops.callCancelTrip(tripId, reason: reason));

  /// Submits the recipient's 4-digit delivery PIN to complete a delivery.
  /// The server verifies the code and settles through the normal completion
  /// path; wrong codes throw with a user-safe message.
  Future<void> verifyDeliveryPin(String tripId, String pin) =>
      _guard(() => _ops.callVerifyDeliveryPin(tripId, pin));

  /// Skips the delivery PIN after 10 minutes of recipient unavailability.
  ///
  /// The caller is responsible for confirming the liability warning dialog
  /// before invoking this. The server double-checks the 10-minute gate and
  /// creates a permanent audit entry. On success the trip is marked verified
  /// so that settlement proceeds normally.
  Future<void> skipDeliveryPin(String tripId) =>
      _guard(() => _ops.callSkipDeliveryPin(tripId));

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
