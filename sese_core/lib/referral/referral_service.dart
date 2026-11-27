import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:flutter/foundation.dart';

import 'referral_code.dart';

/// Client referral API shared by sese_ride (hub screen, onboarding)
/// and sese_hub (read-only lookups).
///
/// Firestore layout:
/// - Verified users/drivers/staff/agents carry their official `sequentialId`
///   (`SC0001`, `SD0001`, `SH0001`, `SA0001`).
/// - `/unique_sequential_ids/{SEQ_ID}` & `/referral_codes/{CODE}` are the public
///   lookup indices `{ownerUid, role, sequentialId, firstName, isVerified}`
///   accessible via single-doc read (`get`) so unauthenticated onboarding validation
///   never needs cross-user reads.
/// - Unauthenticated fallbacks cleanly invoke the backend `validateReferralCode`
///   Cloud Function, which self-heals any missing index document.
class ReferralService {
  final FirebaseFirestore? _firestore;
  final FirebaseFunctions? _functions;

  const ReferralService([this._firestore, this._functions]);

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

  /// Validates [input] (official Member ID like `SC0001` or `SD0001`) against
  /// verified user records. Returns the referrer's UID when valid, null when
  /// blank/invalid. Never throws — returns null on offline/permission errors.
  Future<String?> resolveReferrerId(String input) async {
    final details = await resolveReferrerDetails(input);
    return details?['referrerId'];
  }

  /// Validates [input] against `/unique_sequential_ids` (and `/referral_codes` /
  /// backend callable fallback) and fetches the referrer's UID and first name for UI
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

      // 1. Primary lookup: direct single-doc get on /unique_sequential_ids/{code}
      try {
        final snap = await db.collection('unique_sequential_ids').doc(code).get();
        if (snap.exists && snap.data() != null) {
          final data = snap.data()!;
          id = (data['ownerUid'] ?? data['referrerId'] ?? data['userId'] ?? '').toString().trim();
          final role = (data['role'] ?? '').toString();
          coll = role == 'driver' ? 'drivers' : (role == 'staff' || role == 'hub' ? 'hub_staff' : 'users');
          firstName = (data['firstName'] ?? '').toString().trim();
        }
      } catch (e) {
        debugPrint('ReferralService.unique_sequential_ids get error: $e');
      }

      // 2. Secondary lookup: direct single-doc get on /referral_codes/{code}
      if (id.isEmpty) {
        try {
          final refSnap = await db.collection('referral_codes').doc(code).get();
          if (refSnap.exists && refSnap.data() != null) {
            final data = refSnap.data()!;
            id = (data['ownerUid'] ?? data['referrerId'] ?? data['userId'] ?? '').toString().trim();
            final role = (data['role'] ?? '').toString();
            coll = role == 'driver' ? 'drivers' : (role == 'staff' || role == 'hub' ? 'hub_staff' : 'users');
            firstName = (data['firstName'] ?? '').toString().trim();
          }
        } catch (e) {
          debugPrint('ReferralService.referral_codes get error: $e');
        }
      }

      // 3. Fallback: server-authoritative callable validateReferralCode (handles legacy un-indexed members)
      if (id.isEmpty) {
        try {
          final fn = _fn;
          if (fn != null) {
            final callable = fn.httpsCallable('validateReferralCode');
            final resp = await callable.call<dynamic>({'code': code});
            final rawData = resp.data;
            if (rawData is Map) {
              final data = Map<String, dynamic>.from(rawData);
              if (data['valid'] == true) {
                id = (data['referrerId'] ?? '').toString().trim();
                firstName = (data['firstName'] ?? '').toString().trim();
                final role = (data['role'] ?? '').toString();
                coll = role == 'driver' ? 'drivers' : (role == 'staff' || role == 'hub' ? 'hub_staff' : 'users');
              }
            }
          }
        } catch (e) {
          debugPrint('ReferralService.validateReferralCode callable error: $e');
        }
      }

      // 4. Authenticated client fallback queries on users/drivers collections
      if (id.isEmpty) {
        try {
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
              final rawFirst = (uData['firstName'] ?? uData['fullName'] ?? uData['displayName'] ?? '').toString().trim();
              if (rawFirst.isNotEmpty) {
                firstName = rawFirst.split(RegExp(r'\s+')).first;
              }
            }
          }
        } catch (_) {}
      }

      if (id.isEmpty) {
        try {
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
              final rawFirst = (dData['firstName'] ?? dData['fullName'] ?? dData['displayName'] ?? '').toString().trim();
              if (rawFirst.isNotEmpty) {
                firstName = rawFirst.split(RegExp(r'\s+')).first;
              }
            }
          }
        } catch (_) {}
      }

      if (id.isEmpty) return null;

      if (firstName.isEmpty) {
        firstName = coll == 'drivers' ? 'Driver' : 'Member';
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

  /// Applies [code] (e.g. `SC0001`, `SD0001`, `SA0001`) as the referrer for
  /// the currently authenticated user via the server-authoritative
  /// `applyReferralCode` Cloud Function.
  Future<bool> applyReferralCode(String code) async {
    final normalized = normalizeReferralCode(code);
    if (normalized.isEmpty || !isPlausibleReferralCode(normalized)) return false;
    try {
      final fn = _fn;
      if (fn == null) return false;
      final callable = fn.httpsCallable('applyReferralCode');
      final resp = await callable.call<dynamic>({'code': normalized});
      final raw = resp.data;
      if (raw is Map && raw['success'] == true) {
        return true;
      }
      return false;
    } catch (e) {
      debugPrint('ReferralService.applyReferralCode error: $e');
      return false;
    }
  }
}
