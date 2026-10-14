import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sese_ride/features/notifications/notification_inbox_screen.dart';

void main() {
  group('Notification inbox & bell', () {
    testWidgets('bell renders and opens the inbox screen', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: NotificationBellButton(uid: ''),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('notification_bell')), findsOneWidget);

      await tester.tap(find.byKey(const Key('notification_bell')));
      await tester.pumpAndSettle();

      // Empty uid renders the signed-out inbox state (no Firebase touched).
      expect(find.text('Sign in to view notifications.'), findsOneWidget);
    });

    testWidgets('inbox shows the empty state for signed-out users',
        (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: NotificationInboxScreen(userId: ''),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Sign in to view notifications.'), findsOneWidget);
    });
  });
}
