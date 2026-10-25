import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:flutter/foundation.dart';

/// Dual-balance wallet view: withdrawable cash + SeSe Coin bonus.
///
/// Firestore `wallets/{uid}` shape (server-written):
/// - `mainWalletBalance` (num, naira) — withdrawable cash.
/// - `seseCoinBalance` (num, coins; 1 coin = ₦1) — referral / promo credits.
/// - `balance` (num, legacy kobo mirror — kept for older screens).
class DualWallet {
  final double mainWalletBalance;
  final double seseCoinBalance;

  const DualWallet({
    this.mainWalletBalance = 0,
    this.seseCoinBalance = 0,
  });

  double get total => mainWalletBalance + seseCoinBalance;
}

/// Reads the dual wallet + triggers server-side SeSe Coin conversion.
///
/// Conversion itself runs in the `convertSeseCoins` callable (admin SDK
/// bypasses the read-only wallet rules). The client never writes balances.
class SeseCoinService {
  final FirebaseFirestore? _firestore;
  final FirebaseFunctions? _functions;

  const SeseCoinService([this._firestore, this._functions]);

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

  static double _num(dynamic v) =>
      (v is num) ? v.toDouble() : 0.0;

  /// Live dual-balance stream. Denied/offline reads resolve to zeros.
  Stream<DualWallet> walletStream(String uid) {
    final db = _db;
    if (db == null || uid.isEmpty) {
      return Stream.value(const DualWallet());
    }
    return db.collection('wallets').doc(uid).snapshots().map((doc) {
      final data = doc.data();
      if (data == null) return const DualWallet();
      final main = _num(data['mainWalletBalance']);
      final coin = _num(data['seseCoinBalance']);
      // Legacy docs only carry `balance` in kobo.
      if (main == 0 && coin == 0 && data['balance'] is num) {
        return DualWallet(
            mainWalletBalance:
                ((data['balance'] as num).toDouble()) / 100.0);
      }
      return DualWallet(
          mainWalletBalance: main, seseCoinBalance: coin);
    }).handleError((Object _) => const DualWallet());
  }

  /// One-shot fetch (used by guards that need a synchronous check).
  Future<DualWallet> fetchWallet(String uid) async {
    try {
      final snap =
          await _db?.collection('wallets').doc(uid).get();
      final data = snap?.data();
      if (data == null) return const DualWallet();
      final main = _num(data['mainWalletBalance']);
      final coin = _num(data['seseCoinBalance']);
      if (main == 0 && coin == 0 && data['balance'] is num) {
        return DualWallet(
            mainWalletBalance:
                ((data['balance'] as num).toDouble()) / 100.0);
      }
      return DualWallet(
          mainWalletBalance: main, seseCoinBalance: coin);
    } catch (e) {
      debugPrint('SeseCoinService.fetchWallet: $e');
      return const DualWallet();
    }
  }

  /// Alias for [fetchWallet] returning cash and coin balances.
  Future<DualWallet> getBalances(String uid) => fetchWallet(uid);

  /// Manual "Convert to Wallet" — moves the entire SeSe Coin balance into
  /// the withdrawable cash wallet. The callable enforces
  /// `minConvertibleBonus`; throws [SeseCoinException] otherwise.
  Future<double> convertToWallet() async {
    final fn = _fn;
    if (fn == null) {
      throw const SeseCoinException(
          'backend-unavailable', 'Conversion service is unreachable.');
    }
    try {
      final res =
          await fn.httpsCallable('convertSeseCoins').call({});
      final data = Map<String, dynamic>.from(res.data as Map);
      return ((data['converted'] as num?) ?? 0).toDouble();
    } on FirebaseFunctionsException catch (e) {
      throw SeseCoinException(e.code, e.message ?? 'Conversion failed.');
    }
  }
}

class SeseCoinException implements Exception {
  final String code;
  final String message;

  const SeseCoinException(this.code, this.message);

  @override
  String toString() => 'SeseCoinException($code): $message';
}
