import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:flutter/foundation.dart';

/// Thrown when a split action cannot proceed. [message] is user-safe.
class SplitException implements Exception {
  final String code;
  final String message;

  const SplitException(this.code, this.message);

  @override
  String toString() => 'SplitException($code): $message';
}

/// One co-payer's share of a split (`split_payments/{splitId}/parts/{uid}`).
class SplitPart {
  final String userId;
  final String name;
  final int shareKobo;
  final String status;

  bool get isPending => status == 'pending';
  bool get isAccepted => status == 'accepted';

  const SplitPart({
    required this.userId,
    required this.shareKobo,
    this.name = '',
    this.status = 'pending',
  });

  factory SplitPart.fromMap(String id, Map<String, dynamic>? map) {
    map ??= const {};
    return SplitPart(
      userId: id,
      name: (map['name'] ?? '').toString(),
      shareKobo: (map['shareKobo'] as num?)?.toInt() ?? 0,
      status: (map['status'] ?? 'pending').toString(),
    );
  }
}

/// Client facade for fare splitting (`requestSplitPayment` /
/// `respondSplitPayment` / `settleSplitPayment`).
///
/// Flow: request creates the intent (consent-only) → every co-payer accepts
/// via an authenticated prompt → the last acceptance flips the intent to
/// `ready` → [settle] moves the money atomically server-side. A decline
/// anywhere kills the intent and the requester keeps the full fare.
class SplitService {
  final FirebaseFirestore? _firestore;
  final FirebaseFunctions? _functions;

  const SplitService([this._firestore, this._functions]);

  FirebaseFirestore? get _db {
    try {
      return _firestore ?? FirebaseFirestore.instance;
    } catch (_) {
      return null;
    }
  }

  FirebaseFunctions? get _fn {
    try {
      return _functions ?? FirebaseFunctions.instance;
    } catch (_) {
      return null;
    }
  }

  Never _wrap(Object e) {
    if (e is FirebaseFunctionsException) {
      final detail = (e.message ?? '').trim();
      throw SplitException(
        e.code,
        detail.isEmpty ? 'We could not process that split.' : detail,
      );
    }
    debugPrint('SplitService: $e');
    throw const SplitException(
      'unknown',
      'We could not process that split. Please try again.',
    );
  }

  /// Creates a split intent for [tripId] across [copayerPhones].
  /// Returns the new splitId.
  Future<String> requestSplit({
    required String tripId,
    required List<String> copayerPhones,
  }) async {
    final fn = _fn;
    if (fn == null) {
      throw const SplitException('unavailable', 'Splits are unavailable.');
    }
    try {
      final res = await fn.httpsCallable('requestSplitPayment').call({
        'tripId': tripId,
        'copayerPhones': copayerPhones,
      });
      final data = Map<String, dynamic>.from(res.data as Map);
      return (data['splitId'] ?? '').toString();
    } catch (e) {
      _wrap(e);
    }
  }

  /// Accepts or declines [splitId] as the current user.
  ///
  /// Returns true when this response completed the set — i.e. every party
  /// has now accepted and the intent is `ready` to settle. Callers should
  /// offer [settle] immediately in that case (the last accepter settling
  /// inline keeps money from hanging in `ready`).
  Future<bool> respond({
    required String splitId,
    required bool accept,
  }) async {
    final fn = _fn;
    if (fn == null) {
      throw const SplitException('unavailable', 'Splits are unavailable.');
    }
    try {
      final res = await fn.httpsCallable('respondSplitPayment').call({
        'splitId': splitId,
        'accept': accept,
      });
      final data = res.data is Map
          ? Map<String, dynamic>.from(res.data as Map)
          : const <String, dynamic>{};
      return data['ready'] == true && accept;
    } catch (e) {
      _wrap(e);
    }
  }

  /// Settles a `ready` split: the server re-verifies every co-payer
  /// (KYC/suspension/phone), enforces the trust-tier balance guardrails,
  /// and moves all shares atomically. [transactionPin] authorizes the
  /// execution run (co-payer debits were authorized by their accepts).
  /// Idempotent — safe to retry after a timeout, and a no-op when already
  /// settled.
  Future<void> settle({
    required String splitId,
    required String transactionPin,
  }) async {
    final fn = _fn;
    if (fn == null) {
      throw const SplitException('unavailable', 'Splits are unavailable.');
    }
    try {
      await fn.httpsCallable('settleSplitPayment').call({
        'splitId': splitId,
        'transactionPin': transactionPin,
      });
    } catch (e) {
      _wrap(e);
    }
  }

  /// Split intents where [uid] holds a part row, newest first.
  /// Note: Firestore cannot query "parts where doc id == uid" across
  /// parents, so this streams intents the user REQUESTED. Incoming invites
  /// surface via in-app notifications; the invitee opens the split from
  /// there. A dedicated invite inbox is future work.
  Stream<List<Map<String, dynamic>>> mySplitsStream(String uid) {
    final db = _db;
    if (db == null || uid.isEmpty) return Stream.value(const []);
    return db
        .collection('split_payments')
        .where('requesterId', isEqualTo: uid)
        .limit(10)
        .snapshots()
        .map((s) => s.docs.map((d) => {'splitId': d.id, ...d.data()}).toList())
        .handleError((Object _) => const <Map<String, dynamic>>[]);
  }

  /// Pending incoming invites for [uid] — part rows addressed to them that
  /// they have not answered yet. Single-field collection-group query, so no
  /// composite index is needed (status is filtered client-side); the rules
  /// prove it via the `parts/{userId}` owner branch.
  Stream<List<Map<String, dynamic>>> incomingInvitesStream(String uid) {
    final db = _db;
    if (db == null || uid.isEmpty) return Stream.value(const []);
    return db
        .collectionGroup('parts')
        .where('userId', isEqualTo: uid)
        .snapshots()
        .map((s) => s.docs
            .where((d) => (d.data()['status'] ?? '') == 'pending')
            .map((d) => {
                  'splitId': d.reference.parent.parent?.id ?? '',
                  'shareKobo': (d.data()['shareKobo'] as num?)?.toInt() ?? 0,
                })
            .where((m) => (m['splitId'] as String).isNotEmpty)
            .toList())
        .handleError((Object _) => const <Map<String, dynamic>>[]);
  }

  /// Live part rows for one split.
  Stream<List<SplitPart>> partsStream(String splitId) {
    final db = _db;
    if (db == null || splitId.isEmpty) return Stream.value(const []);
    return db
        .collection('split_payments')
        .doc(splitId)
        .collection('parts')
        .snapshots()
        .map((s) => s.docs.map((d) => SplitPart.fromMap(d.id, d.data())).toList())
        .handleError((Object _) => const <SplitPart>[]);
  }
}
