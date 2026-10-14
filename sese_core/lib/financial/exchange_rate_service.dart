import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart';
import 'exchange_rates.dart';

/// Service streaming and reading `/system_config/exchange_rates`.
class ExchangeRateService {
  final FirebaseFirestore? firestore;

  const ExchangeRateService([this.firestore]);

  FirebaseFirestore? get _db {
    try {
      return firestore ?? FirebaseFirestore.instance;
    } catch (_) {
      return null;
    }
  }

  /// Live stream of `/system_config/exchange_rates`.
  Stream<ExchangeRates> streamExchangeRates() {
    final db = _db;
    if (db == null) return Stream.value(const ExchangeRates());
    return db
        .collection('system_config')
        .doc('exchange_rates')
        .snapshots()
        .map((snap) => ExchangeRates.fromMap(snap.data()))
        .handleError((Object error) {
      debugPrint('ExchangeRateService.streamExchangeRates error: $error');
      return const ExchangeRates();
    });
  }

  /// One-shot fetch of `/system_config/exchange_rates`.
  Future<ExchangeRates> fetchExchangeRates() async {
    try {
      final db = _db;
      if (db == null) return const ExchangeRates();
      final snap = await db.collection('system_config').doc('exchange_rates').get();
      return ExchangeRates.fromMap(snap.data());
    } catch (e) {
      debugPrint('ExchangeRateService.fetchExchangeRates error: $e');
      return const ExchangeRates();
    }
  }
}
