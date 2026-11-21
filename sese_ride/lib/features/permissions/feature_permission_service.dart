import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:sese_core/sese_core.dart';

import 'permission_onboarding_service.dart';

/// Centralized helper for Just-In-Time (JIT) contextual permission requests.
///
/// Ensures the app follows Google Play's recommended permission architecture:
/// 1. Users can skip upfront permission boarding.
/// 2. Permissions are prompted contextually at the exact moment a feature is used.
/// 3. Clear explanations (rationales) are presented before system OS dialogs.
/// 4. Graceful fallbacks and one-tap OS Settings shortcuts for permanently denied states.
abstract final class FeaturePermissionService {
  /// Checks whether [permission] is granted. If not, displays a contextual
  /// rationale bottom sheet or dialog explaining why the feature requires it,
  /// then triggers the runtime OS prompt.
  ///
  /// Returns `true` if granted (or limited on iOS), or `false` if the user declines.
  static Future<bool> ensurePermission({
    required BuildContext context,
    required Permission permission,
    required String featureName,
    required String rationale,
    IconData icon = Icons.security_rounded,
    String confirmLabel = 'Enable Permission',
  }) async {
    try {
      final currentStatus = await permission.status;

      // 1. If already granted, proceed immediately with 0ms overhead
      if (currentStatus.isGranted || currentStatus.isLimited) {
        return true;
      }

      // 2. If permanently denied, offer direct jump to OS Settings
      if (currentStatus.isPermanentlyDenied) {
        if (!context.mounted) return false;
        return await _showPermanentlyDeniedDialog(
          context: context,
          featureName: featureName,
          rationale: rationale,
        );
      }

      // 3. Present contextual rationale before OS prompt
      if (!context.mounted) return false;
      final proceed = await _showContextualRationaleSheet(
        context: context,
        featureName: featureName,
        rationale: rationale,
        icon: icon,
        confirmLabel: confirmLabel,
      );

      if (!proceed) return false;

      // 4. Request OS runtime permission
      final requestedStatus = await permission.request();

      if (requestedStatus.isGranted || requestedStatus.isLimited) {
        return true;
      }

      if (requestedStatus.isPermanentlyDenied && context.mounted) {
        return await _showPermanentlyDeniedDialog(
          context: context,
          featureName: featureName,
          rationale: rationale,
        );
      }

      return false;
    } catch (e) {
      debugPrint('FeaturePermissionService.ensurePermission error: $e');
      return false;
    }
  }

  /// Convenience helper for Location-dependent features (e.g. driver online,
  /// route calculation, recentering map on user).
  static Future<bool> ensureLocation({
    required BuildContext context,
    required String featureName,
    required String rationale,
  }) {
    return ensurePermission(
      context: context,
      permission: Permission.locationWhenInUse,
      featureName: featureName,
      rationale: rationale,
      icon: Icons.location_on_rounded,
      confirmLabel: 'Allow Location',
    );
  }

  /// Convenience helper for Camera-dependent features (e.g. vehicle inspection,
  /// KYC document capture, photo verification).
  static Future<bool> ensureCamera({
    required BuildContext context,
    required String featureName,
    required String rationale,
  }) {
    return ensurePermission(
      context: context,
      permission: Permission.camera,
      featureName: featureName,
      rationale: rationale,
      icon: Icons.camera_alt_rounded,
      confirmLabel: 'Allow Camera',
    );
  }

  /// Convenience helper for Notification-dependent features.
  static Future<bool> ensureNotifications({
    required BuildContext context,
    required String featureName,
    required String rationale,
  }) {
    return ensurePermission(
      context: context,
      permission: Permission.notification,
      featureName: featureName,
      rationale: rationale,
      icon: Icons.notifications_active_rounded,
      confirmLabel: 'Allow Notifications',
    );
  }

  /// Displays the contextual rationale bottom sheet prior to OS prompt.
  static Future<bool> _showContextualRationaleSheet({
    required BuildContext context,
    required String featureName,
    required String rationale,
    required IconData icon,
    required String confirmLabel,
  }) async {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;

    final result = await showModalBottomSheet<bool>(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (ctx) => Container(
        padding: const EdgeInsets.fromLTRB(24, 20, 24, 32),
        decoration: BoxDecoration(
          color: isDark ? const Color(0xFF1E1E1E) : Colors.white,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
        ),
        child: SafeArea(
          top: false,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Center(
                child: Container(
                  width: 40,
                  height: 4,
                  decoration: BoxDecoration(
                    color: Colors.grey.withValues(alpha: 0.3),
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
              const SizedBox(height: 20),
              Row(
                children: [
                  Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: AppColors.seseGold.withValues(alpha: 0.15),
                      shape: BoxShape.circle,
                    ),
                    child: Icon(icon, color: AppColors.seseGold, size: 28),
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          '$featureName Permission',
                          style: const TextStyle(
                            fontSize: 18,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          'Required for this action',
                          style: TextStyle(
                            fontSize: 12,
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              Text(
                rationale,
                style: const TextStyle(fontSize: 14, height: 1.4),
              ),
              const SizedBox(height: 24),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton(
                      style: OutlinedButton.styleFrom(
                        padding: const EdgeInsets.symmetric(vertical: 14),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                      ),
                      onPressed: () => Navigator.of(ctx).pop(false),
                      child: const Text('Not Now'),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: FilledButton(
                      style: FilledButton.styleFrom(
                        backgroundColor: AppColors.seseGold,
                        foregroundColor: Colors.black,
                        padding: const EdgeInsets.symmetric(vertical: 14),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                      ),
                      onPressed: () => Navigator.of(ctx).pop(true),
                      child: Text(
                        confirmLabel,
                        style: const TextStyle(fontWeight: FontWeight.bold),
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );

    return result ?? false;
  }

  /// Displays dialog when permission has been permanently denied in system settings.
  static Future<bool> _showPermanentlyDeniedDialog({
    required BuildContext context,
    required String featureName,
    required String rationale,
  }) async {
    final result = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: Row(
          children: [
            const Icon(Icons.settings_suggest_rounded, color: AppColors.seseGold, size: 26),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                '$featureName Access Disabled',
                style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
              ),
            ),
          ],
        ),
        content: Text(
          '$rationale\n\nAccess was disabled in device settings. Please tap Open Settings to enable it.',
          style: const TextStyle(fontSize: 14, height: 1.4),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: AppColors.seseGold,
              foregroundColor: Colors.black,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
            ),
            onPressed: () {
              Navigator.of(ctx).pop(true);
              PermissionOnboardingService.openSettings();
            },
            child: const Text('Open Settings', style: TextStyle(fontWeight: FontWeight.bold)),
          ),
        ],
      ),
    );

    return result ?? false;
  }
}
