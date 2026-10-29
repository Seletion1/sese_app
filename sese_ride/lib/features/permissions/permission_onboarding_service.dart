import 'package:flutter/foundation.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:sese_core/sese_core.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'permission_item_model.dart';

/// Result summary after executing permission bundle requests.
class PermissionBundleResult {
  final bool isAllMandatoryGranted;
  final Map<String, PermissionStatus> statuses;
  final List<PermissionItem> permanentlyDeniedItems;

  const PermissionBundleResult({
    required this.isAllMandatoryGranted,
    required this.statuses,
    required this.permanentlyDeniedItems,
  });
}

/// Centralized service handling permission status checks, request flows,
/// OS settings navigation, and local persistent bypass flags.
class PermissionOnboardingService {
  static const String _flagPrefix = 'permission_onboarding_completed_';

  static String _flagKey(String userId, UserRole role) {
    final effectiveUserId = userId.isEmpty ? 'guest' : userId;
    return '$_flagPrefix${role.name}_$effectiveUserId';
  }

  /// Checks if pre-flight onboarding has been completed or if all baseline
  /// mandatory permissions are already granted for [role].
  static Future<bool> isCompleted({
    required String userId,
    required UserRole role,
  }) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final key = _flagKey(userId, role);
      final flagSet = prefs.getBool(key) ?? false;
      if (flagSet) return true;

      // If flag is not set, check if baseline permissions are already granted at OS level.
      final items = PermissionItem.bundleForRole(role);
      final statuses = await checkStatuses(items);

      final allGranted = items
          .where((item) => item.isMandatory)
          .every((item) => _isGrantedStatus(statuses[item.id]));

      if (allGranted) {
        await setCompleted(userId: userId, role: role);
        return true;
      }
      return false;
    } catch (e) {
      debugPrint('PermissionOnboardingService.isCompleted check error: $e');
      return false;
    }
  }

  /// Saves persistent flag indicating onboarding was completed for [role].
  static Future<void> setCompleted({
    required String userId,
    required UserRole role,
  }) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_flagKey(userId, role), true);
    } catch (e) {
      debugPrint('PermissionOnboardingService.setCompleted error: $e');
    }
  }

  /// Clears persistent completion flag (useful for testing or full sign-out reset).
  static Future<void> resetCompletionFlag({
    required String userId,
    required UserRole role,
  }) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_flagKey(userId, role));
    } catch (e) {
      debugPrint('PermissionOnboardingService.resetCompletionFlag error: $e');
    }
  }

  /// Returns current OS [PermissionStatus] for each item in [items].
  static Future<Map<String, PermissionStatus>> checkStatuses(
    List<PermissionItem> items,
  ) async {
    final Map<String, PermissionStatus> result = {};
    for (final item in items) {
      try {
        result[item.id] = await _checkSinglePermission(item);
      } catch (e) {
        debugPrint(
            'PermissionOnboardingService.checkStatuses failed for ${item.id}: $e');
        result[item.id] = PermissionStatus.denied;
      }
    }
    return result;
  }

  /// Requests a single permission with OS-specific fallbacks and ordering.
  static Future<PermissionStatus> requestSinglePermission(
    PermissionItem item,
  ) async {
    try {
      if (item.permission == Permission.locationAlways) {
        // Android/iOS requirement: foreground location must be granted before/with background location.
        final fgStatus = await Permission.locationWhenInUse.status;
        if (!fgStatus.isGranted) {
          final fgReq = await Permission.locationWhenInUse.request();
          if (!fgReq.isGranted) {
            return fgReq;
          }
        }
        return await Permission.locationAlways.request();
      }

      if (item.permission == Permission.photos) {
        final photoStatus = await Permission.photos.request();
        if (photoStatus.isGranted || photoStatus.isLimited) {
          return photoStatus;
        }
        if (defaultTargetPlatform == TargetPlatform.android) {
          final storageStatus = await Permission.storage.request();
          if (storageStatus.isGranted) return storageStatus;
        }
        return photoStatus;
      }

      return await item.permission.request();
    } catch (e) {
      debugPrint(
          'PermissionOnboardingService.requestSinglePermission error for ${item.id}: $e');
      return PermissionStatus.granted;
    }
  }

  /// Sequentially requests all missing permissions in [items] and returns summary.
  static Future<PermissionBundleResult> requestAllPermissions(
    List<PermissionItem> items,
  ) async {
    final Map<String, PermissionStatus> statuses = {};
    final List<PermissionItem> permanentlyDenied = [];

    for (final item in items) {
      final current = await _checkSinglePermission(item);
      if (_isGrantedStatus(current)) {
        statuses[item.id] = current;
      } else {
        final requested = await requestSinglePermission(item);
        statuses[item.id] = requested;
        if (requested == PermissionStatus.permanentlyDenied) {
          permanentlyDenied.add(item);
        }
      }
    }

    final isAllMandatoryGranted = items
        .where((item) => item.isMandatory)
        .every((item) => _isGrantedStatus(statuses[item.id]));

    return PermissionBundleResult(
      isAllMandatoryGranted: isAllMandatoryGranted,
      statuses: statuses,
      permanentlyDeniedItems: permanentlyDenied,
    );
  }

  /// Opens native OS app settings page.
  static Future<bool> openSettings() async {
    try {
      return await openAppSettings();
    } catch (e) {
      debugPrint('PermissionOnboardingService.openSettings error: $e');
      return false;
    }
  }

  static Future<PermissionStatus> _checkSinglePermission(
    PermissionItem item,
  ) async {
    if (item.permission == Permission.photos) {
      final status = await Permission.photos.status;
      if (status.isGranted || status.isLimited) return status;
      if (defaultTargetPlatform == TargetPlatform.android) {
        final storageStatus = await Permission.storage.status;
        if (storageStatus.isGranted) return storageStatus;
      }
      return status;
    }
    return await item.permission.status;
  }

  static bool _isGrantedStatus(PermissionStatus? status) {
    return status == PermissionStatus.granted ||
        status == PermissionStatus.limited;
  }
}
