import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart';

import '../maps/global_map_config.dart';

/// Dynamic Remote Keys & API Configuration stored in `/system_config/remote_keys`.
class RemoteKeysConfig {
  final String paystackPublicKey;
  final String paystackSecretKey;
  final String googleMapsApiKey;

  /// Mapbox public access token (`pk.eyJ1…`). Empty when not configured.
  final String mapboxToken;

  /// Mapbox style id for the raster endpoint (`mapbox/light-v11` default —
  /// Google-mimesis light aesthetic). Accepts `mapbox://styles/<user>/<id>`.
  final String mapboxStyle;

  /// Per-feature provider pins, keyed by [MapFeature.code]
  /// (`'auto'`/absent follows the global chain).
  final Map<String, String> featureProviders;

  final String exchangeRateApiKey;

  /// Active map provider: `'google'`, `'mapbox'`, or `'cartodb'`.
  /// Legacy `'open_street_map'` / `'osm'` values are normalised to `'cartodb'`.
  final String activeMapProvider;

  final String osmTileServerUrl;

  /// Hub manual provider override. `'auto'` or empty = normal fallback logic.
  final String manualOverrideProvider;

  final double minimumWalletTopUp; // in Naira (default 1300.0)
  final double withdrawalPayoutThreshold; // in Naira (default 20000.0)
  final bool appMaintenanceMode;
  final bool splitPaymentMasterEnabled;
  final bool forceDeliveryPinSystemWide;
  final double maxCashTripAmountNaira;
  final bool requireDriverCashVerification;
  final int driverBreakOption1Minutes;
  final int driverBreakOption2Minutes;
  final bool driverBreakEnabled;

  const RemoteKeysConfig({
    this.paystackPublicKey = 'pk_test_07354be9dc28e79ca4cb7d2cc4818d81ebfd696b',
    this.paystackSecretKey = 'sk_test_4e0edebfb09041155f816f2e8cff7cfb5bbfac98',
    this.googleMapsApiKey = GlobalMapConfig.defaultGoogleMapsApiKey,
    this.mapboxToken = '',
    this.mapboxStyle = GlobalMapConfig.defaultMapboxStyle,
    this.featureProviders = const {},
    this.exchangeRateApiKey = 'ex_live_79a2b8c3d4e5f6g7h8i9_sample',
    this.activeMapProvider = 'cartodb',
    this.osmTileServerUrl =
        'https://{s}.basemaps.cartocdn.com/rastertiles/voyager/{z}/{x}/{y}{r}.png',
    this.manualOverrideProvider = '',
    this.minimumWalletTopUp = 1300.0,
    this.withdrawalPayoutThreshold = 20000.0,
    this.appMaintenanceMode = false,
    this.splitPaymentMasterEnabled = true,
    this.forceDeliveryPinSystemWide = false,
    this.maxCashTripAmountNaira = 50000.0,
    this.requireDriverCashVerification = true,
    this.driverBreakOption1Minutes = 30,
    this.driverBreakOption2Minutes = 60,
    this.driverBreakEnabled = true,
  });

  factory RemoteKeysConfig.fromMap(Map<String, dynamic>? map) {
    if (map == null) return const RemoteKeysConfig();

    String pubKey = (map['paystackPublicKey'] ??
            map['paystack_public_key'] ??
            map['public_key'] ??
            '')
        .toString()
        .trim();
    if (pubKey.isEmpty || (!pubKey.startsWith('pk_test_') && !pubKey.startsWith('pk_live_'))) {
      pubKey = 'pk_test_07354be9dc28e79ca4cb7d2cc4818d81ebfd696b';
    }

    String secKey = (map['paystackSecretKey'] ??
            map['paystack_secret_key'] ??
            map['secret_key'] ??
            '')
        .toString()
        .trim();
    if (secKey.isEmpty || (!secKey.startsWith('sk_test_') && !secKey.startsWith('sk_live_'))) {
      secKey = 'sk_test_4e0edebfb09041155f816f2e8cff7cfb5bbfac98';
    }

    int intOf(dynamic v, int fallback) {
      if (v is num) return v.toInt();
      if (v is String) return int.tryParse(v) ?? fallback;
      return fallback;
    }

    final rawGoogleKey = (map['googleMapsApiKey'] ??
            map['google_maps_api_key'] ??
            map['mapApiKey'] ??
            map['apiKey'] ??
            map['api_key'] ??
            '')
        .toString()
        .trim();

    final rawMbToken = (map['mapboxToken'] ??
            map['mapbox_token'] ??
            map['mapboxApiKey'] ??
            map['mapbox_api_key'] ??
            '')
        .toString()
        .trim();

    final rawOverride = (map['manualOverrideProvider'] ??
            map['manual_override_provider'] ??
            map['providerOverride'] ??
            '')
        .toString()
        .trim();

    final rawStyle = (map['mapboxStyle'] ??
            map['mapbox_style'] ??
            map['mapboxStyleId'] ??
            '')
        .toString()
        .trim();

    final features = <String, String>{};
    final nested = map['featureProviders'];
    if (nested is Map) {
      for (final entry in nested.entries) {
        features[entry.key.toString()] = entry.value.toString();
      }
    }
    for (final f in MapFeature.values) {
      final flat = map['feature_${f.code}'];
      if (flat != null && flat.toString().trim().isNotEmpty) {
        features[f.code] = flat.toString();
      }
    }

    return RemoteKeysConfig(
      paystackPublicKey: pubKey,
      paystackSecretKey: secKey,
      googleMapsApiKey: rawGoogleKey.isNotEmpty
          ? rawGoogleKey
          : GlobalMapConfig.defaultGoogleMapsApiKey,
      mapboxToken: rawMbToken,
      mapboxStyle: rawStyle.isNotEmpty
          ? rawStyle
          : GlobalMapConfig.defaultMapboxStyle,
      featureProviders: features,
      exchangeRateApiKey: (map['exchangeRateApiKey'] ??
              map['exchange_rate_api_key'] ??
              'ex_live_79a2b8c3d4e5f6g7h8i9_sample')
          .toString()
          .trim(),
      activeMapProvider: (map['activeMapProvider'] ??
              map['active_map_provider'] ??
              map['activeProvider'] ??
              map['mapProvider'] ??
              'cartodb')
          .toString(),
      osmTileServerUrl: (() {
        final raw = (map['osmTileServerUrl'] ??
                map['osm_tile_server_url'] ??
                map['tileUrlTemplate'] ??
                map['tile_url_template'] ??
                '')
            .toString()
            .trim();
        return (raw.isNotEmpty && !raw.contains('light_all'))
            ? raw
            : 'https://{s}.basemaps.cartocdn.com/rastertiles/voyager/{z}/{x}/{y}{r}.png';
      })(),
      manualOverrideProvider: rawOverride,
      minimumWalletTopUp: (map['minimumWalletTopUp'] is num)
          ? (map['minimumWalletTopUp'] as num).toDouble()
          : 1300.0,
      withdrawalPayoutThreshold: (map['withdrawalPayoutThreshold'] is num)
          ? (map['withdrawalPayoutThreshold'] as num).toDouble()
          : 20000.0,
      appMaintenanceMode:
          map['appMaintenanceMode'] == true || map['app_maintenance_mode'] == true,
      splitPaymentMasterEnabled:
          map['splitPaymentMasterEnabled'] != false && map['split_payment_master_enabled'] != false,
      forceDeliveryPinSystemWide:
          map['forceDeliveryPinSystemWide'] == true || map['force_delivery_pin_system_wide'] == true,
      maxCashTripAmountNaira: (map['maxCashTripAmountNaira'] is num)
          ? (map['maxCashTripAmountNaira'] as num).toDouble()
          : 50000.0,
      requireDriverCashVerification:
          map['requireDriverCashVerification'] != false && map['require_driver_cash_verification'] != false,
      driverBreakOption1Minutes: intOf(
          map['driver_break_option_1_minutes'] ?? map['driverBreakOption1Minutes'],
          30),
      driverBreakOption2Minutes: intOf(
          map['driver_break_option_2_minutes'] ?? map['driverBreakOption2Minutes'],
          60),
      driverBreakEnabled: (map['driver_break_enabled'] ?? map['driverBreakEnabled']) != false,
    );
  }

  /// Converts this configuration to a [GlobalMapConfig] instance.
  GlobalMapConfig get globalMapConfig => GlobalMapConfig(
        activeProvider: activeMapProvider,
        apiKey: googleMapsApiKey.isNotEmpty ? googleMapsApiKey : null,
        mapboxToken: mapboxToken.isNotEmpty ? mapboxToken : null,
        mapboxStyle: mapboxStyle.isNotEmpty
            ? mapboxStyle
            : GlobalMapConfig.defaultMapboxStyle,
        tileUrlTemplate: osmTileServerUrl,
        manualOverrideProvider:
            manualOverrideProvider.isNotEmpty && manualOverrideProvider != 'auto'
                ? manualOverrideProvider
                : null,
        featureProviders: Map<String, String>.from(featureProviders),
      );

  Map<String, dynamic> toMap() {
    final mapCfg = globalMapConfig;
    return {
      'paystackPublicKey': paystackPublicKey.trim(),
      'paystack_public_key': paystackPublicKey.trim(),
      'paystackSecretKey': paystackSecretKey.trim(),
      'paystack_secret_key': paystackSecretKey.trim(),
      'googleMapsApiKey': googleMapsApiKey.trim(),
      'mapApiKey': googleMapsApiKey.trim(),
      'apiKey': googleMapsApiKey.trim(),
      'mapboxToken': mapboxToken.trim(),
      'mapbox_token': mapboxToken.trim(),
      'mapboxApiKey': mapboxToken.trim(),
      'mapboxStyle': mapboxStyle.trim(),
      'mapbox_style': mapboxStyle.trim(),
      'featureProviders': Map<String, String>.from(featureProviders),
      for (final f in MapFeature.values)
        if ((featureProviders[f.code] ?? '').isNotEmpty)
          'feature_${f.code}': featureProviders[f.code],
      'exchangeRateApiKey': exchangeRateApiKey.trim(),
      'activeMapProvider': activeMapProvider,
      'activeProvider': mapCfg.normalizedProvider,
      'osmTileServerUrl': osmTileServerUrl.trim(),
      'tileUrlTemplate': osmTileServerUrl.trim(),
      'manualOverrideProvider': manualOverrideProvider.trim(),
      'manual_override_provider': manualOverrideProvider.trim(),
      'minimumWalletTopUp': minimumWalletTopUp,
      'withdrawalPayoutThreshold': withdrawalPayoutThreshold,
      'appMaintenanceMode': appMaintenanceMode,
      'splitPaymentMasterEnabled': splitPaymentMasterEnabled,
      'forceDeliveryPinSystemWide': forceDeliveryPinSystemWide,
      'maxCashTripAmountNaira': maxCashTripAmountNaira,
      'requireDriverCashVerification': requireDriverCashVerification,
      'driver_break_option_1_minutes': driverBreakOption1Minutes,
      'driverBreakOption1Minutes': driverBreakOption1Minutes,
      'driver_break_option_2_minutes': driverBreakOption2Minutes,
      'driverBreakOption2Minutes': driverBreakOption2Minutes,
      'driver_break_enabled': driverBreakEnabled,
      'driverBreakEnabled': driverBreakEnabled,
      'updatedAt': FieldValue.serverTimestamp(),
    };
  }

}

/// Service that streams, fetches, and saves `/system_config/remote_keys`.
class RemoteKeysService {
  final FirebaseFirestore? firestore;

  const RemoteKeysService([this.firestore]);

  FirebaseFirestore? get _db {
    try {
      return firestore ?? FirebaseFirestore.instance;
    } catch (_) {
      return null;
    }
  }

  /// Live stream of `/system_config/remote_keys`.
  Stream<RemoteKeysConfig> streamRemoteKeys() {
    final db = _db;
    if (db == null) return Stream.value(const RemoteKeysConfig());
    return db
        .collection('system_config')
        .doc('remote_keys')
        .snapshots()
        .map((snap) => RemoteKeysConfig.fromMap(snap.data()))
        .handleError((Object _) => const RemoteKeysConfig());
  }

  /// Live real-time stream of the global map configuration.
  Stream<GlobalMapConfig> streamGlobalMapConfig() {
    return streamRemoteKeys().map((cfg) => cfg.globalMapConfig);
  }

  /// One-shot fetch of `/system_config/remote_keys`, falling back to `/system_config/global_default`
  /// and `/system_configs/global_default`.
  Future<RemoteKeysConfig> fetchRemoteKeys() async {
    try {
      final db = _db;
      if (db == null) return const RemoteKeysConfig();
      final snap = await db.collection('system_config').doc('remote_keys').get();
      if (snap.exists && snap.data() != null) {
        return RemoteKeysConfig.fromMap(snap.data());
      }
      final globalSnap = await db.collection('system_config').doc('global_default').get();
      if (globalSnap.exists && globalSnap.data() != null) {
        return RemoteKeysConfig.fromMap(globalSnap.data());
      }
      final altSnap = await db.collection('system_configs').doc('global_default').get();
      return RemoteKeysConfig.fromMap(altSnap.data());
    } catch (e) {
      debugPrint('RemoteKeysService.fetchRemoteKeys error: $e');
      return const RemoteKeysConfig();
    }
  }

  /// One-shot fetch of [GlobalMapConfig].
  Future<GlobalMapConfig> fetchGlobalMapConfig() async {
    final cfg = await fetchRemoteKeys();
    return cfg.globalMapConfig;
  }

  /// Saves remote keys configuration to `/system_config/remote_keys` and mirrors
  /// to both `/system_config/global_default` and `/system_configs/global_default`
  /// to prevent target document mismatch across hub and services.
  Future<void> saveRemoteKeys(RemoteKeysConfig config) async {
    final db = _db;
    if (db == null) return;
    final data = config.toMap();
    await db
        .collection('system_config')
        .doc('remote_keys')
        .set(data, SetOptions(merge: true));
    try {
      await db
          .collection('system_config')
          .doc('global_default')
          .set(data, SetOptions(merge: true));
    } catch (e) {
      debugPrint('RemoteKeysService.saveRemoteKeys system_config mirror warning: $e');
    }
    try {
      await db
          .collection('system_configs')
          .doc('global_default')
          .set(data, SetOptions(merge: true));
    } catch (e) {
      debugPrint('RemoteKeysService.saveRemoteKeys system_configs mirror warning: $e');
    }
  }
}
