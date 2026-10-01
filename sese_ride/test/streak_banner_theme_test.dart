import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sese_core/sese_core.dart';
import 'package:sese_ride/features/driver/presentation/widgets/streak_progress_banner.dart';

/// Step segments are 6px-high Containers; collect their fill colors in
/// layout order.
List<Color?> _segmentColors(WidgetTester tester) {
  final segments = find.byWidgetPredicate((w) {
    if (w is! Container) return false;
    final decoration = w.decoration;
    return w.constraints?.maxHeight == 6 && decoration is BoxDecoration;
  });
  return segments.evaluate().map((e) {
    final c = e.widget as Container;
    return (c.decoration as BoxDecoration?)?.color;
  }).toList();
}

Future<void> _pumpBanner(
  WidgetTester tester, {
  required ThemeData theme,
  int currentStep = 2,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      theme: theme,
      home: Scaffold(
        body: StreakProgressBanner(
          streak: DriverStreakState(
            driverId: 'driver_1',
            currentLevel: StreakLevel.level1,
            currentStep: currentStep,
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  group('StreakProgressBanner theme contrast', () {
    testWidgets('done + active = warm gold primary, upcoming = muted grey',
        (tester) async {
      await _pumpBanner(tester, theme: AppTheme.light());

      final colors = _segmentColors(tester);
      expect(colors.length, greaterThanOrEqualTo(3));
      final gold = AppTheme.light().colorScheme.primary;
      expect(gold, const Color(0xFFFFB800));
      // Steps 0-2 done/active → Warm Gold.
      expect(colors[0], gold);
      expect(colors[1], gold);
      expect(colors[2], gold);
      // Remaining upcoming → muted grey (never hardcoded black).
      for (final c in colors.skip(3)) {
        expect(c, Colors.grey.withValues(alpha: 0.3));
      }
      expect(colors, isNot(contains(Colors.black)));
      expect(colors, isNot(contains(Colors.black87)));
    });

    testWidgets('dark mode segments stay theme-resolved', (tester) async {
      await _pumpBanner(tester, theme: AppTheme.dark(), currentStep: 0);

      final colors = _segmentColors(tester);
      expect(colors, isNotEmpty);
      // Active first step → gold, rest → outline; no hard blacks.
      expect(colors.first, AppTheme.dark().colorScheme.primary);
      expect(colors, isNot(contains(Colors.black)));
      expect(colors, isNot(contains(Colors.black87)));
      expect(find.byKey(const Key('streak_progress_banner')), findsOneWidget);
    });
  });
}
