import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:flutter/foundation.dart';
import 'package:sese_core/sese_core.dart';

/// Account lookup result model returned by backend `lookupAccountForOnboarding`.
class OnboardingLookupResult {
  final bool exists;
  final String? uid;
  final String? role;
  final String? customerVerificationStatus;
  final String? driverVerificationStatus;
  final int vehicleCount;
  final List<String> missingSteps;
  final Map<String, dynamic>? userData;
  final Map<String, dynamic>? driverData;
  final String? message;

  const OnboardingLookupResult({
    required this.exists,
    this.uid,
    this.role,
    this.customerVerificationStatus,
    this.driverVerificationStatus,
    this.vehicleCount = 0,
    this.missingSteps = const [],
    this.userData,
    this.driverData,
    this.message,
  });

  factory OnboardingLookupResult.fromMap(Map<String, dynamic> map) {
    return OnboardingLookupResult(
      exists: map['exists'] == true,
      uid: map['uid'] as String?,
      role: map['role'] as String?,
      customerVerificationStatus: map['customerVerificationStatus'] as String?,
      driverVerificationStatus: map['driverVerificationStatus'] as String?,
      vehicleCount: (map['vehicleCount'] as num?)?.toInt() ?? 0,
      missingSteps: (map['missingSteps'] as List?)?.map((e) => e.toString()).toList() ?? const [],
      userData: map['userData'] != null ? Map<String, dynamic>.from(map['userData'] as Map) : null,
      driverData: map['driverData'] != null ? Map<String, dynamic>.from(map['driverData'] as Map) : null,
      message: map['message'] as String?,
    );
  }
}

/// OTP dispatch response model.
class OnboardingOtpResponse {
  final bool success;
  final String identifier;
  final String message;
  final String? devOtpHint;

  const OnboardingOtpResponse({
    required this.success,
    required this.identifier,
    required this.message,
    this.devOtpHint,
  });

  factory OnboardingOtpResponse.fromMap(Map<String, dynamic> map) {
    return OnboardingOtpResponse(
      success: map['success'] == true,
      identifier: (map['identifier'] ?? '').toString(),
      message: (map['message'] ?? '').toString(),
      devOtpHint: map['devOtpHint'] as String?,
    );
  }
}

/// Registration payload model for `adminRegisterUser`.
class AdminRegistrationPayload {
  final String role; // 'customer' | 'driver'
  final String fullName;
  final String phone;
  final String? email;
  final String? address;
  final String? ninNumber;
  final Map<String, String>? driverDetails;
  final Map<String, dynamic>? vehicleDetails;
  final Map<String, String>? documents;
  final String? livePhotoUrl;

  const AdminRegistrationPayload({
    required this.role,
    required this.fullName,
    required this.phone,
    this.email,
    this.address,
    this.ninNumber,
    this.driverDetails,
    this.vehicleDetails,
    this.documents,
    this.livePhotoUrl,
  });

  Map<String, dynamic> toMap() {
    return {
      'role': role,
      'fullName': fullName,
      'phone': phone,
      if (email != null && email!.isNotEmpty) 'email': email,
      if (address != null && address!.isNotEmpty) 'address': address,
      if (ninNumber != null && ninNumber!.isNotEmpty) 'ninNumber': ninNumber,
      if (driverDetails != null) 'driverDetails': driverDetails,
      if (vehicleDetails != null) 'vehicleDetails': vehicleDetails,
      if (documents != null) 'documents': documents,
      if (livePhotoUrl != null && livePhotoUrl!.isNotEmpty) 'livePhotoUrl': livePhotoUrl,
    };
  }
}

/// Admin Onboarding Service interacting with Cloud Functions backend.
class HubOnboardingService {
  final FirebaseFunctions _functions;
  final FirebaseStorage _storage;

  HubOnboardingService({
    FirebaseFunctions? functions,
    FirebaseStorage? storage,
  })  : _functions = functions ?? FirebaseFunctions.instance,
        _storage = storage ?? FirebaseStorage.instance;

  /// Look up whether an account exists by phone or email address.
  Future<OnboardingLookupResult> lookupAccount(String identifier) async {
    try {
      final callable = _functions.httpsCallable('lookupAccountForOnboarding');
      final res = await callable.call({'identifier': identifier.trim()});
      final data = Map<String, dynamic>.from(res.data as Map);
      return OnboardingLookupResult.fromMap(data);
    } catch (e) {
      debugPrint('lookupAccount failed: $e');
      rethrow;
    }
  }

  /// Dispatch 6-digit OTP code to specified identifier.
  Future<OnboardingOtpResponse> sendOtp(String identifier) async {
    try {
      final callable = _functions.httpsCallable('sendOnboardingOtp');
      final res = await callable.call({'identifier': identifier.trim()});
      final data = Map<String, dynamic>.from(res.data as Map);
      return OnboardingOtpResponse.fromMap(data);
    } catch (e) {
      debugPrint('sendOtp failed: $e');
      rethrow;
    }
  }

  /// Verify input 6-digit OTP code.
  Future<bool> verifyOtp(String identifier, String otp) async {
    try {
      final callable = _functions.httpsCallable('verifyOnboardingOtp');
      final res = await callable.call({
        'identifier': identifier.trim(),
        'otp': otp.trim(),
      });
      final data = Map<String, dynamic>.from(res.data as Map);
      return data['verified'] == true;
    } catch (e) {
      debugPrint('verifyOtp failed: $e');
      rethrow;
    }
  }

  /// Provision complete user/driver profile with Self-Verification Lock.
  Future<Map<String, dynamic>> registerUser(AdminRegistrationPayload payload) async {
    try {
      final callable = _functions.httpsCallable('adminRegisterUser');
      final res = await callable.call(payload.toMap());
      return Map<String, dynamic>.from(res.data as Map);
    } catch (e) {
      debugPrint('registerUser failed: $e');
      rethrow;
    }
  }

  /// Upload captured admin live photo / document byte data to Firebase Storage.
  Future<String> uploadVerificationPhoto({
    required String path,
    required Uint8List bytes,
  }) async {
    try {
      final compressedBytes =
          await ImageCompressionService.compressBytes(bytes);
      final ref = _storage.ref().child(path);
      final task = await ref.putData(
        compressedBytes,
        SettableMetadata(contentType: 'image/jpeg'),
      );
      final downloadUrl = await task.ref.getDownloadURL();
      return downloadUrl;
    } catch (e) {
      debugPrint('uploadVerificationPhoto failed: $e');
      rethrow;
    }
  }
}
