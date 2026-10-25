import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart';
import 'package:sese_core/sese_core.dart';

export 'package:sese_core/sese_core.dart' show DispatchTuning;

/// Service managing dynamic system configurations in Firestore under `system_configs/{configId}`.
/// Aligned with firestore.rules:
/// `match /system_configs/{configId} { allow read: if isAuthenticated(); allow write: if isSuperAdmin(); }`
class SystemConfigService {
  final FirebaseFirestore? _firestore;

  // In-memory cache & fallback when running in development/stub mode
  static final Map<String, RegionConfig> _localCache = {
    'global_default': RegionConfig.globalDefault(),
    'country_NG': RegionConfig(
      id: 'country_NG',
      countryCode: 'NG',
      stateOrRegion: '',
      currencyCode: 'NGN',
      currencySymbol: '₦',
      pricingRates: {
        VehicleCategory.bicycle: const VehiclePricingRate(
          baseFee: 350.0,
          distanceRatePerKm: 90.0,
          timeRatePerMinute: 12.0,
        ),
        VehicleCategory.motorcycle: const VehiclePricingRate(
          baseFee: 450.0,
          distanceRatePerKm: 130.0,
          timeRatePerMinute: 16.0,
        ),
        VehicleCategory.tricycle: const VehiclePricingRate(
          baseFee: 500.0,
          distanceRatePerKm: 140.0,
          timeRatePerMinute: 20.0,
        ),
        VehicleCategory.car: const VehiclePricingRate(
          baseFee: 700.0,
          distanceRatePerKm: 200.0,
          timeRatePerMinute: 30.0,
        ),
        VehicleCategory.van: const VehiclePricingRate(
          baseFee: 1400.0,
          distanceRatePerKm: 350.0,
          timeRatePerMinute: 45.0,
        ),
        VehicleCategory.truck: const VehiclePricingRate(
          baseFee: 3000.0,
          distanceRatePerKm: 550.0,
          timeRatePerMinute: 70.0,
        ),
      },
      carTierThresholds: const CarTierThresholds(),
      streakRewards: const StreakRewardConfig(),
      updatedAt: DateTime.now(),
    ),
    'state_NG_LAGOS': RegionConfig(
      id: 'state_NG_LAGOS',
      countryCode: 'NG',
      stateOrRegion: 'Lagos',
      currencyCode: 'NGN',
      currencySymbol: '₦',
      regionalSurgeMultiplier: 1.20,
      pricingRates: {
        VehicleCategory.car: const VehiclePricingRate(
          baseFee: 1000.0,
          distanceRatePerKm: 250.0,
          timeRatePerMinute: 40.0,
        ),
      },
      carTierThresholds: const CarTierThresholds(
        comfortMultiplier: 1.0,
        premiumMultiplier: 1.4,
        luxeMultiplier: 1.85,
      ),
      streakRewards: const StreakRewardConfig(
        grandCompletionCashAward: 20000.0,
      ),
      updatedAt: DateTime.now(),
    ),
  };

  SystemConfigService([this._firestore]);

  CollectionReference<Map<String, dynamic>>? get _collection {
    try {
      return (_firestore ?? FirebaseFirestore.instance).collection('system_configs');
    } catch (_) {
      return null;
    }
  }

  /// Fetches all stored configuration documents from Firestore with fallback to local cache.
  Future<List<RegionConfig>> getAllConfigs() async {
    try {
      final col = _collection;
      if (col != null) {
        final snapshot = await col.get();
        if (snapshot.docs.isNotEmpty) {
          final configs = snapshot.docs.map((doc) {
            final data = doc.data();
            data['id'] = doc.id;
            return RegionConfig.fromMap(data);
          }).toList();

          // Update local cache with remote docs
          for (final c in configs) {
            _localCache[c.id] = c;
          }
          return configs;
        }
      }
    } catch (e) {
      debugPrint('Firestore read fallback to local cache: $e');
    }

    return _localCache.values.toList();
  }

  /// Saves or updates a RegionConfig in Firestore and updates local cache.
  Future<void> saveConfig(RegionConfig config) async {
    _localCache[config.id] = config;

    try {
      final col = _collection;
      if (col != null) {
        await col.doc(config.id).set(config.toMap(), SetOptions(merge: true));
        if (kDebugMode) debugPrint('Saved dynamic config ${config.id} to Firestore.');
      }
    } catch (e) {
      debugPrint('Error saving config to Firestore (cached locally): $e');
    }
  }

  /// Resolves the effective configuration for given country and optional state.
  Future<RegionConfig> resolveEffectiveConfig({
    required String countryCode,
    String? stateOrRegion,
  }) async {
    final all = await getAllConfigs();
    return ConfigResolutionEngine.resolveFromList(
      allConfigs: all,
      countryCode: countryCode,
      stateOrRegion: stateOrRegion,
    );
  }

  /// Fetches the maximum number of visible bids in the customer carousel from system_settings/dispatch.
  Future<int> getMaxVisibleBids() async {
    try {
      final doc = await (_firestore ?? FirebaseFirestore.instance)
          .collection('system_settings')
          .doc('dispatch')
          .get();
      if (doc.exists) {
        final data = doc.data();
        if (data != null && data['max_visible_bids'] is num) {
          return (data['max_visible_bids'] as num).toInt();
        }
      }
    } catch (e) {
      debugPrint('Error getting max_visible_bids, falling back to 5: $e');
    }
    return 5;
  }

  /// Saves the maximum number of visible bids to system_settings/dispatch.
  Future<void> saveMaxVisibleBids(int maxBids) async {
    try {
      await (_firestore ?? FirebaseFirestore.instance)
          .collection('system_settings')
          .doc('dispatch')
          .set({
        'max_visible_bids': maxBids,
        'updatedAt': FieldValue.serverTimestamp(),
      }, SetOptions(merge: true));
    } catch (e) {
      debugPrint('Error saving max_visible_bids: $e');
    }
  }

  /// Fetches the live dispatch engine tunables from
  /// system_settings/dispatch (Super Admin Dispatch Console). Falls back
  /// to compiled defaults when Firestore is unavailable.
  Future<DispatchTuning> getDispatchTuning() async {
    try {
      final doc = await (_firestore ?? FirebaseFirestore.instance)
          .collection('system_settings')
          .doc('dispatch')
          .get();
      if (doc.exists && doc.data() != null) {
        return DispatchTuning.fromMap(doc.data());
      }
    } catch (e) {
      debugPrint('Error getting dispatch tuning, using defaults: $e');
    }
    return const DispatchTuning();
  }

  /// Saves dispatch engine tunables to system_settings/dispatch (merge).
  /// The backend picks them up within ~60s (tuning cache TTL) and clamps
  /// them into safe bands. NOTE: writes require Super Admin (or the
  /// system-settings scope) per firestore.rules.
  Future<void> saveDispatchTuning(DispatchTuning tuning) async {
    try {
      await (_firestore ?? FirebaseFirestore.instance)
          .collection('system_settings')
          .doc('dispatch')
          .set(
        {
          ...tuning.toMap(),
          'updatedAt': FieldValue.serverTimestamp(),
        },
        SetOptions(merge: true),
      );
    } catch (e) {
      debugPrint('Error saving dispatch tuning: $e');
      rethrow;
    }
  }

  /// Saves P2P transfer rules to system_config/wallet_rules.
  Future<void> saveP2pWalletRules(P2pWalletRules rules) async {
    try {
      await (_firestore ?? FirebaseFirestore.instance)
          .collection('system_config')
          .doc('wallet_rules')
          .set({
        ...rules.toMap(),
        'updatedAt': FieldValue.serverTimestamp(),
      }, SetOptions(merge: true));
    } catch (e) {
      debugPrint('Error saving P2P wallet rules: $e');
    }
  }

  /// Saves residual referral commission revenue settings to system_config/referral_settings.
  Future<void> saveReferralRevenueSettings(ReferralRevenueSettings settings) async {
    try {
      await (_firestore ?? FirebaseFirestore.instance)
          .collection('system_config')
          .doc('referral_settings')
          .set({
        ...settings.toMap(),
        'updatedAt': FieldValue.serverTimestamp(),
      }, SetOptions(merge: true));
    } catch (e) {
      debugPrint('Error saving referral revenue settings: $e');
    }
  }

  /// Stream dynamic awareness tooltips from `system_configs/awareness_tooltips`.
  Stream<Map<String, AwarenessTooltipItem>> streamAwarenessTooltips() {
    final col = _collection;
    if (col == null) return Stream.value(const {});
    return col.doc('awareness_tooltips').snapshots().map((snap) {
      if (!snap.exists || snap.data() == null) return {};
      final data = snap.data()!;
      final result = <String, AwarenessTooltipItem>{};
      data.forEach((k, v) {
        if (v is Map) {
          result[k] = AwarenessTooltipItem.fromMap(
              k, Map<String, dynamic>.from(v));
        }
      });
      return result;
    });
  }

  /// Update awareness tooltips in Firestore (`system_configs/awareness_tooltips`).
  Future<void> saveAwarenessTooltips(
      Map<String, AwarenessTooltipItem> tooltips) async {
    final col = _collection;
    if (col == null) return;
    final map = <String, dynamic>{};
    tooltips.forEach((k, v) => map[k] = v.toMap());
    await col.doc('awareness_tooltips').set(map, SetOptions(merge: true));
  }
}

class P2pWalletRules {
  final int minDriverTrips;
  final double maxP2pLimitNaira;
  final bool adminOverrideEnabled;

  const P2pWalletRules({
    this.minDriverTrips = 3,
    this.maxP2pLimitNaira = 20000.0,
    this.adminOverrideEnabled = true,
  });

  factory P2pWalletRules.fromMap(Map<String, dynamic>? map) {
    map ??= const {};
    int intOf(String k, int fb) => (map![k] is num) ? (map[k] as num).toInt() : fb;
    double doubleOf(String k, double fb) => (map![k] is num) ? (map[k] as num).toDouble() : fb;
    return P2pWalletRules(
      minDriverTrips: intOf('minDriverTrips', 3),
      maxP2pLimitNaira: doubleOf('maxP2pLimit', 20000.0),
      adminOverrideEnabled: map['adminOverrideEnabled'] != false,
    );
  }

  Map<String, dynamic> toMap() => {
    'minDriverTrips': minDriverTrips,
    'min_driver_trips': minDriverTrips,
    'maxP2pLimit': maxP2pLimitNaira,
    'max_p2p_limit': maxP2pLimitNaira,
    'adminOverrideEnabled': adminOverrideEnabled,
  };
}

class ReferralRevenueSettings {
  final double platformBaseCommissionRate;
  final double driverReferrerRate;
  final double customerReferrerRate;

  const ReferralRevenueSettings({
    this.platformBaseCommissionRate = 20.0,
    this.driverReferrerRate = 5.0,
    this.customerReferrerRate = 5.0,
  });

  factory ReferralRevenueSettings.fromMap(Map<String, dynamic>? map) {
    map ??= const {};
    double doubleOf(String k, double fb) => (map![k] is num) ? (map[k] as num).toDouble() : fb;
    return ReferralRevenueSettings(
      platformBaseCommissionRate: doubleOf('platformBaseCommissionRate', 20.0),
      driverReferrerRate: doubleOf('driverReferrerRate', 5.0),
      customerReferrerRate: doubleOf('customerReferrerRate', 5.0),
    );
  }

  Map<String, dynamic> toMap() => {
    'platformBaseCommissionRate': platformBaseCommissionRate,
    'driverReferrerRate': driverReferrerRate,
    'customerReferrerRate': customerReferrerRate,
  };
}
