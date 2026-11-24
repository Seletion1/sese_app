import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sese_ride/features/driver/presentation/widgets/navigation_logos.dart';
import 'package:sese_ride/features/driver/services/navigation_launcher_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('NavigationAppOption & Daily Preference Logic', () {
    setUp(() {
      SharedPreferences.setMockInitialValues({});
    });

    test('has strictly 2 options: Google Maps and Waze', () {
      expect(NavigationAppOption.values.length, 2);
      expect(NavigationAppOption.values, contains(NavigationAppOption.googleMaps));
      expect(NavigationAppOption.values, contains(NavigationAppOption.waze));
    });

    test('getTodayDateString returns canonical YYYY-MM-DD format', () {
      final date = DateTime(2026, 11, 24, 15, 30);
      expect(NavigationLauncherService.getTodayDateString(date), '2026-11-24');

      final singleDigitDate = DateTime(2026, 4, 5);
      expect(NavigationLauncherService.getTodayDateString(singleDigitDate), '2026-04-05');
    });

    test('first tap of the day returns null default (no saved preference)', () async {
      final prefs = await SharedPreferences.getInstance();
      final option = await NavigationLauncherService.getDailyDefaultNavApp(
        overridePrefs: prefs,
        now: DateTime(2026, 11, 24),
      );
      expect(option, isNull);
    });

    test('saving preference persists app name and date', () async {
      final prefs = await SharedPreferences.getInstance();
      final day = DateTime(2026, 11, 24);

      await NavigationLauncherService.setDailyDefaultNavApp(
        NavigationAppOption.waze,
        overridePrefs: prefs,
        now: day,
      );

      expect(prefs.getString(NavigationLauncherService.prefNavAppKey), 'waze');
      expect(prefs.getString(NavigationLauncherService.prefNavDateKey), '2026-11-24');

      // Subsequent read on the same day returns the saved option
      final readOption = await NavigationLauncherService.getDailyDefaultNavApp(
        overridePrefs: prefs,
        now: day,
      );
      expect(readOption, NavigationAppOption.waze);
    });

    test('subsequent reads on the same day return saved default directly', () async {
      final prefs = await SharedPreferences.getInstance();
      final day = DateTime(2026, 11, 24, 9, 0);

      await NavigationLauncherService.setDailyDefaultNavApp(
        NavigationAppOption.googleMaps,
        overridePrefs: prefs,
        now: day,
      );

      final secondTap = await NavigationLauncherService.getDailyDefaultNavApp(
        overridePrefs: prefs,
        now: DateTime(2026, 11, 24, 14, 45),
      );
      expect(secondTap, NavigationAppOption.googleMaps);
    });

    test('next calendar day clears previous preference and returns null (prompts again)', () async {
      final prefs = await SharedPreferences.getInstance();
      final day1 = DateTime(2026, 11, 24);
      final day2 = DateTime(2026, 11, 25);

      await NavigationLauncherService.setDailyDefaultNavApp(
        NavigationAppOption.waze,
        overridePrefs: prefs,
        now: day1,
      );

      // On next day:
      final nextDayOption = await NavigationLauncherService.getDailyDefaultNavApp(
        overridePrefs: prefs,
        now: day2,
      );
      expect(nextDayOption, isNull);

      // Stale keys were cleared
      expect(prefs.getString(NavigationLauncherService.prefNavAppKey), isNull);
      expect(prefs.getString(NavigationLauncherService.prefNavDateKey), isNull);
    });

    test('clearDailyDefaultNavApp explicitly purges preference', () async {
      final prefs = await SharedPreferences.getInstance();
      await NavigationLauncherService.setDailyDefaultNavApp(
        NavigationAppOption.googleMaps,
        overridePrefs: prefs,
        now: DateTime(2026, 11, 24),
      );

      await NavigationLauncherService.clearDailyDefaultNavApp(overridePrefs: prefs);
      expect(prefs.getString(NavigationLauncherService.prefNavAppKey), isNull);
      expect(prefs.getString(NavigationLauncherService.prefNavDateKey), isNull);
    });
  });

  group('CustomPainter Navigation Logos Rendering', () {
    testWidgets('GoogleMapsLogo renders cleanly without layout exceptions', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: Center(
              child: GoogleMapsLogo(size: 40),
            ),
          ),
        ),
      );

      expect(find.byType(GoogleMapsLogo), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('WazeLogo renders cleanly without layout exceptions', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: Center(
              child: WazeLogo(size: 40),
            ),
          ),
        ),
      );

      expect(find.byType(WazeLogo), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('Navigation chooser sheet displays only Google Maps and Waze', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (ctx) => ElevatedButton(
                onPressed: () => NavigationLauncherService.showNavigationChooser(
                  context: ctx,
                  destinationAddress: '34 Olafiloye St, Ikorodu',
                  isHeadingToPickup: true,
                ),
                child: const Text('Open'),
              ),
            ),
          ),
        ),
      );

      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();

      expect(find.text('Navigate to Pickup'), findsOneWidget);
      expect(find.text('34 Olafiloye St, Ikorodu'), findsOneWidget);
      expect(find.text('Google Maps'), findsOneWidget);
      expect(find.text('Waze'), findsOneWidget);

      // Verify Apple Maps and Other Navigation Apps are completely removed
      expect(find.text('Apple Maps'), findsNothing);
      expect(find.text('Other Navigation Apps'), findsNothing);

      // Verify custom painter logos are present in the options
      expect(find.byType(GoogleMapsLogo), findsOneWidget);
      expect(find.byType(WazeLogo), findsOneWidget);

      // Tap Waze option and verify choice
      await tester.tap(find.text('Waze'));
      await tester.pumpAndSettle();
      expect(find.text('Navigate to Pickup'), findsNothing);
    });
  });
}
