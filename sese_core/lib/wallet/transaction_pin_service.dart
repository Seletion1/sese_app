import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:flutter/foundation.dart';

/// Thrown when a transaction-PIN action fails. [message] is user-safe.
class TransactionPinException implements Exception {
  final String code;
  final String message;

  const TransactionPinException(this.code, this.message);

  @override
  String toString() => 'TransactionPinException($code): $message';
}

/// Client facade for the server-side Transaction Security PIN authority
/// (`setTransactionPin` / `verifyTransactionPin` in
/// `functions/src/transactionPin.ts`).
///
/// Zero-trust contract: the PIN is NEVER compared client-side and NEVER
/// stored on the device. The client only transports the entered digits to
/// the callable (or to a money callable's `transactionPin` field); the
/// server compares against the salted hash and enforces the attempt
/// lockout. A wrong PIN surfaces as a user-safe [TransactionPinException].
///
/// The account password (Firebase Auth) and this PIN are fully independent:
/// different storage, different verifiers — changing one can never affect
/// the other.
class TransactionPinService {
  final FirebaseFirestore? _firestore;
  final FirebaseFunctions? _functions;

  const TransactionPinService([this._firestore, this._functions]);

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

  Never _wrap(Object e) {
    if (e is FirebaseFunctionsException) {
      final detail = (e.message ?? '').trim();
      throw TransactionPinException(
        e.code,
        detail.isEmpty ? 'PIN verification failed.' : detail,
      );
    }
    debugPrint('TransactionPinService: $e');
    throw const TransactionPinException(
      'unknown',
      'PIN verification failed. Please try again.',
    );
  }

  /// True when the account already has a server-side PIN (prompt shows the
  /// verify sheet); false means the setup sheet. Reads the owner-readable
  /// vault marker — the hash itself is never used client-side.
  /// Fail-closed to verify mode: when offline/unknown, the server is the
  /// arbiter anyway (`pin-not-set` guidance if truly unset).
  Future<bool> hasPin(String uid) async {
    final db = _db;
    if (db == null || uid.isEmpty) return false;
    try {
      final doc = await db
          .collection('users')
          .doc(uid)
          .collection('private')
          .doc('auth')
          .get();
      final data = doc.data();
      return data != null &&
          (data['pinHash'] ?? '').toString().isNotEmpty;
    } catch (_) {
      return false;
    }
  }

  /// Creates the PIN (first time, no current PIN) or changes it (current
  /// PIN required — verified server-side before replacement).
  Future<void> setPin({String? currentPin, required String newPin}) async {
    final fn = _fn;
    if (fn == null) {
      throw const TransactionPinException(
          'unavailable', 'PIN service is unavailable.');
    }
    try {
      await fn.httpsCallable('setTransactionPin').call({
        if (currentPin != null && currentPin.isNotEmpty)
          'currentPin': currentPin,
        'pin': newPin,
      });
    } catch (e) {
      _wrap(e);
    }
  }

  /// Explicit server-side check (management screen + pre-flight UX). Money
  /// callables re-verify independently — this never authorizes anything.
  Future<void> verifyPin(String pin) async {
    final fn = _fn;
    if (fn == null) {
      throw const TransactionPinException(
          'unavailable', 'PIN service is unavailable.');
    }
    try {
      await fn.httpsCallable('verifyTransactionPin').call({'pin': pin});
    } catch (e) {
      _wrap(e);
    }
  }
}
