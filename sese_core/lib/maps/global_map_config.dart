/// Defines the global map rendering configuration dynamically managed
/// from `sese_hub` and broadcast via Firestore `/system_config/remote_keys`.
library;

/// Supported map providers — in fallback order:
/// **Google Maps (free tier) → Mapbox (free-tier buffer) → Google Maps (pay-as-you-go)**.
///
/// Legacy providers (`cartodb`, `osm`, `open_street_map`) are fully deprecated;
/// any persisted value with those codes is silently promoted to `google` or `mapbox`.
enum MapProviderType {
  google('google', 'Google Maps'),
  mapbox('mapbox', 'Mapbox');

  final String code;
  final String displayName;

  const MapProviderType(this.code, this.displayName);

  /// Parses a Firestore-persisted provider code, including legacy aliases.
  ///
  /// `null`, unknown, or legacy codes resolve to [google] (default primary).
  static MapProviderType fromCode(String? raw) {
    if (raw == null) return MapProviderType.google;
    final normalized = raw.trim().toLowerCase();
    if (normalized == 'google' || normalized == 'google_maps' || normalized.isEmpty) {
      return MapProviderType.google;
    }
    if (normalized == 'mapbox') {
      return MapProviderType.mapbox;
    }
    // Legacy / deprecated values → Google (default primary).
    return MapProviderType.google;
  }
}

/// Map-dependent feature areas, each independently assignable to a provider
/// from the Hub (or left on `'auto'` to follow the global provider chain).
///
/// - [geocoding]: address search / autocomplete / reverse-geocode backend.
/// - [navigation]: driver turn-by-turn cockpit tile engine.
/// - [tracking]: customer-to-driver live-tracking tile engine.
/// - [routing]: backend trip distance & ETA engine (Directions provider).
enum MapFeature {
  geocoding('geocoding', 'Address Searching / Geocoding'),
  navigation('navigation', 'Driver Turn-by-Turn Navigation'),
  tracking('tracking', 'Customer Live Tracking'),
  routing('routing', 'Backend Distance & ETA');

  final String code;
  final String displayName;

  const MapFeature(this.code, this.displayName);

  static MapFeature fromCode(String? raw) {
    final normalized = (raw ?? '').trim().toLowerCase();
    for (final f in MapFeature.values) {
      if (f.code == normalized) return f;
    }
    return MapFeature.geocoding;
  }
}

/// Curated Mapbox styles supported across Dynamic Hub configuration and client rendering.
abstract final class MapboxStyles {
  /// Default Light mode style: high-contrast street geometry with turn labels.
  static const String streetsV12 = 'mapbox/streets-v12';

  /// Topographic and recreational terrain style.
  static const String outdoorsV12 = 'mapbox/outdoors-v12';

  /// Minimal clean light aesthetic.
  static const String lightV11 = 'mapbox/light-v11';

  /// Default Dark/Night mode style.
  static const String darkV11 = 'mapbox/dark-v11';

  /// High-visibility turn-by-turn driving style.
  static const String navigationDayV1 = 'mapbox/navigation-day-v1';

  /// All selectable styles for Hub configuration dropdown.
  static const List<String> availableStyles = [
    streetsV12,
    outdoorsV12,
    lightV11,
    darkV11,
    navigationDayV1,
  ];

  /// Human-readable labels for Hub admin UI.
  static const Map<String, String> styleLabels = {
    streetsV12: 'Streets (Default Light)',
    outdoorsV12: 'Outdoors',
    lightV11: 'Light (Minimal)',
    darkV11: 'Dark (Default Night)',
    navigationDayV1: 'Navigation Day',
  };
}

/// Global map configuration model stored in Firestore `/system_config/remote_keys`.
///
/// Drives map rendering across customer and driver apps in real-time.
/// Billing chain: **Google Maps (free tier) → Mapbox (free-tier buffer) →
/// Google Maps (pay-as-you-go)**. Resets automatically at the top of each
/// UTC calendar month.
///
/// Per-feature overrides ([featureProviders]) let Hub admins pin individual
/// feature areas to a provider; `'auto'` (or absent) follows the global
/// chain. Cold-start rule: tile surfaces snapshot this config when a trip
/// is active and never switch engines mid-trip.
class GlobalMapConfig {
  /// The active map provider code: `'google'` or `'mapbox'`.
  final String activeProvider;

  /// Primary API credential:
  /// • Google Maps — `AIzaSy…` key (used for both free-tier and pay-as-you-go)
  ///
  /// For Mapbox, prefer [mapboxToken]. If [mapboxToken] is absent and [apiKey]
  /// starts with `'pk.'`, it is used as the Mapbox token automatically.
  final String? apiKey;

  /// Mapbox public access token (`pk.eyJ1…`), stored separately from [apiKey].
  /// When set, this takes precedence over [apiKey] for the Mapbox provider.
  final String? mapboxToken;

  /// Manual provider override managed from the Hub.
  ///
  /// When non-null and non-empty, forces the given provider regardless of
  /// [activeProvider]. Supports circuit-breaker resets and A/B testing.
  /// `'auto'` means no override (normal auto-fallback logic applies).
  final String? manualOverrideProvider;

  /// Per-feature provider pins, keyed by [MapFeature.code], valued by
  /// provider code (`'google'` / `'mapbox'`) or `'auto'`.
  /// Absent/unknown entries resolve to `'auto'`. Never null — an empty map
  /// means every feature follows the global billing chain.
  final Map<String, String> featureProviders;

  /// Mapbox style for the raster tile endpoint.
  final String mapboxStyle;

  /// Configurable monthly request/usage caps for each provider.
  final int googleMonthlyCap;
  final int mapboxMonthlyCap;

  /// Default fallback Google Maps API key passed via compile-time environment `--dart-define`.
  static const String defaultGoogleMapsApiKey = String.fromEnvironment('GOOGLE_MAPS_API_KEY');

  /// Default Mapbox style: streets light theme (see [mapboxStyle]).
  static const String defaultMapboxStyle = MapboxStyles.streetsV12;

  /// Default Mapbox dark theme for night / dark mode.
  static const String defaultDarkMapboxStyle = MapboxStyles.darkV11;

  const GlobalMapConfig({
    this.activeProvider = 'google',
    this.apiKey = defaultGoogleMapsApiKey,
    this.mapboxToken,
    this.manualOverrideProvider,
    this.featureProviders = const {},
    this.mapboxStyle = defaultMapboxStyle,
    this.googleMonthlyCap = 20000,
    this.mapboxMonthlyCap = 50000,
  });

  // ── Normalised provider resolution ────────────────────────────────────────

  /// Canonical normalized provider name: `'google'` or `'mapbox'`.
  ///
  /// Applies [manualOverrideProvider] first (unless `'auto'`), then falls back
  /// to the configured [activeProvider]. Legacy codes are promoted to `'google'`.
  String get normalizedProvider {
    final override = manualOverrideProvider?.trim().toLowerCase();
    if (override != null && override.isNotEmpty && override != 'auto') {
      if (override == 'google' || override == 'google_maps') return 'google';
      if (override == 'mapbox') return 'mapbox';
      return 'google';
    }
    final lower = activeProvider.trim().toLowerCase();
    if (lower == 'google_maps' || lower == 'google') return 'google';
    if (lower == 'mapbox') return 'mapbox';
    return 'google';
  }

  MapProviderType get providerType => MapProviderType.fromCode(normalizedProvider);

  bool get isGoogle => normalizedProvider == 'google';
  bool get isMapbox => normalizedProvider == 'mapbox';

  /// Backwards-compat alias — always false now that OSM is deprecated.
  bool get isOsm => false;

  // ── Per-feature provider resolution ──────────────────────────────────────

  /// Raw pin for [feature]: a provider code or `'auto'`. Unknown/absent
  /// entries resolve to `'auto'`.
  String featureProviderRaw(MapFeature feature) {
    final raw = (featureProviders[feature.code] ?? 'auto').trim().toLowerCase();
    if (raw == 'google' || raw == 'google_maps') return 'google';
    if (raw == 'mapbox') return 'mapbox';
    return 'auto';
  }

  /// Effective provider for [feature]: the explicit pin, or `'auto'` to
  /// follow [normalizedProvider].
  String providerFor(MapFeature feature) {
    final pinned = featureProviderRaw(feature);
    return pinned == 'auto' ? normalizedProvider : pinned;
  }

  /// [MapProviderType] for [feature], honouring the pin-or-global rule.
  MapProviderType providerTypeFor(MapFeature feature) =>
      MapProviderType.fromCode(providerFor(feature));

  // ── Mapbox credential helpers ──────────────────────────────────────────────

  /// True when a valid Mapbox access token is available.
  bool get hasValidMapboxToken {
    if (mapboxToken != null && mapboxToken!.trim().isNotEmpty) return true;
    if (apiKey != null && apiKey!.trim().startsWith('pk.')) return true;
    return false;
  }

  /// The resolved Mapbox access token. Prefers [mapboxToken]; falls back to
  /// [apiKey] when it looks like a Mapbox token (`pk.` prefix).
  String? get resolvedMapboxToken {
    if (mapboxToken != null && mapboxToken!.trim().isNotEmpty) {
      return mapboxToken!.trim();
    }
    if (apiKey != null && apiKey!.trim().startsWith('pk.')) {
      return apiKey!.trim();
    }
    return null;
  }

  // ── General credential helpers ─────────────────────────────────────────────

  /// True when the selected provider requires an API key / token.
  bool get requiresApiKey => isGoogle || isMapbox;

  /// True when a non-empty API key is configured for the current provider.
  bool get hasValidApiKey =>
      (apiKey != null && apiKey!.trim().isNotEmpty) ||
      defaultGoogleMapsApiKey.isNotEmpty;

  // ── Tile URL resolution ────────────────────────────────────────────────────

  /// Normalizes [mapboxStyle] to a `styles/v1/<user>/<style>` path.
  String get normalizedMapboxStyle {
    var style = mapboxStyle.trim();
    if (style.startsWith('mapbox://styles/')) {
      style = style.substring('mapbox://styles/'.length);
    }
    if (!style.contains('/')) {
      style = 'mapbox/$style';
    }
    return style.isEmpty ? 'mapbox/light-v11' : style;
  }

  /// Resolves the Mapbox raster tile URL for use with `flutter_map`'s `TileLayer`.
  String resolveMapboxTileUrl({bool isDark = false}) {
    final token = resolvedMapboxToken ?? '';
    final style = normalizedMapboxStyle;
    final String effectiveStyle;
    if (isDark) {
      effectiveStyle = style == MapboxStyles.darkV11 ? style : MapboxStyles.darkV11;
    } else {
      effectiveStyle = style == MapboxStyles.darkV11 ? MapboxStyles.streetsV12 : style;
    }
    return 'https://api.mapbox.com/styles/v1/$effectiveStyle/tiles/256/{z}/{x}/{y}{r}?access_token=$token';
  }

  /// Resolves tile URL for raster tile surfaces (Mapbox).
  String resolveTileUrl({bool isDark = false}) {
    return resolveMapboxTileUrl(isDark: isDark);
  }

  // ── Serialisation ──────────────────────────────────────────────────────────

  factory GlobalMapConfig.fromMap(Map<String, dynamic>? map) {
    if (map == null) return const GlobalMapConfig();

    final provider = (map['activeProvider'] ??
            map['activeMapProvider'] ??
            map['active_map_provider'] ??
            map['mapProvider'] ??
            'google')
        .toString();

    final key = (map['apiKey'] ??
            map['googleMapsApiKey'] ??
            map['mapApiKey'] ??
            map['google_maps_api_key'] ??
            map['api_key'])
        ?.toString()
        .trim();

    final mbToken = (map['mapboxToken'] ??
            map['mapbox_token'] ??
            map['mapboxApiKey'] ??
            map['mapbox_api_key'])
        ?.toString()
        .trim();

    final override = (map['manualOverrideProvider'] ??
            map['manual_override_provider'] ??
            map['providerOverride'])
        ?.toString()
        .trim();

    final style = (map['mapboxStyle'] ??
            map['mapbox_style'] ??
            map['mapboxStyleId'])
        ?.toString()
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

    final gCap = (map['googleMonthlyCap'] ?? map['googleQuotaCap']) as num?;
    final mCap = (map['mapboxMonthlyCap'] ?? map['mapboxQuotaCap']) as num?;

    return GlobalMapConfig(
      activeProvider: provider,
      apiKey: (key != null && key.isNotEmpty) ? key : defaultGoogleMapsApiKey,
      mapboxToken: (mbToken != null && mbToken.isNotEmpty) ? mbToken : null,
      manualOverrideProvider:
          (override != null && override.isNotEmpty && override != 'auto')
              ? override
              : null,
      featureProviders: features,
      mapboxStyle: (style != null && style.isNotEmpty)
          ? style
          : defaultMapboxStyle,
      googleMonthlyCap: gCap?.toInt() ?? 20000,
      mapboxMonthlyCap: mCap?.toInt() ?? 50000,
    );
  }

  Map<String, dynamic> toMap() {
    final cleanKey = (apiKey ?? '').trim();
    final cleanMbToken = (mapboxToken ?? '').trim();
    return {
      'activeProvider': normalizedProvider,
      'activeMapProvider': normalizedProvider,
      'apiKey': cleanKey,
      'googleMapsApiKey': cleanKey,
      'mapApiKey': cleanKey,
      'mapboxToken': cleanMbToken,
      'mapbox_token': cleanMbToken,
      'mapboxApiKey': cleanMbToken,
      'mapboxStyle': mapboxStyle.trim(),
      'featureProviders': Map<String, String>.from(featureProviders),
      'googleMonthlyCap': googleMonthlyCap,
      'mapboxMonthlyCap': mapboxMonthlyCap,
      for (final f in MapFeature.values)
        if ((featureProviders[f.code] ?? '').isNotEmpty)
          'feature_${f.code}': featureProviders[f.code],
      if (manualOverrideProvider != null)
        'manualOverrideProvider': manualOverrideProvider,
    };
  }

  GlobalMapConfig copyWith({
    String? activeProvider,
    String? apiKey,
    String? mapboxToken,
    String? manualOverrideProvider,
    Map<String, String>? featureProviders,
    String? mapboxStyle,
    int? googleMonthlyCap,
    int? mapboxMonthlyCap,
  }) {
    return GlobalMapConfig(
      activeProvider: activeProvider ?? this.activeProvider,
      apiKey: apiKey ?? this.apiKey,
      mapboxToken: mapboxToken ?? this.mapboxToken,
      manualOverrideProvider:
          manualOverrideProvider ?? this.manualOverrideProvider,
      featureProviders: featureProviders ?? this.featureProviders,
      mapboxStyle: mapboxStyle ?? this.mapboxStyle,
      googleMonthlyCap: googleMonthlyCap ?? this.googleMonthlyCap,
      mapboxMonthlyCap: mapboxMonthlyCap ?? this.mapboxMonthlyCap,
    );
  }
}
