import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart';
import 'package:sese_core/sese_core.dart';

import '../../../core/services/remote_config_service.dart';

/// Mirrors an approved driver's profile + KYC into their customer profile.
///
/// Verified drivers (`drivers/{uid}.verificationStatus == 'approved'`) who
/// switch to Customer Mode must NOT be treated as unverified customers:
/// their NIN, address, and live selfie were already audited during driver
/// onboarding. This service copies those records into `users/{uid}` and
/// marks the customer KYC verified, so the "Complete your profile" banner,
/// the "Verify Account" prompts, and the empty Profile Details fields all
/// resolve from the unified record.
///
/// Sync rules:
/// - No-op (returns false) when there is no driver doc, the driver is not
///   approved, or Firestore is unavailable (unit tests / offline).
/// - Only fills customer fields that are missing or empty — a customer's
///   own previously entered data is never overwritten.
/// - Always (re)asserts the verified customer flags for approved drivers.
/// - The write is gated by the `auto_sync_driver_kyc_to_customer` Remote
///   Config flag (default `true`). Turning it off stops the mirroring without
///   an app release; it does not withdraw KYC that has already synced.
///
/// Fields written to `users/{uid}` are `customerVerificationStatus` and
/// `isVerifiedCustomer` (see `CustomerVerification`). There is deliberately
/// no `isVerified` field on the user document — in this codebase `isVerified`
/// is a Firebase Auth custom claim, not a Firestore field, so writing one
/// would be a dead write no reader consumes.
class DriverToCustomerSync {
  const DriverToCustomerSync._();

  /// Runs the sync for [uid]. Returns true when an approved driver record
  /// was mirrored into `users/{uid}`.
  ///
  /// Returns false immediately when the `auto_sync_driver_kyc_to_customer`
  /// flag is disabled.
  static Future<bool> syncIfApprovedDriver(
    String uid, {
    FirebaseFirestore? firestore,
  }) async {
    if (uid.isEmpty) return false;
    if (!RemoteConfigService.autoSyncDriverKycToCustomer) {
      debugPrint('DriverToCustomerSync: skipped (remote flag disabled)');
      return false;
    }
    FirebaseFirestore db;
    try {
      db = firestore ?? FirebaseFirestore.instance;
    } catch (_) {
      return false;
    }
    try {
      final driverSnap = await db.collection('drivers').doc(uid).get();
      final driver = driverSnap.data();
      if (!isApprovedDriverDoc(driver)) return false;

      final userRef = db.collection('users').doc(uid);
      final userSnap = await userRef.get();
      final user = userSnap.data() ?? {};

      await userRef.set(
        buildMirrorUpdate(driver: driver!, user: user),
        SetOptions(merge: true),
      );
      return true;
    } catch (e) {
      debugPrint('DriverToCustomerSync: sync skipped ($e)');
      return false;
    }
  }

  /// Returns true when `drivers/{uid}` exists and is approved. Used by
  /// customer UI to hide redundant KYC prompts for verified drivers even
  /// before (or without) the sync write landing.
  ///
  /// Intentionally **not** gated by `auto_sync_driver_kyc_to_customer`: this is
  /// a read-only recognition that the driver KYC already happened. Disabling
  /// the mirror write should not make the UI re-prompt an approved driver to
  /// verify an account they have already verified.
  static Future<bool> isApprovedDriver(
    String uid, {
    FirebaseFirestore? firestore,
  }) async {
    if (uid.isEmpty) return false;
    FirebaseFirestore db;
    try {
      db = firestore ?? FirebaseFirestore.instance;
    } catch (_) {
      return false;
    }
    try {
      final snap = await db.collection('drivers').doc(uid).get();
      return isApprovedDriverDoc(snap.data());
    } catch (_) {
      return false;
    }
  }

  /// Pure predicate: true when a driver document represents an approved
  /// driver whose KYC may be mirrored into the customer profile.
  static bool isApprovedDriverDoc(Map<String, dynamic>? driver) {
    if (driver == null) return false;
    return (driver[DriverVerification.fieldStatus] ?? '').toString() ==
        DriverVerification.approved;
  }

  /// Pure payload builder: mirrors approved-driver profile/KYC fields into
  /// a `users/{uid}` merge-write payload. Only fills customer fields that
  /// are missing or empty; always asserts the verified customer flags.
  /// Unit-testable without Firestore.
  static Map<String, dynamic> buildMirrorUpdate({
    required Map<String, dynamic> driver,
    required Map<String, dynamic> user,
  }) {
    final existingKyc =
        (user[CustomerVerification.fieldKycData] as Map?)?.map(
              (k, v) => MapEntry(k.toString(), v),
            ) ??
            <String, dynamic>{};

    String driverStr(String key) =>
        (driver[key] ?? '').toString().trim();
    String userStr(String key) => (user[key] ?? '').toString().trim();
    String kycStr(String key) =>
        (existingKyc[key] ?? '').toString().trim();

    // Driver-side address: prefer the residential/home address fields.
    final driverAddress = driverStr('homeAddress').isNotEmpty
        ? driverStr('homeAddress')
        : driverStr('address');
    final driverFullName = driverStr('fullName').isNotEmpty
        ? driverStr('fullName')
        : '${driverStr('firstName')} ${driverStr('lastName')}'.trim();

    // Top-level customer fields: fill only when missing/empty.
    final topLevel = <String, dynamic>{};
    void fillTopLevel(String key, String value) {
      if (value.isNotEmpty && userStr(key).isEmpty) {
        topLevel[key] = value;
      }
    }

    fillTopLevel('firstName', driverStr('firstName'));
    fillTopLevel('lastName', driverStr('lastName'));
    fillTopLevel('fullName', driverFullName);
    fillTopLevel('displayName', driverFullName);
    fillTopLevel('phoneNumber', driverStr('phoneNumber'));
    fillTopLevel(
        'phoneNumberE164',
        driverStr('phoneNumberE164').isNotEmpty
            ? driverStr('phoneNumberE164')
            : driverStr('phoneNumber'));

    // Nested kycData: merge over the existing map, filling empties.
    final kyc = Map<String, dynamic>.from(existingKyc);
    void fillKyc(String key, String value) {
      if (value.isNotEmpty && kycStr(key).isEmpty) {
        kyc[key] = value;
      }
    }

    fillKyc('firstName', driverStr('firstName'));
    fillKyc('lastName', driverStr('lastName'));
    fillKyc('fullName', driverFullName);
    fillKyc('dateOfBirth', driverStr('dateOfBirth'));
    fillKyc('gender', driverStr('gender'));
    fillKyc('residentialAddress', driverAddress);
    fillKyc('idType', driverStr('idType'));
    fillKyc('idNumber', driverStr('idNumber'));
    fillKyc('idFrontUrl', driverStr('idFrontUrl'));
    fillKyc('idBackUrl', driverStr('idBackUrl'));
    fillKyc('selfieUrl', driverStr('selfieUrl'));

    return {
      ...topLevel,
      CustomerVerification.fieldKycData: kyc,
      CustomerVerification.fieldStatus: CustomerVerification.verified,
      CustomerVerification.fieldIsVerified: true,
      CustomerVerification.fieldRejectionReason: '',
    };
  }
}
