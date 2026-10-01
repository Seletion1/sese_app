import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart';

/// One row in the Hub Weekly Payout Desk.
class PayoutQueueEntry {
  final String userId;
  final String fullName;
  final String bankName;
  final String accountNumber;
  final String accountName;
  final double balance;
  final String payoutStatus;
  final DateTime? lastPayoutAt;

  const PayoutQueueEntry({
    required this.userId,
    required this.fullName,
    this.bankName = '',
    this.accountNumber = '',
    this.accountName = '',
    this.balance = 0,
    this.payoutStatus = 'pending',
    this.lastPayoutAt,
  });

  bool get isPaid => payoutStatus == 'paid' || payoutStatus == 'disbursed';
}

/// Hub-side payout queue composited from `wallets` (balances) +
/// `payout_profiles` (bank destinations) + `users`/`drivers` (names).
///
/// Reads require hub staff privileges (see firestore.rules wallets/payout
/// extension). Failures degrade to an empty list — never throws to the UI.
class PayoutQueueService {
  final FirebaseFirestore? _firestore;

  const PayoutQueueService([this._firestore]);

  FirebaseFirestore? get _db {
    try {
      return _firestore ?? FirebaseFirestore.instance;
    } catch (_) {
      return null;
    }
  }

  /// One-shot fetch of users at/above [minPayoutThreshold].
  Future<List<PayoutQueueEntry>> fetchEligible({
    required double minPayoutThreshold,
    int limit = 200,
  }) async {
    final db = _db;
    if (db == null) return const [];
    try {
      final snap = await db
          .collection('wallets')
          .where('mainWalletBalance', isGreaterThanOrEqualTo: minPayoutThreshold)
          .limit(limit)
          .get();
      final out = <PayoutQueueEntry>[];
      for (final doc in snap.docs) {
        out.add(await _hydrate(db, doc.id,
            Map<String, dynamic>.from(doc.data())));
      }
      out.sort((a, b) => b.balance.compareTo(a.balance));
      return out;
    } catch (e) {
      debugPrint('PayoutQueueService.fetchEligible: $e');
      return const [];
    }
  }

  /// Live queue stream (poll-backed: re-hydrates on wallet snapshots).
  Stream<List<PayoutQueueEntry>> queueStream({
    required double minPayoutThreshold,
    int limit = 200,
  }) {
    final db = _db;
    if (db == null) return Stream.value(const <PayoutQueueEntry>[]);
    return db
        .collection('wallets')
        .where('mainWalletBalance',
            isGreaterThanOrEqualTo: minPayoutThreshold)
        .limit(limit)
        .snapshots()
        .asyncMap((snap) async {
      final out = <PayoutQueueEntry>[];
      for (final doc in snap.docs) {
        out.add(await _hydrate(db, doc.id,
            Map<String, dynamic>.from(doc.data())));
      }
      out.sort((a, b) => b.balance.compareTo(a.balance));
      return out;
    }).handleError((Object _) => const <PayoutQueueEntry>[]);
  }

  Future<PayoutQueueEntry> _hydrate(FirebaseFirestore db, String uid,
      Map<String, dynamic> wallet) async {
    String fullName = uid;
    String payoutStatus = 'pending';
    DateTime? lastPayoutAt;
    try {
      final u = await db.collection('users').doc(uid).get();
      if (u.exists && u.data() != null) {
        fullName = ((u.data()!['fullName'] ?? u.data()!['displayName'] ?? uid))
            .toString();
      } else {
        final d = await db.collection('drivers').doc(uid).get();
        if (d.exists && d.data() != null) {
          fullName =
              ((d.data()!['fullName'] ?? d.data()!['displayName'] ?? uid))
                  .toString();
        }
      }
    } catch (_) {}
    String bankName = '';
    String acct = '';
    String acctName = '';
    try {
      final p = await db.collection('payout_profiles').doc(uid).get();
      final pd = p.data();
      if (pd != null) {
        bankName = (pd['bankName'] ?? '').toString();
        acct = (pd['accountNumber'] ?? '').toString();
        acctName = (pd['accountName'] ?? '').toString();
        payoutStatus = (pd['lastPayoutStatus'] ?? 'pending').toString();
        try {
          lastPayoutAt =
              (pd['lastPayoutAt'] as dynamic)?.toDate() as DateTime?;
        } catch (_) {}
      }
    } catch (_) {}
    double balance = 0;
    final raw = wallet['mainWalletBalance'];
    if (raw is num) balance = raw.toDouble();
    return PayoutQueueEntry(
      userId: uid,
      fullName: fullName,
      bankName: bankName,
      accountNumber: acct,
      accountName: acctName,
      balance: balance,
      payoutStatus: payoutStatus,
      lastPayoutAt: lastPayoutAt,
    );
  }

  /// Marks a payout processed / disbursed (hub staff only per rules).
  Future<void> markPayout({
    required String userId,
    required String status,
    String? reference,
  }) async {
    final db = _db;
    if (db == null) throw StateError('Firestore is unavailable.');
    await db.collection('payout_profiles').doc(userId).set({
      'lastPayoutStatus': status,
      'lastPayoutAt': FieldValue.serverTimestamp(),
      'lastPayoutReference': ?reference,
      'updatedAt': FieldValue.serverTimestamp(),
    }, SetOptions(merge: true));
  }
}
