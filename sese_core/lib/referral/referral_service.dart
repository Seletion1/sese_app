import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart';

import 'referral_code.dart';

/// Client referral API shared by sese_ride (hub screen, onboarding)
/// and sese_hub (read-only lookups).
///
/// Firestore layout:
/// - Verified users/drivers carry their official `sequentialId` (`SC0001`, `SD0001`, `SH0001`).
/// - `/unique_sequential_ids/{SEQ_ID}` is the public lookup index
///   `{ownerUid, role, sequentialId, firstName, isVerified}` readable by any
///   authenticated user so onboarding validation never needs cross-user reads.
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

  /// Validates [input] (official Member ID like `SC0001` or `SD0001`) against
  /// verified user records. Returns the referrer's UID when valid, null when
  /// blank/invalid. Never throws — returns null on offline/permission errors.
  Future<String?> resolveReferrerId(String input) async {
    final details = await resolveReferrerDetails(input);
    return details?['referrerId'];
  }

  /// Validates [input] against `/unique_sequential_ids` (and verified `users` /
  /// `drivers` fallback) and fetches the referrer's UID and first name for UI
  /// confirmation.
  Future<Map<String, String>?> resolveReferrerDetails(String input) async {
    final code = normalizeReferralCode(input);
    if (code.isEmpty || !isPlausibleReferralCode(code)) return null;
    final db = _db;
    if (db == null) return null;
    try {
      String id = '';
      String coll = 'users';
      String firstName = '';

      final snap = await db.collection('unique_sequential_ids').doc(code).get();
      if (snap.exists && snap.data() != null) {
        final data = snap.data()!;
        id = (data['ownerUid'] ?? '').toString();
        final role = (data['role'] ?? '').toString();
        coll = role == 'driver' ? 'drivers' : (role == 'staff' ? 'hub_staff' : 'users');
        firstName = (data['firstName'] ?? '').toString().trim();
      }

      if (id.isEmpty) {
        final userQuery = await db
            .collection('users')
            .where('sequentialId', isEqualTo: code)
            .limit(1)
            .get();
        if (userQuery.docs.isNotEmpty) {
          final uData = userQuery.docs.first.data();
          final verified = uData['isVerifiedCustomer'] == true ||
              uData['isProfileVerified'] == true ||
              uData['verificationStatus'] == 'verified' ||
              uData['verificationStatus'] == 'approved';
          if (verified) {
            id = userQuery.docs.first.id;
            coll = 'users';
          }
        }
      }

      if (id.isEmpty) {
        final driverQuery = await db
            .collection('drivers')
            .where('sequentialId', isEqualTo: code)
            .limit(1)
            .get();
        if (driverQuery.docs.isNotEmpty) {
          final dData = driverQuery.docs.first.data();
          final verified = dData['isProfileVerified'] == true ||
              dData['verificationStatus'] == 'verified' ||
              dData['verificationStatus'] == 'approved';
          if (verified) {
            id = driverQuery.docs.first.id;
            coll = 'drivers';
          }
        }
      }

      if (id.isEmpty) return null;

      if (firstName.isEmpty) {
        firstName = 'Member';
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
      }

      return {
        'referrerId': id,
        'firstName': firstName,
        'memberId': code,
      };
    } catch (e) {
      debugPrint('ReferralService.resolveReferrerDetails: $e');
      return null;
    }
  }
}
