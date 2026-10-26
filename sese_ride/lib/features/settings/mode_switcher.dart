import 'package:flutter/material.dart';
import 'package:sese_core/sese_core.dart';

import '../driver/presentation/driver_fleet_screen.dart';
import '../driver/presentation/driver_onboarding_screen.dart';
import '../driver/services/driver_fleet_service.dart';
import '../home/customer_home_shell.dart';
import '../home/driver_home_shell.dart';
import 'role_controller.dart';

/// Dual-role mode switching, launched from Settings ("App Mode").
///
/// Both flows lived on the Home/Menu surfaces before; they are centralized
/// here so customer and driver settings share one implementation. Navigation
/// uses a [NavigatorState] captured up-front so async gaps (eligibility
/// checks, countdown expiry) can never touch a dead context.
abstract final class ModeSwitcher {
  /// Driver → Customer (Module 2 double-confirmation + active-trip guard).
  ///
  /// With an active trip, the 10-minute protection countdown auto-switches
  /// back to Driver Mode on expiry; otherwise any pending countdown is
  /// cancelled.
  static Future<void> switchToCustomer(
    BuildContext context, {
    required AppUser user,
    required AuthRepository auth,
  }) async {
    final navigator = Navigator.of(context);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Confirm Switch'),
        content: const Text(
          'Are you sure you want to switch to Customer Mode?\n\n'
          'You will stop receiving dispatch offers while in Customer Mode.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Confirm'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    final hasActiveTrip =
        await RoleController.instance.checkDriverHasActiveTrip(user.uid);

    await RoleController.instance.activateMode(user.uid, UserRole.customer);

    if (hasActiveTrip) {
      RoleController.instance.startActiveTripCountdown(
        userId: user.uid,
        onExpired: () {
          debugPrint(
              'Active trip protection timer expired: auto-switching to Driver Mode');
          navigator.pushAndRemoveUntil(
            MaterialPageRoute(
              builder: (_) => DriverHomeShell(user: user, auth: auth),
            ),
            (route) => false,
          );
        },
      );
    } else {
      RoleController.instance.cancelActiveTripCountdown(userId: user.uid);
    }

    navigator.pushAndRemoveUntil(
      MaterialPageRoute(
        builder: (_) => CustomerHomeShell(user: user, auth: auth),
      ),
      (route) => false,
    );
  }

  /// Customer → Driver, gated by driver-eligibility evaluation:
  /// - A (onboarded): straight into Driver Home.
  /// - B (no vehicle): nudge to Fleet, then stop.
  /// - C (new): "Complete Driver Profile" prompt → Step 2 onboarding.
  static Future<void> switchToDriver(
    BuildContext context, {
    required AppUser user,
    required AuthRepository auth,
  }) async {
    final navigator = Navigator.of(context);
    final messenger = ScaffoldMessenger.of(context);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Confirm Switch'),
        content: const Text(
          'Are you sure you want to switch to Driver Mode?',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Confirm'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    // Eligibility check with a blocking progress veil (no stateful host
    // needed — the dialog owns the busy UI and is popped when done).
    // Context safety: `navigator`/`messenger` were captured synchronously
    // and `navigator.mounted` is re-checked after every await, so the
    // ignores below never touch a dead route.
    showDialog<void>(
      // ignore: use_build_context_synchronously
      context: navigator.context,
      barrierDismissible: false,
      builder: (_) =>
          const Center(child: CircularProgressIndicator(strokeWidth: 2)),
    );
    final scenario =
        await RoleController.instance.evaluateDriverEligibility(user.uid);
    if (!navigator.mounted) return;
    navigator.pop();

    switch (scenario) {
      case DriverOnboardingScenario.scenarioA:
        await RoleController.instance.activateMode(user.uid, UserRole.driver);
        navigator.pushAndRemoveUntil(
          MaterialPageRoute(
            builder: (_) => DriverHomeShell(user: user, auth: auth),
          ),
          (route) => false,
        );
        break;

      case DriverOnboardingScenario.scenarioB:
        messenger.showSnackBar(
          const SnackBar(
            content: Text(
              'Please add and verify a vehicle before going online as a driver.',
            ),
            backgroundColor: AppColors.seseGold,
          ),
        );
        navigator.push(
          MaterialPageRoute(
            builder: (_) => DriverFleetScreen(
              fleetService: DriverFleetService(),
              driverId: user.uid,
            ),
          ),
        );
        break;

      case DriverOnboardingScenario.scenarioC:
        await showDialog<void>(
          // ignore: use_build_context_synchronously
          context: navigator.context,
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
                  navigator.push(
                    MaterialPageRoute(
                      builder: (_) => DriverOnboardingScreen(
                        user: user,
                        auth: auth,
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
}
