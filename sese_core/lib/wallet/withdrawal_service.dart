import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:flutter/foundation.dart';

import 'bank_service.dart';

/// Thrown when a withdrawal cannot proceed. [message] is safe to surface in a
/// SnackBar — the server authors every message, never a stack trace or key.
class WithdrawalException implements Exception {
  final String code;
  final String message;

  const WithdrawalException(this.code, this.message);

  @override
  String toString() => 'WithdrawalException($code): $message';
}

/// One withdrawal request (`payout_requests/{requestId}`), written by
/// `processWalletWithdrawal`. Server-authored; the client only reads it.
class PayoutRequest {
  final String requestId;
  final int amountKobo;
  final String accountName;
  final String bankName;
  final String status;
  final DateTime? createdAt;

  /// `pending` until Paystack's transfer webhook settles it.
  bool get isPending => status == 'pending';

  /// Money left the wallet and the transfer succeeded.
  bool get isCompleted => status == 'completed';

  /// The transfer failed and the debit was refunded.
  bool get isRefunded => status == 'refunded' || status == 'failed';

  const PayoutRequest({
    required this.requestId,
    required this.amountKobo,
    this.accountName = '',
    this.bankName = '',
    this.status = 'pending',
    this.createdAt,
  });

  factory PayoutRequest.fromMap(String id, Map<String, dynamic>? map) {
    map ??= <String, dynamic>{};
    DateTime? when;
    try {
      when = (map['createdAt'] as dynamic)?.toDate() as DateTime?;
    } catch (_) {
      if (map['createdAt'] is String) {
        when = DateTime.tryParse(map['createdAt'] as String);
      }
    }
    return PayoutRequest(
      requestId: id,
      amountKobo: (map['amountKobo'] as num?)?.round() ?? 0,
      accountName: (map['accountName'] ?? '').toString(),
      bankName: (map['bankName'] ?? '').toString(),
      status: (map['status'] ?? 'pending').toString(),
      createdAt: when,
    );
  }
}

/// Client facade for the direct Paystack withdrawal flow.
///
/// The client cannot move money: every call is a request for the server to act,
/// and the amount is re-validated against the live balance there. Amounts cross
/// the wire in **kobo** because that is the unit of `wallets/{uid}.balance`.
///
/// Secrets: nothing here holds a Paystack key. Bank listing and account
/// resolution go through callables so the secret stays server-side.
class WithdrawalService {
  final FirebaseFirestore? _firestore;
  final FirebaseFunctions? _functions;
  final BankService? _banks;

  const WithdrawalService([this._firestore, this._functions, this._banks]);

  FirebaseFirestore? get _db {
    try {
      return _firestore ?? FirebaseFirestore.instance;
    } catch (_) {
      return null;
    }
  }

  FirebaseFunctions? get _fn {
    try {
      return _functions ?? FirebaseFunctions.instance;
    } catch (_) {
      return null;
    }
  }

  BankService get _bankService => _banks ?? BankService(_firestore, _functions);

  /// Nigerian bank catalogue for the picker. Delegates to [BankService] so the
  /// list and the account verification share one cache and one call path.
  Future<List<BankInfo>> fetchBanks() => _bankService.fetchBanks();

  /// Resolves an account number to its registered holder name.
  /// Returns null when the account cannot be verified.
  Future<String?> resolveAccountName({
    required String bankCode,
    required String accountNumber,
  }) {
    return _bankService.resolveAccountName(
      bankCode: bankCode,
      accountNumber: accountNumber,
    );
  }

  /// Live withdrawable balance in kobo.
  Stream<int> availableKoboStream(String uid) {
    final db = _db;
    if (db == null || uid.isEmpty) return Stream.value(0);
    return db
        .collection('wallets')
        .doc(uid)
        .snapshots()
        .map((doc) => ((doc.data()?['balance'] as num?) ?? 0).round())
        .handleError((Object _) => 0);
  }

  /// Requests a withdrawal of [amountKobo] to the given account.
  ///
  /// Throws [WithdrawalException] with a user-safe message on rejection
  /// (insufficient balance, name mismatch, unverified account). The server
  /// re-verifies the account name against the profile; the client's own
  /// comparison is advisory only.
  Future<PayoutRequest> requestWithdrawal({
    required String uid,
    required int amountKobo,
    required String bankCode,
    required String accountNumber,
  }) async {
    final fn = _fn;
    if (fn == null) {
      throw const WithdrawalException(
        'unavailable',
        'Withdrawals are unavailable right now.',
      );
    }
    try {
      final res = await fn.httpsCallable('processWalletWithdrawal').call({
        'amountKobo': amountKobo,
        'bankCode': bankCode,
        'accountNumber': accountNumber,
      });
      final data = Map<String, dynamic>.from(res.data as Map);
      return PayoutRequest.fromMap(
        data['requestId']?.toString() ?? '',
        data,
      );
    } on FirebaseFunctionsException catch (e) {
      // The server's HttpsError message is already user-facing; fall back to a
      // generic line only when it is missing so we never render a raw code.
      // `message` is nullable on the plugin's exception type.
      final detail = (e.message ?? '').trim();
      throw WithdrawalException(
        e.code,
        detail.isEmpty ? 'We could not process that withdrawal.' : detail,
      );
    } catch (e) {
      debugPrint('WithdrawalService.requestWithdrawal: $e');
      throw const WithdrawalException(
        'unknown',
        'We could not process that withdrawal. Please try again.',
      );
    }
  }

  /// The caller's own payout requests, newest first. The owner read is granted
  /// by firestore.rules `payout_requests/{requestId}`.
  Stream<List<PayoutRequest>> payoutRequestsStream(String uid,
      {int limit = 20}) {
    final db = _db;
    if (db == null || uid.isEmpty) {
      return Stream.value(const <PayoutRequest>[]);
    }
    return db
        .collection('payout_requests')
        .where('userId', isEqualTo: uid)
        .limit(limit)
        .snapshots()
        .map((snap) => snap.docs
            .map((d) => PayoutRequest.fromMap(d.id, d.data()))
            .toList())
        .handleError((Object _) => const <PayoutRequest>[]);
  }
}

/// Advisory mirror of the server's identity check, used to grey out the submit
/// button before a round-trip. The server still re-checks — this is UX, not
/// security, and must never be treated as a gate.
bool namesLooselyMatch(String profileName, String accountName) {
  // Mirrors the server's `accountNameMatches` in functions/src/payouts.ts.
  // Keep the two in step: apostrophes drop with no separator ("O'Brien" ==
  // "OBRIEN"), hyphens and other non-letters become separators.
  Set<String> tokens(String raw) => raw
      .toUpperCase()
      .replaceAll(RegExp(r"['’`]"), '')
      .replaceAll(RegExp(r'[^A-Z]'), ' ')
      .trim()
      .split(RegExp(r'\s+'))
      .where((t) => t.isNotEmpty)
      .toSet();

  final a = tokens(profileName);
  final b = tokens(accountName);
  if (a.length < 2 || b.length < 2) return false;
  final shorter = a.length <= b.length ? a : b;
  final longer = a.length <= b.length ? b : a;
  return shorter.every(longer.contains);
}
