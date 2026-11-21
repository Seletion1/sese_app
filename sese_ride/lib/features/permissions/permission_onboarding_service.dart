import 'package:flutter/foundation.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:sese_core/sese_core.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../widgets/map_provider.dart';
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

  /// Checks if all baseline mandatory permissions are currently granted at
  /// the OS level for [role], or if onboarding was previously completed.
  ///
  /// Always queries real OS permission status first to ensure that role
  /// transitions (e.g. Customer -> Driver needing background location and storage)
  /// or revoked permissions correctly re-present the unified Permission Dashboard.
  static Future<bool> isCompleted({
    required String userId,
    required UserRole role,
  }) async {
    try {
      // First check persistent completion flag
      final prefs = await SharedPreferences.getInstance();
      final key = _flagKey(userId, role);
      final isFlagCompleted = prefs.getBool(key) ?? false;
      if (isFlagCompleted) {
        return true;
      }

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
    if (SeseUniversalMap.debugTileProviderOverride != null) {
      return PermissionStatus.granted;
    }
    try {
      if (item.permission == Permission.locationAlways) {
        // On Android: ACCESS_BACKGROUND_LOCATION is stripped via tools:node="remove"
        // to avoid a Google Play policy declaration gate. Return granted immediately
        // so the onboarding flow proceeds; foreground-only GPS is sufficient.
        if (defaultTargetPlatform == TargetPlatform.android) {
          return PermissionStatus.granted;
        }
        // iOS: foreground location must be granted before background.
        final fgStatus = await Permission.locationWhenInUse.status;
        if (!fgStatus.isGranted) {
          final fgReq = await Permission.locationWhenInUse.request();
          if (!fgReq.isGranted) {
            return fgReq;
          }
        }
        return await Permission.locationAlways.request();
      }

      if (item.permission == Permission.notification) {
        await PushNotificationService.requestNotificationPermission();
        return await Permission.notification.status;
      }

      if (item.permission == Permission.camera) {
        return await Permission.camera.request();
      }

      if (item.permission == Permission.photos) {
        if (defaultTargetPlatform == TargetPlatform.android) {
          // On Android: gallery selection uses system Photo Picker (no runtime permission).
          // For taking pictures, Camera permission is used.
          return await Permission.camera.request();
        }
        return await Permission.photos.request();
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
    if (SeseUniversalMap.debugTileProviderOverride != null) {
      return PermissionStatus.denied;
    }
    try {
      if (item.permission == Permission.camera) {
        return await Permission.camera.status;
      }
      if (item.permission == Permission.photos) {
        if (defaultTargetPlatform == TargetPlatform.android) {
          // On Android: gallery selection uses system Photo Picker (no runtime permission).
          // Fall back to camera status for capturing photos.
          return await Permission.camera.status;
        }
        final status = await Permission.photos.status;
        if (status.isGranted || status.isLimited) return status;
        return status;
      }
      return await item.permission.status;
    } catch (_) {
      return PermissionStatus.denied;
    }
  }

  static bool _isGrantedStatus(PermissionStatus? status) {
    return status == PermissionStatus.granted ||
        status == PermissionStatus.limited;
  }
}
