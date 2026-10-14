import 'package:cloud_functions/cloud_functions.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sese_ride/features/payments/payment_service.dart';

/// Fake backend: records the init payload and replays canned responses.
class _FakePaymentsBackend implements PaymentsBackend {
  Map<String, dynamic>? lastInitPayload;
  Map<String, dynamic>? initResponse;
  Object? initError;
  Map<String, dynamic> verifyResponse = {'settled': true};

  @override
  Future<Map<String, dynamic>> callInitializePayment(
      Map<String, dynamic> data) async {
    lastInitPayload = Map<String, dynamic>.from(data);
    final err = initError;
    if (err != null) throw err;
    return Map<String, dynamic>.from(initResponse ?? {});
  }

  @override
  Future<Map<String, dynamic>> callVerifyPayment(String reference) async {
    return Map<String, dynamic>.from(verifyResponse);
  }
}

/// Backend that fails the test if the network path is ever reached
/// (amount validation must reject before any backend call).
class _UnreachableBackend implements PaymentsBackend {
  @override
  Future<Map<String, dynamic>> callInitializePayment(
      Map<String, dynamic> data) {
    throw StateError('backend must not be called for invalid amounts');
  }

  @override
  Future<Map<String, dynamic>> callVerifyPayment(String reference) {
    throw StateError('unreachable');
  }
}

void main() {
  group('Wallet top-up (Paystack initializePayment)', () {
    test('rejects amounts below ₦100 without calling the backend', () async {
      final svc = PaymentService(backend: _UnreachableBackend());
      expect(
        () => svc.initializeTopUp(amountNaira: 99, email: 'a@b.ng'),
        throwsA(isA<PaymentException>().having(
            (e) => e.code, 'code', 'amount-too-small')),
      );
    });

    test('rejects amounts above ₦500,000 without calling the backend',
        () async {
      final svc = PaymentService(backend: _UnreachableBackend());
      expect(
        () => svc.initializeTopUp(amountNaira: 500001, email: 'a@b.ng'),
        throwsA(isA<PaymentException>().having(
            (e) => e.code, 'code', 'amount-too-large')),
      );
    });

    test('sends kobo + purpose + email and returns the checkout page',
        () async {
      final backend = _FakePaymentsBackend()
        ..initResponse = {
          'authorizationUrl': 'https://checkout.paystack.com/abc',
          'accessCode': 'abc123',
          'reference': 'sese_test_ref',
        };
      final svc = PaymentService(backend: backend);

      final auth = await svc.initializeTopUp(
          amountNaira: 2000, email: 'rider@example.ng');

      expect(auth.authorizationUrl, 'https://checkout.paystack.com/abc');
      expect(auth.reference, 'sese_test_ref');
      // ₦2000 → 200,000 kobo, integer-exact.
      expect(backend.lastInitPayload?['amountKobo'], 200000);
      expect(backend.lastInitPayload?['purpose'], 'wallet_topup');
      expect(backend.lastInitPayload?['email'], 'rider@example.ng');
    });

    test('PAYSTACK_NOT_CONFIGURED maps to the setup message', () async {
      final backend = _FakePaymentsBackend()
        ..initError = FirebaseFunctionsException(
          code: 'failed-precondition',
          message: 'PAYSTACK_NOT_CONFIGURED',
        );
      final svc = PaymentService(backend: backend);

      PaymentException? caught;
      try {
        await svc.initializeTopUp(amountNaira: 2000, email: 'rider@example.ng');
        fail('expected a PaymentException');
      } on PaymentException catch (e) {
        caught = e;
      }

      expect(
        caught.userMessage,
        'Online payment is not set up yet. Please top up via bank '
        'transfer or contact support.',
      );
    });

    test('Paystack "Invalid key" maps to the setup message', () async {
      final backend = _FakePaymentsBackend()
        ..initError = FirebaseFunctionsException(
          code: 'internal',
          message: 'Invalid key',
        );
      final svc = PaymentService(backend: backend);

      PaymentException? caught;
      try {
        await svc.initializeTopUp(amountNaira: 2000, email: 'rider@example.ng');
        fail('expected a PaymentException');
      } on PaymentException catch (e) {
        caught = e;
      }

      expect(caught.userMessage, contains('not set up yet'));
    });

    test('verifyTopUp reports settlement', () async {
      final backend = _FakePaymentsBackend()
        ..verifyResponse = {'settled': true};
      expect(await PaymentService(backend: backend).verifyTopUp('ref1'),
          isTrue);
      backend.verifyResponse = {'settled': false};
      expect(await PaymentService(backend: backend).verifyTopUp('ref1'),
          isFalse);
    });
  });
}
