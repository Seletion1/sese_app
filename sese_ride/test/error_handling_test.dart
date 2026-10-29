import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sese_core/sese_core.dart';
import 'package:sese_core/services/crash_reporter_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('sese_ride error handler renders clean user card with zero raw exception strings',
      (WidgetTester tester) async {
    CrashReporterService.initialize(
      appName: 'sese_ride',
      appVersion: '1.0.3+4',
    );

    final details = FlutterErrorDetails(
      exception: "'package:flutter/src/widgets/navigator.dart': Failed assertion: line 5949 pos 12: '!_debugLocked': is not true.",
      stack: StackTrace.current,
    );

    final widget = CrashReporterService.buildErrorWidget(details);

    await tester.pumpWidget(
      MaterialApp(
        home: widget,
      ),
    );

    await tester.pumpAndSettle();

    // Verify user-reassuring card renders
    expect(find.text('Something went wrong'), findsOneWidget);
    expect(find.textContaining("Don't worry, your data is secure"), findsOneWidget);

    // Verify raw exception string is completely hidden from user view
    expect(find.textContaining('package:flutter/src/widgets/navigator.dart'), findsNothing);
    expect(find.textContaining('Failed assertion'), findsNothing);
    expect(find.textContaining('line 5949'), findsNothing);
  });
}
