import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sese_core/sese_core.dart';
import 'package:sese_ride/features/permissions/permission_item_model.dart';
import 'package:sese_ride/features/permissions/permission_onboarding_gate.dart';
import 'package:sese_ride/features/permissions/permission_onboarding_screen.dart';
import 'package:sese_ride/features/permissions/permission_onboarding_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:sese_ride/widgets/map_provider.dart';
import 'package:sese_ride/widgets/osm_map_view.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    await prefs.clear();
    SeseUniversalMap.debugTileProviderOverride = BlankTileProvider();
    PermissionOnboardingService.resetForTesting();
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

    test('bundleForDriver returns Precise Location, Notifications, Camera & Display Over Other Apps', () {
      final driverBundle = PermissionItem.bundleForDriver();
      expect(driverBundle.length, 4);
      expect(driverBundle[0].id, 'precise_location');
      expect(driverBundle[1].id, 'notifications');
      expect(driverBundle[2].id, 'photos_storage');
      expect(driverBundle[2].title, 'Camera & Documents');
      expect(driverBundle[3].id, 'overlay_bubble');
      expect(driverBundle[3].title, 'Display Over Other Apps');
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

    testWidgets('Renders Customer role permission cards and skip button correctly',
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
      expect(find.byKey(const Key('skip_permissions_button')), findsOneWidget);
      expect(find.byKey(const Key('proceed_without_all_button')), findsOneWidget);
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
      expect(find.text('Notifications'), findsOneWidget);
      expect(find.text('Camera & Documents'), findsOneWidget);
    });

    testWidgets('Skip for now opens confirmation sheet and allows continuing anyway',
        (WidgetTester tester) async {
      bool completedCalled = false;

      await tester.pumpWidget(
        MaterialApp(
          home: PermissionOnboardingScreen(
            user: testUser,
            role: UserRole.customer,
            onCompleted: () {
              completedCalled = true;
            },
          ),
        ),
      );

      await tester.pumpAndSettle();

      // Tap "Skip for now"
      await tester.tap(find.byKey(const Key('skip_permissions_button')));
      await tester.pumpAndSettle();

      // Confirmation sheet should be visible
      expect(find.text('Proceed with Limited Features?'), findsOneWidget);
      expect(find.byKey(const Key('stay_and_grant_button')), findsOneWidget);
      expect(find.byKey(const Key('confirm_proceed_without_permissions')), findsOneWidget);

      // Tap "Continue Anyway"
      await tester.tap(find.byKey(const Key('confirm_proceed_without_permissions')));
      await tester.pumpAndSettle();

      expect(completedCalled, isTrue);

      // Verify persistence was saved
      final isDone = await PermissionOnboardingService.isCompleted(
        userId: testUser.uid,
        role: UserRole.customer,
      );
      expect(isDone, isTrue);
    });

    testWidgets('Proceed with limited features allows user to Stay & Grant',
        (WidgetTester tester) async {
      bool completedCalled = false;

      await tester.pumpWidget(
        MaterialApp(
          home: PermissionOnboardingScreen(
            user: testUser,
            role: UserRole.customer,
            onCompleted: () {
              completedCalled = true;
            },
          ),
        ),
      );

      await tester.pumpAndSettle();

      // Tap "Proceed with limited features"
      await tester.tap(find.byKey(const Key('proceed_without_all_button')));
      await tester.pumpAndSettle();

      expect(find.text('Proceed with Limited Features?'), findsOneWidget);

      // Tap "Stay & Grant"
      await tester.tap(find.byKey(const Key('stay_and_grant_button')));
      await tester.pumpAndSettle();

      // Sheet dismissed, onCompleted not called, remains on onboarding screen
      expect(completedCalled, isFalse);
      expect(find.text('Proceed with Limited Features?'), findsNothing);
      expect(find.text('Permissions Required'), findsOneWidget);
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
