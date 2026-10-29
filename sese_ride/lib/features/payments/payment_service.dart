import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:flutter/foundation.dart';
import 'package:url_launcher/url_launcher.dart';

/// Paystack key policy (do NOT hardcode keys here):
/// - Publishable keys are safe by design but are delivered server-side via
///   `initializePayment` (checkout runs on the server-issued
///   `authorizationUrl`), so no key constant lives in this app.
/// - The SECRET key lives ONLY in Cloud Functions (`PAYSTACK_SECRET_KEY`
///   via Secret Manager) and must never be embedded, logged, or committed.

/// Thrown when a payment action fails. Always carries a [userMessage] safe
/// to show in a SnackBar.
class PaymentException implements Exception {
  final String code;
  final String userMessage;

  const PaymentException(this.code, this.userMessage);

  @override
  String toString() => 'PaymentException($code): $userMessage';
}

/// One wallet history row (`wallets/{uid}/transactions/{txId}`).
class WalletTransaction {
  final String id;
  final String type;
  final int amountKobo;
  final String currency;
  final String paymentReference;
  final DateTime? createdAt;

  const WalletTransaction({
    required this.id,
    required this.type,
    required this.amountKobo,
    this.currency = 'NGN',
    this.paymentReference = '',
    this.createdAt,
  });

  double get amountNaira => amountKobo / 100.0;

  /// Human label for the transaction type.
  String get label {
    switch (type) {
      case 'wallet_topup':
        return 'Wallet top-up';
      case 'trip_payment':
        return 'Trip payment';
      case 'streak_level2_cashback':
        return 'Streak cash-back';
      case 'streak_level3_bonus':
        return 'Streak bonus';
      case 'streak_grand_award':
        return 'Streak grand award';
      case 'platform_commission':
      case 'commission_fee':
      case 'commission':
        return 'Platform commission fee';
      case 'bank_withdrawal':
      case 'withdrawal':
        return 'Bank withdrawal';
      case 'payout':
        return 'Payout';
      case 'referral_bonus':
      case 'referral_earnings':
      case 'referral_commission':
      case 'REFERRAL_COMMISSION_DRIVER':
      case 'REFERRAL_COMMISSION_CUSTOMER':
        return 'Referral bonus';
      case 'incentive_bonus':
        return 'Incentive bonus';
      default:
        return type.replaceAll('_', ' ');
    }
  }

  /// Driver-facing label: fare receipts read as income on driver wallets.
  String displayLabel({bool driverView = false}) {
    if (driverView && type == 'trip_payment') return 'Ride fare received';
    return label;
  }

  /// Ledger direction. Every type the backend writes today is a credit;
  /// known debit families (and `*_debit`/`*_fee`/`*_withdrawal`/`*_payout`
  /// suffixes for forward-compat) resolve to debit.
  bool get isCredit {
    const debitTypes = {
      'platform_commission',
      'commission_fee',
      'commission',
      'bank_withdrawal',
      'withdrawal',
      'payout',
      'trip_charge',
      'fee',
      'debit',
      'penalty',
    };
    if (debitTypes.contains(type)) return false;
    if (type.endsWith('_debit') ||
        type.endsWith('_fee') ||
        type.endsWith('_withdrawal') ||
        type.endsWith('_payout')) {
      return false;
    }
    return true;
  }

  /// Signed, formatted amount for ledger rows (`+₦2,500.00` / `-₦350.00`).
  String get signedAmount =>
      '${isCredit ? '+' : '-'}${PaymentService.formatNaira(amountNaira)}';

  /// Wallet-ledger incentive types (bonuses, referrals, awards).
  static bool isIncentiveType(String type) => const {
        'streak_level2_cashback',
        'streak_level3_bonus',
        'streak_grand_award',
        'referral_bonus',
        'referral_earnings',
        'referral_commission',
        'REFERRAL_COMMISSION_DRIVER',
        'REFERRAL_COMMISSION_CUSTOMER',
        'incentive_bonus',
      }.contains(type);

  factory WalletTransaction.fromMap(String id, Map<String, dynamic> map) {
    DateTime? when;
    final raw = map['createdAt'];
    try {
      if (raw != null) when = (raw as dynamic).toDate() as DateTime?;
    } catch (_) {
      if (raw is String) when = DateTime.tryParse(raw);
    }
    int kobo = 0;
    if (map['amountKobo'] is num) {
      kobo = (map['amountKobo'] as num).toInt();
    } else if (map['amount'] is num) {
      // Legacy naira-denominated entries.
      kobo = ((map['amount'] as num).toDouble() * 100).round();
    }
    return WalletTransaction(
      id: id,
      type: (map['type'] ?? 'wallet_topup').toString(),
      amountKobo: kobo,
      currency: (map['currency'] ?? 'NGN').toString(),
      paymentReference: (map['paymentReference'] ?? '').toString(),
      createdAt: when,
    );
  }
}

/// One driver payout record (`driver_payouts/{payoutId}`), written by the
/// hub/operations backend. All fields defensive — amounts may be stored as
/// kobo integers, naira doubles, or minor-unit ints depending on the flow.
class DriverPayout {
  final String id;
  final double amountNaira;
  final String status;
  final String reference;
  final DateTime? createdAt;

  const DriverPayout({
    required this.id,
    required this.amountNaira,
    this.status = 'pending',
    this.reference = '',
    this.createdAt,
  });

  factory DriverPayout.fromMap(String id, Map<String, dynamic> map) {
    double naira = 0;
    final kobo = map['amountKobo'];
    final amount = map['amount'];
    final minor = map['fareMinor'] ?? map['amountMinor'];
    if (kobo is num) {
      naira = kobo.toDouble() / 100.0;
    } else if (minor is num) {
      naira = minor.toDouble() / 100.0;
    } else if (amount is num) {
      // Backend convention: `amount` is a naira double.
      naira = amount.toDouble();
    }
    DateTime? when;
    final raw = map['createdAt'] ?? map['requestedAt'];
    try {
      if (raw != null) when = (raw as dynamic).toDate() as DateTime?;
    } catch (_) {
      if (raw is String) when = DateTime.tryParse(raw);
      if (raw is num) {
        when = DateTime.fromMillisecondsSinceEpoch(raw.toInt());
      }
    }
    return DriverPayout(
      id: id,
      amountNaira: naira,
      status: (map['status'] ?? 'pending').toString(),
      reference: (map['reference'] ?? map['payoutId'] ?? '').toString(),
      createdAt: when,
    );
  }
}

/// Result of `initializePayment`: hosted checkout URL + our reference.
class PaymentAuthorization {
  final String authorizationUrl;
  final String accessCode;
  final String reference;

  const PaymentAuthorization({
    required this.authorizationUrl,
    required this.accessCode,
    required this.reference,
  });
}

/// Transport seam for the payment callables (unit-testable without Firebase).
abstract class PaymentsBackend {
  Future<Map<String, dynamic>> callInitializePayment(
      Map<String, dynamic> data);
  Future<Map<String, dynamic>> callVerifyPayment(String reference);
}

class _FunctionsPaymentsBackend implements PaymentsBackend {
  FirebaseFunctions get _fn => FirebaseFunctions.instance;

  @override
  Future<Map<String, dynamic>> callInitializePayment(
      Map<String, dynamic> data) async {
    final result = await _fn.httpsCallable('initializePayment').call(data);
    return Map<String, dynamic>.from(result.data as Map);
  }

  @override
  Future<Map<String, dynamic>> callVerifyPayment(String reference) async {
    final result = await _fn
        .httpsCallable('verifyPayment')
        .call({'reference': reference});
    return Map<String, dynamic>.from(result.data as Map);
  }
}

/// Payments for every user (customers AND drivers): wallet top-up via
/// Paystack, live balance, and transaction history.
///
/// Wallet balance unit is **kobo** (integer-exact, Paystack-native). All
/// money movement happens server-side; the client only opens Paystack's
/// hosted checkout and asks the backend to verify.
class PaymentService {
  /// Minimum top-up in naira (mirrors the backend floor of ₦100).
  static const double minTopUpNaira = 100.0;

  /// Maximum top-up in naira (mirrors the backend ceiling of ₦500,000).
  static const double maxTopUpNaira = 500000.0;

  final FirebaseFirestore? _firestore;
  final PaymentsBackend? _backend;

  PaymentService({this._firestore, this._backend});

  FirebaseFirestore? get _db {
    try {
      return _firestore ?? FirebaseFirestore.instance;
    } catch (_) {
      return null;
    }
  }

  PaymentsBackend get _ops => _backend ?? _FunctionsPaymentsBackend();

  /// Live wallet balance in kobo. Denied/unavailable reads resolve to 0
  /// and end instead of retrying forever.
  Stream<int> walletBalanceKoboStream(String uid) {
    final db = _db;
    if (db == null || uid.isEmpty) return Stream.value(0);
    return db
        .collection('wallets')
        .doc(uid)
        .snapshots()
        .map((doc) => ((doc.data()?['balance'] as num?) ?? 0).toInt())
        .handleError((Object _) => 0);
  }

  /// Wallet history, newest first. Denied/unavailable reads resolve to
  /// empty and end instead of retrying forever.
  Stream<List<WalletTransaction>> walletHistoryStream(String uid,
      {int limit = 20}) {
    final db = _db;
    if (db == null || uid.isEmpty) {
      return Stream.value(const <WalletTransaction>[]);
    }
    return db
        .collection('wallets')
        .doc(uid)
        .collection('transactions')
        .orderBy('createdAt', descending: true)
        .limit(limit)
        .snapshots()
        .map((snap) => snap.docs
            .map((d) => WalletTransaction.fromMap(d.id, d.data()))
            .toList())
        .handleError((Object _) => const <WalletTransaction>[]);
  }

  /// Driver payout records (`driver_payouts`), newest first.
  /// Denied/unavailable reads resolve to empty. Fields are parsed
  /// defensively — the hub writes these records, never this app.
  Stream<List<DriverPayout>> driverPayoutsStream(String uid,
      {int limit = 10}) {
    final db = _db;
    if (db == null || uid.isEmpty) {
      return Stream.value(const <DriverPayout>[]);
    }
    return db
        .collection('driver_payouts')
        .where('driverId', isEqualTo: uid)
        .limit(limit * 3)
        .snapshots()
        .map((snap) {
      final items = snap.docs
          .map((d) => DriverPayout.fromMap(d.id, d.data()))
          .toList()
        ..sort((a, b) => _comparePayoutDate(b, a));
      return items.take(limit).toList();
    }).handleError((Object _) => const <DriverPayout>[]);
  }

  static int _comparePayoutDate(DriverPayout a, DriverPayout b) {
    final da = a.createdAt ?? DateTime.fromMillisecondsSinceEpoch(0);
    final db = b.createdAt ?? DateTime.fromMillisecondsSinceEpoch(0);
    return da.compareTo(db);
  }

  /// Starts a wallet top-up. Returns the hosted checkout page to open.
  /// Throws [PaymentException] on validation or backend failure.
  Future<PaymentAuthorization> initializeTopUp({
    required double amountNaira,
    required String email,
    String? transactionPin,
  }) async {
    if (amountNaira < minTopUpNaira) {
      throw const PaymentException(
          'amount-too-small', 'Minimum top-up is ₦100.');
    }
    if (amountNaira > maxTopUpNaira) {
      throw const PaymentException(
          'amount-too-large', 'Maximum top-up is ₦500,000.');
    }
    final amountKobo = (amountNaira * 100).round();
    try {
      final data = await _ops.callInitializePayment({
        'amountKobo': amountKobo,
        'purpose': 'wallet_topup',
        'email': email,
        if (transactionPin != null && transactionPin.isNotEmpty)
          'transactionPin': transactionPin,
      });
      final url = (data['authorizationUrl'] ?? '').toString();
      final reference = (data['reference'] ?? '').toString();
      if (url.isEmpty || reference.isEmpty) {
        throw const PaymentException('invalid-response',
            'Payment server did not return a checkout page.');
      }
      return PaymentAuthorization(
        authorizationUrl: url,
        accessCode: (data['accessCode'] ?? '').toString(),
        reference: reference,
      );
    } on FirebaseFunctionsException catch (e) {
      debugPrint('PaymentService.initialize ${e.code}: ${e.message}');
      throw PaymentException(e.code, _mapError(e.code, e.message));
    } catch (e) {
      debugPrint('PaymentService.initialize error: $e');
      if (e is PaymentException) rethrow;
      throw const PaymentException('network-error',
          'Could not reach the payment server. Check your connection.');
    }
  }

  /// Verifies a payment after the user pays on the checkout page.
  /// Returns true when the wallet was credited by this call (false when it
  /// was already settled, e.g. by the webhook).
  Future<bool> verifyTopUp(String reference) async {
    try {
      final data = await _ops.callVerifyPayment(reference);
      return data['settled'] == true;
    } on FirebaseFunctionsException catch (e) {
      debugPrint('PaymentService.verify ${e.code}: ${e.message}');
      throw PaymentException(e.code, _mapError(e.code, e.message));
    } catch (e) {
      debugPrint('PaymentService.verify error: $e');
      if (e is PaymentException) rethrow;
      throw const PaymentException('network-error',
          'Could not verify the payment. Try again.');
    }
  }

  /// Opens the Paystack hosted checkout, preferring the external browser and
  /// falling back to the platform default handler. Returns false when no
  /// app on the device can open the URL (e.g. no browser / WebView disabled)
  /// so the caller can say exactly that instead of a generic failure.
  Future<bool> launchCheckout(String authorizationUrl) async {
    final uri = Uri.tryParse(authorizationUrl.trim());
    if (uri == null || !uri.hasScheme) {
      debugPrint('PaymentService.launchCheckout: malformed url');
      return false;
    }
    debugPrint(
        'PaymentService.launchCheckout: opening ${uri.host} (scheme ${uri.scheme})');
    try {
      if (await canLaunchUrl(uri)) {
        final ok =
            await launchUrl(uri, mode: LaunchMode.externalApplication);
        debugPrint('PaymentService.launchCheckout external: $ok');
        if (ok) return true;
      } else {
        debugPrint('PaymentService.launchCheckout: no handler (canLaunchUrl)');
      }
    } catch (e) {
      debugPrint('PaymentService.launchCheckout external error: $e');
    }
    try {
      final ok = await launchUrl(uri, mode: LaunchMode.platformDefault);
      debugPrint('PaymentService.launchCheckout platformDefault: $ok');
      return ok;
    } catch (e) {
      debugPrint('PaymentService.launchCheckout platformDefault error: $e');
      return false;
    }
  }

  static String formatNaira(double amount) {
    final absAmount = amount.abs();
    final parts = absAmount.toStringAsFixed(2).split('.');
    final digits = parts[0].split('').reversed.toList();
    final out = <String>[];
    for (var i = 0; i < digits.length; i++) {
      if (i > 0 && i % 3 == 0) out.add(',');
      out.add(digits[i]);
    }
    final formatted = '₦${out.reversed.join()}.${parts[1]}';
    return amount < 0 ? '-$formatted' : formatted;
  }

  static String _mapError(String code, String? message) {
    // The backend has no usable Paystack secret (revoked key or nothing
    // configured): tell the user what is actually wrong instead of
    // "Invalid key". Matches both Paystack's own rejection and the
    // backend's PAYSTACK_NOT_CONFIGURED fail-fast code.
    final msg = (message ?? '').toLowerCase();
    if (msg.contains('invalid key') ||
        msg.contains('paystack_not_configured')) {
      return 'Online payment is not set up yet. Please top up via bank '
          'transfer or contact support.';
    }
    switch (code) {
      case 'unauthenticated':
        return 'Your session has expired. Please sign in again.';
      case 'unavailable':
        return 'Could not reach the payment server. Check your connection '
            'and try again.';
      case 'invalid-argument':
        return message ?? 'Invalid payment details.';
      case 'not-found':
        return 'Payment not found. Start a new top-up.';
      case 'failed-precondition':
        return message ?? 'This payment can no longer be completed.';
      case 'permission-denied':
        return 'This payment belongs to a different account.';
      default:
        return message ?? 'Payment failed. Please try again.';
    }
  }
}
