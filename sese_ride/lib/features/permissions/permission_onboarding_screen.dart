import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:sese_core/sese_core.dart';

import '../../widgets/map_provider.dart';
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

  /// Presents the unified "Permissions Required" board as a full-screen modal
  /// route from any feature (e.g. Go Online, Recenter, Camera) so no fragmented
  /// single-permission popups are ever shown. Returns `true` if Precise Location
  /// is granted when the board closes.
  static Future<bool> showAsModal(
    BuildContext context, {
    required AppUser user,
    required UserRole role,
  }) async {
    await Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        fullscreenDialog: true,
        builder: (ctx) => PermissionOnboardingScreen(
          user: user,
          role: role,
          onCompleted: () {
            if (Navigator.of(ctx).canPop()) {
              Navigator.of(ctx).pop();
            }
          },
        ),
      ),
    );
    return PermissionOnboardingService.refreshLocationStatus();
  }

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

class _PermissionOnboardingScreenState extends State<PermissionOnboardingScreen>
    with WidgetsBindingObserver {
  late final List<PermissionItem> _bundleItems;
  Map<String, PermissionStatus> _statuses = {};
  bool _isLoading = true;
  bool _isRequesting = false;

  static const Color _seseGold = AppColors.seseGold;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _bundleItems = PermissionItem.bundleForRole(widget.role);
    _loadStatuses();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _loadStatuses();
    }
  }

  Future<void> _loadStatuses() async {
    setState(() => _isLoading = true);
    final statuses = await PermissionOnboardingService.checkStatuses(_bundleItems);
    await PermissionOnboardingService.refreshLocationStatus();
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
    await PermissionOnboardingService.refreshLocationStatus();

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
      _showProceedWithoutPermissionsConfirmation();
    }
  }

  /// Displays a non-blocking confirmation bottom sheet when the user chooses
  /// to skip or proceed without granting all permissions.
  Future<void> _showProceedWithoutPermissionsConfirmation() async {
    final ungranted = _bundleItems
        .where((item) => !_isGranted(_statuses[item.id]))
        .toList();

    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;

    await showModalBottomSheet<void>(
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
                      color: Colors.amber.withValues(alpha: 0.15),
                      shape: BoxShape.circle,
                    ),
                    child: const Icon(
                      Icons.warning_amber_rounded,
                      color: Colors.amber,
                      size: 28,
                    ),
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          'Proceed with Limited Features?',
                          style: TextStyle(
                            fontSize: 18,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          'Some permissions are not yet enabled',
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
                'You can explore SeSe now without granting all permissions. However, the following features may be limited until enabled:',
                style: theme.textTheme.bodyMedium?.copyWith(
                  height: 1.4,
                  color: theme.textTheme.bodyMedium?.color?.withValues(alpha: 0.8),
                ),
              ),
              const SizedBox(height: 14),
              ...ungranted.map((item) {
                String effectDescription;
                switch (item.id) {
                  case 'location':
                  case 'precise_location':
                    effectDescription =
                        'Live map centering, pickup auto-detection, and navigation.';
                    break;
                  case 'notifications':
                    effectDescription =
                        'Instant ride requests, message notifications, and arrival alerts.';
                    break;
                  case 'photos_storage':
                    effectDescription =
                        'Capturing vehicle inspection photos and profile documents.';
                    break;
                  default:
                    effectDescription = item.description;
                }
                return Padding(
                  padding: const EdgeInsets.only(bottom: 10),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Padding(
                        padding: const EdgeInsets.only(top: 2, right: 10),
                        child: Icon(
                          item.icon,
                          size: 18,
                          color: _seseGold,
                        ),
                      ),
                      Expanded(
                        child: RichText(
                          text: TextSpan(
                            style: theme.textTheme.bodyMedium?.copyWith(fontSize: 13),
                            children: [
                              TextSpan(
                                text: '${item.title}: ',
                                style: const TextStyle(fontWeight: FontWeight.bold),
                              ),
                              TextSpan(
                                text: effectDescription,
                                style: TextStyle(
                                  color: theme.textTheme.bodyMedium?.color
                                      ?.withValues(alpha: 0.75),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ],
                  ),
                );
              }),
              const SizedBox(height: 10),
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: _seseGold.withValues(alpha: 0.08),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(
                    color: _seseGold.withValues(alpha: 0.2),
                  ),
                ),
                child: Row(
                  children: [
                    const Icon(Icons.info_outline_rounded,
                        size: 20, color: _seseGold),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        'You can grant these at any time when using those features, or in your device settings.',
                        style: theme.textTheme.bodySmall?.copyWith(
                          fontSize: 12,
                          height: 1.3,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 24),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton(
                      key: const Key('stay_and_grant_button'),
                      style: OutlinedButton.styleFrom(
                        padding: const EdgeInsets.symmetric(vertical: 14),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                      ),
                      onPressed: () => Navigator.of(ctx).pop(),
                      child: const Text('Stay & Grant'),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: FilledButton(
                      key: const Key('confirm_proceed_without_permissions'),
                      style: FilledButton.styleFrom(
                        backgroundColor: _seseGold,
                        foregroundColor: Colors.black,
                        padding: const EdgeInsets.symmetric(vertical: 14),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                      ),
                      onPressed: () async {
                        Navigator.of(ctx).pop();
                        PermissionOnboardingService.markSessionSkipped(
                          widget.user.uid,
                          widget.role,
                        );
                        await PermissionOnboardingService.refreshLocationStatus();
                        if (mounted) widget.onCompleted();
                      },
                      child: const Text(
                        'Continue Anyway',
                        style: TextStyle(fontWeight: FontWeight.bold),
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
  }

  String get _roleSubtitle {
    return 'To give you a seamless ride booking and delivery experience, SeSe needs access to the following permissions.';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final isTest = SeseUniversalMap.debugTileProviderOverride != null;

    return Scaffold(
      key: const Key('permission_onboarding_screen'),
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        actions: [
          TextButton(
            key: const Key('skip_permissions_button'),
            onPressed: _showProceedWithoutPermissionsConfirmation,
            child: Text(
              'Skip for now',
              style: TextStyle(
                color: theme.colorScheme.onSurface.withValues(alpha: 0.7),
                fontWeight: FontWeight.w600,
                fontSize: 14,
              ),
            ),
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: SafeArea(
        child: (_isLoading && !isTest)
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
                                    if (!mounted) return;
                                    setState(() {
                                      _statuses[item.id] = newStatus;
                                    });
                                    await PermissionOnboardingService.refreshLocationStatus();
                                    if (_areAllMandatoryGranted) {
                                      await PermissionOnboardingService.setCompleted(
                                        userId: widget.user.uid,
                                        role: widget.role,
                                      );
                                      if (mounted) widget.onCompleted();
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
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        SizedBox(
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
                        if (!_areAllMandatoryGranted) ...[
                          const SizedBox(height: 8),
                          TextButton(
                            key: const Key('proceed_without_all_button'),
                            onPressed: _showProceedWithoutPermissionsConfirmation,
                            child: Text(
                              'Proceed with limited features',
                              style: TextStyle(
                                color: theme.textTheme.bodyMedium?.color
                                    ?.withValues(alpha: 0.7),
                                fontWeight: FontWeight.w600,
                                fontSize: 13,
                              ),
                            ),
                          ),
                        ],
                      ],
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
