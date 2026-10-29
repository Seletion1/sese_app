import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sese_core/sese_core.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('GlobalErrorWidget UI Tests', () {
    testWidgets('Renders clean, reassuring user card with zero stack trace strings',
        (WidgetTester tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: GlobalErrorWidget(),
        ),
      );

      await tester.pumpAndSettle();

      // Reassuring user copy
      expect(find.text('Something went wrong'), findsOneWidget);
      expect(
        find.textContaining("Don't worry, your data is secure"),
        findsOneWidget,
      );
      expect(find.byKey(const Key('global_error_restart_button')), findsOneWidget);

      // Verify ZERO technical stack trace / line number / package path strings are displayed
      expect(find.textContaining('package:flutter'), findsNothing);
      expect(find.textContaining('.dart'), findsNothing);
      expect(find.textContaining('Failed assertion'), findsNothing);
      expect(find.textContaining('line '), findsNothing);
    });

    testWidgets('Triggers restart callback when button is tapped',
        (WidgetTester tester) async {
      bool restarted = false;

      await tester.pumpWidget(
        MaterialApp(
          home: GlobalErrorWidget(
            onRestart: () {
              restarted = true;
            },
          ),
        ),
      );

      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('global_error_restart_button')));
      await tester.pumpAndSettle();

      expect(restarted, isTrue);
    });
  });

  group('CrashReporterService Initialization', () {
    test('initialize sets up global handlers and buildErrorWidget', () {
      CrashReporterService.initialize(
        appName: 'sese_core_test',
        appVersion: '2.0.0',
      );

      expect(CrashReporterService.appName, 'sese_core_test');
      expect(CrashReporterService.appVersion, '2.0.0');

      final errorWidget = CrashReporterService.buildErrorWidget(
        FlutterErrorDetails(
          exception: Exception('Test assertion error'),
          stack: StackTrace.current,
        ),
      );

      expect(errorWidget, isA<GlobalErrorWidget>());
    });
  });
}
