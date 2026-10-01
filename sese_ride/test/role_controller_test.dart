import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sese_core/sese_core.dart';
import 'package:sese_ride/features/home/active_trip_countdown_banner.dart';
import 'package:sese_ride/features/settings/role_controller.dart';

void main() {
  setUp(() {
    RoleController.instance.cancelActiveTripCountdown();
    RoleController.instance.setCurrentRole(UserRole.customer);
  });

  tearDown(() {
    RoleController.instance.cancelActiveTripCountdown();
    RoleController.instance.setCurrentRole(UserRole.customer);
  });

  group('RoleController role state', () {
    test('defaults to customer with a 10:00 countdown', () {
      expect(RoleController.instance.currentRole, UserRole.customer);
      expect(RoleController.instance.hasActiveTripProtection, isFalse);
      expect(RoleController.instance.remainingCountdownSeconds, 600);
      expect(RoleController.instance.countdownDisplay, '10:00');
    });

    test('setCurrentRole switches modes', () {
      RoleController.instance.setCurrentRole(UserRole.driver);
      expect(RoleController.instance.currentRole, UserRole.driver);
    });
  });

  group('RoleController cross-onboarding guards', () {
    test('empty uid resolves to scenario C / no active trip', () async {
      expect(
        await RoleController.instance.evaluateDriverEligibility(''),
        DriverOnboardingScenario.scenarioC,
      );
      expect(
        await RoleController.instance.checkDriverHasActiveTrip(''),
        isFalse,
      );
    });
  });

  group('RoleController 10-minute active-trip countdown', () {
    test('start arms protection at 10 minutes', () {
      RoleController.instance
          .startActiveTripCountdown(onExpired: () {});
      expect(RoleController.instance.hasActiveTripProtection, isTrue);
      expect(RoleController.instance.remainingCountdownSeconds, 600);
      expect(RoleController.instance.countdownDisplay, '10:00');
    });

    test('cancel disarms and resets the timer', () {
      RoleController.instance
          .startActiveTripCountdown(onExpired: () {});
      RoleController.instance.cancelActiveTripCountdown();
      expect(RoleController.instance.hasActiveTripProtection, isFalse);
      expect(RoleController.instance.remainingCountdownSeconds, 600);
    });
  });

  group('ActiveTripCountdownBanner', () {
    testWidgets('hidden when no protection is armed', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: ActiveTripCountdownBanner(onReturnToDriver: _noop),
          ),
        ),
      );
      await tester.pump();
      expect(
          find.byKey(const Key('active_trip_countdown_banner')),
          findsNothing);
    });

    testWidgets('shows timer and returns to driver mode on tap',
        (tester) async {
      var returned = false;
      RoleController.instance
          .startActiveTripCountdown(onExpired: () {});
      try {
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: ActiveTripCountdownBanner(onReturnToDriver: () {
                returned = true;
              }),
            ),
          ),
        );
        await tester.pump();
        expect(
            find.byKey(const Key('active_trip_countdown_banner')),
            findsOneWidget);
        expect(find.textContaining('Auto-switch in:'), findsOneWidget);

        await tester.tap(find.byKey(const Key('return_to_driver_button')));
        await tester.pump();
        expect(returned, isTrue);
        expect(RoleController.instance.hasActiveTripProtection, isFalse);
      } finally {
        RoleController.instance.cancelActiveTripCountdown();
      }
    });
  });
}

void _noop() {}
