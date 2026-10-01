import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sese_hub/features/support/hub_support_chat_screen.dart';

void main() {
  testWidgets('HubSupportChatScreen renders tabs and queue empty state on desktop',
      (tester) async {
    tester.view.physicalSize = const Size(1024, 768);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);

    await tester.pumpWidget(
      const MaterialApp(
        home: HubSupportChatScreen(),
      ),
    );

    expect(find.text('Support Desk & Live Escalation'), findsOneWidget);
    expect(find.text('Queue'), findsOneWidget);
    expect(find.text('Active Chats'), findsOneWidget);

    // Initial state without selection shows instructions on desktop
    expect(
      find.text('Select a chat or claim a pending request to begin'),
      findsOneWidget,
    );
  });

  testWidgets('HubSupportChatScreen renders single pane full-width tabs on mobile',
      (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);

    await tester.pumpWidget(
      const MaterialApp(
        home: HubSupportChatScreen(),
      ),
    );

    expect(find.text('Support Desk & Live Escalation'), findsOneWidget);
    expect(find.text('Queue'), findsOneWidget);
    expect(find.text('Active Chats'), findsOneWidget);

    // On mobile, detail placeholder instructions are not rendered side-by-side
    expect(
      find.text('Select a chat or claim a pending request to begin'),
      findsNothing,
    );
  });
}
