import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:flutter/foundation.dart';

/// A Nigerian (or regional) bank from the Paystack bank list.
class BankInfo {
  final String name;
  final String slug;
  final String code;

  const BankInfo({
    required this.name,
    required this.slug,
    required this.code,
  });

  factory BankInfo.fromMap(Map<String, dynamic> map) => BankInfo(
        name: (map['name'] ?? '').toString(),
        slug: (map['slug'] ?? '').toString(),
        code: (map['code'] ?? '').toString(),
      );
}

/// Verified bank account destination stored at `payout_profiles/{uid}`.
class BankAccount {
  final String bankName;
  final String bankCode;
  final String accountNumber;
  final String accountName;
  final DateTime? verifiedAt;

  const BankAccount({
    this.bankName = '',
    this.bankCode = '',
    this.accountNumber = '',
    this.accountName = '',
    this.verifiedAt,
  });

  bool get isComplete =>
      bankCode.isNotEmpty &&
      accountNumber.length == 10 &&
      accountName.isNotEmpty;

  factory BankAccount.fromMap(Map<String, dynamic>? map) {
    map ??= const {};
    DateTime? when;
    try {
      when = (map['verifiedAt'] as dynamic)?.toDate() as DateTime?;
    } catch (_) {
      if (map['verifiedAt'] is String) {
        when = DateTime.tryParse(map['verifiedAt'] as String);
      }
    }
    return BankAccount(
      bankName: (map['bankName'] ?? '').toString(),
      bankCode: (map['bankCode'] ?? '').toString(),
      accountNumber: (map['accountNumber'] ?? '').toString(),
      accountName: (map['accountName'] ?? '').toString(),
      verifiedAt: when,
    );
  }

  Map<String, dynamic> toMap() => {
        'bankName': bankName,
        'bankCode': bankCode,
        'accountNumber': accountNumber,
        'accountName': accountName,
        'verifiedAt': verifiedAt != null
            ? Timestamp.fromDate(verifiedAt!)
            : FieldValue.serverTimestamp(),
        'updatedAt': FieldValue.serverTimestamp(),
      };
}

/// Bank list + account-number verification.
///
/// Transport: `paystackBanks` / `resolveBankAccount` callables (secret stays
/// server-side). All methods degrade gracefully to empty/false on error so
/// Wallet Settings never hard-blocks.
class BankService {
  final FirebaseFirestore? _firestore;
  final FirebaseFunctions? _functions;

  const BankService([this._firestore, this._functions]);

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

  /// Pre-loaded Nigerian bank catalogue (Access, First Bank, GTBank, Kuda,
  /// Moniepoint, OPay, PalmPay, Stanbic, UBA, Wema, Zenith). Serves as instant
  /// default and offline fallback.
  static const List<BankInfo> defaultNigerianBanks = [
    BankInfo(name: 'Access Bank', slug: 'access-bank', code: '044'),
    BankInfo(name: 'First Bank of Nigeria', slug: 'first-bank-of-nigeria', code: '011'),
    BankInfo(name: 'Guaranty Trust Bank (GTBank)', slug: 'guaranty-trust-bank', code: '058'),
    BankInfo(name: 'Kuda Bank', slug: 'kuda-bank', code: '50211'),
    BankInfo(name: 'Moniepoint MFB', slug: 'moniepoint-mfb', code: '50515'),
    BankInfo(name: 'OPay', slug: 'opay', code: '999992'),
    BankInfo(name: 'PalmPay', slug: 'palmpay', code: '999991'),
    BankInfo(name: 'Stanbic IBTC Bank', slug: 'stanbic-ibtc-bank', code: '221'),
    BankInfo(name: 'United Bank for Africa (UBA)', slug: 'united-bank-for-africa', code: '033'),
    BankInfo(name: 'Wema Bank', slug: 'wema-bank', code: '035'),
    BankInfo(name: 'Zenith Bank', slug: 'zenith-bank', code: '057'),
  ];

  /// Cached bank list (10-minute in-memory TTL).
  static List<BankInfo>? _cache;
  static DateTime? _cacheAt;

  Future<List<BankInfo>> fetchBanks({bool forceRefresh = false}) async {
    if (!forceRefresh &&
        _cache != null &&
        _cacheAt != null &&
        DateTime.now().difference(_cacheAt!).inMinutes < 10) {
      return _cache!;
    }
    final fn = _fn;
    if (fn == null) return _cache ?? defaultNigerianBanks;
    try {
      final res = await fn.httpsCallable('paystackBanks').call({});
      final data = Map<String, dynamic>.from(res.data as Map);
      final list = (data['banks'] as List? ?? [])
          .whereType<Map>()
          .map((m) => BankInfo.fromMap(Map<String, dynamic>.from(m)))
          .toList();
      if (list.isNotEmpty) {
        _cache = list;
        _cacheAt = DateTime.now();
        return list;
      }
      return _cache ?? defaultNigerianBanks;
    } catch (e) {
      debugPrint('BankService.fetchBanks: $e');
      return _cache ?? defaultNigerianBanks;
    }
  }

  /// Real-time account-name lookup via verifyBankAccount / resolveBankAccount.
  /// Returns the account name, or null when unresolvable. Never throws.
  Future<String?> resolveAccountName({
    required String bankCode,
    required String accountNumber,
  }) async {
    final fn = _fn;
    if (fn == null) return null;
    if (bankCode.isEmpty || accountNumber.length != 10) return null;
    try {
      dynamic res;
      try {
        res = await fn.httpsCallable('verifyBankAccount').call({
          'bankCode': bankCode,
          'accountNumber': accountNumber,
        });
      } catch (_) {
        res = await fn.httpsCallable('resolveBankAccount').call({
          'bankCode': bankCode,
          'accountNumber': accountNumber,
        });
      }
      final data = Map<String, dynamic>.from(res.data as Map);
      final name =
          (data['account_name'] ?? data['accountName'] ?? '').toString();
      return name.isEmpty ? null : name;
    } catch (e) {
      debugPrint('BankService.resolveAccountName: $e');
      return null;
    }
  }

  Stream<BankAccount> bankAccountStream(String uid) {
    final db = _db;
    if (db == null || uid.isEmpty) {
      return Stream.value(const BankAccount());
    }
    return db
        .collection('payout_profiles')
        .doc(uid)
        .snapshots()
        .map((s) => BankAccount.fromMap(s.data()))
        .handleError((Object _) => const BankAccount());
  }

  Future<BankAccount> fetchBankAccount(String uid) async {
    try {
      final snap =
          await _db?.collection('payout_profiles').doc(uid).get();
      return BankAccount.fromMap(snap?.data());
    } catch (e) {
      debugPrint('BankService.fetchBankAccount: $e');
      return const BankAccount();
    }
  }

  /// Owner write (per firestore.rules `payout_profiles/{userId}`).
  Future<void> saveBankAccount(String uid, BankAccount account) async {
    final db = _db;
    if (db == null) throw StateError('Firestore is unavailable.');
    await db
        .collection('payout_profiles')
        .doc(uid)
        .set(account.toMap(), SetOptions(merge: true));
  }
}
