import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sese_core/sese_core.dart';
import 'package:sese_ride/features/support/support_chat_screen.dart';
import 'package:sese_ride/features/support/support_chat_service.dart';

class _StubChatService extends SupportChatService {
  final StreamController<List<SupportMessage>> messagesCtrl =
      StreamController<List<SupportMessage>>.broadcast();
  final StreamController<String> statusCtrl =
      StreamController<String>.broadcast();
  final List<String> sent = [];
  bool requestedHuman = false;

  void dispose() {
    messagesCtrl.close();
    statusCtrl.close();
  }

  @override
  Future<String> openOrCreateSession({
    required String userId,
    required String userRole,
    required String userName,
  }) async {
    return 'chat_session_1';
  }

  @override
  Stream<List<SupportMessage>> messagesStream(String chatId) =>
      messagesCtrl.stream;

  @override
  Stream<String> statusStream(String chatId) =>
      statusCtrl.stream.distinct();

  @override
  Future<void> sendMessage({
    required String chatId,
    required String userId,
    required String text,
  }) async {
    sent.add(text);
  }

  @override
  Future<void> requestHumanAgent({
    required String chatId,
    required String userId,
  }) async {
    requestedHuman = true;
  }
}

AppUser chatUser() => AppUser(
      uid: 'user_1',
      fullName: 'Bamiduro Tester',
      email: 'chat@test.co',
      phoneNumber: '+2348012345678',
      role: UserRole.driver,
      createdAt: DateTime(2024),
    );

Future<void> _pumpChat(
    WidgetTester tester, _StubChatService service) async {
  await tester.pumpWidget(
    MaterialApp(
      home: SupportChatScreen(
        user: chatUser(),
        userRole: 'driver',
        service: service,
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  group('SupportMessage model', () {
    test('parses new senderType/senderId shape', () {
      final msg = SupportMessage.fromMap('m1', {
        'senderType': 'ai',
        'senderId': 'ai_assistant',
        'text': 'Hello! How can I help you today?',
      });
      expect(msg.isAi, isTrue);
      expect(msg.isMine, isFalse);
      expect(msg.senderLabel, 'Sese Assistant');
    });

    test('admin / agent label', () {
      const msg = SupportMessage(
        id: 'm2',
        senderType: 'agent',
        senderId: 'agent_123',
        text: 'I am on it.',
      );
      expect(msg.isAgent, isTrue);
      expect(msg.senderLabel, 'Support Agent');
    });

    test('backward compatibility with legacy sender field', () {
      final msg = SupportMessage.fromMap('m3', {
        'sender': 'bot',
        'text': 'Legacy bot reply',
      });
      expect(msg.isAi, isTrue);
      expect(msg.senderLabel, 'Sese Assistant');
    });
  });

  group('SupportChatStatus', () {
    test('identifies human involved and resolved statuses', () {
      expect(SupportChatStatus.isHumanInvolved(SupportChatStatus.pendingAgent), isTrue);
      expect(SupportChatStatus.isHumanInvolved(SupportChatStatus.agentConnected), isTrue);
      expect(SupportChatStatus.isHumanInvolved(SupportChatStatus.aiActive), isFalse);

      expect(SupportChatStatus.isResolved(SupportChatStatus.resolved), isTrue);
      expect(SupportChatStatus.isLocked(SupportChatStatus.resolved), isTrue);
    });
  });

  group('SupportChatScreen', () {
    testWidgets('shows empty state then user bubble after send',
        (tester) async {
      final service = _StubChatService();
      addTearDown(service.dispose);
      await _pumpChat(tester, service);

      service.messagesCtrl.add(const []);
      service.statusCtrl.add(SupportChatStatus.aiActive);
      await tester.pumpAndSettle();
      expect(find.textContaining('payouts, trip issues, wallet'), findsOneWidget);

      await tester.enterText(
          find.byKey(const Key('support_input')), 'Where is my payout?');
      await tester.tap(find.byKey(const Key('support_send_button')));
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pump(const Duration(milliseconds: 100));
      expect(service.sent, ['Where is my payout?']);
      expect(find.byKey(const Key('typing_indicator')), findsOneWidget);

      service.messagesCtrl.add(const [
        SupportMessage(
          id: 'u1',
          senderType: 'user',
          senderId: 'user_1',
          text: 'Where is my payout?',
        ),
        SupportMessage(
          id: 'b1',
          senderType: 'ai',
          senderId: 'ai_assistant',
          text: 'Payouts settle to your wallet immediately after trips.',
        ),
      ]);
      await tester.pumpAndSettle();
      expect(find.text('Payouts settle to your wallet immediately after trips.'), findsOneWidget);
      expect(find.byKey(const Key('typing_indicator')), findsNothing);
    });

    testWidgets('connect button triggers requestHumanAgent', (tester) async {
      final service = _StubChatService();
      addTearDown(service.dispose);
      await _pumpChat(tester, service);

      service.messagesCtrl.add(const []);
      service.statusCtrl.add(SupportChatStatus.aiActive);
      await tester.pumpAndSettle();

      final button = find.byKey(const Key('connect_human_button'));
      expect(button, findsOneWidget);
      await tester.tap(button);
      await tester.pumpAndSettle();

      expect(service.requestedHuman, isTrue);
      expect(
        find.textContaining('Connecting you to an available support agent'),
        findsOneWidget,
      );
    });

    testWidgets('shows pending_agent banner and hides connect button', (tester) async {
      final service = _StubChatService();
      addTearDown(service.dispose);
      await _pumpChat(tester, service);

      service.messagesCtrl.add(const []);
      service.statusCtrl.add(SupportChatStatus.pendingAgent);
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('connect_human_button')), findsNothing);
      expect(find.byKey(const Key('pending_agent_banner')), findsOneWidget);
      expect(find.textContaining('Looking for an available support agent'), findsOneWidget);
    });

    testWidgets('shows agent_connected banner when claimed', (tester) async {
      final service = _StubChatService();
      addTearDown(service.dispose);
      await _pumpChat(tester, service);

      service.messagesCtrl.add(const []);
      service.statusCtrl.add(SupportChatStatus.agentConnected);
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('agent_connected_banner')), findsOneWidget);
      expect(find.textContaining('Connected to a Support Agent'), findsOneWidget);
    });

    testWidgets('locks input on resolved status', (tester) async {
      final service = _StubChatService();
      addTearDown(service.dispose);
      await _pumpChat(tester, service);

      service.messagesCtrl.add(const []);
      service.statusCtrl.add(SupportChatStatus.resolved);
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('resolved_banner')), findsOneWidget);
      expect(find.text('This chat has been resolved and closed.'), findsOneWidget);
      expect(find.text('This chat is closed.'), findsOneWidget);
      expect(find.byKey(const Key('support_input')), findsNothing);
    });
  });
}
