import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart';

import 'referral_code.dart';

/// Client referral API shared by sese_ride (hub screen, onboarding)
/// and sese_hub (read-only lookups).
///
/// Firestore layout:
/// - `/users/{uid}` and `/drivers/{uid}` carry `referralCode`, `referredBy`,
///   `referralSignupAt`.
/// - `/referral_codes/{CODE}` is the public lookup mirror
///   `{referrerId, collection}` readable by any authenticated user so
///   onboarding validation never needs a cross-user `/users` list query.
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
}
