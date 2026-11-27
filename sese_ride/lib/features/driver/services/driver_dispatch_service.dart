import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import 'package:sese_core/sese_core.dart';

import '../../trips/models/trip_models.dart';

/// Thrown when a driver trip action (accept/decline/arrive/cancel) fails.
/// Always carries a [userMessage] safe to show in a SnackBar.
class DriverDispatchException implements Exception {
  final String code;
  final String userMessage;

  const DriverDispatchException(this.code, this.userMessage);

  @override
  String toString() => 'DriverDispatchException($code): $userMessage';
}

/// Backward compatibility alias.
typedef DriverStreakException = DriverDispatchException;

/// Transport seam for driver trip-action callables (unit-testable).
abstract class DriverDispatchBackend {
  Future<Map<String, dynamic>> callAcceptTrip(String tripId, {String? sessionId});
  Future<Map<String, dynamic>> callDeclineTrip(String tripId, {String action = 'rejected'});
  Future<Map<String, dynamic>> callAdvanceTripStatus(
    String tripId,
    String status, {
    double? driverLat,
    double? driverLng,
  });
  Future<Map<String, dynamic>> callCancelTrip(String tripId, {String? reason});
  Future<Map<String, dynamic>> callConfirmCashCancellation(
    String tripId, {
    bool cashCollected = true,
  });
  Future<Map<String, dynamic>> callVerifyDeliveryPin(
    String tripId,
    String pin, {
    double? driverLat,
    double? driverLng,
  });

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

  /// Records arrival at drop-off for drop-off waiting and billing tracking.
  Future<Map<String, dynamic>> callRecordDropoffArrival(String tripId) =>
      Future.value(const {'ok': true});

  /// Driver requests remote customer confirmation for out-of-range drop-off.
  Future<Map<String, dynamic>> callRequestDropoffApproval(
    String tripId, {
    required double driverLat,
    required double driverLng,
    String? reason,
  }) =>
      Future.value(const {'ok': true});

  /// Driver cancels pending out-of-range drop-off approval request.
  Future<Map<String, dynamic>> callCancelDropoffApprovalRequest(String tripId) =>
      Future.value(const {'ok': true});
}

/// Backward compatibility alias.
typedef DriverStreakBackend = DriverDispatchBackend;

class _FunctionsDriverDispatchBackend implements DriverDispatchBackend {
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
  Future<Map<String, dynamic>> callDeclineTrip(String tripId, {String action = 'rejected'}) =>
      _call('declineTrip', {'tripId': tripId, 'action': action});

  @override
  Future<Map<String, dynamic>> callAdvanceTripStatus(
    String tripId,
    String status, {
    double? driverLat,
    double? driverLng,
  }) =>
      _call('advanceTripStatus', {
        'tripId': tripId,
        'status': status,
        'driverLat': ?driverLat,
        'driverLng': ?driverLng,
      });

  @override
  Future<Map<String, dynamic>> callCancelTrip(String tripId, {String? reason}) =>
      _call('cancelTrip', {
        'tripId': tripId,
        if (reason != null && reason.isNotEmpty) 'reason': reason,
      });

  @override
  Future<Map<String, dynamic>> callConfirmCashCancellation(
    String tripId, {
    bool cashCollected = true,
  }) =>
      _call('confirmCashCancellation', {
        'tripId': tripId,
        'cashCollected': cashCollected,
      });

  @override
  Future<Map<String, dynamic>> callVerifyDeliveryPin(
    String tripId,
    String pin, {
    double? driverLat,
    double? driverLng,
  }) =>
      _call('verifyDeliveryPin', {
        'tripId': tripId,
        'pin': pin,
        'driverLat': ?driverLat,
        'driverLng': ?driverLng,
      });

  @override
  Future<Map<String, dynamic>> callRequestDropoffApproval(
    String tripId, {
    required double driverLat,
    required double driverLng,
    String? reason,
  }) async {
    try {
      return await _call('requestDropoffApproval', {
        'tripId': tripId,
        'driverLat': driverLat,
        'driverLng': driverLng,
        if (reason != null && reason.isNotEmpty) 'reason': reason,
      });
    } catch (e) {
      debugPrint('callRequestDropoffApproval: falling back to advanceTripStatus ($e)');
      return await _call('advanceTripStatus', {
        'tripId': tripId,
        'status': 'pending_customer_approval',
        'driverLat': driverLat,
        'driverLng': driverLng,
        if (reason != null && reason.isNotEmpty) 'reason': reason,
      });
    }
  }

  @override
  Future<Map<String, dynamic>> callCancelDropoffApprovalRequest(String tripId) =>
      _call('cancelDropoffApprovalRequest', {'tripId': tripId});

  @override
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

  @override
  Future<Map<String, dynamic>> callRecordDropoffArrival(String tripId) async {
    try {
      return await _call('recordDropoffArrival', {'tripId': tripId});
    } catch (_) {
      return await _call('advanceTripStatus', {
        'tripId': tripId,
        'status': 'IN_PROGRESS',
        'recordDropoffArrival': true,
      });
    }
  }
}

/// Live data + actions for the Driver Dispatch system.
///
/// - Streams come from Firestore (`trips` pings/assignments, `system_configs/global_default`).
/// - Mutations go through server-authoritative callables in functions/src/trips.ts.
class DriverDispatchService {
  final FirebaseFirestore? firestore;
  final DriverDispatchBackend? backend;

  /// Multi-device active session ID. Forwarded to `acceptTrip` when set
  /// to ensure only the currently active session can accept incoming trips.
  String? activeSessionId;

  /// The active driver's UID.
  String? driverId;

  DriverDispatchService({
    this.firestore,
    this.backend,
    this.driverId,
  });

  FirebaseFirestore? get _db {
    try {
      return firestore ?? FirebaseFirestore.instance;
    } catch (_) {
      return null;
    }
  }

  DriverDispatchBackend get _ops => backend ?? _FunctionsDriverDispatchBackend();

  /// Tier 1 exclusive ping OR Hub multi-driver re-assigned pool ping for [driverId].
  Stream<ActiveTrip?> pingStream(String driverId) {
    final db = _db;
    if (db == null || driverId.isEmpty) return Stream.value(null);

    final directStream = db
        .collection('trips')
        .where('pingDriverId', isEqualTo: driverId)
        .limit(5)
        .snapshots();

    final poolStream = db
        .collection('trips')
        .where('pingDriverIds', arrayContains: driverId)
        .limit(5)
        .snapshots();

    ActiveTrip? pickValidTrip(QuerySnapshot<Map<String, dynamic>> snap) {
      for (final d in snap.docs) {
        final trip = ActiveTrip.fromMap(d.id, d.data());
        if (trip.status == TripStatus.waitingForAcceptance &&
            trip.customerId != driverId) {
          return trip;
        }
      }
      return null;
    }

    final controller = StreamController<ActiveTrip?>.broadcast();
    ActiveTrip? latestDirect;
    ActiveTrip? latestPool;

    void emit() {
      if (!controller.isClosed) {
        controller.add(latestDirect ?? latestPool);
      }
    }

    late final StreamSubscription sub1;
    late final StreamSubscription sub2;

    sub1 = directStream.listen(
      (snap) {
        latestDirect = pickValidTrip(snap);
        emit();
      },
      onError: (_) {},
    );
    sub2 = poolStream.listen(
      (snap) {
        latestPool = pickValidTrip(snap);
        emit();
      },
      onError: (_) {},
    );

    controller.onCancel = () {
      sub1.cancel();
      sub2.cancel();
    };

    return controller.stream;
  }

  /// Tier 3 marketplace broadcast (open to all nearby online drivers).
  Stream<List<ActiveTrip>> marketplaceStream({
    String? driverId,
    int limit = 20,
  }) {
    final effectiveDriverId = (driverId != null && driverId.isNotEmpty)
        ? driverId
        : (() {
            try {
              return FirebaseAuth.instance.currentUser?.uid;
            } catch (_) {
              return null;
            }
          })() ??
          '';
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
              .where((t) => effectiveDriverId.isEmpty || t.customerId != effectiveDriverId)
              .toList(),
        )
        .handleError((Object _) => const <ActiveTrip>[]);
  }

  /// Driver's currently assigned live trip, if any.
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
            if (trip.isLive && trip.customerId != driverId) return trip;
          }
          return null;
        })
        .handleError((Object err) {
          debugPrint('activeTripStream error: $err');
          return null;
        });
  }

  /// Platform dispatch tunables. Falls back to model defaults when Firestore
  /// is unavailable.
  Stream<DailyStreakConfig> dispatchConfigStream() {
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

  /// Backward compatibility stream alias.
  Stream<DailyStreakConfig> streakConfigStream() => dispatchConfigStream();

  Future<void> acceptTrip(String tripId, {String? sessionId}) =>
      _guard(() => _ops.callAcceptTrip(tripId, sessionId: sessionId ?? activeSessionId));

  Future<void> declineTrip(String tripId, {String action = 'rejected'}) =>
      _guard(() => _ops.callDeclineTrip(tripId, action: action));

  Future<void> advanceTripStatus(String tripId, String status) =>
      advanceTripStatusWithLocation(tripId, status);

  Future<void> advanceTripStatusWithLocation(
    String tripId,
    String status, {
    double? driverLat,
    double? driverLng,
  }) =>
      _guard(() => _ops.callAdvanceTripStatus(
            tripId,
            status,
            driverLat: driverLat,
            driverLng: driverLng,
          ));

  Future<void> cancelTrip(String tripId, {String? reason}) =>
      _guard(() => _ops.callCancelTrip(tripId, reason: reason));

  Future<void> confirmCashCancellation(
    String tripId, {
    bool cashCollected = true,
  }) =>
      _guard(
        () => _ops.callConfirmCashCancellation(
          tripId,
          cashCollected: cashCollected,
        ),
      );

  Future<void> verifyDeliveryPin(String tripId, String pin) =>
      verifyDeliveryPinWithLocation(tripId, pin);

  Future<void> verifyDeliveryPinWithLocation(
    String tripId,
    String pin, {
    double? driverLat,
    double? driverLng,
  }) =>
      _guard(() => _ops.callVerifyDeliveryPin(
            tripId,
            pin,
            driverLat: driverLat,
            driverLng: driverLng,
          ));

  Future<void> skipDeliveryPin(String tripId) =>
      _guard(() => _ops.callSkipDeliveryPin(tripId));

  Future<void> recordDropoffArrival(String tripId) =>
      _guard(() => _ops.callRecordDropoffArrival(tripId));

  Future<void> requestDropoffApproval({
    required String tripId,
    required double driverLat,
    required double driverLng,
    String? reason,
  }) =>
      _guard(() => _ops.callRequestDropoffApproval(
            tripId,
            driverLat: driverLat,
            driverLng: driverLng,
            reason: reason,
          ));

  Future<void> cancelDropoffApprovalRequest(String tripId) =>
      _guard(() => _ops.callCancelDropoffApprovalRequest(tripId));

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
      debugPrint('DriverDispatchService ${e.code}: ${e.message}');
      throw DriverDispatchException(e.code, _mapError(e.code, e.message));
    } catch (e) {
      debugPrint('DriverDispatchService error: $e');
      if (e is DriverDispatchException) rethrow;
      throw const DriverDispatchException(
        'network-error',
        'Could not reach the dispatch server. Check your connection.',
      );
    }
  }

  static String _mapError(String code, String? message) {
    switch (code) {
      case 'unauthenticated':
        if (message?.contains('App Check') == true) {
          return 'App Check attestation failed: missing or unregistered token.';
        }
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

/// Backward compatibility class alias.
typedef DriverStreakService = DriverDispatchService;
