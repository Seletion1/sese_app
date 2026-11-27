import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:sese_core/sese_core.dart';

import 'permission_onboarding_screen.dart';
import 'permission_onboarding_service.dart';

/// Centralized helper for Just-In-Time (JIT) permission checks.
///
/// Routes every permission request through the single unified
/// [PermissionOnboardingScreen] ("Permissions Required" board) so the user
/// never sees fragmented single-permission popups.
abstract final class FeaturePermissionService {
  static Future<bool> ensurePermission({
    required BuildContext context,
    required Permission permission,
    required String featureName,
    required String rationale,
    AppUser? user,
    UserRole role = UserRole.customer,
    IconData icon = Icons.security_rounded,
    String confirmLabel = 'Enable Permission',
  }) async {
    try {
      final currentStatus = await permission.status;
      if (currentStatus.isGranted || currentStatus.isLimited) {
        if (permission == Permission.locationWhenInUse) {
          PermissionOnboardingService.locationGrantedNotifier.value = true;
        }
        return true;
      }

      if (!context.mounted) return false;
      final resolvedUser = user ??
          AppUser(
            uid: '',
            email: '',
            fullName: 'SeSe User',
            phoneNumber: '',
            role: role,
            createdAt: DateTime.now(),
          );
      await PermissionOnboardingScreen.showAsModal(
        context,
        user: resolvedUser,
        role: role,
      );

      final updated = await permission.status;
      final granted = updated.isGranted || updated.isLimited;
      if (permission == Permission.locationWhenInUse) {
        PermissionOnboardingService.locationGrantedNotifier.value = granted;
      }
      return granted;
    } catch (e) {
      debugPrint('FeaturePermissionService.ensurePermission error: $e');
      return false;
    }
  }

  static Future<bool> ensureLocation({
    required BuildContext context,
    required String featureName,
    required String rationale,
    AppUser? user,
    UserRole role = UserRole.customer,
  }) {
    return ensurePermission(
      context: context,
      permission: Permission.locationWhenInUse,
      featureName: featureName,
      rationale: rationale,
      user: user,
      role: role,
      icon: Icons.location_on_rounded,
      confirmLabel: 'Allow Location',
    );
  }

  static Future<bool> ensureCamera({
    required BuildContext context,
    required String featureName,
    required String rationale,
    AppUser? user,
    UserRole role = UserRole.driver,
  }) {
    return ensurePermission(
      context: context,
      permission: Permission.camera,
      featureName: featureName,
      rationale: rationale,
      user: user,
      role: role,
      icon: Icons.camera_alt_rounded,
      confirmLabel: 'Allow Camera',
    );
  }

  static Future<bool> ensureNotifications({
    required BuildContext context,
    required String featureName,
    required String rationale,
    AppUser? user,
    UserRole role = UserRole.driver,
  }) {
    return ensurePermission(
      context: context,
      permission: Permission.notification,
      featureName: featureName,
      rationale: rationale,
      user: user,
      role: role,
      icon: Icons.notifications_active_rounded,
      confirmLabel: 'Allow Notifications',
    );
  }
}
