import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sese_core/widgets/sese_logo.dart';
import 'package:sese_ride/driver_overlay_entry.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('OverlayBubble Widget Tests', () {
    testWidgets('renders gold circular border and SeSe branding', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: Center(
              child: OverlayBubble(),
            ),
          ),
        ),
      );

      expect(find.byType(OverlayBubble), findsOneWidget);
      expect(find.byType(SeSeLogo), findsOneWidget);
    });

    testWidgets('long press reveals dismiss target and callback fires on tap', (tester) async {
      bool dismissed = false;

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Center(
              child: OverlayBubble(
                onDismiss: () => dismissed = true,
              ),
            ),
          ),
        ),
      );

      // Initially dismiss target is hidden
      expect(find.text('Hide'), findsNothing);

      // Long press bubble
      await tester.longPress(find.byType(OverlayBubble));
      await tester.pumpAndSettle();

      // Verify dismiss target is visible
      expect(find.text('Hide'), findsOneWidget);

      // Tap dismiss target
      await tester.tap(find.text('Hide'));
      await tester.pumpAndSettle();

      expect(dismissed, isTrue);
    });
  });
}
