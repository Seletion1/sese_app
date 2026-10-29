import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sese_core/sese_core.dart';
import 'package:sese_ride/features/permissions/permission_item_model.dart';
import 'package:sese_ride/features/permissions/permission_onboarding_gate.dart';
import 'package:sese_ride/features/permissions/permission_onboarding_screen.dart';
import 'package:sese_ride/features/permissions/permission_onboarding_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
  });

  group('PermissionItem Bundles', () {
    test('bundleForCustomer returns Location & Notification permissions', () {
      final customerBundle = PermissionItem.bundleForCustomer();
      expect(customerBundle.length, 2);
      expect(customerBundle[0].id, 'location');
      expect(customerBundle[0].title, 'Location Access');
      expect(customerBundle[1].id, 'notifications');
      expect(customerBundle[1].title, 'Notifications');
    });

    test('bundleForDriver returns Precise, Background Location, Notifications & Photos', () {
      final driverBundle = PermissionItem.bundleForDriver();
      expect(driverBundle.length, 4);
      expect(driverBundle[0].id, 'precise_location');
      expect(driverBundle[1].id, 'background_location');
      expect(driverBundle[2].id, 'notifications');
      expect(driverBundle[3].id, 'photos_storage');
    });

    test('bundleForRole routes correct bundle for UserRole', () {
      expect(PermissionItem.bundleForRole(UserRole.customer).length, 2);
      expect(PermissionItem.bundleForRole(UserRole.driver).length, 4);
    });
  });

  group('PermissionOnboardingService Persistence', () {
    test('isCompleted returns false initially for fresh user', () async {
      final isDone = await PermissionOnboardingService.isCompleted(
        userId: 'user-123',
        role: UserRole.customer,
      );
      expect(isDone, isFalse);
    });

    test('setCompleted sets flag and makes isCompleted return true', () async {
      await PermissionOnboardingService.setCompleted(
        userId: 'user-123',
        role: UserRole.customer,
      );
      final isDone = await PermissionOnboardingService.isCompleted(
        userId: 'user-123',
        role: UserRole.customer,
      );
      expect(isDone, isTrue);
    });
  });

  group('PermissionOnboardingScreen UI Widget Tests', () {
    final testUser = AppUser(
      uid: 'test-user-1',
      fullName: 'Test User',
      email: 'test@example.com',
      phoneNumber: '08000000000',
      role: UserRole.customer,
      createdAt: DateTime.now(),
    );

    testWidgets('Renders Customer role permission cards correctly',
        (WidgetTester tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: PermissionOnboardingScreen(
            user: testUser,
            role: UserRole.customer,
            onCompleted: () {},
          ),
        ),
      );

      await tester.pumpAndSettle();

      expect(find.text('Permissions Required'), findsOneWidget);
      expect(find.text('Location Access'), findsOneWidget);
      expect(find.text('Notifications'), findsOneWidget);
      expect(
          find.textContaining('Required to find nearby rides'), findsOneWidget);
      expect(find.byKey(const Key('grant_permissions_button')), findsOneWidget);
    });

    testWidgets('Renders Driver role permission cards correctly',
        (WidgetTester tester) async {
      final driverUser = AppUser(
        uid: 'test-driver-1',
        fullName: 'Test Driver',
        email: 'driver@example.com',
        phoneNumber: '08000000001',
        role: UserRole.driver,
        createdAt: DateTime.now(),
      );

      await tester.pumpWidget(
        MaterialApp(
          home: PermissionOnboardingScreen(
            user: driverUser,
            role: UserRole.driver,
            onCompleted: () {},
          ),
        ),
      );

      await tester.pumpAndSettle();

      expect(find.text('Permissions Required'), findsOneWidget);
      expect(find.text('Precise Location'), findsOneWidget);
      expect(find.text('Background Location'), findsOneWidget);
      expect(find.text('Notifications'), findsOneWidget);
      expect(find.text('Photos & Storage'), findsOneWidget);
    });
  });

  group('PermissionOnboardingGate Routing Tests', () {
    final testUser = AppUser(
      uid: 'gate-user-1',
      fullName: 'Gate User',
      email: 'gate@example.com',
      phoneNumber: '08000000002',
      role: UserRole.customer,
      createdAt: DateTime.now(),
    );

    testWidgets('Displays PermissionOnboardingScreen when onboarding not completed',
        (WidgetTester tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: PermissionOnboardingGate(
            user: testUser,
            role: UserRole.customer,
            child: const Text('CUSTOMER HOME SHELL CONTENT'),
          ),
        ),
      );

      await tester.pumpAndSettle();

      expect(find.text('CUSTOMER HOME SHELL CONTENT'), findsNothing);
      expect(find.text('Permissions Required'), findsOneWidget);
    });

    testWidgets('Renders child content directly when onboarding is completed',
        (WidgetTester tester) async {
      await PermissionOnboardingService.setCompleted(
        userId: testUser.uid,
        role: UserRole.customer,
      );

      await tester.pumpWidget(
        MaterialApp(
          home: PermissionOnboardingGate(
            user: testUser,
            role: UserRole.customer,
            child: const Text('CUSTOMER HOME SHELL CONTENT'),
          ),
        ),
      );

      await tester.pumpAndSettle();

      expect(find.text('CUSTOMER HOME SHELL CONTENT'), findsOneWidget);
      expect(find.text('Permissions Required'), findsNothing);
    });
  });
}
