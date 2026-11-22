import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sese_core/sese_core.dart';
import 'package:sese_hub/features/config/services/system_config_service.dart';
import 'package:sese_hub/features/dashboard/presentation/hub_dashboard_screen.dart';
import 'package:sese_hub/features/settings/hub_settings_screen.dart';
import 'package:sese_hub/features/staff/presentation/staff_management_screen.dart';
import 'package:sese_hub/features/staff/services/hub_access_service.dart';

void main() {
  group('AddStaffDialog Gmail + module provisioning', () {
    Future<void> pumpDialog(WidgetTester tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: AddStaffDialog(
              provisionerEmail: 'admin@sese.app',
              accessService: HubAccessService(),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    testWidgets('offers email field and module tier selection',
        (tester) async {
      await pumpDialog(tester);

      expect(find.text("Admin's Email address"), findsOneWidget);
      expect(find.text('Super Admin'), findsOneWidget);
      expect(find.text('Scoped Sub-Admin'), findsOneWidget);
      expect(find.text('Scoped Permissions Checklist'), findsOneWidget);
    });

    testWidgets('switching to Super Admin displays auto-grant message',
        (tester) async {
      await pumpDialog(tester);

      await tester.tap(find.text('Super Admin'));
      await tester.pumpAndSettle();

      expect(find.text('Super Admin tier automatically grants full system permissions across all modules.'), findsOneWidget);
    });

    testWidgets('switching back to Scoped Sub-Admin restores permissions checklist',
        (tester) async {
      await pumpDialog(tester);

      await tester.tap(find.text('Super Admin'));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Scoped Sub-Admin'));
      await tester.pumpAndSettle();

      expect(find.text('Scoped Permissions Checklist'), findsOneWidget);
    });
  });

  group('HubDashboardScreen unified tabs (3-slot + More)', () {
    Future<void> pumpShell(
      WidgetTester tester, {
      required UserRole role,
      bool isOwner = false,
      List<String> permissions = const [],
    }) async {
      SharedPreferences.setMockInitialValues({});
      await tester.pumpWidget(
        MaterialApp(
          home: HubDashboardScreen(
            configService: SystemConfigService(),
            staffRole: role,
            isOwner: isOwner,
            permissions: permissions,
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    testWidgets('fleet + support grants render exactly those tabs in bottom bar',
        (tester) async {
      await pumpShell(tester,
          role: UserRole.admin,
          permissions: const [permFleetVerify, permSupportChat]);

      // Both granted module tabs appear in the 3-slot bottom bar.
      expect(find.text('Fleet & Security'), findsOneWidget);
      expect(find.text('Support Inbox'), findsOneWidget);
      // Un-granted tabs are absent entirely — not in bar, not in More.
      expect(find.text('Dynamic Config'), findsNothing);
      expect(find.text('Staff'), findsNothing);
      expect(find.text('Agent Console'), findsNothing);
      expect(find.text('Logout'), findsNothing);
    });

    testWidgets('dynamic_config grant renders the config tab in bottom bar',
        (tester) async {
      await pumpShell(tester,
          role: UserRole.agent, permissions: const [permDynamicConfig]);

      expect(find.text('Dynamic Config'), findsOneWidget);
      expect(find.text('Fleet & Security'), findsNothing);
      expect(find.text('Support Inbox'), findsNothing);
    });

    testWidgets(
        'owner sees section buttons in scrollable bar and pinned Profile button',
        (tester) async {
      await pumpShell(tester, role: UserRole.superRole, isOwner: true);

      // Owner sees module tabs in the horizontally scrollable bottom bar.
      expect(find.text('Active Rides'), findsOneWidget);
      expect(find.text('Fleet & Security'), findsOneWidget);
      expect(find.text('User Onboarding'), findsOneWidget);
      expect(find.text('Dynamic Config'), findsOneWidget);

      // Stationary pinned Profile button is present.
      expect(find.text('Profile'), findsOneWidget);
      expect(find.byKey(const Key('hub_nav_more')), findsOneWidget);

      // Verify no top-left hamburger menu icon is in the app bar.
      expect(find.byIcon(Icons.menu), findsNothing);

      // Open the Profile drawer and verify shortcuts and settings are accessible.
      await tester.tap(find.byKey(const Key('hub_nav_more')));
      await tester.pumpAndSettle();

      expect(find.text('Profile Settings'), findsOneWidget);
      expect(
          find.descendant(
              of: find.byType(Drawer), matching: find.text('Staff')),
          findsOneWidget);
      expect(find.text('Theme / Appearance'), findsOneWidget);
      expect(find.text('Sign Out'), findsOneWidget);
    });

    testWidgets('permission-less staffer collapses to profile, logout in profile',
        (tester) async {
      await pumpShell(tester, role: UserRole.admin);

      expect(find.text('Fleet & Security'), findsNothing);
      expect(find.text('Support Inbox'), findsNothing);
      expect(find.text('Dynamic Config'), findsNothing);
      // No Logout destination in the bar...
      expect(find.text('Logout'), findsNothing);
      // ...Profile renders directly (bar-less single tab) hosting Sign Out.
      expect(find.text('Sign Out'), findsWidgets);
    });

    testWidgets('tapping pinned Profile button opens section sub-list and avatar opens Settings',
        (tester) async {
      // Owner with Fleet permission:
      await pumpShell(tester, role: UserRole.superRole, isOwner: true);

      // Switch to Fleet & Security section
      await tester.tap(find.text('Fleet & Security'));
      await tester.pumpAndSettle();

      // Top-left hamburger icon must NOT be present
      expect(find.byIcon(Icons.menu), findsNothing);

      // Tap pinned Profile button to open Profile & Section sub-list panel
      await tester.tap(find.byKey(const Key('hub_nav_more')));
      await tester.pumpAndSettle();

      // The drawer shows the sub-sections for Fleet Verification
      expect(
          find.descendant(
              of: find.byType(Drawer),
              matching: find.text('Fleet Verification & Security Pipeline Desk')),
          findsOneWidget);
      expect(find.text('Pending Vehicle Registrations'), findsOneWidget);
      expect(find.text('Driver KYC Approvals'), findsOneWidget);

      // Tapping the avatar inside the drawer opens Profile Settings
      expect(find.byKey(const Key('hub_profile_avatar_tap')), findsOneWidget);
      await tester.tap(find.byKey(const Key('hub_profile_avatar_tap')));
      await tester.pumpAndSettle();

      // Settings screen should now be pushed on top
      expect(find.byType(HubSettingsScreen), findsOneWidget);
    });
  });
}
