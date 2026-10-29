import 'package:flutter_test/flutter_test.dart';
import 'package:sese_ride/features/payments/payment_service.dart';

class _ScriptedBackend implements PaymentsBackend {
  Map<String, dynamic>? initResponse;
  Map<String, dynamic>? verifyResponse;
  Object? initError;
  Object? verifyError;
  bool initCalled = false;

  @override
  Future<Map<String, dynamic>> callInitializePayment(
      Map<String, dynamic> data) async {
    initCalled = true;
    if (initError != null) throw initError!;
    return initResponse ?? const {};
  }

  @override
  Future<Map<String, dynamic>> callVerifyPayment(String reference) async {
    if (verifyError != null) throw verifyError!;
    return verifyResponse ?? const {'settled': true};
  }
}

void main() {
  group('PaymentService top-up validation', () {
    test('rejects amounts below ₦100 without calling backend', () async {
      final backend = _ScriptedBackend();
      final service = PaymentService(backend: backend);
      expect(
        () => service.initializeTopUp(amountNaira: 50, email: 'a@b.co'),
        throwsA(isA<PaymentException>().having(
            (e) => e.code, 'code', 'amount-too-small')),
      );
      expect(backend.initCalled, isFalse);
    });

    test('rejects amounts above ₦500,000 without calling backend', () async {
      final backend = _ScriptedBackend();
      final service = PaymentService(backend: backend);
      expect(
        () => service.initializeTopUp(amountNaira: 600000, email: 'a@b.co'),
        throwsA(isA<PaymentException>().having(
            (e) => e.code, 'code', 'amount-too-large')),
      );
      expect(backend.initCalled, isFalse);
    });

    test('returns authorization on valid backend response', () async {
      final backend = _ScriptedBackend()
        ..initResponse = {
          'authorizationUrl': 'https://checkout.paystack.com/x',
          'accessCode': 'abc',
          'reference': 'sese_ref_1',
        };
      final service = PaymentService(backend: backend);
      final auth = await service.initializeTopUp(
          amountNaira: 1000, email: 'a@b.co');
      expect(auth.reference, 'sese_ref_1');
      expect(auth.authorizationUrl, contains('paystack'));
    });

    test('throws when backend returns no checkout URL', () async {
      final backend = _ScriptedBackend()..initResponse = {};
      final service = PaymentService(backend: backend);
      expect(
        () => service.initializeTopUp(amountNaira: 1000, email: 'a@b.co'),
        throwsA(isA<PaymentException>().having(
            (e) => e.code, 'code', 'invalid-response')),
      );
    });

    test('verify returns settled flag', () async {
      final backend = _ScriptedBackend()
        ..verifyResponse = {'settled': false, 'creditedKobo': 0};
      final service = PaymentService(backend: backend);
      expect(await service.verifyTopUp('sese_ref_1'), isFalse);
    });

    test('backend PaymentException passes through untouched', () async {
      final backend = _ScriptedBackend()
        ..verifyError =
            const PaymentException('failed-precondition', 'Not successful.');
      final service = PaymentService(backend: backend);
      expect(
        () => service.verifyTopUp('bad_ref'),
        throwsA(isA<PaymentException>().having(
            (e) => e.userMessage, 'message', 'Not successful.')),
      );
    });
  });

  group('WalletTransaction parsing', () {
    test('reads kobo amounts and labels', () {
      final tx = WalletTransaction.fromMap('t1', {
        'type': 'wallet_topup',
        'amountKobo': 250000,
        'currency': 'NGN',
        'paymentReference': 'sese_ref_1',
      });
      expect(tx.amountNaira, 2500.0);
      expect(tx.label, 'Wallet top-up');
    });

    test('converts legacy naira amounts to kobo', () {
      final tx = WalletTransaction.fromMap('t2', {
        'type': 'streak_grand_award',
        'amount': 10000.0,
      });
      expect(tx.amountKobo, 1000000);
      expect(tx.label, 'Streak grand award');
    });

    test('formats referral commission types and incentive check', () {
      final tx1 = WalletTransaction.fromMap('t3', {
        'type': 'REFERRAL_COMMISSION_DRIVER',
        'amount': 500.0,
      });
      expect(tx1.label, 'Referral bonus');
      expect(WalletTransaction.isIncentiveType('REFERRAL_COMMISSION_DRIVER'), isTrue);

      final tx2 = WalletTransaction.fromMap('t4', {
        'type': 'REFERRAL_COMMISSION_CUSTOMER',
        'amount': 250.0,
      });
      expect(tx2.label, 'Referral bonus');
      expect(WalletTransaction.isIncentiveType('REFERRAL_COMMISSION_CUSTOMER'), isTrue);
    });
  });

  group('formatNaira', () {
    test('formats with thousands separators', () {
      expect(PaymentService.formatNaira(3700), '₦3,700.00');
      expect(PaymentService.formatNaira(10000.5), '₦10,000.50');
    });

    test('formats negative amounts correctly without string artifacts', () {
      expect(PaymentService.formatNaira(-525), '-₦525.00');
      expect(PaymentService.formatNaira(-1275), '-₦1,275.00');
      expect(PaymentService.formatNaira(-8500), '-₦8,500.00');
    });
  });
}
