import '../maps/global_map_config.dart';

/// Dynamic Map & API Key credentials configuration model stored in Firestore
/// under document `system_config/api_keys`.
///
/// Drives platform-specific map credential injection on app launch across
/// customer and driver applications.
class ApiKeysConfig {
  /// Active map provider code: `'google'` or `'mapbox'`.
  final String activeMapProvider;

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
    this.googleAndroidKey = GlobalMapConfig.defaultGoogleMapsApiKey,
    this.googleIosKey = '',
    this.googleWebKey = '',
    this.mapboxAndroidToken = '',
    this.mapboxIosToken = '',
    this.mapboxWebToken = '',
  });

  /// Canonical normalized provider code: `'google'` or `'mapbox'`.
  String get normalizedProvider {
    final lower = activeMapProvider.trim().toLowerCase();
    if (lower == 'mapbox') return 'mapbox';
    return 'google';
  }

  bool get isGoogle => normalizedProvider == 'google';
  bool get isMapbox => normalizedProvider == 'mapbox';

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
      googleAndroidKey: gAndroid.isNotEmpty
          ? gAndroid
          : GlobalMapConfig.defaultGoogleMapsApiKey,
      googleIosKey: gIos,
      googleWebKey: gWeb,
      mapboxAndroidToken: mAndroid,
      mapboxIosToken: mIos,
      mapboxWebToken: mWeb,
    );
  }

  Map<String, dynamic> toMap() => {
        'active_map_provider': normalizedProvider,
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
    String? googleAndroidKey,
    String? googleIosKey,
    String? googleWebKey,
    String? mapboxAndroidToken,
    String? mapboxIosToken,
    String? mapboxWebToken,
  }) {
    return ApiKeysConfig(
      activeMapProvider: activeMapProvider ?? this.activeMapProvider,
      googleAndroidKey: googleAndroidKey ?? this.googleAndroidKey,
      googleIosKey: googleIosKey ?? this.googleIosKey,
      googleWebKey: googleWebKey ?? this.googleWebKey,
      mapboxAndroidToken: mapboxAndroidToken ?? this.mapboxAndroidToken,
      mapboxIosToken: mapboxIosToken ?? this.mapboxIosToken,
      mapboxWebToken: mapboxWebToken ?? this.mapboxWebToken,
    );
  }
}
