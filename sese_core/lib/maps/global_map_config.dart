/// Defines the global map rendering configuration dynamically managed
/// from `sese_hub` and broadcast via Firestore `/system_config/remote_keys`.
library;

/// Supported map providers — in fallback order: Google → Mapbox → CartoDB.
///
/// `osm` is fully deprecated; any persisted `'osm'` or `'open_street_map'`
/// code is silently promoted to `cartodb` (free CartoDB basemaps, no key
/// required) so existing deployments never go blank on upgrade.
enum MapProviderType {
  google('google', 'Google Maps'),
  mapbox('mapbox', 'Mapbox'),
  cartodb('cartodb', 'CartoDB');

  final String code;
  final String displayName;

  const MapProviderType(this.code, this.displayName);

  /// Parses a Firestore-persisted provider code, including legacy aliases.
  ///
  /// `null` / unknown / legacy `'osm'` / `'open_street_map'` all fall through
  /// to [cartodb] so the app always renders something visible.
  static MapProviderType fromCode(String? raw) {
    if (raw == null) return MapProviderType.cartodb;
    final normalized = raw.trim().toLowerCase();
    if (normalized == 'google' || normalized == 'google_maps') {
      return MapProviderType.google;
    }
    if (normalized == 'mapbox') {
      return MapProviderType.mapbox;
    }
    // cartodb, osm, open_street_map, and anything else → cartodb
    return MapProviderType.cartodb;
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
/// Provider fallback chain: **Google Maps → Mapbox → CartoDB**.
///
/// Per-feature overrides ([featureProviders]) let Hub admins pin individual
/// feature areas to a provider; `'auto'` (or absent) follows the global
/// chain. Cold-start rule: tile surfaces snapshot this config when a trip
/// is active and never switch engines mid-trip.
class GlobalMapConfig {
  /// The active map provider code: `'google'`, `'mapbox'`, or `'cartodb'`.
  /// Legacy aliases `'google_maps'`, `'osm'`, and `'open_street_map'` are
  /// normalised at read time.
  final String activeProvider;

  /// Primary API credential:
  /// • Google Maps — `AIzaSy…` key
  /// • CartoDB     — optional; free basemaps require no key
  ///
  /// For Mapbox, prefer [mapboxToken]. If [mapboxToken] is absent and [apiKey]
  /// starts with `'pk.'`, it is used as the Mapbox token automatically.
  final String? apiKey;

  /// Mapbox public access token (`pk.eyJ1…`), stored separately from [apiKey].
  /// When set, this takes precedence over [apiKey] for the Mapbox provider.
  final String? mapboxToken;

  /// Custom tile URL template for CartoDB or any other raster tile source.
  final String tileUrlTemplate;

  /// Manual provider override managed from the Hub.
  ///
  /// When non-null and non-empty, forces the given provider regardless of
  /// [activeProvider]. Supports circuit-breaker resets and A/B testing.
  /// `'auto'` means no override (normal auto-fallback logic applies).
  final String? manualOverrideProvider;

  /// Per-feature provider pins, keyed by [MapFeature.code], valued by
  /// provider code (`'google'` / `'mapbox'` / `'cartodb'`) or `'auto'`.
  /// Absent/unknown entries resolve to `'auto'`. Never null — an empty map
  /// means every feature follows the global chain.
  final Map<String, String> featureProviders;

  /// Mapbox style for the raster tile endpoint. Defaults to the Google-
  /// mimesis light aesthetic (`light-v11`: near-white background `#f8f9fa`,
  /// pale landuse, white roads). Accepts a style id (`mapbox/light-v11`,
  /// `mapbox/streets-v12`, `mapbox/dark-v11`) or a full custom style URL
  /// (`mapbox://styles/<user>/<id>`), which is normalized to the same
  /// raster endpoint.
  ///
  /// Honest limitation: `flutter_map` renders raster tiles, not Mapbox GL
  /// vector styles — the Appendix-A JSON cannot be consumed directly without
  /// a vector-tile plugin. The rasterized style endpoint delivers the same
  /// palette (light background, neutral landuse, white roads), which is what
  /// this field controls.
  final String mapboxStyle;

  /// Default fallback Google Maps API key bundled with the app.
  static const String defaultGoogleMapsApiKey =
      'AIzaSyAN5bY0G6qglEcaImzxHoxMq8EsslYIPtw';

  /// CartoDB free basemap tiles — no API key required. Voyager matches the
  /// Google Maps clean aesthetic (road colors, fonts); `{r}` serves @2x
  /// retina tiles where the renderer requests them.
  static const String _cartoLight =
      'https://{s}.basemaps.cartocdn.com/rastertiles/voyager/{z}/{x}/{y}{r}.png';
  static const String _cartoDark =
      'https://{s}.basemaps.cartocdn.com/dark_all/{z}/{x}/{y}{r}.png';

  /// Default Mapbox style: streets light theme (see [mapboxStyle]).
  static const String defaultMapboxStyle = MapboxStyles.streetsV12;

  /// Default Mapbox dark theme for night / dark mode.
  static const String defaultDarkMapboxStyle = MapboxStyles.darkV11;

  const GlobalMapConfig({
    this.activeProvider = 'cartodb',
    this.apiKey = defaultGoogleMapsApiKey,
    this.mapboxToken,
    this.tileUrlTemplate = _cartoLight,
    this.manualOverrideProvider,
    this.featureProviders = const {},
    this.mapboxStyle = defaultMapboxStyle,
  });

  // ── Normalised provider resolution ────────────────────────────────────────

  /// Canonical normalized provider name: `'google'`, `'mapbox'`, or `'cartodb'`.
  ///
  /// Applies [manualOverrideProvider] first (unless `'auto'`), then falls back
  /// to the configured [activeProvider].
  String get normalizedProvider {
    final override = manualOverrideProvider?.trim().toLowerCase();
    if (override != null && override.isNotEmpty && override != 'auto') {
      if (override == 'google' || override == 'google_maps') return 'google';
      if (override == 'mapbox') return 'mapbox';
      return 'cartodb';
    }
    final lower = activeProvider.trim().toLowerCase();
    if (lower == 'google_maps' || lower == 'google') return 'google';
    if (lower == 'mapbox') return 'mapbox';
    return 'cartodb'; // osm, open_street_map, cartodb, or anything else
  }

  MapProviderType get providerType => MapProviderType.fromCode(normalizedProvider);

  bool get isGoogle => normalizedProvider == 'google';
  bool get isMapbox => normalizedProvider == 'mapbox';
  bool get isCartoDb => normalizedProvider == 'cartodb';

  /// Backwards-compat alias — always false now that OSM is deprecated.
  bool get isOsm => false;

  /// True when CartoDB is the effective provider or a CartoDB tile URL is configured.
  bool get isCartoDbConfigured =>
      isCartoDb || tileUrlTemplate.toLowerCase().contains('carto');

  // ── Per-feature provider resolution ──────────────────────────────────────

  /// Raw pin for [feature]: a provider code or `'auto'`. Unknown/absent
  /// entries resolve to `'auto'`.
  String featureProviderRaw(MapFeature feature) {
    final raw = (featureProviders[feature.code] ?? 'auto').trim().toLowerCase();
    if (raw == 'google' || raw == 'google_maps') return 'google';
    if (raw == 'mapbox') return 'mapbox';
    if (raw == 'cartodb' || raw == 'osm' || raw == 'open_street_map') {
      return 'cartodb';
    }
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

  /// True when a valid Mapbox access token is available (from [mapboxToken] or
  /// an [apiKey] that begins with `'pk.'`).
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

  /// True when a non-empty API key is configured (Google or CartoDB).
  bool get hasValidApiKey => apiKey != null && apiKey!.trim().isNotEmpty;

  // ── Tile URL resolution ────────────────────────────────────────────────────

  /// Normalizes [mapboxStyle] to a `styles/v1/<user>/<style>` path.
  /// Accepts `mapbox/light-v11`-style ids (default), bare ids (assumed
  /// under the `mapbox` namespace), and full `mapbox://styles/<user>/<id>`
  /// custom-style URLs.
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
  ///
  /// Uses Mapbox's Styles API raster endpoint (256 px tiles, compatible with
  /// `flutter_map` without any native Mapbox SDK). The style comes from
  /// [mapboxStyle] (default `light-v11` Google mimesis). `{r}` serves @2x
  /// retina tiles where the renderer requests them. Falls back to free
  /// CartoDB tiles when no token is available so the map never goes blank.
  String resolveMapboxTileUrl({bool isDark = false}) {
    final token = resolvedMapboxToken;
    if (token == null || token.isEmpty) {
      return isDark ? _cartoDark : _cartoLight;
    }
    // Dynamic theme-listening logic:
    // When the app or device is in dark mode, dynamically use Mapbox dark style.
    // When in light mode, use the selected style (defaulting to streets-v12).
    final style = normalizedMapboxStyle;
    final String effectiveStyle;
    if (isDark) {
      effectiveStyle = style == MapboxStyles.darkV11 ? style : MapboxStyles.darkV11;
    } else {
      effectiveStyle = style == MapboxStyles.darkV11 ? MapboxStyles.streetsV12 : style;
    }
    return 'https://api.mapbox.com/styles/v1/$effectiveStyle/tiles/256/{z}/{x}/{y}{r}?access_token=$token';
  }

  /// Resolves the tile URL for raster tile providers (Mapbox or CartoDB).
  String resolveTileUrl({bool isDark = false}) {
    if (isMapbox) return resolveMapboxTileUrl(isDark: isDark);

    // CartoDB: prefer explicit custom template, then key-authenticated, then free.
    if (tileUrlTemplate.trim().isNotEmpty &&
        (tileUrlTemplate.contains('carto') ||
            tileUrlTemplate.contains('mapbox'))) {
      return tileUrlTemplate.trim();
    }
    if (isCartoDb && hasValidApiKey) {
      return 'https://{s}.basemaps.cartocdn.com/rastertiles/voyager/{z}/{x}/{y}{r}.png?api_key=${apiKey!.trim()}';
    }
    return isDark ? _cartoDark : _cartoLight;
  }

  // ── Serialisation ──────────────────────────────────────────────────────────

  factory GlobalMapConfig.fromMap(Map<String, dynamic>? map) {
    if (map == null) return const GlobalMapConfig();

    final provider = (map['activeProvider'] ??
            map['activeMapProvider'] ??
            map['active_map_provider'] ??
            map['mapProvider'] ??
            'cartodb')
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

    final tileUrl = (map['tileUrlTemplate'] ??
            map['osmTileServerUrl'] ??
            map['cartoTileUrl'] ??
            map['tile_url_template'] ??
            map['osm_tile_server_url'] ??
            '')
        .toString()
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

    // Per-feature pins: flat `feature_<code>` keys (Hub writes these) plus
    // an optional nested `featureProviders` map (API writes). Unknown codes
    // normalize at read time via [featureProviderRaw].
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

    return GlobalMapConfig(
      activeProvider: provider,
      apiKey: (key != null && key.isNotEmpty) ? key : defaultGoogleMapsApiKey,
      mapboxToken: (mbToken != null && mbToken.isNotEmpty) ? mbToken : null,
      tileUrlTemplate:
          (tileUrl.isNotEmpty && !tileUrl.contains('light_all'))
              ? tileUrl
              : _cartoLight,
      manualOverrideProvider:
          (override != null && override.isNotEmpty && override != 'auto')
              ? override
              : null,
      featureProviders: features,
      mapboxStyle: (style != null && style.isNotEmpty)
          ? style
          : defaultMapboxStyle,
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
      'tileUrlTemplate': tileUrlTemplate.trim(),
      'osmTileServerUrl': tileUrlTemplate.trim(),
      'featureProviders': Map<String, String>.from(featureProviders),
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
    String? tileUrlTemplate,
    String? manualOverrideProvider,
    Map<String, String>? featureProviders,
    String? mapboxStyle,
  }) {
    return GlobalMapConfig(
      activeProvider: activeProvider ?? this.activeProvider,
      apiKey: apiKey ?? this.apiKey,
      mapboxToken: mapboxToken ?? this.mapboxToken,
      tileUrlTemplate: tileUrlTemplate ?? this.tileUrlTemplate,
      manualOverrideProvider:
          manualOverrideProvider ?? this.manualOverrideProvider,
      featureProviders: featureProviders ?? this.featureProviders,
      mapboxStyle: mapboxStyle ?? this.mapboxStyle,
    );
  }
}
