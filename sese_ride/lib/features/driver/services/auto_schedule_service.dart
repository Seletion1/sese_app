import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:flutter/foundation.dart';

/// Auto Online Schedule preference stored on `drivers/{uid}`.
///
/// The backend [sweepAutoOnlineSchedule] Cloud Function reads these fields
/// every minute and applies one-time daily online/offline transitions using
/// Africa/Lagos (WAT) server time — the phone clock is never consulted.
class AutoSchedulePrefs {
  /// Whether the schedule is active. Defaults to true for all drivers.
  final bool enabled;

  /// Time the driver should be automatically set Online (24-hour "HH:MM" WAT).
  final String autoOnlineTime;

  /// Time the driver should be automatically set Offline (24-hour "HH:MM" WAT).
  final String autoOfflineTime;

  const AutoSchedulePrefs({
    this.enabled = true,
    this.autoOnlineTime = '06:00',
    this.autoOfflineTime = '22:00',
  });

  /// Parses from a Firestore document map (all fields optional — missing fields
  /// fall back to the platform defaults so legacy drivers get the schedule
  /// without requiring a first-time save).
  factory AutoSchedulePrefs.fromMap(Map<String, dynamic>? map) {
    if (map == null) return const AutoSchedulePrefs();
    final raw = map['autoScheduleEnabled'];
    return AutoSchedulePrefs(
      // Absent field (null) is treated as enabled (platform default).
      enabled: raw == null ? true : raw == true,
      autoOnlineTime: (map['autoOnlineTime'] as String?)?.trim() ?? '06:00',
      autoOfflineTime: (map['autoOfflineTime'] as String?)?.trim() ?? '22:00',
    );
  }

  Map<String, dynamic> toMap() => {
        'autoScheduleEnabled': enabled,
        'autoOnlineTime': autoOnlineTime,
        'autoOfflineTime': autoOfflineTime,
      };

  AutoSchedulePrefs copyWith({
    bool? enabled,
    String? autoOnlineTime,
    String? autoOfflineTime,
  }) =>
      AutoSchedulePrefs(
        enabled: enabled ?? this.enabled,
        autoOnlineTime: autoOnlineTime ?? this.autoOnlineTime,
        autoOfflineTime: autoOfflineTime ?? this.autoOfflineTime,
      );

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is AutoSchedulePrefs &&
          enabled == other.enabled &&
          autoOnlineTime == other.autoOnlineTime &&
          autoOfflineTime == other.autoOfflineTime;

  @override
  int get hashCode => Object.hash(enabled, autoOnlineTime, autoOfflineTime);
}

/// Thrown when the auto-schedule service call fails.
class AutoScheduleException implements Exception {
  final String message;
  const AutoScheduleException(this.message);

  @override
  String toString() => 'AutoScheduleException: $message';
}

/// Service that reads and persists [AutoSchedulePrefs] for the calling driver.
///
/// **Write path**: calls the `saveAutoScheduleSettings` Cloud Function so the
/// server validates and persists the settings — the client never writes
/// `drivers/{uid}` directly for safety.
///
/// **Read path**: streams `drivers/{uid}` for live updates (the schedule job
/// may stamp `lastAutoOnlineDate` / `lastAutoOfflineDate` back on that doc,
/// but we only surface the preference fields here).
class AutoScheduleService {
  final FirebaseFirestore? _firestoreOverride;
  final FirebaseFunctions? _functionsOverride;

  AutoScheduleService({
    FirebaseFirestore? firestore,
    FirebaseFunctions? functions,
  })  : _firestoreOverride = firestore,
        _functionsOverride = functions;

  FirebaseFirestore? get _db {
    try {
      return _firestoreOverride ?? FirebaseFirestore.instance;
    } catch (_) {
      return null;
    }
  }

  FirebaseFunctions? get _fn {
    try {
      return _functionsOverride ?? FirebaseFunctions.instance;
    } catch (_) {
      return null;
    }
  }

  /// Live stream of this driver's auto-schedule preferences from Firestore.
  /// Emits the platform defaults when the document is missing or the field is
  /// absent (backward-compatible with existing driver docs).
  Stream<AutoSchedulePrefs> prefsStream(String uid) {
    final db = _db;
    if (db == null || uid.isEmpty) {
      return Stream.value(const AutoSchedulePrefs());
    }
    try {
      return db
          .collection('drivers')
          .doc(uid)
          .snapshots()
          .map((snap) => AutoSchedulePrefs.fromMap(snap.data()))
          .handleError((Object _) => const AutoSchedulePrefs());
    } catch (_) {
      return Stream.value(const AutoSchedulePrefs());
    }
  }

  /// One-shot fetch of the current prefs (for initial UI population).
  Future<AutoSchedulePrefs> fetchPrefs(String uid) async {
    final db = _db;
    if (db == null || uid.isEmpty) return const AutoSchedulePrefs();
    try {
      final snap = await db.collection('drivers').doc(uid).get();
      return AutoSchedulePrefs.fromMap(snap.data());
    } catch (_) {
      return const AutoSchedulePrefs();
    }
  }

  /// Persists the driver's schedule preferences via the Cloud Function.
  ///
  /// Throws [AutoScheduleException] on network or validation errors.
  Future<void> savePrefs(String uid, AutoSchedulePrefs prefs) async {
    if (uid.isEmpty) {
      throw const AutoScheduleException('Driver ID is required.');
    }
    final fn = _fn;
    if (fn == null) {
      throw const AutoScheduleException(
        'Network unavailable. Check your connection and try again.',
      );
    }
    try {
      await fn.httpsCallable('saveAutoScheduleSettings').call(prefs.toMap());
    } on FirebaseFunctionsException catch (e) {
      debugPrint('AutoScheduleService.savePrefs error: $e');
      final msg = (e.message ?? '').trim();
      throw AutoScheduleException(
        msg.isEmpty ? 'Could not save schedule settings.' : msg,
      );
    } catch (e) {
      debugPrint('AutoScheduleService.savePrefs unexpected error: $e');
      throw const AutoScheduleException(
        'Could not save schedule settings. Please try again.',
      );
    }
  }
}
