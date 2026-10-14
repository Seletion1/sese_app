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

/// Result returned from live recipient lookup and eligibility verification.
class P2pRecipientResult {
  final String recipientId;
  final String recipientName;
  final String accountType; // Driver or Customer
  final int completedTrips;
  final int minDriverTrips;
  final double maxP2pLimitNaira;
  final bool canReceive;
  final int tripsRemaining;
  final String reason;

  const P2pRecipientResult({
    required this.recipientId,
    required this.recipientName,
    required this.accountType,
    required this.completedTrips,
    required this.minDriverTrips,
    required this.maxP2pLimitNaira,
    required this.canReceive,
    required this.tripsRemaining,
    required this.reason,
  });

  factory P2pRecipientResult.fromMap(Map<String, dynamic> map) {
    return P2pRecipientResult(
      recipientId: (map['recipientId'] ?? '').toString(),
      recipientName: (map['recipientName'] ?? 'SeSe User').toString(),
      accountType: (map['accountType'] ?? 'Customer').toString(),
      completedTrips: (map['completedTrips'] as num?)?.toInt() ?? 0,
      minDriverTrips: (map['minDriverTrips'] as num?)?.toInt() ?? 3,
      maxP2pLimitNaira: (map['maxP2pLimitNaira'] as num?)?.toDouble() ?? 20000.0,
      canReceive: map['canReceive'] == true,
      tripsRemaining: (map['tripsRemaining'] as num?)?.toInt() ?? 0,
      reason: (map['reason'] ?? '').toString(),
    );
  }
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

  /// Live lookup fetching recipient's Name & Account Type (Driver/Customer)
  /// and evaluating driver eligibility guards.
  Future<P2pRecipientResult> lookupRecipient({
    required String recipientPhone,
  }) async {
    final fn = _fn;
    if (fn == null) {
      throw const P2pException(
        'unavailable',
        'Recipient lookup is unavailable right now.',
      );
    }
    try {
      final res = await fn.httpsCallable('lookupP2pRecipient').call({
        'recipientPhone': recipientPhone,
      });
      final data = Map<String, dynamic>.from(res.data as Map);
      return P2pRecipientResult.fromMap(data);
    } on FirebaseFunctionsException catch (e) {
      final detail = (e.message ?? '').trim();
      throw P2pException(
        e.code,
        detail.isEmpty ? 'Could not resolve recipient phone number.' : detail,
      );
    } catch (e) {
      debugPrint('P2pService.lookupRecipient: $e');
      throw const P2pException(
        'unknown',
        'Could not resolve recipient phone number. Please try again.',
      );
    }
  }

  /// Sends [amountKobo] to the SeSe user registered under [recipientPhone].
  /// [transactionPin] is verified server-side before any movement — the
  /// prompt sheet collects it, this transport only carries it.
  /// Returns the recipient's display name on success.
  Future<String> transfer({
    required String recipientPhone,
    required int amountKobo,
    required String transactionPin,
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
        'transactionPin': transactionPin,
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
