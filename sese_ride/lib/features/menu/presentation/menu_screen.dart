import 'package:flutter/material.dart';
import 'package:sese_core/sese_core.dart';
import '../../driver/presentation/driver_fleet_screen.dart';
import '../../driver/presentation/driver_onboarding_screen.dart';
import '../../driver/services/driver_fleet_service.dart';
import '../../home/customer_home_shell.dart';
import '../../home/driver_home_shell.dart';
import '../../settings/delete_account_dialog.dart';
import '../../settings/role_controller.dart';

/// Side / Navigation Menu Screen supporting Dual Role Switching,
/// Cross-Onboarding, Theme Management, and Secure Account Deletion.
class MenuScreen extends StatefulWidget {
  final AppUser user;
  final AuthRepository auth;
  final UserRole currentRole;

  const MenuScreen({
    super.key,
    required this.user,
    required this.auth,
    required this.currentRole,
  });

  @override
  State<MenuScreen> createState() => _MenuScreenState();
}

class _MenuScreenState extends State<MenuScreen> {
  bool _evaluatingSwitch = false;

  /// Handles switching from Customer to Driver.
  Future<void> _handleCustomerToDriverSwitch() async {
    setState(() => _evaluatingSwitch = true);
    final scenario = await RoleController.instance.evaluateDriverEligibility(widget.user.uid);
    if (!mounted) return;
    setState(() => _evaluatingSwitch = false);

    switch (scenario) {
      case DriverOnboardingScenario.scenarioA:
        // Scenario A (Fully Onboarded): Switch directly to Driver View.
        RoleController.instance.setCurrentRole(UserRole.driver);
        Navigator.of(context).pushAndRemoveUntil(
          MaterialPageRoute(
            builder: (_) => DriverHomeShell(user: widget.user, auth: widget.auth),
          ),
          (route) => false,
        );
        break;

      case DriverOnboardingScenario.scenarioB:
        // Scenario B (Missing Vehicle Only): Direct to Add Vehicle / Manage Fleet.
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Please add and register a vehicle before going online as a driver.'),
            backgroundColor: AppColors.seseGold,
          ),
        );
        Navigator.of(context).push(
          MaterialPageRoute(
            builder: (_) => DriverFleetScreen(
              fleetService: DriverFleetService(),
              driverId: widget.user.uid,
            ),
          ),
        );
        break;

      case DriverOnboardingScenario.scenarioC:
        // Scenario C (Unverified / New): Prompt dialog and route to Driver Onboarding Form (Step 2).
        await showDialog<void>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: const Text('Complete Driver Profile'),
            content: const Text(
              'Complete Driver Profile to start earning. Submit your personal information and identity verification.',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(ctx).pop(),
                child: const Text('Later'),
              ),
              FilledButton(
                style: FilledButton.styleFrom(
                  backgroundColor: AppColors.seseGold,
                  foregroundColor: Colors.black,
                ),
                onPressed: () {
                  Navigator.of(ctx).pop();
                  Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (_) => DriverOnboardingScreen(
                        user: widget.user,
                        auth: widget.auth,
                      ),
                    ),
                  );
                },
                child: const Text('Get Started'),
              ),
            ],
          ),
        );
        break;
    }
  }

  /// Handles switching from Driver to Customer with Active Trip Protection.
  Future<void> _handleDriverToCustomerSwitch() async {
    setState(() => _evaluatingSwitch = true);
    final hasActiveTrip =
        await RoleController.instance.checkDriverHasActiveTrip(widget.user.uid);
    if (!mounted) return;
    setState(() => _evaluatingSwitch = false);

    RoleController.instance.setCurrentRole(UserRole.customer);

    if (hasActiveTrip) {
      // Active Trip Protection Rule:
      // Start 10-Minute countdown. When expired, switch back to Driver Mode automatically.
      RoleController.instance.startActiveTripCountdown(
        onExpired: () {
          debugPrint('Active trip protection countdown expired: returning to Driver Mode');
          RoleController.instance.setCurrentRole(UserRole.driver);
          Navigator.of(context).pushAndRemoveUntil(
            MaterialPageRoute(
              builder: (_) => DriverHomeShell(user: widget.user, auth: widget.auth),
            ),
            (route) => false,
          );
        },
      );
    } else {
      RoleController.instance.cancelActiveTripCountdown();
    }

    Navigator.of(context).pushAndRemoveUntil(
      MaterialPageRoute(
        builder: (_) => CustomerHomeShell(user: widget.user, auth: widget.auth),
      ),
      (route) => false,
    );
  }

  @override
  Widget build(BuildContext context) {
    final isDriver = widget.currentRole == UserRole.driver;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Side Menu'),
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          // User Profile Card
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Row(
                children: [
                  UserAvatar(
                    displayName: widget.user.fullName,
                    photoUrl: widget.user.photoUrl,
                    radius: 26,
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          widget.user.fullName.isEmpty
                              ? (isDriver ? 'Driver' : 'Customer')
                              : widget.user.fullName,
                          style: const TextStyle(
                            fontSize: 17,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        Text(
                          widget.user.email,
                          style: const TextStyle(color: Colors.grey, fontSize: 13),
                        ),
                        const SizedBox(height: 4),
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                          decoration: BoxDecoration(
                            color: AppColors.seseGoldLight,
                            borderRadius: BorderRadius.circular(4),
                          ),
                          child: Text(
                            isDriver ? 'DRIVER MODE' : 'CUSTOMER MODE',
                            style: const TextStyle(
                              fontSize: 10,
                              fontWeight: FontWeight.bold,
                              color: Colors.black87,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 12),

          // 1. Dual Role Switching & Cross-Onboarding
          Card(
            color: AppColors.seseGoldLight.withValues(alpha: 0.5),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
              side: BorderSide.none,
            ),
            child: ListTile(
              key: const Key('switch_mode_tile'),
              leading: Icon(
                isDriver ? Icons.person_outline : Icons.two_wheeler,
                color: AppColors.seseGold,
                size: 28,
              ),
              title: Text(
                isDriver ? 'Switch to Customer Mode' : 'Switch to Driver Mode',
                style: const TextStyle(fontWeight: FontWeight.bold),
              ),
              subtitle: Text(
                isDriver
                    ? 'Book rides, order deliveries, and manage rider profile'
                    : 'Earn on your schedule with verified driver dispatch',
                style: const TextStyle(fontSize: 12),
              ),
              trailing: _evaluatingSwitch
                  ? const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.swap_horiz, color: AppColors.seseGold),
              onTap: _evaluatingSwitch
                  ? null
                  : (isDriver ? _handleDriverToCustomerSwitch : _handleCustomerToDriverSwitch),
            ),
          ),
          const SizedBox(height: 8),

          // 2. Theme / Appearance Switcher
          ValueListenableBuilder<ThemeMode>(
            valueListenable: ThemeController.instance,
            builder: (context, themeMode, _) {
              return ListTile(
                key: const Key('menu_theme_tile'),
                leading: const Icon(Icons.brightness_6_outlined, color: AppColors.seseGold),
                title: const Text('Theme / Appearance'),
                subtitle: Text(themeMode.label),
                trailing: const Icon(Icons.chevron_right, color: AppColors.seseGold),
                onTap: () => showThemePickerSheet(context, ThemeController.instance),
              );
            },
          ),
          const SizedBox(height: 12),

          // Sign Out
          ListTile(
            leading: const Icon(Icons.logout),
            title: const Text('Sign Out'),
            onTap: () => widget.auth.signOut(),
          ),
          const SizedBox(height: 12),

          // 3. Secure Account Deletion
          ListTile(
            key: const Key('menu_delete_account_tile'),
            leading: Icon(Icons.delete_forever_outlined, color: Colors.red.shade700),
            title: Text(
              'Delete Account',
              style: TextStyle(
                color: Colors.red.shade700,
                fontWeight: FontWeight.bold,
              ),
            ),
            subtitle: const Text(
              'Permanent account erasure and 30-day archival',
              style: TextStyle(fontSize: 11, color: Colors.grey),
            ),
            onTap: () => DeleteAccountDialog.show(
              context,
              user: widget.user,
              auth: widget.auth,
            ),
          ),
        ],
      ),
    );
  }
}
