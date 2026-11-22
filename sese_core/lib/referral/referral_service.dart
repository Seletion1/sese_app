import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart';

import '../financial/financial_config.dart';
import '../models/user_role.dart';
import 'referral_code.dart';

/// One referred user + cumulative earnings + eligibility countdown.
class ReferredUserEntry {
  final String userId;
  final String fullName;
  final DateTime? joinedAt;
  final double totalEarned;
  final int daysRemaining;
  final bool isActive;

  const ReferredUserEntry({
    required this.userId,
    required this.fullName,
    this.joinedAt,
    this.totalEarned = 0,
    this.daysRemaining = 0,
    this.isActive = true,
  });
}

/// Aggregate referral stats for the Referral Hub earnings card.
class ReferralStats {
  final int totalReferrals;
  final int activeReferrals;
  final double totalCoinsEarned;

  const ReferralStats({
    this.totalReferrals = 0,
    this.activeReferrals = 0,
    this.totalCoinsEarned = 0,
  });
}

/// Client referral API shared by sese_ride (hub screen, onboarding,
/// dashboard) and sese_hub (read-only lookups).
///
/// Firestore layout:
/// - `/users/{uid}` and `/drivers/{uid}` carry `referralCode`, `referredBy`,
///   `referralSignupAt`, `referralExpiresAt`, `referrerRole`.
/// - `/referral_codes/{CODE}` is the public lookup mirror
///   `{referrerId, collection}` readable by any authenticated user so
///   onboarding validation never needs a cross-user `/users` list query.
/// - `/referral_earnings/{id}` rows carry
///   `{referrerId, refereeId, amount, orderId, createdAt}` (server-written).
class ReferralService {
  final FirebaseFirestore? _firestore;

  const ReferralService([this._firestore]);

  FirebaseFirestore? get _db {
    try {
      return _firestore ?? FirebaseFirestore.instance;
    } catch (_) {
      return null;
    }
  }

  /// Validates [input] against `/referral_codes`. Returns the referrer's
  /// user id when valid, null when blank/invalid. Never throws — returns
  /// null on offline/permission errors so onboarding never blocks.
  Future<String?> resolveReferrerId(String input) async {
    final details = await resolveReferrerDetails(input);
    return details?['referrerId'];
  }

  /// Validates [input] against `/referral_codes` and fetches the referrer's
  /// ID and first name for visual UI confirmation.
  Future<Map<String, String>?> resolveReferrerDetails(String input) async {
    final code = normalizeReferralCode(input);
    if (code.isEmpty) return null;
    final db = _db;
    if (db == null) return null;
    try {
      String id = '';
      String coll = 'users';
      final snap = await db.collection('referral_codes').doc(code).get();
      if (snap.exists && snap.data() != null) {
        final data = snap.data()!;
        id = (data['referrerId'] ?? '').toString();
        coll = (data['collection'] ?? 'users').toString();
      }

      if (id.isEmpty) {
        final userQuery = await db
            .collection('users')
            .where('referralCode', isEqualTo: code)
            .limit(1)
            .get();
        if (userQuery.docs.isNotEmpty) {
          id = userQuery.docs.first.id;
          coll = 'users';
        }
      }

      if (id.isEmpty) return null;

      String firstName = 'Referrer';
      try {
        final userSnap = await db.collection(coll).doc(id).get();
        if (userSnap.exists && userSnap.data() != null) {
          final uData = userSnap.data()!;
          final fullName = (uData['fullName'] ??
                  uData['displayName'] ??
                  uData['firstName'] ??
                  '')
              .toString();
          if (fullName.isNotEmpty) {
            firstName = fullName.trim().split(RegExp(r'\s+')).first;
          }
        }
      } catch (_) {}

      return {
        'referrerId': id,
        'firstName': firstName,
      };
    } catch (e) {
      debugPrint('ReferralService.resolveReferrerDetails: $e');
      return null;
    }
  }

  /// Streams aggregate stats for [referrerId] (counts from user/driver docs
  /// where `referredBy == referrerId`; coins from their wallet doc).
  Stream<ReferralStats> statsStream(String referrerId) {
    final db = _db;
    if (db == null || referrerId.isEmpty) {
      return Stream.value(const ReferralStats());
    }
    // Combine three lightweight streams manually via asyncMap on referrals.
    return _referredDocsStream(db, referrerId).asyncMap((docs) async {
      int active = 0;
      final now = DateTime.now();
      for (final d in docs) {
        final exp = _parseDate(d['referralExpiresAt']);
        if (exp == null || exp.isAfter(now)) active++;
      }
      double coins = 0;
      try {
        final w =
            await db.collection('wallets').doc(referrerId).get();
        coins = ((w.data()?['seseCoinBalance'] as num?) ?? 0).toDouble();
      } catch (_) {}
      double lifetime = coins;
      try {
        final earn = await db
            .collection('referral_earnings')
            .where('referrerId', isEqualTo: referrerId)
            .get();
        double sum = 0;
        for (final e in earn.docs) {
          sum += ((e.data()['amount'] as num?) ?? 0).toDouble();
        }
        if (sum > 0) lifetime = sum;
      } catch (_) {}
      return ReferralStats(
        totalReferrals: docs.length,
        activeReferrals: active,
        totalCoinsEarned: lifetime,
      );
    }).handleError((Object _) => const ReferralStats());
  }

  /// Streams every referred user with cumulative earnings + countdown.
  Stream<List<ReferredUserEntry>> referralsStream(String referrerId) {
    final db = _db;
    if (db == null || referrerId.isEmpty) {
      return Stream.value(const <ReferredUserEntry>[]);
    }
    return _referredDocsStream(db, referrerId).asyncMap((docs) async {
      // Batch-load cumulative earnings per referee.
      final Map<String, double> earnedByReferee = {};
      try {
        final earn = await db
            .collection('referral_earnings')
            .where('referrerId', isEqualTo: referrerId)
            .get();
        for (final e in earn.docs) {
          final rid = (e.data()['refereeId'] ?? '').toString();
          earnedByReferee[rid] =
              (earnedByReferee[rid] ?? 0) +
              (((e.data()['amount'] as num?) ?? 0).toDouble());
        }
      } catch (e) {
        debugPrint('ReferralService earnings read: $e');
      }
      final now = DateTime.now();
      final out = <ReferredUserEntry>[];
      for (final d in docs) {
        final exp = _parseDate(d['referralExpiresAt']);
        final joined = _parseDate(
            d['referralSignupAt'] ?? d['createdAt']);
        int remaining = 0;
        bool active = true;
        if (exp != null) {
          remaining = exp.difference(now).inDays;
          if (remaining < 0) {
            remaining = 0;
            active = false;
          }
        }
        out.add(ReferredUserEntry(
          userId: (d['uid'] ?? d['userId'] ?? '').toString(),
          fullName: (d['fullName'] ?? d['displayName'] ?? 'Referred user')
              .toString(),
          joinedAt: joined,
          totalEarned: earnedByReferee[(d['uid'] ?? '').toString()] ?? 0,
          daysRemaining: remaining,
          isActive: active,
        ));
      }
      out.sort((a, b) => b.totalEarned.compareTo(a.totalEarned));
      return out;
    }).handleError((Object _) => const <ReferredUserEntry>[]);
  }

  /// Merges `/users` + `/drivers` docs referred by [referrerId].
  ///
  /// Reads are server-minted only: `referral_codes/{CODE}` is public
  /// readable (`firestore.rules`), and the referee docs are read by UID
  /// (owner-readable). Legacy `referredBy` collection queries are
  /// intentionally NOT issued any more — they are client-banned
  /// (`firestore.rules` bans the field on `users`/`drivers`) and would be
  /// silently empty anyway.
  Stream<List<Map<String, dynamic>>> _referredDocsStream(
      FirebaseFirestore db, String referrerId) async* {
    yield await _fetchAll(db, referrerId);
    // Live updates: re-emit when any referee doc or earnings row changes.
    yield* Stream.fromFutures(
      [
        db.collection('referral_codes').doc(referrerId.toUpperCase()).snapshots(),
        db
            .collection('referral_earnings')
            .where('referrerId', isEqualTo: referrerId)
            .snapshots(),
      ],
    ).asyncMap((_) => _fetchAll(db, referrerId)).handleError(
          (Object _) => const <Map<String, dynamic>>[],
        );
  }

  /// Resolves the referee docs (`users`/`drivers`) for [referrerId].
  Future<List<Map<String, dynamic>>> _fetchAll(
      FirebaseFirestore db, String referrerId) async {
    // Resolve the referee UID through the public referral_codes mirror.
    String refereeUid = '';
    final out = <Map<String, dynamic>>[];
    try {
      final codeSnap = await db
          .collection('referral_codes')
          .doc(referrerId.toUpperCase())
          .get();
      refereeUid = (codeSnap.data()?['referrerId'] ?? '').toString();
    } catch (_) {}

    if (refereeUid.isNotEmpty) {
      // A dual-role referee may be in either `users` or `drivers` — probe
      // both; owner reads are allowed by the security rules.
      for (final col in ['users', 'drivers']) {
        try {
          final snap = await db.collection(col).doc(refereeUid).get();
          if (snap.exists) {
            final m = Map<String, dynamic>.from(snap.data()!);
            m['uid'] = refereeUid;
            out.add(m);
          }
        } catch (_) {}
      }
    }
    return out;
  }

  static DateTime? _parseDate(dynamic v) {
    if (v == null) return null;
    try {
      return (v as dynamic).toDate() as DateTime;
    } catch (_) {}
    if (v is String) return DateTime.tryParse(v);
    if (v is int) {
      return DateTime.fromMillisecondsSinceEpoch(v);
    }
    return null;
  }

  /// Eligibility window (days) for a referrer role.
  static int windowDaysForRole(UserRole role, FinancialConfig cfg) {
    switch (role) {
      case UserRole.agent:
      case UserRole.admin:
      case UserRole.superRole:
        return cfg.agentReferralDurationDays;
      case UserRole.customer:
      case UserRole.driver:
        return cfg.standardReferralDurationDays;
    }
  }

  /// Commission rate for a referrer role.
  static double rateForRole(UserRole role, FinancialConfig cfg) {
    switch (role) {
      case UserRole.agent:
      case UserRole.admin:
      case UserRole.superRole:
        return cfg.agentReferralCommissionRate;
      case UserRole.customer:
      case UserRole.driver:
        return cfg.userReferralCommissionRate;
    }
  }
}
