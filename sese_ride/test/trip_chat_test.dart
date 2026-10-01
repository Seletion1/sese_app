import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sese_ride/features/trips/presentation/trip_chat_screen.dart';
import 'package:sese_ride/features/trips/services/trip_chat_service.dart';

/// In-memory trip chat backend (no Firestore/Storage).
class _FakeTripChat extends TripChatService {
  final _ctrl = StreamController<List<TripChatMessage>>.broadcast();
  List<TripChatMessage> current = const [];
  final sent = <String>[];

  @override
  Stream<List<TripChatMessage>> messagesStream(String tripId) =>
      Stream.multi((sink) {
        sink.add(current);
        final sub = _ctrl.stream.listen(sink.add);
        sink.onCancel = sub.cancel;
      });

  @override
  Future<void> sendText({
    required String tripId,
    required String senderId,
    required String senderRole,
    required String text,
  }) async {
    sent.add(text);
    current = [
      ...current,
      TripChatMessage(
        id: 'm${current.length}',
        senderId: senderId,
        senderRole: senderRole,
        text: text,
      ),
    ];
    _ctrl.add(current);
  }

  Future<void> close() => _ctrl.close();
}

Future<void> _pumpChat(
  WidgetTester tester,
  _FakeTripChat svc, {
  bool hidePhones = false,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: TripChatScreen(
          tripId: 'trip-1',
          currentUid: 'cust-1',
          senderRole: 'customer',
          peerName: 'Adaeze',
          peerPhone: '08012345678',
          hidePhones: hidePhones,
          service: svc,
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  group('TripChatScreen', () {
    testWidgets('shows masked phone when hiding is enabled', (tester) async {
      final svc = _FakeTripChat();
      addTearDown(svc.close);
      await _pumpChat(tester, svc, hidePhones: true);

      expect(find.text('080****5678'), findsOneWidget);
      expect(find.text('08012345678'), findsNothing);
    });

    testWidgets('shows raw phone when hiding is off', (tester) async {
      final svc = _FakeTripChat();
      addTearDown(svc.close);
      await _pumpChat(tester, svc, hidePhones: false);

      expect(find.text('08012345678'), findsOneWidget);
    });

    testWidgets('sending text posts to the thread', (tester) async {
      final svc = _FakeTripChat();
      addTearDown(svc.close);
      await _pumpChat(tester, svc);

      await tester.enterText(
          find.byKey(const Key('trip_chat_input')), 'On my way');
      await tester.tap(find.byKey(const Key('trip_chat_send_button')));
      await tester.pumpAndSettle();

      expect(svc.sent, ['On my way']);
      expect(find.text('On my way'), findsOneWidget);
    });

    testWidgets('has photo button and no voice recorder', (tester) async {
      final svc = _FakeTripChat();
      addTearDown(svc.close);
      await _pumpChat(tester, svc);

      expect(
          find.byKey(const Key('trip_chat_photo_button')), findsOneWidget);
      expect(find.byIcon(Icons.mic), findsNothing);
      expect(find.byIcon(Icons.mic_none_outlined), findsNothing);
    });
  });
}
