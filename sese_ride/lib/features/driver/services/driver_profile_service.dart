import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart' as fb;
import 'package:firebase_storage/firebase_storage.dart';
import 'package:flutter/foundation.dart';
import 'package:sese_core/sese_core.dart';

/// Read model for `drivers/{uid}` profile fields shown on the profile screen.
class DriverProfile {
  final String uid;
  final String fullName;
  final String email;
  final String phoneNumber;
  final String photoUrl;
  final String homeAddress;
  final String verificationStatus;
  final String licenseNo;
  final String initialVehicleType;
  final DateTime? createdAt;

  /// Compliance expiry dates stored on `drivers/{uid}`.
  ///
  /// Null means the driver has not yet entered a value (treated as unknown,
  /// not expired). The server never auto-sets these; the driver enters them
  /// from their physical documents via [DriverProfileService.saveDocumentExpiry].
  final DateTime? licenseExpiry;
  final DateTime? inspectionExpiry;
  final DateTime? insuranceExpiry;

  /// Hub audit flags on `drivers/{uid}`. Drivers may only go Online when
  /// both [isProfileVerified] and [isVehicleVerified] are true.
  final bool isProfileVerified;
  final bool isVehicleVerified;
  final bool canGoOnline;

  /// Per-field review map written by hub. Keys are field IDs
  /// (e.g. `homeAddress`, `licenseNo`, `idFront`). Empty when no review
  /// has been submitted yet.
  final Map<String, FieldReviewStatus> fieldReviewStatus;

  /// Overall rejection reason from the hub when [verificationStatus] is
  /// `rejected`. Empty when not rejected or no reason provided.
  final String profileRejectionReason;

  const DriverProfile({
    required this.uid,
    this.fullName = '',
    this.email = '',
    this.phoneNumber = '',
    this.photoUrl = '',
    this.homeAddress = '',
    this.verificationStatus = '',
    this.licenseNo = '',
    this.initialVehicleType = '',
    this.createdAt,
    this.licenseExpiry,
    this.inspectionExpiry,
    this.insuranceExpiry,
    this.isProfileVerified = false,
    this.isVehicleVerified = false,
    this.canGoOnline = false,
    this.fieldReviewStatus = const {},
    this.profileRejectionReason = '',
  });

  factory DriverProfile.fromMap(String uid, Map<String, dynamic> map) {
    DateTime? when;
    final raw = map['createdAt'];
    try {
      if (raw != null) when = (raw as dynamic).toDate() as DateTime?;
    } catch (_) {
      if (raw is String) when = DateTime.tryParse(raw);
    }

    /// Safely converts a Firestore Timestamp or ISO-8601 String to DateTime.
    DateTime? parseDate(dynamic v) {
      if (v == null) return null;
      try {
        return (v as dynamic).toDate() as DateTime;
      } catch (_) {
        if (v is String) return DateTime.tryParse(v);
        return null;
      }
    }

    return DriverProfile(
      uid: uid,
      fullName: (map['fullName'] ?? map['name'] ?? '').toString(),
      email: (map['email'] ?? '').toString(),
      phoneNumber:
          (map['phoneNumber'] ?? map['phone'] ?? '').toString(),
      photoUrl:
          (map['photoUrl'] ?? map['photoURL'] ?? '').toString(),
      homeAddress: (map['homeAddress'] ?? map['address'] ?? '').toString(),
      verificationStatus:
          (map['verificationStatus'] ?? '').toString(),
      licenseNo: (map['licenseNo'] ?? '').toString(),
      initialVehicleType:
          (map['initialVehicleType'] ?? map['vehicleType'] ?? '').toString(),
      createdAt: when,
      licenseExpiry: parseDate(map['licenseExpiry']),
      inspectionExpiry: parseDate(map['inspectionExpiry']),
      insuranceExpiry: parseDate(map['insuranceExpiry']),
      isProfileVerified: map['isProfileVerified'] == true,
      isVehicleVerified: map['isVehicleVerified'] == true,
      canGoOnline: map['canGoOnline'] == true,
      fieldReviewStatus: () {
        final raw = map['fieldReviewStatus'];
        if (raw is Map) {
          return Map.fromEntries(
            raw.entries
                .whereType<MapEntry<String, dynamic>>()
                .where((e) => e.value is Map)
                .map((e) => MapEntry(
                      e.key,
                      FieldReviewStatus.fromMap(
                          Map<String, dynamic>.from(e.value as Map)),
                    )),
          );
        }
        return const <String, FieldReviewStatus>{};
      }(),
      profileRejectionReason:
          (map[DriverVerification.fieldProfileRejectionReason] ?? '').toString(),
    );
  }

  // ---------------------------------------------------------------------------
  // Expiry helpers (used by both the UI and the dashboard guard).
  // ---------------------------------------------------------------------------

  /// Returns the label of the first mandatory document that is expired (past
  /// today at midnight), or null when all are within date or not yet entered.
  String? get firstExpiredDocument {
    final today = _todayMidnight();
    if (licenseExpiry != null && licenseExpiry!.isBefore(today)) {
      return "Driver's License";
    }
    if (inspectionExpiry != null && inspectionExpiry!.isBefore(today)) {
      return 'Vehicle Inspection Certificate';
    }
    if (insuranceExpiry != null && insuranceExpiry!.isBefore(today)) {
      return 'Vehicle Insurance Policy';
    }
    return null;
  }

  /// Returns the label of the first document expiring within the next 7 days
  /// (but not yet expired), or null when nothing is imminently due.
  String? get firstSoonExpiringDocument {
    final today = _todayMidnight();
    final warnCutoff = today.add(const Duration(days: 7));
    if (licenseExpiry != null &&
        !licenseExpiry!.isBefore(today) &&
        licenseExpiry!.isBefore(warnCutoff)) {
      return "Driver's License";
    }
    if (inspectionExpiry != null &&
        !inspectionExpiry!.isBefore(today) &&
        inspectionExpiry!.isBefore(warnCutoff)) {
      return 'Vehicle Inspection Certificate';
    }
    if (insuranceExpiry != null &&
        !insuranceExpiry!.isBefore(today) &&
        insuranceExpiry!.isBefore(warnCutoff)) {
      return 'Vehicle Insurance Policy';
    }
    return null;
  }

  static DateTime _todayMidnight() {
    final now = DateTime.now();
    return DateTime(now.year, now.month, now.day);
  }
}

/// Thrown for profile failures. Carries a [userMessage] safe for SnackBars.
class DriverProfileException implements Exception {
  final String code;
  final String userMessage;

  const DriverProfileException(this.code, this.userMessage);

  @override
  String toString() => 'DriverProfileException($code): $userMessage';
}

/// Driver profile data + actions.
///
/// - Reads `drivers/{uid}` (read-only profile + registration details).
/// - Phone edits write `phoneNumber` + `phoneNumberE164` (Firestore rules
///   require the valid E.164 pair on every driver update).
/// - Avatar capture is camera-only ([ImagePickerSource.camera] equivalent);
///   gallery is never offered so submissions stay authentic.
class DriverProfileService {
  final FirebaseFirestore? _firestore;
  final FirebaseStorage? _storage;

  /// Test seams: override camera capture / upload without platform plugins.
  final Future<XFile?> Function()? pickImageOverride;
  final Future<String> Function(XFile file, String uid)? uploadOverride;

  DriverProfileService(
      {this._firestore,
      this._storage,
      this.pickImageOverride,
      this.uploadOverride});

  FirebaseFirestore? get _db {
    try {
      return _firestore ?? FirebaseFirestore.instance;
    } catch (_) {
      return null;
    }
  }

  /// Live driver profile. Null when unavailable/denied (ends, no retry loop).
  Stream<DriverProfile?> profileStream(String uid) {
    final db = _db;
    if (db == null || uid.isEmpty) return Stream.value(null);
    return db
        .collection('drivers')
        .doc(uid)
        .snapshots()
        .map((doc) => doc.data() == null
            ? null
            : DriverProfile.fromMap(doc.id, doc.data()!))
        .handleError((Object _) => null);
  }

  /// Normalizes a raw phone entry to E.164. Delegates to [SesePhoneSanitizer].
  /// Returns null when the result is not a valid E.164 number.
  static String? toE164(String raw) {
    if (raw.trim().isEmpty) return null;
    final normalized = SesePhoneSanitizer.normalize(raw, defaultIsoCode: 'NG');
    if (!SesePhoneSanitizer.isValidE164(normalized)) return null;
    return normalized;
  }

  /// Saves the driver's phone number (both E.164 fields the rules require).
  Future<void> savePhoneNumber(String uid, String rawPhone) async {
    final e164 = toE164(rawPhone);
    if (e164 == null) {
      throw const DriverProfileException(
        'invalid-phone',
        'Enter a valid phone number (e.g. 0803 123 4567).',
      );
    }
    final db = _db;
    if (db == null || uid.isEmpty) {
      throw const DriverProfileException(
        'unavailable',
        'Profile service unavailable. Try again.',
      );
    }
    try {
      await db.collection('drivers').doc(uid).update({
        'phoneNumber': e164,
        'phoneNumberE164': e164,
        'updatedAt': FieldValue.serverTimestamp(),
      });
    } catch (e) {
      debugPrint('DriverProfileService.savePhoneNumber error: $e');
      throw const DriverProfileException(
        'save-failed',
        'Could not save the phone number. Check your connection.',
      );
    }
  }

  /// Writes document expiry dates to `drivers/{uid}`.
  ///
  /// Any null argument is omitted from the update, so callers can save a
  /// single field without clobbering the others.
  Future<void> saveDocumentExpiry(
    String uid, {
    DateTime? licenseExpiry,
    DateTime? inspectionExpiry,
    DateTime? insuranceExpiry,
  }) async {
    final db = _db;
    if (db == null || uid.isEmpty) {
      throw const DriverProfileException(
        'unavailable',
        'Profile service unavailable. Try again.',
      );
    }
    final payload = <String, dynamic>{
      'updatedAt': FieldValue.serverTimestamp(),
    };
    if (licenseExpiry != null) payload['licenseExpiry'] = licenseExpiry;
    if (inspectionExpiry != null) payload['inspectionExpiry'] = inspectionExpiry;
    if (insuranceExpiry != null) payload['insuranceExpiry'] = insuranceExpiry;
    try {
      await db.collection('drivers').doc(uid).update(payload);
    } catch (e) {
      debugPrint('DriverProfileService.saveDocumentExpiry error: $e');
      throw const DriverProfileException(
        'save-failed',
        'Could not save document expiry dates. Check your connection.',
      );
    }
  }

  /// Updates a single rejected field value and sets overall verificationStatus
  /// back to `pending` while preserving `approved` field statuses in the
  /// fieldReviewStatus map (only clearing the resubmitted field's entry).
  ///
  /// Call this for each individual field the driver edits (homeAddress,
  /// licenseNo, initialVehicleType). After all edits, call [resubmitProfile].
  Future<void> updateRejectedField(
    String uid,
    String fieldId,
    dynamic newValue,
  ) async {
    final db = _db;
    if (db == null || uid.isEmpty) {
      throw const DriverProfileException(
        'unavailable',
        'Profile service unavailable. Try again.',
      );
    }
    try {
      await db.collection('drivers').doc(uid).update({
        fieldId: newValue,
        // Remove just this field from the fieldReviewStatus map so the hub
        // sees it as fresh when re-reviewing.
        '${DriverVerification.fieldReviewStatus}.$fieldId':
            FieldValue.delete(),
        'updatedAt': FieldValue.serverTimestamp(),
      });
    } catch (e) {
      debugPrint('DriverProfileService.updateRejectedField error: $e');
      throw const DriverProfileException(
        'save-failed',
        'Could not save your change. Check your connection.',
      );
    }
  }

  /// Marks the driver profile as re-submitted for hub review after the driver
  /// has corrected rejected fields. Sets verificationStatus back to `pending`
  /// and `isPendingReview` to true.
  Future<void> resubmitProfile(String uid) async {
    final db = _db;
    if (db == null || uid.isEmpty) {
      throw const DriverProfileException(
        'unavailable',
        'Profile service unavailable. Try again.',
      );
    }
    try {
      await db.collection('drivers').doc(uid).update({
        DriverVerification.fieldStatus: DriverVerification.pending,
        'isPendingReview': true,
        DriverVerification.fieldProfileRejectionReason: FieldValue.delete(),
        'updatedAt': FieldValue.serverTimestamp(),
      });
    } catch (e) {
      debugPrint('DriverProfileService.resubmitProfile error: $e');
      throw const DriverProfileException(
        'save-failed',
        'Could not submit your profile. Check your connection.',
      );
    }
  }

  /// Captures a driver photo with the device camera ONLY and publishes it:
  /// uploads to Firebase Storage, then updates `photoUrl` on the driver
  /// document (and the Firebase Auth profile so headers refresh app-wide).
  /// Returns the download URL, or null when the user cancels capture.
  Future<String?> captureAndPublishAvatar(String uid) async {
    if (uid.isEmpty) {
      throw const DriverProfileException(
          'invalid-user', 'Sign in again to update your photo.');
    }
    // Runtime camera handshake BEFORE the native picker (no BuildContext
    // here, so a permanent denial surfaces as null — the caller shows the
    // settings prompt via MediaPermissionService.promptIfPermanentlyDenied).
    final permission =
        await MediaPermissionService.ensureFor(ImageSource.camera);
    if (permission != MediaPermissionOutcome.granted) return null;
    final XFile? file = pickImageOverride != null
        ? await pickImageOverride!()
        : await ImageCompressionService.pickAndCompressImage(
            source: ImageSource.camera,
            preferredCameraDevice: CameraDevice.front,
            targetScreen: 'driver_profile',
            targetField: 'profile_photo',
            userId: uid,
          );
    if (file == null) return null; // user cancelled

    final url = uploadOverride != null
        ? await uploadOverride!(file, uid)
        : await _uploadAvatar(uid, file);

    final db = _db;
    try {
      if (db != null) {
        // Use set(merge: true) so the write succeeds even when the document
        // was not yet created on Firestore (e.g. driver account just set up).
        await db.collection('drivers').doc(uid).set({
          'photoUrl': url,
          'updatedAt': FieldValue.serverTimestamp(),
        }, SetOptions(merge: true));
        // Best-effort mirror for any users/{uid} doc + auth profile so
        // avatars refresh across the app without re-login.
        try {
          final userDoc = await db.collection('users').doc(uid).get();
          if (userDoc.exists) {
            await db.collection('users').doc(uid).update({'photoUrl': url});
          }
        } catch (_) {}
      }
      try {
        await fb.FirebaseAuth.instance.currentUser?.updatePhotoURL(url);
      } catch (_) {}
    } catch (e) {
      debugPrint('DriverProfileService avatar publish error: $e');
      throw const DriverProfileException(
        'publish-failed',
        'Photo uploaded but the profile could not be updated.',
      );
    }
    return url;
  }

  Future<String> _uploadAvatar(String uid, XFile file) async {
    FirebaseStorage getStorage() {
      try {
        return _storage ?? FirebaseStorage.instance;
      } catch (_) {
        throw const DriverProfileException(
          'unavailable',
          'Photo upload is unavailable. Try again.',
        );
      }
    }

    try {
      final stamp = DateTime.now().millisecondsSinceEpoch;
      final ref =
          getStorage().ref('driver_photos/$uid/profile_$stamp.jpg');
      final rawBytes = await file.readAsBytes();
      final bytes = await ImageCompressionService.compressBytes(rawBytes);
      await ref.putData(
        bytes,
        SettableMetadata(contentType: 'image/jpeg'),
      );
      return await ref.getDownloadURL();
    } catch (e) {
      debugPrint('DriverProfileService._uploadAvatar error: $e');
      if (e is DriverProfileException) rethrow;
      throw const DriverProfileException(
        'upload-failed',
        'Photo upload failed. Check your connection and try again.',
      );
    }
  }
}
