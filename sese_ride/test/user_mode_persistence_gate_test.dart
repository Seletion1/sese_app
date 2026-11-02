import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sese_core/sese_core.dart';
import 'package:sese_ride/features/settings/role_controller.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    RoleController.instance.cancelActiveTripCountdown();
    RoleController.instance.setCurrentRole(UserRole.customer);
  });

  tearDown(() {
    RoleController.instance.cancelActiveTripCountdown();
    RoleController.instance.setCurrentRole(UserRole.customer);
  });

  group('User Mode State Persistence across Rebuilds', () {
    test('RoleController activeMode persistence and restoreSession cycle', () async {
      const userId = 'driver_user_777';

      // 1. Initial role is customer
      expect(RoleController.instance.currentRole, UserRole.customer);

      // 2. User activates driver mode
      await RoleController.instance.activateMode(userId, UserRole.driver);
      expect(RoleController.instance.currentRole, UserRole.driver);

      // 3. Simulate process reset where memory defaults back to customer
      RoleController.instance.setCurrentRole(UserRole.customer);
      expect(RoleController.instance.currentRole, UserRole.customer);

      // 4. restoreSession reads local preference and recovers Driver mode
      final restored = await RoleController.instance.restoreSession(
        userId: userId,
        fallbackRole: UserRole.customer,
        onProtectionExpired: () {},
      );

      expect(restored, UserRole.driver);
      expect(RoleController.instance.currentRole, UserRole.driver);
    });

    testWidgets('ListenableBuilder rebuilds when RoleController mode changes', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ListenableBuilder(
              listenable: RoleController.instance,
              builder: (context, _) {
                return Text('ActiveRole: ${RoleController.instance.currentRole.name}');
              },
            ),
          ),
        ),
      );

      await tester.pump();
      expect(find.text('ActiveRole: customer'), findsOneWidget);

      // Activate driver mode
      RoleController.instance.setCurrentRole(UserRole.driver);
      await tester.pump();

      expect(find.text('ActiveRole: driver'), findsOneWidget);

      // Re-trigger widget rebuild (simulating Hot Reload / parent rebuild)
      tester.binding.scheduleFrame();
      await tester.pump();

      // State MUST remain driver mode
      expect(find.text('ActiveRole: driver'), findsOneWidget);
    });
  });
}
