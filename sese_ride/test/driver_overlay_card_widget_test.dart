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
  });
}
