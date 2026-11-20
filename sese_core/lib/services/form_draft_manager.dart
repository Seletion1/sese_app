import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Container for a recovered image picker result after Android process recreation.
class RecoveredPickerResult {
  final String screen;
  final String field;
  final String userId;
  final XFile file;

  const RecoveredPickerResult({
    required this.screen,
    required this.field,
    required this.userId,
    required this.file,
  });

  @override
  String toString() =>
      'RecoveredPickerResult(screen: $screen, field: $field, userId: $userId, path: ${file.path})';
}

/// Persistent draft model for customer KYC verification form.
class CustomerKycDraft {
  final String firstName;
  final String lastName;
  final String dob;
  final String gender;
  final String address;
  final String? proofOfAddressPath;
  final String occupation;
  final String orgName;
  final String orgAddress;
  final String idType;
  final String idNumber;
  final String? idFrontPath;
  final String? idBackPath;
  final String? selfiePath;
  final DateTime updatedAt;

  const CustomerKycDraft({
    this.firstName = '',
    this.lastName = '',
    this.dob = '',
    this.gender = 'Male',
    this.address = '',
    this.proofOfAddressPath,
    this.occupation = '',
    this.orgName = '',
    this.orgAddress = '',
    this.idType = 'NIN',
    this.idNumber = '',
    this.idFrontPath,
    this.idBackPath,
    this.selfiePath,
    required this.updatedAt,
  });

  Map<String, dynamic> toJson() => {
        'firstName': firstName,
        'lastName': lastName,
        'dob': dob,
        'gender': gender,
        'address': address,
        'proofOfAddressPath': proofOfAddressPath,
        'occupation': occupation,
        'orgName': orgName,
        'orgAddress': orgAddress,
        'idType': idType,
        'idNumber': idNumber,
        'idFrontPath': idFrontPath,
        'idBackPath': idBackPath,
        'selfiePath': selfiePath,
        'updatedAt': updatedAt.toIso8601String(),
      };

  factory CustomerKycDraft.fromJson(Map<String, dynamic> json) =>
      CustomerKycDraft(
        firstName: json['firstName'] ?? '',
        lastName: json['lastName'] ?? '',
        dob: json['dob'] ?? '',
        gender: json['gender'] ?? 'Male',
        address: json['address'] ?? '',
        proofOfAddressPath: json['proofOfAddressPath'],
        occupation: json['occupation'] ?? '',
        orgName: json['orgName'] ?? '',
        orgAddress: json['orgAddress'] ?? '',
        idType: json['idType'] ?? 'NIN',
        idNumber: json['idNumber'] ?? '',
        idFrontPath: json['idFrontPath'],
        idBackPath: json['idBackPath'],
        selfiePath: json['selfiePath'],
        updatedAt: json['updatedAt'] != null
            ? DateTime.tryParse(json['updatedAt']) ?? DateTime.now()
            : DateTime.now(),
      );

  CustomerKycDraft copyWith({
    String? firstName,
    String? lastName,
    String? dob,
    String? gender,
    String? address,
    String? proofOfAddressPath,
    String? occupation,
    String? orgName,
    String? orgAddress,
    String? idType,
    String? idNumber,
    String? idFrontPath,
    String? idBackPath,
    String? selfiePath,
    DateTime? updatedAt,
  }) {
    return CustomerKycDraft(
      firstName: firstName ?? this.firstName,
      lastName: lastName ?? this.lastName,
      dob: dob ?? this.dob,
      gender: gender ?? this.gender,
      address: address ?? this.address,
      proofOfAddressPath: proofOfAddressPath ?? this.proofOfAddressPath,
      occupation: occupation ?? this.occupation,
      orgName: orgName ?? this.orgName,
      orgAddress: orgAddress ?? this.orgAddress,
      idType: idType ?? this.idType,
      idNumber: idNumber ?? this.idNumber,
      idFrontPath: idFrontPath ?? this.idFrontPath,
      idBackPath: idBackPath ?? this.idBackPath,
      selfiePath: selfiePath ?? this.selfiePath,
      updatedAt: updatedAt ?? this.updatedAt,
    );
  }
}

/// Persistent draft model for driver onboarding (Step 2: Personal Information).
class DriverOnboardingDraft {
  final String firstName;
  final String lastName;
  final String phone;
  final String dob;
  final String gender;
  final String country;
  final String? stateOrRegion;
  final String address;
  final double? addressLat;
  final double? addressLng;
  final String idType;
  final String idNumber;
  final String? idExpiryDate;
  final String kinName;
  final String kinRelationship;
  final String kinRelationshipOther;
  final String kinPhone;
  final String kinAddress;
  final String? idFrontPath;
  final String? idBackPath;
  final String? selfiePath;
  final DateTime updatedAt;

  const DriverOnboardingDraft({
    this.firstName = '',
    this.lastName = '',
    this.phone = '',
    this.dob = '',
    this.gender = 'Male',
    this.country = 'Nigeria',
    this.stateOrRegion,
    this.address = '',
    this.addressLat,
    this.addressLng,
    this.idType = 'NIN',
    this.idNumber = '',
    this.idExpiryDate,
    this.kinName = '',
    this.kinRelationship = '',
    this.kinRelationshipOther = '',
    this.kinPhone = '',
    this.kinAddress = '',
    this.idFrontPath,
    this.idBackPath,
    this.selfiePath,
    required this.updatedAt,
  });

  Map<String, dynamic> toJson() => {
        'firstName': firstName,
        'lastName': lastName,
        'phone': phone,
        'dob': dob,
        'gender': gender,
        'country': country,
        'stateOrRegion': stateOrRegion,
        'address': address,
        'addressLat': addressLat,
        'addressLng': addressLng,
        'idType': idType,
        'idNumber': idNumber,
        'idExpiryDate': idExpiryDate,
        'kinName': kinName,
        'kinRelationship': kinRelationship,
        'kinRelationshipOther': kinRelationshipOther,
        'kinPhone': kinPhone,
        'kinAddress': kinAddress,
        'idFrontPath': idFrontPath,
        'idBackPath': idBackPath,
        'selfiePath': selfiePath,
        'updatedAt': updatedAt.toIso8601String(),
      };

  factory DriverOnboardingDraft.fromJson(Map<String, dynamic> json) =>
      DriverOnboardingDraft(
        firstName: json['firstName'] ?? '',
        lastName: json['lastName'] ?? '',
        phone: json['phone'] ?? '',
        dob: json['dob'] ?? '',
        gender: json['gender'] ?? 'Male',
        country: json['country'] ?? 'Nigeria',
        stateOrRegion: json['stateOrRegion'],
        address: json['address'] ?? '',
        addressLat: (json['addressLat'] as num?)?.toDouble(),
        addressLng: (json['addressLng'] as num?)?.toDouble(),
        idType: json['idType'] ?? 'NIN',
        idNumber: json['idNumber'] ?? '',
        idExpiryDate: json['idExpiryDate'],
        kinName: json['kinName'] ?? '',
        kinRelationship: json['kinRelationship'] ?? '',
        kinRelationshipOther: json['kinRelationshipOther'] ?? '',
        kinPhone: json['kinPhone'] ?? '',
        kinAddress: json['kinAddress'] ?? '',
        idFrontPath: json['idFrontPath'],
        idBackPath: json['idBackPath'],
        selfiePath: json['selfiePath'],
        updatedAt: json['updatedAt'] != null
            ? DateTime.tryParse(json['updatedAt']) ?? DateTime.now()
            : DateTime.now(),
      );

  DriverOnboardingDraft copyWith({
    String? firstName,
    String? lastName,
    String? phone,
    String? dob,
    String? gender,
    String? country,
    String? stateOrRegion,
    String? address,
    double? addressLat,
    double? addressLng,
    String? idType,
    String? idNumber,
    String? idExpiryDate,
    String? kinName,
    String? kinRelationship,
    String? kinRelationshipOther,
    String? kinPhone,
    String? kinAddress,
    String? idFrontPath,
    String? idBackPath,
    String? selfiePath,
    DateTime? updatedAt,
  }) {
    return DriverOnboardingDraft(
      firstName: firstName ?? this.firstName,
      lastName: lastName ?? this.lastName,
      phone: phone ?? this.phone,
      dob: dob ?? this.dob,
      gender: gender ?? this.gender,
      country: country ?? this.country,
      stateOrRegion: stateOrRegion ?? this.stateOrRegion,
      address: address ?? this.address,
      addressLat: addressLat ?? this.addressLat,
      addressLng: addressLng ?? this.addressLng,
      idType: idType ?? this.idType,
      idNumber: idNumber ?? this.idNumber,
      idExpiryDate: idExpiryDate ?? this.idExpiryDate,
      kinName: kinName ?? this.kinName,
      kinRelationship: kinRelationship ?? this.kinRelationship,
      kinRelationshipOther: kinRelationshipOther ?? this.kinRelationshipOther,
      kinPhone: kinPhone ?? this.kinPhone,
      kinAddress: kinAddress ?? this.kinAddress,
      idFrontPath: idFrontPath ?? this.idFrontPath,
      idBackPath: idBackPath ?? this.idBackPath,
      selfiePath: selfiePath ?? this.selfiePath,
      updatedAt: updatedAt ?? this.updatedAt,
    );
  }
}

/// Unified Form Draft & Android Process-Death Recovery Service.
///
/// Handles Android OS activity recreation when camera or gallery intents
/// trigger background process destruction under memory pressure:
///
/// 1. **Pending Target Tracking**: Persists the active screen and field ID to
///    [SharedPreferences] before opening the camera/gallery.
/// 2. **Lost Data Recovery**: Calls [ImagePicker.retrieveLostData()] on app start /
///    resume to recover images picked before process death.
/// 3. **Permanent Storage**: Immediately moves captured files from volatile OS
///    cache into `getApplicationDocumentsDirectory()/kyc_drafts/`.
/// 4. **Real-Time Draft Auto-Save**: Saves form fields, dropdowns, and file paths
///    to local storage so no user input is wiped when the OS restarts the activity.
/// 5. **Route Auto-Restoration**: Remembers unsubmitted verification drafts so the
///    app seamlessly reopens the exact form instead of dumping the user on the home screen.
class FormDraftManager {
  FormDraftManager._();

  static final FormDraftManager instance = FormDraftManager._();

  static const String _prefPendingScreen = 'kyc_pending_picker_screen';
  static const String _prefPendingField = 'kyc_pending_picker_field';
  static const String _prefPendingUserId = 'kyc_pending_picker_user_id';
  static const String _prefRestoreRoutePrefix = 'kyc_pending_restore_route_';
  static const String _prefCustomerDraftPrefix = 'customer_kyc_draft_';
  static const String _prefDriverDraftPrefix = 'driver_onboarding_draft_';

  // ---------------------------------------------------------------------------
  // 1. Pending Picker Target Tracking
  // ---------------------------------------------------------------------------

  /// Records the active screen, field identifier, and user ID before launching
  /// the camera or gallery picker.
  Future<void> recordPendingPickerTarget({
    required String screen,
    required String field,
    required String userId,
  }) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_prefPendingScreen, screen);
      await prefs.setString(_prefPendingField, field);
      await prefs.setString(_prefPendingUserId, userId);
      // Also register this screen as the pending restore route
      await setPendingRestoreRoute(userId, screen);
      debugPrint(
        'FormDraftManager: recorded pending picker target -> screen: $screen, field: $field, uid: $userId',
      );
    } catch (e) {
      debugPrint('FormDraftManager: failed to record pending target: $e');
    }
  }

  /// Retrieves the recorded pending picker target, if any.
  Future<({String screen, String field, String userId})?>
      getPendingPickerTarget() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final screen = prefs.getString(_prefPendingScreen);
      final field = prefs.getString(_prefPendingField);
      final userId = prefs.getString(_prefPendingUserId);
      if (screen != null && field != null && userId != null) {
        return (screen: screen, field: field, userId: userId);
      }
    } catch (e) {
      debugPrint('FormDraftManager: failed to get pending target: $e');
    }
    return null;
  }

  /// Clears the recorded pending picker target after successful pick or cancel.
  Future<void> clearPendingPickerTarget() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_prefPendingScreen);
      await prefs.remove(_prefPendingField);
      await prefs.remove(_prefPendingUserId);
    } catch (e) {
      debugPrint('FormDraftManager: failed to clear pending target: $e');
    }
  }

  // ---------------------------------------------------------------------------
  // 2. Permanent File Storage
  // ---------------------------------------------------------------------------

  /// Copies a file from temporary cache to permanent app documents storage
  /// (`getApplicationDocumentsDirectory()/kyc_drafts/`).
  ///
  /// This prevents Android from purging the file while backgrounded.
  Future<XFile> copyToPermanentDraftStorage(
    XFile file, {
    required String prefix,
  }) async {
    if (kIsWeb) return file;
    try {
      final docsDir = await getApplicationDocumentsDirectory();
      final draftsDir = Directory('${docsDir.path}/kyc_drafts');
      if (!await draftsDir.exists()) {
        await draftsDir.create(recursive: true);
      }
      final extension = file.path.contains('.')
          ? file.path.substring(file.path.lastIndexOf('.'))
          : '.jpg';
      final fileName =
          '${prefix}_${DateTime.now().millisecondsSinceEpoch}$extension';
      final permanentPath = '${draftsDir.path}/$fileName';

      final originalFile = File(file.path);
      if (await originalFile.exists()) {
        await originalFile.copy(permanentPath);
      } else {
        final bytes = await file.readAsBytes();
        await File(permanentPath).writeAsBytes(bytes);
      }

      debugPrint(
        'FormDraftManager: moved file to permanent draft storage: $permanentPath',
      );
      return XFile(permanentPath);
    } catch (e) {
      debugPrint('FormDraftManager: failed to copy file to permanent storage: $e');
      return file;
    }
  }

  // ---------------------------------------------------------------------------
  // 3. Android Process-Death Lost Data Recovery
  // ---------------------------------------------------------------------------

  /// Recovers lost image data if Android killed `MainActivity` while the camera
  /// or gallery was open.
  ///
  /// Safe to call on all platforms; no-op on non-Android or Web.
  Future<RecoveredPickerResult?> checkAndRecoverLostData({
    ImagePicker? picker,
  }) async {
    if (kIsWeb || !Platform.isAndroid) return null;

    try {
      final imagePicker = picker ?? ImagePicker();
      final LostDataResponse response = await imagePicker.retrieveLostData();

      if (response.isEmpty || response.file == null) {
        return null;
      }

      debugPrint(
        'FormDraftManager: recovered lost picker image: ${response.file!.path}',
      );

      final target = await getPendingPickerTarget();
      if (target == null) {
        debugPrint(
          'FormDraftManager: lost image recovered, but no pending target was recorded.',
        );
        return null;
      }

      // 1. Move to permanent storage
      final permanentFile = await copyToPermanentDraftStorage(
        response.file!,
        prefix: '${target.screen}_${target.field}',
      );

      final result = RecoveredPickerResult(
        screen: target.screen,
        field: target.field,
        userId: target.userId,
        file: permanentFile,
      );

      // 2. Attach to the corresponding form draft
      await attachRecoveredFileToDraft(result);

      // 3. Ensure route restoration is armed
      await setPendingRestoreRoute(target.userId, target.screen);

      // 4. Clear the pending target
      await clearPendingPickerTarget();

      return result;
    } catch (e) {
      debugPrint('FormDraftManager: error checking lost data: $e');
      return null;
    }
  }

  /// Attaches a recovered file directly to the active screen's local draft.
  Future<void> attachRecoveredFileToDraft(RecoveredPickerResult result) async {
    try {
      if (result.screen == 'customer_verification') {
        final draft = await loadCustomerKycDraft(result.userId) ??
            CustomerKycDraft(updatedAt: DateTime.now());
        CustomerKycDraft updated = draft;
        switch (result.field) {
          case 'proof_of_address':
            updated = draft.copyWith(proofOfAddressPath: result.file.path);
            break;
          case 'id_front':
            updated = draft.copyWith(idFrontPath: result.file.path);
            break;
          case 'id_back':
            updated = draft.copyWith(idBackPath: result.file.path);
            break;
          case 'live_selfie':
          case 'selfie':
            updated = draft.copyWith(selfiePath: result.file.path);
            break;
        }
        await saveCustomerKycDraft(result.userId, updated);
      } else if (result.screen == 'driver_onboarding') {
        final draft = await loadDriverOnboardingDraft(result.userId) ??
            DriverOnboardingDraft(updatedAt: DateTime.now());
        DriverOnboardingDraft updated = draft;
        switch (result.field) {
          case 'id_front':
            updated = draft.copyWith(idFrontPath: result.file.path);
            break;
          case 'id_back':
            updated = draft.copyWith(idBackPath: result.file.path);
            break;
          case 'live_selfie':
          case 'selfie':
            updated = draft.copyWith(selfiePath: result.file.path);
            break;
        }
        await saveDriverOnboardingDraft(result.userId, updated);
      }
    } catch (e) {
      debugPrint('FormDraftManager: attachRecoveredFileToDraft error: $e');
    }
  }

  // ---------------------------------------------------------------------------
  // 4. Customer KYC Draft Management
  // ---------------------------------------------------------------------------

  /// Saves the customer's KYC draft to local storage.
  Future<void> saveCustomerKycDraft(
    String userId,
    CustomerKycDraft draft,
  ) async {
    if (userId.isEmpty) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      final key = '$_prefCustomerDraftPrefix$userId';
      final jsonStr = jsonEncode(draft.toJson());
      await prefs.setString(key, jsonStr);
    } catch (e) {
      debugPrint('FormDraftManager: saveCustomerKycDraft failed: $e');
    }
  }

  /// Loads the customer's KYC draft from local storage.
  Future<CustomerKycDraft?> loadCustomerKycDraft(String userId) async {
    if (userId.isEmpty) return null;
    try {
      final prefs = await SharedPreferences.getInstance();
      final key = '$_prefCustomerDraftPrefix$userId';
      final jsonStr = prefs.getString(key);
      if (jsonStr == null || jsonStr.isEmpty) return null;
      final map = jsonDecode(jsonStr) as Map<String, dynamic>;
      final draft = CustomerKycDraft.fromJson(map);

      // Verify that stored image paths still exist on disk
      String? verifyPath(String? path) {
        if (path == null || path.isEmpty) return null;
        if (kIsWeb) return path;
        return File(path).existsSync() ? path : null;
      }

      return draft.copyWith(
        proofOfAddressPath: verifyPath(draft.proofOfAddressPath),
        idFrontPath: verifyPath(draft.idFrontPath),
        idBackPath: verifyPath(draft.idBackPath),
        selfiePath: verifyPath(draft.selfiePath),
      );
    } catch (e) {
      debugPrint('FormDraftManager: loadCustomerKycDraft failed: $e');
      return null;
    }
  }

  /// Returns whether an active, unsubmitted Customer KYC draft exists.
  Future<bool> hasCustomerKycDraft(String userId) async {
    final draft = await loadCustomerKycDraft(userId);
    if (draft == null) return false;
    // Considered active if any meaningful field or file is present
    return draft.dob.isNotEmpty ||
        draft.address.isNotEmpty ||
        draft.proofOfAddressPath != null ||
        draft.idNumber.isNotEmpty ||
        draft.idFrontPath != null ||
        draft.idBackPath != null ||
        draft.selfiePath != null;
  }

  /// Clears the customer's KYC draft upon submission or explicit discard.
  Future<void> clearCustomerKycDraft(String userId) async {
    if (userId.isEmpty) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove('$_prefCustomerDraftPrefix$userId');
      await clearPendingRestoreRoute(userId);
      debugPrint('FormDraftManager: cleared customer KYC draft for $userId');
    } catch (e) {
      debugPrint('FormDraftManager: clearCustomerKycDraft failed: $e');
    }
  }

  // ---------------------------------------------------------------------------
  // 5. Driver Onboarding Draft Management
  // ---------------------------------------------------------------------------

  /// Saves the driver's onboarding draft to local storage.
  Future<void> saveDriverOnboardingDraft(
    String userId,
    DriverOnboardingDraft draft,
  ) async {
    if (userId.isEmpty) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      final key = '$_prefDriverDraftPrefix$userId';
      final jsonStr = jsonEncode(draft.toJson());
      await prefs.setString(key, jsonStr);
    } catch (e) {
      debugPrint('FormDraftManager: saveDriverOnboardingDraft failed: $e');
    }
  }

  /// Loads the driver's onboarding draft from local storage.
  Future<DriverOnboardingDraft?> loadDriverOnboardingDraft(String userId) async {
    if (userId.isEmpty) return null;
    try {
      final prefs = await SharedPreferences.getInstance();
      final key = '$_prefDriverDraftPrefix$userId';
      final jsonStr = prefs.getString(key);
      if (jsonStr == null || jsonStr.isEmpty) return null;
      final map = jsonDecode(jsonStr) as Map<String, dynamic>;
      final draft = DriverOnboardingDraft.fromJson(map);

      // Verify that stored image paths still exist on disk
      String? verifyPath(String? path) {
        if (path == null || path.isEmpty) return null;
        if (kIsWeb) return path;
        return File(path).existsSync() ? path : null;
      }

      return draft.copyWith(
        idFrontPath: verifyPath(draft.idFrontPath),
        idBackPath: verifyPath(draft.idBackPath),
        selfiePath: verifyPath(draft.selfiePath),
      );
    } catch (e) {
      debugPrint('FormDraftManager: loadDriverOnboardingDraft failed: $e');
      return null;
    }
  }

  /// Returns whether an active, unsubmitted Driver Onboarding draft exists.
  Future<bool> hasDriverOnboardingDraft(String userId) async {
    final draft = await loadDriverOnboardingDraft(userId);
    if (draft == null) return false;
    return draft.dob.isNotEmpty ||
        draft.address.isNotEmpty ||
        draft.idNumber.isNotEmpty ||
        draft.kinName.isNotEmpty ||
        draft.idFrontPath != null ||
        draft.idBackPath != null ||
        draft.selfiePath != null;
  }

  /// Clears the driver's onboarding draft upon submission or explicit discard.
  Future<void> clearDriverOnboardingDraft(String userId) async {
    if (userId.isEmpty) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove('$_prefDriverDraftPrefix$userId');
      await clearPendingRestoreRoute(userId);
      debugPrint('FormDraftManager: cleared driver onboarding draft for $userId');
    } catch (e) {
      debugPrint('FormDraftManager: clearDriverOnboardingDraft failed: $e');
    }
  }

  // ---------------------------------------------------------------------------
  // 6. Route Restoration Management
  // ---------------------------------------------------------------------------

  /// Records a route to be restored on the next app launch/resume after process restart.
  Future<void> setPendingRestoreRoute(String userId, String route) async {
    if (userId.isEmpty) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('$_prefRestoreRoutePrefix$userId', route);
    } catch (e) {
      debugPrint('FormDraftManager: setPendingRestoreRoute failed: $e');
    }
  }

  /// Retrieves the pending restore route for the signed-in user.
  Future<String?> getPendingRestoreRoute(String userId) async {
    if (userId.isEmpty) return null;
    try {
      final prefs = await SharedPreferences.getInstance();
      return prefs.getString('$_prefRestoreRoutePrefix$userId');
    } catch (e) {
      debugPrint('FormDraftManager: getPendingRestoreRoute failed: $e');
      return null;
    }
  }

  /// Clears the pending restore route.
  Future<void> clearPendingRestoreRoute(String userId) async {
    if (userId.isEmpty) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove('$_prefRestoreRoutePrefix$userId');
    } catch (e) {
      debugPrint('FormDraftManager: clearPendingRestoreRoute failed: $e');
    }
  }
}
