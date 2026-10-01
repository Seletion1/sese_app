import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_auth/firebase_auth.dart' as fb;
import 'package:flutter/foundation.dart';

/// Signed GPS payload attached to every online-status request.
///
/// The coordinates are advisory only: the backend re-validates accuracy,
/// mock/spoof flags, and plausibility before granting any state change.
class DriverGpsFix {
  /// Reject fixes worse than this (client-side fail-fast; server re-checks).
  static const double maxAcceptableAccuracyMeters = 100.0;

  final double latitude;
  final double longitude;
  final double accuracyMeters;
  final DateTime timestamp;
  final bool isMocked;

  const DriverGpsFix({
    required this.latitude,
    required this.longitude,
    required this.accuracyMeters,
    required this.timestamp,
    this.isMocked = false,
  });

  Map<String, dynamic> toMap() => {
        'latitude': latitude,
        'longitude': longitude,
        'accuracy': accuracyMeters,
        'timestamp': timestamp.toIso8601String(),
        'isMocked': isMocked,
      };
}

/// Server decision for an online-status request.
class DriverStatusDecision {
  final bool granted;
  final String status;
  final String message;

  const DriverStatusDecision({
    required this.granted,
    required this.status,
    required this.message,
  });

  factory DriverStatusDecision.fromMap(Map<String, dynamic> map) {
    return DriverStatusDecision(
      granted: map['granted'] == true || map['confirmed'] == true,
      status: (map['status'] ?? 'unknown').toString(),
      message: (map['message'] ?? '').toString(),
    );
  }
}

/// Thrown when the backend refuses (or cannot verify) a status change.
/// The UI must keep the previous (offline) state in this case.
class DriverStatusException implements Exception {
  final String code;
  final String message;

  const DriverStatusException(this.code, this.message);

  @override
  String toString() => 'DriverStatusException($code): $message';
}

/// Transport abstraction so the handshake is unit-testable without Firebase.
abstract class DriverStatusBackend {
  Future<Map<String, dynamic>> callGoOnline(
    String idToken, {
    required String driverId,
    required Map<String, dynamic> fix,
  });

  Future<Map<String, dynamic>> callGoOffline({
    required String driverId,
  });
}

/// Production transport: Firebase Callable Functions
/// (`goOnline` / `goOffline`). Auth travels as the Callable's verified
/// Firebase JWT (Bearer ID token), so the backend never trusts client claims.
class CloudFunctionsDriverStatusBackend implements DriverStatusBackend {
  final FirebaseFunctions? _functions;

  CloudFunctionsDriverStatusBackend([this._functions]);

  FirebaseFunctions? get _fn {
    try {
      return _functions ?? FirebaseFunctions.instance;
    } catch (_) {
      return null;
    }
  }

  @override
  Future<Map<String, dynamic>> callGoOnline(
    String idToken, {
    required String driverId,
    required Map<String, dynamic> fix,
  }) async {
    final fn = _fn;
    if (fn == null) {
      throw const DriverStatusException(
        'backend-unavailable',
        'Status server is unreachable. Staying offline.',
      );
    }
    try {
      final result = await fn.httpsCallable('goOnline').call({
        'driverId': driverId,
        'fix': fix,
        // Callable already carries the verified ID token; echoed explicitly
        // so HTTP-gateway deployments can validate the Bearer token too.
        'idToken': idToken,
      });
      return Map<String, dynamic>.from(result.data as Map);
    } on FirebaseFunctionsException catch (e) {
      throw DriverStatusException(e.code, e.message ?? 'Online request denied.');
    }
  }

  @override
  Future<Map<String, dynamic>> callGoOffline({
    required String driverId,
  }) async {
    final fn = _fn;
    if (fn == null) {
      throw const DriverStatusException(
        'backend-unavailable',
        'Status server is unreachable. Staying online.',
      );
    }
    try {
      final result = await fn.httpsCallable('goOffline').call({
        'driverId': driverId,
      });
      return Map<String, dynamic>.from(result.data as Map);
    } on FirebaseFunctionsException catch (e) {
      throw DriverStatusException(e.code, e.message ?? 'Offline request denied.');
    }
  }
}

/// Zero-trust driver availability handshake.
///
/// The client is presentation-only: it NEVER flips `_isOnline` itself.
/// Every transition requires a server grant:
/// - `requestGoOnline` → `goOnline()` callable with Bearer ID token + signed
///   GPS fix. Server verifies JWT, licence/vehicle approval, suspension,
///   fleet attachment, and GPS spoof sanity, then writes `isOnline: true`,
///   `status: 'active'` + geo index and returns the grant.
/// - `requestGoOffline` → `goOffline()` callable. Server refuses while a trip
///   is mid-ride, otherwise clears the geo registry, writes
///   `isOnline: false`, and returns confirmation.
class DriverStatusService {
  final DriverStatusBackend _backend;
  final Future<String?> Function()? _idTokenProvider;
  final fb.FirebaseAuth? _authExplicit;

  DriverStatusService({
    DriverStatusBackend? backend,
    this._idTokenProvider,
    fb.FirebaseAuth? auth,
  })  : _backend = backend ?? CloudFunctionsDriverStatusBackend(),
        _authExplicit = auth;

  Future<String?> _resolveIdToken() async {
    final provider = _idTokenProvider;
    if (provider != null) {
      try {
        return await provider();
      } catch (e) {
        debugPrint('DriverStatusService: idTokenProvider error: $e');
        return null;
      }
    }
    try {
      final auth = _authExplicit ?? fb.FirebaseAuth.instance;
      return await auth.currentUser?.getIdToken();
    } catch (e) {
      debugPrint('DriverStatusService: getIdToken error: $e');
      return null;
    }
  }

  /// Fail-fast client pre-checks. These are UX only — the server re-validates
  /// everything and is the sole authority.
  void _precheckFix(DriverGpsFix fix) {
    if (fix.isMocked) {
      throw const DriverStatusException(
        'gps-spoofed',
        'Mock location detected. Disable mock locations to go online.',
      );
    }
    if (fix.accuracyMeters > DriverGpsFix.maxAcceptableAccuracyMeters) {
      throw const DriverStatusException(
        'gps-inaccurate',
        'GPS accuracy too low. Move to open sky and try again.',
      );
    }
  }

  Future<DriverStatusDecision> requestGoOnline({
    required String driverId,
    required DriverGpsFix fix,
  }) async {
    _precheckFix(fix);
    final idToken = await _resolveIdToken();
    if (idToken == null || idToken.isEmpty) {
      throw const DriverStatusException(
        'unauthenticated',
        'Sign in again to verify your session.',
      );
    }
    final data = await _backend.callGoOnline(
      idToken,
      driverId: driverId,
      fix: fix.toMap(),
    );
    return DriverStatusDecision.fromMap(data);
  }

  Future<DriverStatusDecision> requestGoOffline({
    required String driverId,
  }) async {
    final data = await _backend.callGoOffline(driverId: driverId);
    return DriverStatusDecision.fromMap(data);
  }
}
