import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sese_core/sese_core.dart';
import 'package:sese_hub/features/config/services/system_config_service.dart';
import 'package:sese_hub/features/dashboard/presentation/hub_dashboard_screen.dart';
import 'package:sese_hub/features/staff/presentation/staff_management_screen.dart';
import 'package:sese_hub/features/staff/services/hub_access_service.dart';

void main() {
  group('AddStaffDialog Gmail + module provisioning', () {
    Future<void> pumpDialog(WidgetTester tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: AddStaffDialog(
              provisionerEmail: 'bamiduromichael2@gmail.com',
              accessService: HubAccessService(),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    testWidgets('offers Gmail field and exactly the four modules',
        (tester) async {
      await pumpDialog(tester);

      expect(find.text("Candidate's Gmail address"), findsOneWidget);
      expect(find.text('Fleet & Security'), findsOneWidget);
      expect(find.text('Dynamic Config'), findsOneWidget);
      expect(find.text('Staff Management'), findsOneWidget);
      expect(find.text('Support Inbox'), findsOneWidget);
      // Legacy/system-critical codes are gone from provisioning.
      expect(find.text('Manage admin invites'), findsNothing);
      expect(find.text('Manage vault keys'), findsNothing);
      expect(find.text('Manage system settings'), findsNothing);
    });

    testWidgets('staff_manage is disabled for Agent, enabled for Super',
        (tester) async {
      await pumpDialog(tester);

      CheckboxListTile staffTile() => tester.widget<CheckboxListTile>(
          find.widgetWithText(CheckboxListTile, 'Staff Management'));
      expect(staffTile().onChanged, isNull);
      expect(find.text('Super Admin only'), findsOneWidget);

      await tester.tap(find.byType(DropdownButtonFormField<UserRole>));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Super').last);
      await tester.pumpAndSettle();

      expect(staffTile().onChanged, isNotNull);
    });

    testWidgets('switching Super back to Agent drops staff_manage',
        (tester) async {
      await pumpDialog(tester);

      await tester.tap(find.byType(DropdownButtonFormField<UserRole>));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Super').last);
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(CheckboxListTile, 'Staff Management'));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<CheckboxListTile>(
                find.widgetWithText(CheckboxListTile, 'Staff Management'))
            .value,
        isTrue,
      );

      await tester.tap(find.byType(DropdownButtonFormField<UserRole>));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Agent').last);
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<CheckboxListTile>(
                find.widgetWithText(CheckboxListTile, 'Staff Management'))
            .value,
        isFalse,
      );
    });
  });

  group('HubDashboardScreen unified tabs', () {
    Future<void> pumpShell(
      WidgetTester tester, {
      required UserRole role,
      bool isOwner = false,
      List<String> permissions = const [],
    }) async {
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

    testWidgets('fleet + support grants render exactly those tabs',
        (tester) async {
      await pumpShell(tester,
          role: UserRole.admin,
          permissions: const [permFleetVerify, permSupportChat]);

      expect(find.text('Fleet & Security'), findsOneWidget);
      expect(find.text('Support Inbox'), findsOneWidget);
      expect(find.text('Dynamic Config'), findsNothing);
      expect(find.text('Staff'), findsNothing);
      expect(find.text('Agent Console'), findsNothing);
      expect(find.text('Logout'), findsNothing);
    });

    testWidgets('dynamic_config grant renders the config tab', (tester) async {
      await pumpShell(tester,
          role: UserRole.agent, permissions: const [permDynamicConfig]);

      expect(find.text('Dynamic Config'), findsOneWidget);
      expect(find.text('Fleet & Security'), findsNothing);
      expect(find.text('Support Inbox'), findsNothing);
    });

    testWidgets('owner sees every tab including Staff', (tester) async {
      await pumpShell(tester, role: UserRole.superRole, isOwner: true);

      expect(find.text('Fleet & Security'), findsOneWidget);
      expect(find.text('Support Inbox'), findsOneWidget);
      expect(find.text('Dynamic Config'), findsOneWidget);
      expect(find.text('Staff'), findsOneWidget);
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
  });
}
