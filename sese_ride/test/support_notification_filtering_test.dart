import 'package:flutter_test/flutter_test.dart';
import 'package:sese_ride/features/support/support_chat_screen.dart';

void main() {
  group('Support chat active presence & suppression', () {
    test('isViewingChat tracks active session presence correctly', () {
      expect(SupportChatScreen.isChatOpen, isFalse);
      expect(SupportChatScreen.isViewingChat('session_123'), isFalse);

      // Simulating chat opened but session ID still resolving
      SupportChatScreen.activeChatId = '';
      expect(SupportChatScreen.isChatOpen, isTrue);
      expect(SupportChatScreen.isViewingChat('session_123'), isTrue);
      expect(SupportChatScreen.isViewingChat(null), isTrue);

      // Simulating session ID resolved
      SupportChatScreen.activeChatId = 'session_123';
      expect(SupportChatScreen.isChatOpen, isTrue);
      expect(SupportChatScreen.isViewingChat('session_123'), isTrue);
      expect(SupportChatScreen.isViewingChat('session_456'), isFalse);

      // Simulating screen disposed
      SupportChatScreen.activeChatId = null;
      expect(SupportChatScreen.isChatOpen, isFalse);
      expect(SupportChatScreen.isViewingChat('session_123'), isFalse);
    });
  });
}
