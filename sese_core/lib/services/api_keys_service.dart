import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:flutter/foundation.dart';

import '../models/api_keys_config.dart';

/// Service that streams, fetches, and saves Firestore document `/system_config/api_keys`.
class ApiKeysService {
  final FirebaseFirestore? firestore;

  const ApiKeysService([this.firestore]);

  FirebaseFirestore? get _db {
    try {
      return firestore ?? FirebaseFirestore.instance;
    } catch (_) {
      return null;
    }
  }

  Stream<ApiKeysConfig> streamApiKeys() {
    final db = _db;
    if (db == null) return Stream.value(const ApiKeysConfig());
    return db
        .collection('system_config')
        .doc('api_keys')
        .snapshots()
        .map((snap) => ApiKeysConfig.fromMap(snap.data()))
        .handleError((Object error) {
      debugPrint('ApiKeysService.streamApiKeys fallback error: $error');
      return const ApiKeysConfig();
    });
  }

  Future<ApiKeysConfig> fetchApiKeys() async {
    final db = _db;
    if (db == null) return const ApiKeysConfig();
    try {
      final snap = await db
          .collection('system_config')
          .doc('api_keys')
          .get()
          .timeout(const Duration(seconds: 6));
      if (snap.exists && snap.data() != null) {
        return ApiKeysConfig.fromMap(snap.data());
      }
      return const ApiKeysConfig();
    } catch (e) {
      debugPrint('ApiKeysService.fetchApiKeys error: $e');
      try {
        final cached = await db
            .collection('system_config')
            .doc('api_keys')
            .get(const GetOptions(source: Source.cache));
        if (cached.exists && cached.data() != null) {
          return ApiKeysConfig.fromMap(cached.data());
        }
      } catch (_) {}
      return const ApiKeysConfig();
    }
  }

  Future<void> saveApiKeys(ApiKeysConfig config) async {
    final db = _db;
    if (db == null) return;
    final data = config.toMap();
    data['updatedAt'] = FieldValue.serverTimestamp();
    await db
        .collection('system_config')
        .doc('api_keys')
        .set(data, SetOptions(merge: true));
  }

  /// Resets live monthly usage counters (`google_calls`, `mapbox_calls`) on
  /// `system_config/api_keys` (Hub admin operation).
  Future<void> resetUsageCounters() async {
    final db = _db;
    if (db == null) return;
    await db.collection('system_config').doc('api_keys').set({
      'google_calls': 0,
      'mapbox_calls': 0,
      'last_synced_month': ApiKeysConfig.currentUtcMonthKey(),
      'updatedAt': FieldValue.serverTimestamp(),
    }, SetOptions(merge: true));
  }

  /// Increments the live monthly usage counter (`google_calls` or
  /// `mapbox_calls`) in `system_config/api_keys` via the `recordMapUsage`
  /// Cloud Function. Degrades silently when Firebase is unavailable.
  Future<void> recordMapUsage(String provider, {int delta = 1}) async {
    try {
      final normalized =
          provider.trim().toLowerCase() == 'mapbox' ? 'mapbox' : 'google';
      await FirebaseFunctions.instance
          .httpsCallable('recordMapUsage')
          .call({'provider': normalized, 'delta': delta});
    } catch (e) {
      if (kDebugMode) {
        debugPrint('ApiKeysService.recordMapUsage skipped: $e');
      }
    }
  }
}
