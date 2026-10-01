import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sese_core/sese_core.dart';
import 'package:sese_ride/features/home/driver_home_shell.dart';

void main() {
  AppUser driverUser() => AppUser(
        uid: 'driver_1',
        fullName: 'Test Driver',
        email: 'driver@test.co',
        phoneNumber: '08000000000',
        role: UserRole.driver,
        createdAt: DateTime(2024),
      );

  Future<void> pumpShell(WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: DriverHomeShell(
          user: driverUser(),
          auth: const StubAuthRepository(),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  group('Driver Menu tab navigation shortcuts', () {
    testWidgets('Wallet and Earnings tiles route to their screens',
        (tester) async {
      await pumpShell(tester);

      // Default tab is Home (index 2) — Menu content is offstage.
      await tester.tap(find.text('Menu'));
      await tester.pumpAndSettle();

      // Strict menu order: Wallet, Earnings, Trips, Support, Settings,
      // Switch-to-Customer at the very bottom. Go Online lives on Home;
      // Fleet, Theme, Sign Out, Delete live in Settings.
      expect(find.text('Go Online (Home)'), findsNothing);
      expect(find.text('Manage Fleet & Documents'), findsNothing);

      // Wallet above Earnings, with the specified subtitles.
      expect(find.text('Wallet'), findsOneWidget);
      expect(
          find.text(
              'Manage funds, top up, request payouts, and view '
              'transaction history'),
          findsOneWidget);
      expect(find.text('Earnings'), findsWidgets);
      expect(
          find.text(
              'View daily, weekly, and monthly trip earnings and '
              'streak progress'),
          findsOneWidget);
      // Tile order: Wallet first, Settings near bottom, Switch last.
      final walletY =
          tester.getTopLeft(find.byKey(const Key('menu_wallet_tile'))).dy;
      final earningsY =
          tester.getTopLeft(find.byKey(const Key('menu_earnings_tile'))).dy;
      expect(walletY, lessThan(earningsY));
      final settingsY =
          tester.getTopLeft(find.byKey(const Key('menu_settings_tile'))).dy;
      final switchY =
          tester.getTopLeft(find.byKey(const Key('menu_switch_mode_tile'))).dy;
      expect(earningsY, lessThan(settingsY));
      expect(settingsY, lessThan(switchY));

      // Wallet tile pushes the wallet screen: balance card with both
      // actions plus the chronological ledger (no earnings card).
      await tester.tap(find.byKey(const Key('menu_wallet_tile')));
      await tester.pumpAndSettle();
      expect(find.text('Wallet Balance'), findsOneWidget);
      expect(find.text('+ Top Up'), findsOneWidget);
      expect(find.text('Withdraw / Payout'), findsOneWidget);
      expect(find.text('Transaction history'), findsOneWidget);
      expect(find.text('Earnings breakdown'), findsNothing);
    });

    testWidgets('Trips History switches to the Trips tab (index 3)',
        (tester) async {
      await pumpShell(tester);

      await tester.tap(find.text('Menu'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('menu_trips_history_tile')));
      await tester.pumpAndSettle();
      // Trips tab content (same view as the bottom-nav Trips item).
      expect(find.text('Active trips'), findsOneWidget);
      expect(find.byType(BottomNavigationBar), findsOneWidget);
    });

    testWidgets('Support switches to the Help tab (index 4)', (tester) async {
      await pumpShell(tester);

      await tester.tap(find.text('Menu'));
      await tester.pumpAndSettle();
      // Support sits below the fold (menu hub is scrollable).
      await tester.ensureVisible(find.byKey(const Key('menu_support_tile')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('menu_support_tile')));
      await tester.pumpAndSettle();
      // Help tab content (same view as the bottom-nav Help item).
      expect(find.text('Contact Driver Support'), findsOneWidget);
      expect(find.byType(BottomNavigationBar), findsOneWidget);
    });

    testWidgets('Bottom bar hides on the Menu view, shows elsewhere',
        (tester) async {
      await pumpShell(tester);

      // Home (index 2) shows the bar.
      expect(find.byType(BottomNavigationBar), findsOneWidget);

      // Menu (index 0) hides it — full-screen hub.
      await tester.tap(find.text('Menu'));
      await tester.pumpAndSettle();
      expect(find.byType(BottomNavigationBar), findsNothing);

      // Leaving the menu via Trips History restores it.
      await tester.tap(find.byKey(const Key('menu_trips_history_tile')));
      await tester.pumpAndSettle();
      expect(find.text('Active trips'), findsOneWidget);
      expect(find.byType(BottomNavigationBar), findsOneWidget);
    });

    testWidgets('System back on Menu returns to Home, not out of the app',
        (tester) async {
      await pumpShell(tester);

      await tester.tap(find.text('Menu'));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('menu_settings_tile')), findsOneWidget);

      // System back returns straight to Home, not out of the app.
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('power_toggle')), findsOneWidget);
      expect(find.byKey(const Key('menu_settings_tile')), findsNothing);
    });

    testWidgets('Bottom Earnings tab shows the breakdown dashboard',
        (tester) async {
      await pumpShell(tester);

      await tester.tap(find.text('Earnings'));
      await tester.pumpAndSettle();
      // Period filter + daily summary cards.
      expect(find.text('Daily'), findsOneWidget);
      expect(find.text('Weekly'), findsOneWidget);
      expect(find.text('Monthly'), findsOneWidget);
      expect(find.text("Today's fare income"), findsOneWidget);
      expect(find.text("Today's net profit"), findsOneWidget);
    });

    testWidgets('System back on the Earnings tab returns to Home',
        (tester) async {
      await pumpShell(tester);

      await tester.tap(find.text('Earnings'));
      await tester.pumpAndSettle();
      expect(find.text('Daily'), findsOneWidget);

      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('power_toggle')), findsOneWidget);
      expect(find.byType(BottomNavigationBar), findsOneWidget);
    });

    testWidgets('Wallet backs out to Menu, system back returns Home',
        (tester) async {
      await pumpShell(tester);

      await tester.tap(find.text('Menu'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('menu_wallet_tile')));
      await tester.pumpAndSettle();
      expect(find.text('Wallet Balance'), findsOneWidget);

      // System back pops the pushed wallet screen back to the Menu.
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('menu_settings_tile')), findsOneWidget);
    });

    testWidgets('Settings tile opens the Settings screen with fleet access',
        (tester) async {
      await pumpShell(tester);

      await tester.tap(find.text('Menu'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('menu_settings_tile')));
      await tester.pumpAndSettle();
      expect(find.text('Settings'), findsWidgets);
      expect(find.text('Manage Fleet & Documents'), findsOneWidget);
      expect(find.text('Alert Tone'), findsOneWidget);
      expect(find.text('Hide Phone Number'), findsOneWidget);
    });
  });
}
