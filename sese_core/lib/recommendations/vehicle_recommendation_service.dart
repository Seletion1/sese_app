import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart';

import 'vehicle_recommendation_config.dart';

/// Reads/writes the recommendation thresholds at
/// `system_configs/vehicle_recommendations`.
///
/// Mirrors [FinancialConfigService]: readable by any authenticated app (per
/// firestore.rules `system_configs/{configId}`); writable only by Super
/// Admins. All readers fall back to [VehicleRecommendationConfig] compiled
/// defaults on error/offline, so the dispatch UI keeps working with sane
/// recommendations when the document is missing.
class VehicleRecommendationService {
  static const String docId = 'vehicle_recommendations';

  final FirebaseFirestore? _firestore;

  const VehicleRecommendationService([this._firestore]);

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
  Future<VehicleRecommendationConfig> getConfig() async {
    try {
      final snap = await _doc?.get();
      if (snap != null && snap.exists && snap.data() != null) {
        return VehicleRecommendationConfig.fromMap(snap.data());
      }
    } catch (e) {
      debugPrint('VehicleRecommendationService.getConfig fallback: $e');
    }
    return const VehicleRecommendationConfig();
  }

  /// Live stream with safe defaults on error.
  Stream<VehicleRecommendationConfig> configStream() {
    final doc = _doc;
    if (doc == null) {
      return Stream.value(const VehicleRecommendationConfig());
    }
    return doc.snapshots().map((snap) {
      if (!snap.exists || snap.data() == null) {
        return const VehicleRecommendationConfig();
      }
      return VehicleRecommendationConfig.fromMap(snap.data());
    }).handleError((Object _) => const VehicleRecommendationConfig());
  }

  /// Super Admin write (merge). Throws on permission/network failure so the
  /// Hub UI can surface the error.
  Future<void> saveConfig(VehicleRecommendationConfig config) async {
    final doc = _doc;
    if (doc == null) throw StateError('Firestore is unavailable.');
    await doc.set(config.toMap(), SetOptions(merge: true));
  }
}
