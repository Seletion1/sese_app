import 'package:flutter_test/flutter_test.dart';
import 'package:sese_core/sese_core.dart';

void main() {
  group('TransactionPinException', () {
    test('formats toString correctly', () {
      const exception = TransactionPinException('invalid-pin', 'PIN must be 4 digits.');
      expect(exception.code, 'invalid-pin');
      expect(exception.message, 'PIN must be 4 digits.');
      expect(exception.toString(), 'TransactionPinException(invalid-pin): PIN must be 4 digits.');
    });
  });

  group('TransactionPinService offline/test resilience', () {
    test('hasPin degrades gracefully when uninitialized', () async {
      const service = TransactionPinService();
      final hasPin = await service.hasPin('test-uid-123');
      expect(hasPin, isFalse);
    });

    test('setPin throws TransactionPinException when functions is uninitialized', () async {
      const service = TransactionPinService();
      expect(
        () => service.setPin(newPin: '1234'),
        throwsA(isA<TransactionPinException>()),
      );
    });

    test('verifyPin throws TransactionPinException when functions is uninitialized', () async {
      const service = TransactionPinService();
      expect(
        () => service.verifyPin('1234'),
        throwsA(isA<TransactionPinException>()),
      );
    });

    test('resetPin throws TransactionPinException when functions is uninitialized', () async {
      const service = TransactionPinService();
      expect(
        () => service.resetPin(newPin: '1234'),
        throwsA(isA<TransactionPinException>()),
      );
    });
  });
}
