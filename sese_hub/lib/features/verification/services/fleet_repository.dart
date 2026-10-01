import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart';
import 'package:sese_core/sese_core.dart';

/// Raw vehicle document snapshot (id + data), decoupled from Firestore
/// types so merge/filter logic stays unit-testable.
class PendingVehicleDoc {
  final String id;
  final String key;
  final Map<String, dynamic> data;

  const PendingVehicleDoc({
    required this.id,
    required this.key,
    required this.data,
  });
}

/// Tolerant pending-vehicle queue for the Fleet Verification desk.
///
/// A vehicle belongs in the queue when EITHER marker says "not yet
/// verified", and never when it was rejected/approved:
/// - `verificationStatus == 'PENDING'` (canonical, any casing), OR
/// - `isVerified == false` (legacy alias written by older clients), OR
/// - no canonical status at all (legacy doc) without an active/approved
///   marker — so freshly registered vehicles render immediately.
/// Excluded: `verificationStatus` REJECTED/APPROVED, `isVerified == true`,
/// legacy `status` rejected/active/approved.
///
/// Implementation: two single-field `collectionGroup('vehicles')` streams
/// merged client-side (no composite index required), de-duplicated by
/// driver/id, rejected docs filtered out, newest first.
class FleetRepository {
  final FirebaseFirestore? _firestore;

  const FleetRepository([this._firestore]);

  FirebaseFirestore? get _db {
    try {
      return _firestore ?? FirebaseFirestore.instance;
    } catch (_) {
      return null;
    }
  }

/// Live tolerant pending queue. Emits an empty list (never an error)
/// when Firestore is unavailable; forwards a query error only when
/// NEITHER backing query has produced data yet.
  Stream<List<VehicleModel>> pendingVehiclesStream() {
    final db = _db;
    if (db == null) return Stream.value(const <VehicleModel>[]);

    final canonical = db
        .collectionGroup('vehicles')
        .where('verificationStatus', isEqualTo: 'PENDING')
        .snapshots();
    final legacy = db
        .collectionGroup('vehicles')
        .where('isVerified', isEqualTo: false)
        .snapshots();

    final controller = StreamController<List<VehicleModel>>.broadcast();
    Map<String, PendingVehicleDoc> latestCanonical = {};
    Map<String, PendingVehicleDoc> latestLegacy = {};

    StreamSubscription? subCanonical;
    StreamSubscription? subLegacy;

    void emit() {
      controller.add(mergePendingDocs([
        ...latestCanonical.values,
        ...latestLegacy.values,
      ]));
    }

    controller.onListen = () {
      subCanonical = canonical.listen(
        (snap) {
          latestCanonical = {
            for (final d in snap.docs)
              _keyOf(d.id, d.data(), d.reference): PendingVehicleDoc(
                id: d.id,
                key: _keyOf(d.id, d.data(), d.reference),
                data: d.data(),
              ),
          };
          emit();
        },
        onError: (Object e) {
          if (latestLegacy.isEmpty) {
            controller.addError(e);
          }
        },
      );
      subLegacy = legacy.listen(
        (snap) {
          latestLegacy = {
            for (final d in snap.docs)
              _keyOf(d.id, d.data(), d.reference): PendingVehicleDoc(
                id: d.id,
                key: _keyOf(d.id, d.data(), d.reference),
                data: d.data(),
              ),
          };
          emit();
        },
        onError: (Object e) {
          if (latestCanonical.isEmpty) {
            controller.addError(e);
          }
        },
      );
    };
    controller.onCancel = () async {
      await subCanonical?.cancel();
      await subLegacy?.cancel();
      subCanonical = null;
      subLegacy = null;
      // Do NOT close the broadcast controller here: TabBarView tab switches
      // cancel the StreamBuilder subscription temporarily. Keeping the
      // controller open allows re-listening (onListen fires again) without
      // wiping pending records from view on re-entry.
    };
    return controller.stream;
  }

  static String _keyOf(
    String docId,
    Map<String, dynamic> data,
    DocumentReference ref,
  ) {
    var driverId = (data['driverId'] ?? '').toString().trim();
    if (driverId.isEmpty) {
      try {
        driverId = ref.parent.parent?.id ?? '';
      } catch (_) {
        driverId = '';
      }
    }
    return '$driverId/$docId';
  }

  /// Pure queue predicate (see class docs). Unit-testable.
  static bool isPendingQueueMatch(Map<String, dynamic> data) {
    final canonical =
        (data['verificationStatus'] ?? '').toString().toUpperCase();
    final vehicleStatus =
        (data['vehicleStatus'] ?? '').toString().toLowerCase();
    final legacyStatus = (data['status'] ?? '').toString().toLowerCase();
    if (canonical == 'REJECTED' || legacyStatus == 'rejected' || vehicleStatus == 'rejected') return false;
    if (canonical == 'APPROVED' ||
        canonical == 'VERIFIED' ||
        data['isVerified'] == true) {
      return false;
    }
    if (legacyStatus == 'active' || legacyStatus == 'approved') return false;
    if (canonical == 'PENDING' || canonical == 'SUBMITTED' || canonical == 'PENDING_VERIFICATION') return true;
    if (vehicleStatus == 'pending_verification' || vehicleStatus == 'pending' || vehicleStatus == 'submitted') return true;
    if (data['isVerified'] == false) return true;
    // Legacy doc with no canonical status and no active/approved marker:
    // treat as pending so it renders instead of vanishing.
    if (!data.containsKey('verificationStatus')) return true;
    return false;
  }

  /// Merges raw docs from both backing queries: de-duplicates by
  /// driver/id, drops non-matching (rejected/approved) docs, newest first.
  static List<VehicleModel> mergePendingDocs(
      Iterable<PendingVehicleDoc> docs) {
    final byKey = <String, PendingVehicleDoc>{};
    for (final d in docs) {
      byKey.putIfAbsent(d.key, () => d);
    }
    final out = <VehicleModel>[];
    for (final d in byKey.values) {
      if (!isPendingQueueMatch(d.data)) continue;
      try {
        out.add(VehicleModel.fromMap(d.data, id: d.id));
      } catch (e) {
        debugPrint('FleetRepository: skipping unparsable vehicle ${d.id}: $e');
      }
    }
    out.sort((a, b) => b.createdAt.compareTo(a.createdAt));
    return out;
  }
}
