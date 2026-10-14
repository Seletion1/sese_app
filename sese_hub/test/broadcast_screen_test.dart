import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sese_hub/features/notifications/presentation/broadcast_screen.dart';

void main() {
  group('BroadcastScreen validation', () {
    Future<void> pumpScreen(WidgetTester tester) async {
      await tester.pumpWidget(
        const MaterialApp(home: BroadcastScreen()),
      );
      await tester.pumpAndSettle();
    }

    testWidgets('requires title and body before sending', (tester) async {
      await pumpScreen(tester);

      expect(find.byKey(const Key('broadcast_send')), findsOneWidget);

      await tester.scrollUntilVisible(
        find.byKey(const Key('broadcast_send')),
        300,
        scrollable: find
            .descendant(
              of: find.byType(SingleChildScrollView),
              matching: find.byType(Scrollable),
            )
            .first,
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('broadcast_send')));
      await tester.pumpAndSettle();

      expect(find.text('Title and message body are required.'), findsOneWidget);
    });

    testWidgets('renders audience, scope, vehicle, and mode controls',
        (tester) async {
      await pumpScreen(tester);

      expect(find.text('Audience Role'), findsOneWidget);
      expect(find.text('Geographic Scope'), findsOneWidget);
      expect(find.text('Vehicle Type Filter (Drivers)'), findsOneWidget);
      expect(find.text('Targeting Mode'), findsOneWidget);
      expect(find.text('All Vehicles'), findsOneWidget);
    });

    testWidgets('specific user IDs mode requires at least one ID',
        (tester) async {
      await pumpScreen(tester);

      await tester.enterText(
          find.byKey(const Key('broadcast_title')), 'Maintenance');
      await tester.enterText(
          find.byKey(const Key('broadcast_body')), 'Downtime tonight.');
      await tester.scrollUntilVisible(
        find.text('User IDs').first,
        300,
        scrollable: find
            .descendant(
              of: find.byType(SingleChildScrollView),
              matching: find.byType(Scrollable),
            )
            .first,
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('User IDs').first);
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('broadcast_user_ids')), findsOneWidget);
      await tester.scrollUntilVisible(
        find.byKey(const Key('broadcast_send')),
        300,
        scrollable: find
            .descendant(
              of: find.byType(SingleChildScrollView),
              matching: find.byType(Scrollable),
            )
            .first,
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('broadcast_send')));
      await tester.pumpAndSettle();

      expect(find.text('Enter at least one user ID.'), findsOneWidget);
    });
  });
}
