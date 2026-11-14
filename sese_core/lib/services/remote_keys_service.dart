import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart';

import '../maps/global_map_config.dart';

/// Dynamic Remote Keys & API Configuration stored in `/system_config/remote_keys`.
///
/// SECURITY: Only PUBLIC/publishable credentials belong here.
class RemoteKeysConfig {
  final String paystackPublicKey;
  final String googleMapsApiKey;

  /// Mapbox public access token (`pk.eyJ1…`). Empty when not configured.
  final String mapboxToken;

  /// Mapbox style id for the raster endpoint (`mapbox/light-v11` default).
  final String mapboxStyle;

  /// Per-feature provider pins, keyed by [MapFeature.code]
  /// (`'auto'`/absent follows the global chain).
  final Map<String, String> featureProviders;

  final String exchangeRateApiKey;
  final String resendApiKey;

  /// Active map provider: `'google'` or `'mapbox'`.
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

  /// Maximum allowed driver drop-off completion radius in meters (default 500m).
  ///
  /// Outside this geofence, server-side completion requires remote customer
  /// out-of-range approval.
  final double dropoffCompletionRadiusMeters;

  final int googleMonthlyCap;
  final int mapboxMonthlyCap;

  const RemoteKeysConfig({
    this.paystackPublicKey = '',
    this.googleMapsApiKey = GlobalMapConfig.defaultGoogleMapsApiKey,
    this.mapboxToken = '',
    this.mapboxStyle = GlobalMapConfig.defaultMapboxStyle,
    this.featureProviders = const {},
    this.exchangeRateApiKey = '',
    this.resendApiKey = '',
    this.activeMapProvider = 'google',
    this.osmTileServerUrl = '',
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
    this.dropoffCompletionRadiusMeters = 500.0,
    this.googleMonthlyCap = 20000,
    this.mapboxMonthlyCap = 50000,
  });

  factory RemoteKeysConfig.fromMap(Map<String, dynamic>? map) {
    if (map == null) return const RemoteKeysConfig();

    String pubKey = (map['paystackPublicKey'] ??
            map['paystack_public_key'] ??
            map['public_key'] ??
            '')
        .toString()
        .trim();
    if (!pubKey.startsWith('pk_test_') && !pubKey.startsWith('pk_live_')) {
      pubKey = '';
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
              '')
          .toString()
          .trim(),
      resendApiKey: (map['resendApiKey'] ??
              map['resend_api_key'] ??
              map['resendKey'] ??
              '')
          .toString()
          .trim(),
      activeMapProvider: (map['activeMapProvider'] ??
              map['active_map_provider'] ??
              map['activeProvider'] ??
              map['mapProvider'] ??
              'google')
          .toString(),
      osmTileServerUrl: (map['osmTileServerUrl'] ??
              map['osm_tile_server_url'] ??
              map['tileUrlTemplate'] ??
              '')
          .toString()
          .trim(),
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
      dropoffCompletionRadiusMeters: (map['dropoffCompletionRadiusMeters'] is num)
          ? (map['dropoffCompletionRadiusMeters'] as num).toDouble()
          : ((map['dropoff_completion_radius_meters'] is num)
              ? (map['dropoff_completion_radius_meters'] as num).toDouble()
              : 500.0),
      googleMonthlyCap: intOf(map['googleMonthlyCap'] ?? map['googleQuotaCap'], 20000),
      mapboxMonthlyCap: intOf(map['mapboxMonthlyCap'] ?? map['mapboxQuotaCap'], 50000),
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
        manualOverrideProvider:
            manualOverrideProvider.isNotEmpty && manualOverrideProvider != 'auto'
                ? manualOverrideProvider
                : null,
        featureProviders: Map<String, String>.from(featureProviders),
        googleMonthlyCap: googleMonthlyCap,
        mapboxMonthlyCap: mapboxMonthlyCap,
      );

  Map<String, dynamic> toMap() {
    final mapCfg = globalMapConfig;
    return {
      'paystackPublicKey': paystackPublicKey.trim(),
      'paystack_public_key': paystackPublicKey.trim(),
      'googleMapsApiKey': googleMapsApiKey.trim(),
      'mapApiKey': googleMapsApiKey.trim(),
      'apiKey': googleMapsApiKey.trim(),
      'mapboxToken': mapboxToken.trim(),
      'mapbox_token': mapboxToken.trim(),
      'mapboxApiKey': mapboxToken.trim(),
      'mapboxStyle': mapboxStyle.trim(),
      'mapbox_style': mapboxStyle.trim(),
      'featureProviders': Map<String, String>.from(featureProviders),
      'googleMonthlyCap': googleMonthlyCap,
      'mapboxMonthlyCap': mapboxMonthlyCap,
      for (final f in MapFeature.values)
        if ((featureProviders[f.code] ?? '').isNotEmpty)
          'feature_${f.code}': featureProviders[f.code],
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
      'dropoffCompletionRadiusMeters': dropoffCompletionRadiusMeters,
      'dropoff_completion_radius_meters': dropoffCompletionRadiusMeters,
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

  Stream<RemoteKeysConfig> streamRemoteKeys() {
    final db = _db;
    if (db == null) return Stream.value(const RemoteKeysConfig());
    return db
        .collection('system_configs')
        .doc('global_default')
        .snapshots()
        .map((snap) => RemoteKeysConfig.fromMap(snap.data()))
        .handleError((Object error) {
      debugPrint('RemoteKeysService.streamRemoteKeys fallback warning: $error');
      return const RemoteKeysConfig();
    });
  }

  Stream<GlobalMapConfig> streamGlobalMapConfig() {
    return streamRemoteKeys().map((cfg) => cfg.globalMapConfig);
  }

  Future<RemoteKeysConfig> fetchRemoteKeys() async {
    try {
      final db = _db;
      if (db == null) return const RemoteKeysConfig();
      final altSnap = await db.collection('system_configs').doc('global_default').get();
      if (altSnap.exists && altSnap.data() != null) {
        return RemoteKeysConfig.fromMap(altSnap.data());
      }
      final snap = await db.collection('system_config').doc('remote_keys').get();
      if (snap.exists && snap.data() != null) {
        return RemoteKeysConfig.fromMap(snap.data());
      }
      final globalSnap = await db.collection('system_config').doc('global_default').get();
      if (globalSnap.exists && globalSnap.data() != null) {
        return RemoteKeysConfig.fromMap(globalSnap.data());
      }
      return const RemoteKeysConfig();
    } catch (e) {
      debugPrint('RemoteKeysService.fetchRemoteKeys error: $e');
      return const RemoteKeysConfig();
    }
  }

  Future<GlobalMapConfig> fetchGlobalMapConfig() async {
    final cfg = await fetchRemoteKeys();
    return cfg.globalMapConfig;
  }

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
