import 'package:cloud_functions/cloud_functions.dart';
import 'package:flutter/foundation.dart';

/// Thrown when a P2P transfer cannot proceed. [message] is user-safe.
class P2pException implements Exception {
  final String code;
  final String message;

  const P2pException(this.code, this.message);

  @override
  String toString() => 'P2pException($code): $message';
}

/// Client facade for wallet-to-wallet transfers (`transferWalletFunds`).
///
/// Amounts cross the wire in **kobo**. The server re-validates everything;
/// this class only forwards and translates errors.
class P2pService {
  final FirebaseFunctions? _functions;

  const P2pService([this._functions]);

  FirebaseFunctions? get _fn {
    try {
      return _functions ?? FirebaseFunctions.instance;
    } catch (_) {
      return null;
    }
  }

  /// Sends [amountKobo] to the SeSe user registered under [recipientPhone].
  /// Returns the recipient's display name on success.
  Future<String> transfer({
    required String recipientPhone,
    required int amountKobo,
  }) async {
    final fn = _fn;
    if (fn == null) {
      throw const P2pException(
        'unavailable',
        'Transfers are unavailable right now.',
      );
    }
    try {
      final res = await fn.httpsCallable('transferWalletFunds').call({
        'recipientPhone': recipientPhone,
        'amountKobo': amountKobo,
      });
      final data = Map<String, dynamic>.from(res.data as Map);
      return (data['recipientName'] ?? '').toString();
    } on FirebaseFunctionsException catch (e) {
      final detail = (e.message ?? '').trim();
      throw P2pException(
        e.code,
        detail.isEmpty ? 'We could not send that transfer.' : detail,
      );
    } catch (e) {
      debugPrint('P2pService.transfer: $e');
      throw const P2pException(
        'unknown',
        'We could not send that transfer. Please try again.',
      );
    }
  }
}
