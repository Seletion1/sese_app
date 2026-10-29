import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:sese_core/sese_core.dart';

import 'permission_item_model.dart';
import 'permission_onboarding_service.dart';

/// Pre-flight Permission Onboarding Screen (`PermissionOnboardingScreen`).
///
/// Presented immediately after role selection / auth, and before entering
/// the main home shell. Renders role-specific permission cards with
/// friendly explanations, status badges, and an interactive request flow.
class PermissionOnboardingScreen extends StatefulWidget {
  final AppUser user;
  final UserRole role;
  final AuthRepository? auth;
  final VoidCallback onCompleted;

  const PermissionOnboardingScreen({
    super.key,
    required this.user,
    required this.role,
    this.auth,
    required this.onCompleted,
  });

  @override
  State<PermissionOnboardingScreen> createState() =>
      _PermissionOnboardingScreenState();
}

class _PermissionOnboardingScreenState extends State<PermissionOnboardingScreen> {
  late final List<PermissionItem> _bundleItems;
  Map<String, PermissionStatus> _statuses = {};
  bool _isLoading = true;
  bool _isRequesting = false;

  static const Color _seseGold = AppColors.seseGold;

  @override
  void initState() {
    super.initState();
    _bundleItems = PermissionItem.bundleForRole(widget.role);
    _loadStatuses();
  }

  Future<void> _loadStatuses() async {
    setState(() => _isLoading = true);
    final statuses = await PermissionOnboardingService.checkStatuses(_bundleItems);
    if (!mounted) return;
    setState(() {
      _statuses = statuses;
      _isLoading = false;
    });

    // Check if already fully granted on load
    final allGranted = _bundleItems
        .where((item) => item.isMandatory)
        .every((item) => _isGranted(_statuses[item.id]));
    if (allGranted) {
      await PermissionOnboardingService.setCompleted(
        userId: widget.user.uid,
        role: widget.role,
      );
      if (mounted) widget.onCompleted();
    }
  }

  bool _isGranted(PermissionStatus? status) {
    return status == PermissionStatus.granted ||
        status == PermissionStatus.limited;
  }

  bool get _areAllMandatoryGranted {
    return _bundleItems
        .where((item) => item.isMandatory)
        .every((item) => _isGranted(_statuses[item.id]));
  }

  Future<void> _handleGrantPermissions() async {
    if (_areAllMandatoryGranted) {
      await PermissionOnboardingService.setCompleted(
        userId: widget.user.uid,
        role: widget.role,
      );
      widget.onCompleted();
      return;
    }

    setState(() => _isRequesting = true);

    final result =
        await PermissionOnboardingService.requestAllPermissions(_bundleItems);

    if (!mounted) return;

    setState(() {
      _statuses = result.statuses;
      _isRequesting = false;
    });

    if (result.isAllMandatoryGranted) {
      await PermissionOnboardingService.setCompleted(
        userId: widget.user.uid,
        role: widget.role,
      );
      if (mounted) widget.onCompleted();
    } else {
      _showDeniedDialog(result.permanentlyDeniedItems);
    }
  }

  void _showDeniedDialog(List<PermissionItem> permanentlyDenied) {
    final missingNames = _bundleItems
        .where((item) => item.isMandatory && !_isGranted(_statuses[item.id]))
        .map((item) => item.title)
        .join(', ');

    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: const Row(
          children: [
            Icon(Icons.security_rounded, color: _seseGold, size: 28),
            SizedBox(width: 10),
            Expanded(
              child: Text(
                'Permission Required',
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
              ),
            ),
          ],
        ),
        content: Text(
          'SeSe requires $missingNames to ensure safe, accurate, and seamless operations.\n\n'
          'Please enable them in your device settings to continue.',
          style: const TextStyle(fontSize: 14, height: 1.4),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: Text(
              'Not Now',
              style: TextStyle(color: Theme.of(context).disabledColor),
            ),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: _seseGold,
              foregroundColor: Colors.black,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
              ),
            ),
            onPressed: () {
              Navigator.of(ctx).pop();
              PermissionOnboardingService.openSettings();
            },
            child: const Text(
              'Open Settings',
              style: TextStyle(fontWeight: FontWeight.bold),
            ),
          ),
        ],
      ),
    );
  }

  String get _roleSubtitle {
    switch (widget.role) {
      case UserRole.driver:
        return 'To receive ride offers, navigate routes, and verify vehicle state, SeSe needs access to the following permissions.';
      case UserRole.customer:
      case UserRole.admin:
      case UserRole.superRole:
      case UserRole.agent:
        return 'To give you a seamless ride booking and delivery experience, SeSe needs access to the following permissions.';
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;

    return Scaffold(
      key: const Key('permission_onboarding_screen'),
      body: SafeArea(
        child: _isLoading
            ? const Center(
                child: CircularProgressIndicator(color: _seseGold),
              )
            : Column(
                children: [
                  Expanded(
                    child: SingleChildScrollView(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 20.0,
                        vertical: 24.0,
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.center,
                        children: [
                          const SizedBox(height: 12),

                          // Header Icon Shield Badge
                          Container(
                            width: 80,
                            height: 80,
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              color: _seseGold.withValues(alpha: 0.15),
                              border: Border.all(
                                color: _seseGold.withValues(alpha: 0.4),
                                width: 2,
                              ),
                              boxShadow: [
                                BoxShadow(
                                  color: _seseGold.withValues(alpha: 0.25),
                                  blurRadius: 16,
                                  spreadRadius: 2,
                                ),
                              ],
                            ),
                            child: const Icon(
                              Icons.verified_user_rounded,
                              size: 42,
                              color: _seseGold,
                            ),
                          ),

                          const SizedBox(height: 20),

                          Text(
                            'Permissions Required',
                            style: theme.textTheme.headlineSmall?.copyWith(
                              fontWeight: FontWeight.w800,
                              letterSpacing: -0.5,
                            ),
                            textAlign: TextAlign.center,
                          ),

                          const SizedBox(height: 10),

                          Text(
                            _roleSubtitle,
                            style: theme.textTheme.bodyMedium?.copyWith(
                              color: theme.textTheme.bodyMedium?.color
                                  ?.withValues(alpha: 0.75),
                              height: 1.4,
                            ),
                            textAlign: TextAlign.center,
                          ),

                          const SizedBox(height: 28),

                          // Cards List
                          ..._bundleItems.map((item) {
                            final status = _statuses[item.id];
                            final isGranted = _isGranted(status);

                            return Padding(
                              padding: const EdgeInsets.only(bottom: 14.0),
                              child: _PermissionExplanationCard(
                                item: item,
                                isGranted: isGranted,
                                isDark: isDark,
                                onTap: () async {
                                  if (!isGranted) {
                                    final newStatus =
                                        await PermissionOnboardingService
                                            .requestSinglePermission(item);
                                    if (mounted) {
                                      setState(() {
                                        _statuses[item.id] = newStatus;
                                      });
                                    }
                                  }
                                },
                              ),
                            );
                          }),
                        ],
                      ),
                    ),
                  ),

                  // Bottom Action Button
                  Container(
                    padding: const EdgeInsets.all(20.0),
                    decoration: BoxDecoration(
                      color: isDark ? const Color(0xFF1E1E1E) : Colors.white,
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withValues(alpha: 0.08),
                          blurRadius: 10,
                          offset: const Offset(0, -4),
                        ),
                      ],
                    ),
                    child: SizedBox(
                      width: double.infinity,
                      height: 52,
                      child: ElevatedButton(
                        key: const Key('grant_permissions_button'),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: _seseGold,
                          foregroundColor: Colors.black,
                          elevation: 2,
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(14),
                          ),
                        ),
                        onPressed: _isRequesting ? null : _handleGrantPermissions,
                        child: _isRequesting
                            ? const SizedBox(
                                width: 24,
                                height: 24,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2.5,
                                  color: Colors.black,
                                ),
                              )
                            : Text(
                                _areAllMandatoryGranted
                                    ? 'Continue'
                                    : 'Grant Permissions',
                                style: const TextStyle(
                                  fontSize: 16,
                                  fontWeight: FontWeight.bold,
                                  letterSpacing: 0.2,
                                ),
                              ),
                      ),
                    ),
                  ),
                ],
              ),
      ),
    );
  }
}

/// Friendly Explanation Card UI Component
class _PermissionExplanationCard extends StatelessWidget {
  final PermissionItem item;
  final bool isGranted;
  final bool isDark;
  final VoidCallback onTap;

  static const Color _seseGold = AppColors.seseGold;

  const _PermissionExplanationCard({
    required this.item,
    required this.isGranted,
    required this.isDark,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cardBg = isDark ? const Color(0xFF252525) : Colors.white;

    return Container(
      decoration: BoxDecoration(
        color: cardBg,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: isGranted
              ? Colors.green.withValues(alpha: 0.4)
              : _seseGold.withValues(alpha: 0.35),
          width: 1.5,
        ),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: isDark ? 0.25 : 0.04),
            blurRadius: 8,
            offset: const Offset(0, 3),
          ),
        ],
      ),
      child: Material(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(16),
        child: InkWell(
          borderRadius: BorderRadius.circular(16),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.all(16.0),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Icon Avatar Container
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: isGranted
                        ? Colors.green.withValues(alpha: 0.15)
                        : _seseGold.withValues(alpha: 0.15),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Icon(
                    item.icon,
                    size: 26,
                    color: isGranted ? Colors.green.shade600 : _seseGold,
                  ),
                ),

                const SizedBox(width: 14),

                // Title & Friendly Explanation Text
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Expanded(
                            child: Text(
                              item.title,
                              style: theme.textTheme.titleMedium?.copyWith(
                                fontWeight: FontWeight.bold,
                                fontSize: 15,
                              ),
                            ),
                          ),
                          const SizedBox(width: 8),

                          // Status Badge
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 10,
                              vertical: 4,
                            ),
                            decoration: BoxDecoration(
                              color: isGranted
                                  ? Colors.green.withValues(alpha: 0.15)
                                  : _seseGold.withValues(alpha: 0.15),
                              borderRadius: BorderRadius.circular(20),
                            ),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(
                                  isGranted
                                      ? Icons.check_circle_rounded
                                      : Icons.info_outline_rounded,
                                  size: 14,
                                  color: isGranted
                                      ? Colors.green.shade600
                                      : _seseGold,
                                ),
                                const SizedBox(width: 4),
                                Text(
                                  isGranted ? 'Granted' : 'Required',
                                  style: TextStyle(
                                    fontSize: 11,
                                    fontWeight: FontWeight.bold,
                                    color: isGranted
                                        ? Colors.green.shade600
                                        : (isDark
                                            ? _seseGold
                                            : Colors.amber.shade900),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),

                      const SizedBox(height: 6),

                      Text(
                        item.description,
                        style: theme.textTheme.bodyMedium?.copyWith(
                          fontSize: 13,
                          color: theme.textTheme.bodyMedium?.color
                              ?.withValues(alpha: 0.7),
                          height: 1.35,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
