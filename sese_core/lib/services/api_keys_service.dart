import 'package:cloud_firestore/cloud_firestore.dart';
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
    try {
      final db = _db;
      if (db == null) return const ApiKeysConfig();
      final snap = await db
          .collection('system_config')
          .doc('api_keys')
          .get()
          .timeout(const Duration(seconds: 4));
      if (snap.exists && snap.data() != null) {
        return ApiKeysConfig.fromMap(snap.data());
      }
      return const ApiKeysConfig();
    } catch (e) {
      debugPrint('ApiKeysService.fetchApiKeys error: $e');
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
}
