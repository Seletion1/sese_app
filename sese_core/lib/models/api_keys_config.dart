import 'package:flutter/foundation.dart';

/// Dynamic Map & API Key credentials, caps, and live usage counters stored
/// in Firestore under document `system_config/api_keys`.
///
/// Drives platform-specific map credential injection on app launch across
/// customer and driver applications, as well as live usage tracking and
/// automatic cap-based fallback from Google Maps to Mapbox.
class ApiKeysConfig {
  static const int defaultGoogleMonthlyCap = 20000;
  static const int defaultMapboxMonthlyCap = 50000;

  /// Active map provider code: `'google'` or `'mapbox'`.
  final String activeMapProvider;

  /// Whether client apps automatically fall back to Mapbox when
  /// [effectiveGoogleCalls] reaches [googleMonthlyCap].
  final bool autoFallback;

  /// Monthly call caps configured in SeseHub.
  final int googleMonthlyCap;
  final int mapboxMonthlyCap;

  /// Live monthly usage counters persisted in `system_config/api_keys`.
  final int googleCalls;
  final int mapboxCalls;

  /// UTC calendar month (`YYYY-MM`) corresponding to [googleCalls] and
  /// [mapboxCalls]. Counters automatically roll over to `0` on a new month.
  final String lastSyncedMonth;

  /// Google Maps Platform API keys by platform.
  final String googleAndroidKey;
  final String googleIosKey;
  final String googleWebKey;

  /// Mapbox public access tokens by platform (`pk.eyJ1…`).
  final String mapboxAndroidToken;
  final String mapboxIosToken;
  final String mapboxWebToken;

  const ApiKeysConfig({
    this.activeMapProvider = 'google',
    this.autoFallback = true,
    this.googleMonthlyCap = defaultGoogleMonthlyCap,
    this.mapboxMonthlyCap = defaultMapboxMonthlyCap,
    this.googleCalls = 0,
    this.mapboxCalls = 0,
    this.lastSyncedMonth = '',
    this.googleAndroidKey = '',
    this.googleIosKey = '',
    this.googleWebKey = '',
    this.mapboxAndroidToken = '',
    this.mapboxIosToken = '',
    this.mapboxWebToken = '',
  });

  /// Current UTC calendar month key (`YYYY-MM`).
  static String currentUtcMonthKey([DateTime? now]) {
    final dt = (now ?? DateTime.now()).toUtc();
    final m = dt.month.toString().padLeft(2, '0');
    return '${dt.year}-$m';
  }

  /// Canonical normalized provider code: `'google'` or `'mapbox'`.
  String get normalizedProvider {
    final lower = activeMapProvider.trim().toLowerCase();
    if (lower == 'mapbox') return 'mapbox';
    return 'google';
  }

  bool get isGoogle => normalizedProvider == 'google';
  bool get isMapbox => normalizedProvider == 'mapbox';

  /// Effective Google call count for the current UTC month.
  int get effectiveGoogleCalls =>
      lastSyncedMonth == currentUtcMonthKey() ? googleCalls : 0;

  /// Effective Mapbox call count for the current UTC month.
  int get effectiveMapboxCalls =>
      lastSyncedMonth == currentUtcMonthKey() ? mapboxCalls : 0;

  /// True when [autoFallback] is enabled and Google Maps usage has reached
  /// [googleMonthlyCap].
  bool get isGoogleCapReached =>
      autoFallback &&
      googleMonthlyCap > 0 &&
      effectiveGoogleCalls >= googleMonthlyCap;

  /// Effective provider after applying [isGoogleCapReached] auto-fallback.
  String get effectiveProvider => isGoogleCapReached ? 'mapbox' : normalizedProvider;

  /// Returns the Google Maps API key matching the current platform.
  String googleKeyForPlatform(TargetPlatform platform, {bool isWeb = kIsWeb}) {
    if (isWeb) return googleWebKey.trim();
    if (platform == TargetPlatform.iOS) return googleIosKey.trim();
    if (platform == TargetPlatform.android) return googleAndroidKey.trim();
    return googleWebKey.trim();
  }

  /// Returns the Mapbox access token matching the current platform.
  String mapboxTokenForPlatform(TargetPlatform platform, {bool isWeb = kIsWeb}) {
    if (isWeb) return mapboxWebToken.trim();
    if (platform == TargetPlatform.iOS) return mapboxIosToken.trim();
    if (platform == TargetPlatform.android) return mapboxAndroidToken.trim();
    return mapboxWebToken.trim();
  }

  static int _intOf(dynamic v, int fallback) {
    if (v is int) return v >= 0 ? v : fallback;
    if (v is num) return v >= 0 ? v.toInt() : fallback;
    if (v is String) {
      final parsed = int.tryParse(v.trim());
      if (parsed != null && parsed >= 0) return parsed;
    }
    return fallback;
  }

  factory ApiKeysConfig.fromMap(Map<String, dynamic>? map) {
    if (map == null) return const ApiKeysConfig();

    final googleMap = map['google_maps'] is Map
        ? Map<String, dynamic>.from(map['google_maps'] as Map)
        : <String, dynamic>{};
    final mapboxMap = map['mapbox'] is Map
        ? Map<String, dynamic>.from(map['mapbox'] as Map)
        : <String, dynamic>{};

    final provider = (map['active_map_provider'] ??
            map['activeMapProvider'] ??
            map['activeProvider'] ??
            'google')
        .toString()
        .trim();

    final rawAutoFallback = map['auto_fallback'] ?? map['autoFallback'];
    final autoFallback = rawAutoFallback is bool ? rawAutoFallback : true;

    final gCap = _intOf(
      map['google_monthly_cap'] ?? map['googleMonthlyCap'],
      defaultGoogleMonthlyCap,
    );
    final mCap = _intOf(
      map['mapbox_monthly_cap'] ?? map['mapboxMonthlyCap'],
      defaultMapboxMonthlyCap,
    );
    final gCalls = _intOf(
      map['google_calls'] ?? map['googleCalls'],
      0,
    );
    final mCalls = _intOf(
      map['mapbox_calls'] ?? map['mapboxCalls'],
      0,
    );
    final lastMonth = (map['last_synced_month'] ??
            map['lastSyncedMonth'] ??
            '')
        .toString()
        .trim();

    final gAndroid = (googleMap['android_key'] ??
            googleMap['androidKey'] ??
            map['googleMapsAndroidKey'] ??
            '')
        .toString()
        .trim();

    final gIos = (googleMap['ios_key'] ??
            googleMap['iosKey'] ??
            map['googleMapsIosKey'] ??
            '')
        .toString()
        .trim();

    final gWeb = (googleMap['web_key'] ??
            googleMap['webKey'] ??
            map['googleMapsWebKey'] ??
            '')
        .toString()
        .trim();

    final mAndroid = (mapboxMap['android_token'] ??
            mapboxMap['androidToken'] ??
            map['mapboxAndroidToken'] ??
            '')
        .toString()
        .trim();

    final mIos = (mapboxMap['ios_token'] ??
            mapboxMap['iosToken'] ??
            map['mapboxIosToken'] ??
            '')
        .toString()
        .trim();

    final mWeb = (mapboxMap['web_token'] ??
            mapboxMap['webToken'] ??
            map['mapboxWebToken'] ??
            '')
        .toString()
        .trim();

    return ApiKeysConfig(
      activeMapProvider: provider,
      autoFallback: autoFallback,
      googleMonthlyCap: gCap,
      mapboxMonthlyCap: mCap,
      googleCalls: gCalls,
      mapboxCalls: mCalls,
      lastSyncedMonth: lastMonth,
      googleAndroidKey: gAndroid,
      googleIosKey: gIos,
      googleWebKey: gWeb,
      mapboxAndroidToken: mAndroid,
      mapboxIosToken: mIos,
      mapboxWebToken: mWeb,
    );
  }

  /// Serializes editable configuration fields (omits live counters so admin
  /// config saves never overwrite concurrent client usage increments).
  Map<String, dynamic> toMap() => {
        'active_map_provider': normalizedProvider,
        'auto_fallback': autoFallback,
        'google_monthly_cap': googleMonthlyCap,
        'mapbox_monthly_cap': mapboxMonthlyCap,
        'google_maps': {
          'android_key': googleAndroidKey.trim(),
          'ios_key': googleIosKey.trim(),
          'web_key': googleWebKey.trim(),
        },
        'mapbox': {
          'android_token': mapboxAndroidToken.trim(),
          'ios_token': mapboxIosToken.trim(),
          'web_token': mapboxWebToken.trim(),
        },
      };

  ApiKeysConfig copyWith({
    String? activeMapProvider,
    bool? autoFallback,
    int? googleMonthlyCap,
    int? mapboxMonthlyCap,
    int? googleCalls,
    int? mapboxCalls,
    String? lastSyncedMonth,
    String? googleAndroidKey,
    String? googleIosKey,
    String? googleWebKey,
    String? mapboxAndroidToken,
    String? mapboxIosToken,
    String? mapboxWebToken,
  }) {
    return ApiKeysConfig(
      activeMapProvider: activeMapProvider ?? this.activeMapProvider,
      autoFallback: autoFallback ?? this.autoFallback,
      googleMonthlyCap: googleMonthlyCap ?? this.googleMonthlyCap,
      mapboxMonthlyCap: mapboxMonthlyCap ?? this.mapboxMonthlyCap,
      googleCalls: googleCalls ?? this.googleCalls,
      mapboxCalls: mapboxCalls ?? this.mapboxCalls,
      lastSyncedMonth: lastSyncedMonth ?? this.lastSyncedMonth,
      googleAndroidKey: googleAndroidKey ?? this.googleAndroidKey,
      googleIosKey: googleIosKey ?? this.googleIosKey,
      googleWebKey: googleWebKey ?? this.googleWebKey,
      mapboxAndroidToken: mapboxAndroidToken ?? this.mapboxAndroidToken,
      mapboxIosToken: mapboxIosToken ?? this.mapboxIosToken,
      mapboxWebToken: mapboxWebToken ?? this.mapboxWebToken,
    );
  }
}
