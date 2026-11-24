import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:flutter/foundation.dart';
import 'package:sese_core/sese_core.dart';
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

/// One credit transaction history row (`wallets/{uid}/transactions/{txId}`).
class SeseCreditTransaction {
  final String id;
  final String type;
  final int amountKobo;
  final String currency;
  final String paymentReference;
  final DateTime? createdAt;
  final String? role;

  const SeseCreditTransaction({
    required this.id,
    required this.type,
    required this.amountKobo,
    this.currency = 'NGN',
    this.paymentReference = '',
    this.createdAt,
    this.role,
  });

  double get amountNaira => amountKobo / 100.0;

  /// Human label for the transaction type.
  String get label {
    switch (type) {
      case 'wallet_topup':
      case 'driver_credit_topup':
        return 'Sese Credits top-up';
      case 'trip_payment':
        return 'Trip payment';
      case 'trip_wallet_settlement':
        return 'Ride fare received';
      case 'trip_escrow_hold':
      case 'escrow_hold':
        return 'Trip payment hold';
      case 'trip_escrow_refund':
      case 'escrow_refund':
        return 'Trip payment refund';
      case 'platform_commission':
      case 'commission_fee':
      case 'commission':
        return 'Platform commission fee';
      case 'waiting_fee_paid':
      case 'unpaid_waiting_fee_debited':
        return 'Waiting fee';
      case 'waiting_fee_credited':
      case 'unpaid_waiting_fee_credited':
        return 'Waiting fee earned';
      case 'debt_settled_cash':
        return 'Debt settled';
      default:
        return type.replaceAll('_', ' ');
    }
  }

  /// Driver-facing label: fare receipts read as income on driver credits ledger.
  String displayLabel({bool driverView = false}) {
    if (driverView && type == 'trip_payment') return 'Ride fare received';
    return label;
  }

  /// Ledger direction. Every credit adds to the credit balance; debits subtract.
  /// Dynamically evaluates amounts, role context, and known debit/credit families.
  bool get isCredit {
    if (amountKobo < 0 || amountNaira < 0) return false;
    final lower = type.toLowerCase();
    if (role == 'customer' &&
        (lower == 'trip_payment' || lower == 'trip_charge')) {
      return false;
    }
    const debitTypes = {
      'platform_commission',
      'commission_fee',
      'commission',
      'recovered_debt_debit',
      'trip_charge',
      'fee',
      'debit',
      'penalty',
      'trip_escrow_hold',
      'escrow_hold',
      'waiting_fee_paid',
      'unpaid_waiting_fee_debited',
    };
    if (debitTypes.contains(lower)) return false;
    if (lower.endsWith('_debit') ||
        lower.endsWith('_fee') ||
        lower.endsWith('_hold')) {
      return false;
    }
    return true;
  }

  /// Signed, formatted amount for ledger rows (`+₦2,500.00` / `-₦350.00`).
  /// Guaranteed to never collide or produce double signs like `+-` or `-+`.
  String get signedAmount =>
      SeseService.formatSignedNaira(amountNaira, isCredit: isCredit);

  /// Whether this transaction is customer-facing.
  bool get isCustomerFacing {
    if (role == 'driver') return false;
    if (role == 'customer') return true;

    final lower = type.toLowerCase();
    if (lower.startsWith('driver_')) return false;

    const driverOnlyTypes = {
      'platform_commission',
      'commission_fee',
      'commission',
      'recovered_debt_debit',
      'trip_wallet_settlement',
      'waiting_fee_credited',
      'unpaid_waiting_fee_credited',
    };
    if (driverOnlyTypes.contains(lower)) return false;
    if (lower.contains('commission') && !lower.contains('customer')) return false;

    // Driver fare received stored as positive trip_payment without role tag
    if (lower == 'trip_payment' && amountKobo > 0) {
      return false;
    }

    return true;
  }

  /// Whether this transaction is driver-facing (e.g. platform commission fees,
  /// trip fare settlements, top-ups).
  bool get isDriverFacing {
    if (role == 'customer') return false;
    if (role == 'driver') return true;

    final lower = type.toLowerCase();
    if (lower.startsWith('driver_')) return true;

    // Known customer-only types
    if (lower.startsWith('customer_') ||
        lower == 'trip_escrow_hold' ||
        lower == 'escrow_hold' ||
        lower == 'trip_escrow_refund' ||
        lower == 'escrow_refund' ||
        lower == 'waiting_fee_paid' ||
        lower == 'unpaid_waiting_fee_debited' ||
        lower == 'debt_settled_cash') {
      return false;
    }

    // Customer ride payment (outgoing debit)
    if (lower == 'trip_payment' && (amountKobo < 0 || amountNaira < 0)) {
      return false;
    }

    return true;
  }

  factory SeseCreditTransaction.fromMap(String id, Map<String, dynamic> map) {
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
    final rawRole = map['role'] ?? map['userRole'] ?? map['actorRole'];
    final roleStr = rawRole?.toString().toLowerCase();
    return SeseCreditTransaction(
      id: id,
      type: (map['type'] ?? 'driver_credit_topup').toString(),
      amountKobo: kobo,
      currency: (map['currency'] ?? 'NGN').toString(),
      paymentReference: (map['paymentReference'] ?? '').toString(),
      createdAt: when,
      role: roleStr,
    );
  }
}

/// Backward compatibility typedef
typedef WalletTransaction = SeseCreditTransaction;

/// Result of `initializePayment`: hosted checkout URL + our reference.
class PaymentAuthorization {
  final String authorizationUrl;
  final String accessCode;
  final String reference;
  final String gateway;

  const PaymentAuthorization({
    required this.authorizationUrl,
    required this.accessCode,
    required this.reference,
    this.gateway = 'paystack',
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

/// Platform service and credit operations: Paystack payment initialization,
/// driver Sese Credits top-up, live credit balance, and transaction history.
///
/// Credit unit is **kobo** (integer-exact, Paystack-native). All
/// money and credit movement happens server-side; the client only opens Paystack's
/// hosted checkout and asks the backend to verify.
class SeseService {
  /// Minimum top-up in naira (mirrors the backend floor of ₦100).
  static const double minTopUpNaira = 100.0;

  /// Maximum top-up in naira (mirrors the backend ceiling of ₦500,000).
  static const double maxTopUpNaira = 500000.0;

  final FirebaseFirestore? _firestore;
  final PaymentsBackend? _backend;

  SeseService({this._firestore, this._backend});

  FirebaseFirestore? get _db {
    try {
      return _firestore ?? FirebaseFirestore.instance;
    } catch (_) {
      return null;
    }
  }

  PaymentsBackend get _ops => _backend ?? _FunctionsPaymentsBackend();

  /// Sese Credits balance stream in kobo.
  Stream<int> creditBalanceKoboStream(String uid, {String? role}) =>
      walletBalanceKoboStream(uid, role: role);

  /// Sese Credits transaction history stream.
  Stream<List<SeseCreditTransaction>> creditHistoryStream(String uid, {String? role}) =>
      walletHistoryStream(uid, role: role);

  /// Whether the driver has sufficient Sese Credits to accept/dispatch trips.
  Future<bool> hasSufficientCredits(String driverId) =>
      hasSufficientDriverBalance(driverId);

  /// Live wallet / credit balance in kobo with instant local cache fallback.
  /// When [role] is supplied ('driver' or 'customer'), reads the dedicated
  /// role balance if populated before falling back to mainWalletBalance.
  Stream<int> walletBalanceKoboStream(String uid, {String? role}) {
    final cacheKey = role != null
        ? 'wallet_balance_kobo_${uid}_$role'
        : 'wallet_balance_kobo_$uid';
    final cachedBal = LocalCacheService.instance.getInt(cacheKey) ?? 0;
    final db = _db;
    if (db == null || uid.isEmpty) return Stream.value(cachedBal);
    return db
        .collection('wallets')
        .doc(uid)
        .snapshots()
        .map((doc) {
          final data = doc.data();
          num? balKobo;
          if (role == 'driver' && data?['driverBalance'] is num) {
            balKobo = (data!['driverBalance'] as num) * 100;
          } else if (role == 'customer' && data?['customerBalance'] is num) {
            balKobo = (data!['customerBalance'] as num) * 100;
          } else if (data?['mainWalletBalance'] is num) {
            balKobo = (data!['mainWalletBalance'] as num) * 100;
          } else if (data?['balance'] is num) {
            balKobo = data!['balance'] as num;
          }
          final bal = (balKobo ?? cachedBal).round();
          LocalCacheService.instance.setInt(cacheKey, bal);
          return bal;
        })
        .handleError((Object _) => cachedBal);
  }

  /// On-demand live wallet balance fetch in kobo.
  Future<int> fetchWalletBalanceKobo(String uid, {String? role}) async {
    final cacheKey = role != null
        ? 'wallet_balance_kobo_${uid}_$role'
        : 'wallet_balance_kobo_$uid';
    final cachedBal = LocalCacheService.instance.getInt(cacheKey) ?? 0;
    final db = _db;
    if (db == null || uid.isEmpty) return cachedBal;
    try {
      final doc = await db.collection('wallets').doc(uid).get();
      final data = doc.data();
      if (data == null) return cachedBal;
      num? balKobo;
      if (role == 'driver' && data['driverBalance'] is num) {
        balKobo = (data['driverBalance'] as num) * 100;
      } else if (role == 'customer' && data['customerBalance'] is num) {
        balKobo = (data['customerBalance'] as num) * 100;
      } else if (data['mainWalletBalance'] is num) {
        balKobo = (data['mainWalletBalance'] as num) * 100;
      } else if (data['balance'] is num) {
        balKobo = data['balance'] as num;
      }
      final bal = (balKobo ?? cachedBal).round();
      LocalCacheService.instance.setInt(cacheKey, bal);
      return bal;
    } catch (_) {
      return cachedBal;
    }
  }

  /// Checks whether [driverId] holds at least the minimum wallet balance
  /// threshold configured in the Hub (defaulting to ₦1.00 if unconfigured).
  ///
  /// Returns `true` if balance is sufficient (>= min threshold), `false` if low.
  Future<bool> hasSufficientDriverBalance(
    String driverId, {
    double? overrideMinNaira,
  }) async {
    if (driverId.isEmpty) return true;
    final config = await const FinancialConfigService().getConfig();
    final minNaira = overrideMinNaira ?? config.minWalletBalanceToOnline;
    final balKobo = await fetchWalletBalanceKobo(driverId);
    return (balKobo / 100.0) >= minNaira;
  }

  /// Credit and transaction history, newest first. Filterable by [role]:
  /// - `'customer'`: returns customer-facing records (ride payments, refunds).
  /// - `'driver'`: returns driver-facing records (fare receipts, platform commissions, top-ups).
  /// - `null`: returns all transactions without role filtering.
  Stream<List<WalletTransaction>> walletHistoryStream(
    String uid, {
    int limit = 20,
    String? role,
  }) {
    final db = _db;
    if (db == null || uid.isEmpty) {
      return Stream.value(const <WalletTransaction>[]);
    }
    final fetchLimit = role != null ? limit * 3 : limit;
    return db
        .collection('wallets')
        .doc(uid)
        .collection('transactions')
        .orderBy('createdAt', descending: true)
        .limit(fetchLimit)
        .snapshots()
        .map((snap) {
          final all = snap.docs
              .map((d) => WalletTransaction.fromMap(d.id, d.data()))
              .toList();
          if (role == 'customer') {
            return all
                .where((t) =>
                    t.isCustomerFacing &&
                    t.role != 'driver' &&
                    t.role != 'hub')
                .take(limit)
                .toList();
          } else if (role == 'driver') {
            return all
                .where((t) =>
                    t.isDriverFacing &&
                    t.role != 'customer' &&
                    t.role != 'hub')
                .take(limit)
                .toList();
          }
          return all.take(limit).toList();
        })
        .handleError((Object _) => const <WalletTransaction>[]);
  }

  /// Initializes a hosted payment for driver credits or per-trip direct checkout
  /// via [gateway] ('paystack' or 'opay').
  /// Throws [PaymentException] on validation or backend failure.
  Future<PaymentAuthorization> initializePayment({
    required double amountNaira,
    required String email,
    String purpose = 'driver_credit',
    String? tripId,
    String gateway = 'paystack',
  }) async {
    if (amountNaira < minTopUpNaira) {
      throw const PaymentException(
          'amount-too-small', 'Minimum payment amount is ₦100.');
    }
    if (amountNaira > maxTopUpNaira) {
      throw const PaymentException(
          'amount-too-large', 'Maximum top-up is ₦500,000.');
    }
    final amountKobo = (amountNaira * 100).round();
    try {
      final data = await _ops.callInitializePayment({
        'amountKobo': amountKobo,
        'purpose': purpose,
        'email': email,
        'gateway': gateway,
        if (tripId != null && tripId.isNotEmpty) 'tripId': tripId,
      });
      final url = (data['authorizationUrl'] ?? '').toString();
      final reference = (data['reference'] ?? '').toString();
      final resolvedGateway = (data['gateway'] ?? gateway).toString();
      if (url.isEmpty || reference.isEmpty) {
        throw const PaymentException('invalid-response',
            'Payment server did not return a checkout page.');
      }
      return PaymentAuthorization(
        authorizationUrl: url,
        accessCode: (data['accessCode'] ?? '').toString(),
        reference: reference,
        gateway: resolvedGateway,
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

  /// Starts driver Sese Credits top-up via Paystack or OPay Checkout.
  Future<PaymentAuthorization> initializeTopUp({
    required double amountNaira,
    required String email,
    String? purpose,
    String? tripId,
    String gateway = 'paystack',
  }) =>
      initializePayment(
        amountNaira: amountNaira,
        email: email,
        purpose: purpose ?? 'driver_credit',
        tripId: tripId,
        gateway: gateway,
      );

  /// Verifies a payment after the user pays on the checkout page.
  /// Returns true when the payment was settled by this call (or previously by webhook).
  Future<bool> verifyPayment(String reference) async {
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

  /// Verifies Sese Credits top-up.
  Future<bool> verifyTopUp(String reference) => verifyPayment(reference);

  /// Opens the Paystack hosted checkout in a genuine browser environment.
  /// Prefers `LaunchMode.inAppBrowserView` (Chrome Custom Tabs on Android /
  /// SFSafariViewController on iOS), which provides a full native browser
  /// with cookies, DOM storage, autofill, and 3DS banking redirects while
  /// staying inside the app. Falls back cleanly to `LaunchMode.externalApplication`
  /// and `LaunchMode.platformDefault`.
  ///
  /// Never uses `LaunchMode.inAppWebView` (`io.flutter.plugins.urllauncher.WebViewActivity`)
  /// because it lacks DOM storage, fails on Huawei/Mali GPU lifecycles, and
  /// defeats the purpose of an external browser fallback.
  Future<bool> launchCheckout(String authorizationUrl) async {
    final uri = Uri.tryParse(authorizationUrl.trim());
    if (uri == null || !uri.hasScheme) {
      debugPrint('SeseService.launchCheckout: malformed url');
      return false;
    }
    debugPrint(
        'SeseService.launchCheckout: opening ${uri.host} (scheme ${uri.scheme})');

    // Attempt 1: In-App Browser View / Chrome Custom Tabs / SFSafariViewController.
    // Full native browser session, DOM storage, cookies, banking app handoffs,
    // and safe against unexported third-party app intent filter traps.
    try {
      final ok = await launchUrl(uri, mode: LaunchMode.inAppBrowserView);
      debugPrint('SeseService.launchCheckout inAppBrowserView: $ok');
      if (ok) return true;
    } catch (e) {
      debugPrint('SeseService.launchCheckout inAppBrowserView error: $e');
    }

    // Attempt 2: External Application (standard system browser application)
    try {
      final ok = await launchUrl(uri, mode: LaunchMode.externalApplication);
      debugPrint('SeseService.launchCheckout externalApplication: $ok');
      if (ok) return true;
    } catch (e) {
      debugPrint('SeseService.launchCheckout externalApplication error: $e');
    }

    // Attempt 3: Platform Default
    try {
      final ok = await launchUrl(uri, mode: LaunchMode.platformDefault);
      debugPrint('SeseService.launchCheckout platformDefault: $ok');
      return ok;
    } catch (e) {
      debugPrint('SeseService.launchCheckout platformDefault error: $e');
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

  /// Formats a signed naira amount (`+₦X.XX` or `-₦X.XX`) cleanly.
  /// Eliminates colliding signs (`+-` or `-+`) by formatting the absolute value
  /// and prepending a single explicit sign according to [isCredit] or the sign of [amount].
  static String formatSignedNaira(double amount, {bool? isCredit}) {
    final credit = isCredit ?? (amount >= 0);
    final absFormatted = formatNaira(amount.abs());
    return '${credit ? '+' : '-'}$absFormatted';
  }

  static String _mapError(String code, String? message) {
    // The backend has no usable secret (revoked key or nothing
    // configured): tell the user what is actually wrong instead of
    // "Invalid key". Matches both gateway's own rejection and the
    // backend's NOT_CONFIGURED fail-fast codes.
    final msg = (message ?? '').toLowerCase();
    if (msg.contains('invalid key') ||
        msg.contains('paystack_not_configured')) {
      return 'Online payment is not set up yet. Please top up via bank '
          'transfer or contact support.';
    }
    if (msg.contains('opay_not_configured')) {
      return 'OPay Checkout is not set up yet. Please select Paystack or contact support.';
    }
    if (msg.contains('gateway_not_supported') || msg.contains('unsupported gateway')) {
      return 'The selected payment gateway is not supported.';
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
      case 'internal':
        return 'Payment received by Paystack. Tap Verify to complete credit update.';
      default:
        if (msg == 'internal') {
          return 'Payment received by Paystack. Tap Verify to complete credit update.';
        }
        return message ?? 'Payment failed. Please try again.';
    }
  }
}

/// Backward compatibility alias for SeseService.
typedef PaymentService = SeseService;
typedef SeseCreditService = SeseService;
