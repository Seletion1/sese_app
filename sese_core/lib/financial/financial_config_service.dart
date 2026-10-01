import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart';

import 'financial_config.dart';

/// Reads/writes the dynamic money thresholds at `system_configs/financials`.
///
/// Readable by any authenticated app (per firestore.rules
/// `system_configs/{configId}`); writable only by Super Admins. All readers
/// fall back to [FinancialConfig] compiled defaults on error/offline.
class FinancialConfigService {
  static const String docId = 'financials';

  final FirebaseFirestore? _firestore;

  const FinancialConfigService([this._firestore]);

  FirebaseFirestore? get _db {
    try {
      return _firestore ?? FirebaseFirestore.instance;
    } catch (_) {
      return null;
    }
  }

  DocumentReference<Map<String, dynamic>>? get _doc {
    final db = _db;
    if (db == null) return null;
    return db.collection('system_configs').doc(docId);
  }

  /// One-shot fetch with safe defaults on failure.
  Future<FinancialConfig> getConfig() async {
    try {
      final snap = await _doc?.get();
      if (snap != null && snap.exists && snap.data() != null) {
        return FinancialConfig.fromMap(snap.data());
      }
    } catch (e) {
      debugPrint('FinancialConfigService.getConfig fallback: $e');
    }
    return const FinancialConfig();
  }

  /// Live stream with safe defaults on error.
  Stream<FinancialConfig> configStream() {
    final doc = _doc;
    if (doc == null) return Stream.value(const FinancialConfig());
    return doc.snapshots().map((snap) {
      if (!snap.exists || snap.data() == null) {
        return const FinancialConfig();
      }
      return FinancialConfig.fromMap(snap.data());
    }).handleError((Object _) => const FinancialConfig());
  }

  /// Super Admin write (merge). Throws on permission/network failure so the
  /// Hub UI can surface the error.
  Future<void> saveConfig(FinancialConfig config) async {
    final doc = _doc;
    if (doc == null) throw StateError('Firestore is unavailable.');
    await doc.set(config.toMap(), SetOptions(merge: true));
  }
}
