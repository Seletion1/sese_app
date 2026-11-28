import 'package:flutter_test/flutter_test.dart';
import 'package:sese_ride/features/payments/sese_service.dart';

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
      expect(auth.gateway, 'paystack');
    });

    test('supports OPay gateway initialization and propagation', () async {
      final backend = _ScriptedBackend()
        ..initResponse = {
          'authorizationUrl': 'https://cashier.opaycheckout.com/pay/abc',
          'accessCode': 'opay_code_123',
          'reference': 'sese_opay_ref_1',
          'gateway': 'opay',
        };
      final service = PaymentService(backend: backend);
      final auth = await service.initializePayment(
        amountNaira: 2500,
        email: 'user@seseride.com',
        gateway: 'opay',
      );
      expect(auth.reference, 'sese_opay_ref_1');
      expect(auth.gateway, 'opay');
      expect(auth.authorizationUrl, contains('opaycheckout.com'));
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
      expect(tx.label, 'Sese Credits top-up');
    });

    test('converts legacy naira amounts to kobo', () {
      final tx = WalletTransaction.fromMap('t2', {
        'type': 'trip_payment',
        'amount': 10000.0,
      });
      expect(tx.amountKobo, 1000000);
      expect(tx.label, 'Trip payment');
    });

    test('formats top-up subtitle with date & time only without raw references', () {
      final dt = DateTime(2026, 11, 28, 8, 15);
      final tx = WalletTransaction.fromMap('t3', {
        'type': 'credit_topup',
        'amountKobo': 200000,
        'paymentReference': 'sese_p869DfLV_mwuqyg22g21',
        'createdAt': dt.toIso8601String(),
      });
      expect(tx.formattedSubtitle, 'Nov 28, 2026 • 08:15');
      expect(tx.formattedSubtitle, isNot(contains('sese_p869')));
    });

    test('formats commission subtitle with date, time, and resolved Order ID', () {
      final dt = DateTime(2026, 11, 28, 8, 15);
      final tx = WalletTransaction.fromMap('t4', {
        'type': 'platform_commission',
        'amountKobo': -73500,
        'orderCode': 'DTID0001',
        'createdAt': dt.toIso8601String(),
      });
      expect(tx.resolvedOrderId, 'DTID0001');
      expect(tx.formattedSubtitle, 'Nov 28, 2026 • 08:15 • DTID0001');
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
