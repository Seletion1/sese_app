import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sese_core/sese_core.dart';
import 'package:sese_ride/features/home/driver_home_shell.dart';
import 'package:sese_ride/features/trips/models/bid_models.dart';
import 'package:sese_ride/features/trips/models/trip_models.dart';
import 'package:sese_ride/features/trips/services/trip_service.dart';
import 'package:sese_ride/widgets/osm_map_view.dart';

void main() {
  // The shell's IndexedStack builds the driver map tab eagerly: render the
  // map placeholder (both OSM and Google branches honor this seam) so no
  // test depends on network tiles or a native platform view.
  setUp(() {
    OsmMapView.debugTileProviderOverride = const BlankTileProvider();
  });
  tearDown(() {
    OsmMapView.debugTileProviderOverride = null;
  });

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
          tripRepository: const _StubTripRepository(),
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

      // Strict menu order: Wallet, Earnings, Trips, Support, Settings.
      // Go Online lives on Home; Fleet, Theme, App Mode, Sign Out, Delete
      // live in Settings.
      expect(find.text('Go Online (Home)'), findsNothing);
      expect(find.text('Manage Fleet & Documents'), findsNothing);

      // Wallet above Earnings.
      expect(find.text('Wallet'), findsOneWidget);
      expect(find.text('Earnings'), findsWidgets);
      // Tile order: Wallet first, Settings near the bottom (mode
      // switching moved to Settings → App Mode).
      final walletY =
          tester.getTopLeft(find.byKey(const Key('menu_wallet_tile'))).dy;
      final earningsY =
          tester.getTopLeft(find.byKey(const Key('menu_earnings_tile'))).dy;
      expect(walletY, lessThan(earningsY));
      final settingsY =
          tester.getTopLeft(find.byKey(const Key('menu_settings_tile'))).dy;
      expect(earningsY, lessThan(settingsY));
      expect(find.byKey(const Key('menu_switch_mode_tile')), findsNothing);

      // Wallet tile pushes the wallet screen: balance card with both
      // actions plus the chronological ledger (no earnings card). The
      // ledger header sits below the fold — scroll it into view first
      // (ListView builds lazily).
      await tester.tap(find.byKey(const Key('menu_wallet_tile')));
      await tester.pumpAndSettle();
      expect(find.text('Wallet Balance'), findsOneWidget);
      expect(find.text('+ Top Up'), findsOneWidget);
      expect(find.text('Withdraw / Payout'), findsOneWidget);
      await tester.scrollUntilVisible(
        find.text('Transaction history'),
        300,
      );
      await tester.pumpAndSettle();
      expect(find.text('Transaction history'), findsOneWidget);
      expect(find.text('Earnings breakdown'), findsNothing);
    });

    testWidgets('Trips History switches to the Trips tab (index 2)',
        (tester) async {
      await pumpShell(tester);

      await tester.tap(find.text('Menu'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('menu_trips_history_tile')));
      await tester.pumpAndSettle();
      // Trips tab content (same view as the bottom-nav Trips item).
      expect(find.text('No trips available yet'), findsOneWidget);
      expect(find.byType(BottomNavigationBar), findsOneWidget);
    });

    testWidgets('Support switches to the Help tab (index 3)', (tester) async {
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

      // Home (index 1) shows the bar.
      expect(find.byType(BottomNavigationBar), findsOneWidget);

      // Menu (index 0) hides it — full-screen hub.
      await tester.tap(find.text('Menu'));
      await tester.pumpAndSettle();
      expect(find.byType(BottomNavigationBar), findsNothing);

      // Leaving the menu via Trips History restores it.
      await tester.tap(find.byKey(const Key('menu_trips_history_tile')));
      await tester.pumpAndSettle();
      expect(find.text('No trips available yet'), findsOneWidget);
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

    testWidgets('Menu Earnings tile opens EarningsScreen',
        (tester) async {
      await pumpShell(tester);

      await tester.tap(find.text('Menu'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('menu_earnings_tile')));
      await tester.pumpAndSettle();

      expect(find.text('Daily'), findsOneWidget);
      expect(find.text('Weekly'), findsOneWidget);
      expect(find.text('Monthly'), findsOneWidget);
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
      // Lower sections build lazily — scroll each into view first.
      await tester.scrollUntilVisible(
        find.text('Hide Phone Number'),
        300,
      );
      await tester.pumpAndSettle();
      expect(find.text('Hide Phone Number'), findsOneWidget);
      // Mode switching lives in Settings → App Mode for drivers.
      await tester.scrollUntilVisible(
        find.byKey(const Key('settings_switch_mode_tile')),
        300,
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('settings_switch_mode_tile')),
          findsOneWidget);
      expect(find.text('Switch to Customer Mode'), findsOneWidget);
    });
  });
}

class _StubTripRepository implements TripRepository {
  const _StubTripRepository();

  @override
  Future<String> createTrip(TripDraft draft) async => 'trip-1';

  @override
  Stream<ActiveTrip?> tripStream(String tripId) => Stream.value(null);

  @override
  Stream<List<ActiveTrip>> activeTripsStream(String customerId) =>
      Stream.value(const []);

  @override
  Stream<List<ActiveTrip>> userTripHistoryStream(String userId, {bool isDriver = false}) =>
      Stream.value(const []);

  @override
  Future<void> cancelTrip(String tripId, {String? reason, bool useCashSettlement = false}) async {}

  @override
  Future<void> submitBid(String tripId, double offeredFare, {int? etaMinutes}) async {}

  @override
  Future<void> rejectBid(String tripId, String driverId) async {}

  @override
  Future<void> acceptBid(String tripId, String driverId) async {}

  @override
  Future<void> increaseTripFare(String tripId, double newFare) async {}

  @override
  Future<void> keepSearchingTrip(String tripId) async {}

  @override
  Stream<List<BidModel>> bidsStream(String tripId) => Stream.value(const []);
}
