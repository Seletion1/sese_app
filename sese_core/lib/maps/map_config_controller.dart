import 'dart:async';

import 'package:flutter/foundation.dart';

import '../services/remote_keys_service.dart';
import 'global_map_config.dart';

/// Centralized state manager for the global map engine configuration.
///
/// Provider fallback chain: **Google Maps → Mapbox → CartoDB**.
/// `osm` / `open_street_map` is fully deprecated — unknown codes resolve to CartoDB.
///
/// Managed dynamically via Hub Firestore `/system_config/remote_keys`.
/// Synchronously accessible via [MapConfigController.instance] and
/// reactive via [configNotifier].
class MapConfigController {
  static final MapConfigController instance = MapConfigController._();

  MapConfigController._() {
    _initStream();
  }

  /// Reactive notifier holding the latest [GlobalMapConfig].
  final ValueNotifier<GlobalMapConfig> configNotifier =
      ValueNotifier<GlobalMapConfig>(const GlobalMapConfig());

  StreamSubscription<GlobalMapConfig>? _subscription;

  // ── Google fallback state ──────────────────────────────────────────────────

  bool _isGoogleFallbackActive = false;
  String? _googleFallbackReason;

  // ── Mapbox fallback state ──────────────────────────────────────────────────

  bool _isMapboxFallbackActive = false;
  String? _mapboxFallbackReason;

  // ── Circuit breaker: Google Maps pay-as-you-go protection ─────────────────
  //
  // When the circuit trips (≥10 consecutive tile/quota errors), Google Maps is
  // bypassed automatically for the remainder of the calendar month (UTC).
  // Admins can also force-reset via the Hub dashboard (resetCircuitBreaker()).

  DateTime? _circuitOpenedAt;
  static const int _circuitTripThreshold = 10;
  int _tileErrorCount = 0;
  bool _circuitOpen = false;

  // ── Accessors ──────────────────────────────────────────────────────────────

  /// The current synchronous snapshot of the map configuration.
  GlobalMapConfig get currentConfig => configNotifier.value;

  bool get isGoogleFallbackActive => _isGoogleFallbackActive || _circuitOpen;
  String? get fallbackReason => _circuitOpen
      ? 'Google Maps circuit breaker open (quota/tile errors). Resets monthly.'
      : _googleFallbackReason;

  bool get isMapboxFallbackActive => _isMapboxFallbackActive;
  String? get mapboxFallbackReason => _mapboxFallbackReason;

  /// Backwards-compat alias — always false now that OSM is deprecated.
  bool get isOsm => false;

  // ── Stream init ────────────────────────────────────────────────────────────

  void _initStream() {
    try {
      _subscription = const RemoteKeysService().streamGlobalMapConfig().listen(
        (config) {
          configNotifier.value = config;
          // Admin updating provider or API key can clear fallback state.
          if (!config.isGoogle || config.hasValidApiKey) {
            _isGoogleFallbackActive = false;
            _googleFallbackReason = null;
          }
        },
        onError: (e) {
          debugPrint('MapConfigController stream error: $e');
        },
      );
    } catch (e) {
      debugPrint('MapConfigController initStream warning: $e');
    }
  }

  // ── Config update ──────────────────────────────────────────────────────────

  /// Manually updates or overrides the configuration (used by Hub or tests).
  void updateConfig(GlobalMapConfig newConfig) {
    configNotifier.value = newConfig;
    if (!newConfig.isGoogle || newConfig.hasValidApiKey) {
      _isGoogleFallbackActive = false;
      _googleFallbackReason = null;
    }
  }

  // ── Google fallback ────────────────────────────────────────────────────────

  /// Triggers a graceful fallback from Google Maps → Mapbox → CartoDB.
  ///
  /// Invoked when Google Maps fails to initialize, GMS is missing, or
  /// repeated tile load/auth errors are detected.
  void triggerGoogleFallback({String reason = 'Google Maps unavailable'}) {
    if (!_isGoogleFallbackActive) {
      _isGoogleFallbackActive = true;
      _googleFallbackReason = reason;
      debugPrint('MapConfigController: Google fallback active — $reason');
      configNotifier.value = configNotifier.value; // re-push to rebuild widgets
    }
  }

  /// Clears the Google fallback state so the native engine can be retried.
  void resetGoogleFallback() {
    if (_isGoogleFallbackActive) {
      _isGoogleFallbackActive = false;
      _googleFallbackReason = null;
      configNotifier.value = configNotifier.value;
    }
  }

  // ── Mapbox fallback ────────────────────────────────────────────────────────

  /// Triggers a graceful fallback from Mapbox → CartoDB.
  ///
  /// Invoked when Mapbox tile loading fails or a token is missing.
  void triggerMapboxFallback({String reason = 'Mapbox unavailable'}) {
    if (!_isMapboxFallbackActive) {
      _isMapboxFallbackActive = true;
      _mapboxFallbackReason = reason;
      debugPrint('MapConfigController: Mapbox fallback active — $reason');
      configNotifier.value = configNotifier.value;
    }
  }

  /// Clears the Mapbox fallback state so Mapbox can be retried.
  void resetMapboxFallback() {
    if (_isMapboxFallbackActive) {
      _isMapboxFallbackActive = false;
      _mapboxFallbackReason = null;
      configNotifier.value = configNotifier.value;
    }
  }

  // ── Circuit breaker ────────────────────────────────────────────────────────

  /// Records a Google Maps tile or auth error and trips the circuit breaker
  /// after [_circuitTripThreshold] consecutive failures.
  ///
  /// Each call also checks whether the breaker should auto-reset (new month).
  void recordGoogleTileError() {
    _checkCircuitMonthlyReset();
    _tileErrorCount++;
    if (!_circuitOpen && _tileErrorCount >= _circuitTripThreshold) {
      _circuitOpen = true;
      _circuitOpenedAt = DateTime.now().toUtc();
      debugPrint(
          'MapConfigController: Google circuit breaker tripped after '
          '$_tileErrorCount tile errors.');
      triggerGoogleFallback(
          reason:
              'Google Maps quota/tile errors detected. Circuit breaker active.');
    }
  }

  /// Manually resets the Google circuit breaker.
  ///
  /// Call this from the Hub dashboard's "Reset Circuit Breaker" action.
  void resetCircuitBreaker() {
    final wasOpen = _circuitOpen;
    _circuitOpen = false;
    _tileErrorCount = 0;
    _circuitOpenedAt = null;
    if (wasOpen) {
      resetGoogleFallback();
    }
    debugPrint('MapConfigController: Google circuit breaker manually reset.');
  }

  void _checkCircuitMonthlyReset() {
    final opened = _circuitOpenedAt;
    if (!_circuitOpen || opened == null) return;
    final now = DateTime.now().toUtc();
    // Next calendar month (handles December → January roll-over).
    final resetDate = DateTime.utc(
      opened.month == 12 ? opened.year + 1 : opened.year,
      opened.month == 12 ? 1 : opened.month + 1,
    );
    if (now.isAfter(resetDate)) {
      debugPrint(
          'MapConfigController: Google circuit breaker auto-reset (new month).');
      resetCircuitBreaker();
    }
  }

  // ── Effective provider resolution ──────────────────────────────────────────

  /// Shared chain resolver: maps a canonical provider code to the effective
  /// type, honouring fallback state, the circuit breaker, and credential
  /// presence. Fallback chain: **Google Maps → Mapbox → CartoDB**.
  MapProviderType _resolveChain(String providerCode, GlobalMapConfig cfg) {
    final type = MapProviderType.fromCode(providerCode);
    switch (type) {
      case MapProviderType.google:
        if (isGoogleFallbackActive || !cfg.hasValidApiKey) {
          if (cfg.hasValidMapboxToken && !_isMapboxFallbackActive) {
            return MapProviderType.mapbox;
          }
          return MapProviderType.cartodb;
        }
        return MapProviderType.google;
      case MapProviderType.mapbox:
        if (_isMapboxFallbackActive || !cfg.hasValidMapboxToken) {
          return MapProviderType.cartodb;
        }
        return MapProviderType.mapbox;
      case MapProviderType.cartodb:
        return MapProviderType.cartodb;
    }
  }

  /// Resolves the effective active map provider type, honouring fallback state
  /// and the manual override in this priority order:
  ///
  /// 1. [GlobalMapConfig.manualOverrideProvider] (Hub admin pin).
  /// 2. Configured provider + circuit/fallback modifiers.
  /// 3. Fallback chain: **Google Maps → Mapbox → CartoDB**.
  MapProviderType get effectiveProviderType =>
      _resolveChain(currentConfig.normalizedProvider, currentConfig);

  /// Effective provider for a single feature area ([MapFeature]): the Hub
  /// feature pin when set to an explicit provider, otherwise the global
  /// [effectiveProviderType]. Credential/fallback safety applies either way.
  MapProviderType providerTypeForFeature(MapFeature feature) {
    final pinned = currentConfig.featureProviderRaw(feature);
    if (pinned == 'auto') return effectiveProviderType;
    return _resolveChain(pinned, currentConfig);
  }

  bool get isGoogle => effectiveProviderType == MapProviderType.google;
  bool get isMapbox => effectiveProviderType == MapProviderType.mapbox;
  bool get isCartoDb => effectiveProviderType == MapProviderType.cartodb;

  // ── Geocoding feature-pin enforcement ────────────────────────────────────
  //
  // The Hub geocoding slot pins the search backend:
  // - explicit 'google' → Google proxy only (Nominatim fallback skipped).
  // - explicit 'cartodb' → Nominatim only (no Google calls at all).
  // - 'mapbox' / 'auto' → current chain behavior (primary per effective
  //   provider, the other as fallback). Mapbox has no client geocoder wired
  //   (token-scoped REST + billing), so it follows the Google path.

  /// True when Hub pinned geocoding to Google (skip Nominatim entirely).
  bool get geocodingGoogleOnly =>
      currentConfig.featureProviderRaw(MapFeature.geocoding) == 'google';

  /// True when Hub pinned geocoding to CartoDB/Nominatim (no Google calls).
  bool get geocodingNominatimOnly =>
      currentConfig.featureProviderRaw(MapFeature.geocoding) == 'cartodb';

  // ── Cold-start & mid-trip protection ─────────────────────────────────────
  //
  // Rule: Hub-driven provider changes apply to trip surfaces only on a fresh
  // engine creation (cold start of that map widget). While a trip is live,
  // tile widgets snapshot the config at creation and never tear down or
  // swap engines mid-trip — the native platform view survives Hub edits,
  // fallback trips, and circuit events until the trip surface is disposed.
  //
  // The counter below is observability + future gating (live screens call
  // setTripActive around their tracking sessions); the actual freeze lives
  // in `SeseUniversalMap`, which snapshots [currentConfig] at init for trip
  // contexts (activeTrip / realtimeTracking / inAppNavigation) and resolves
  // its renderer from the snapshot for the widget's whole lifetime.

  int _activeTripCount = 0;

  /// True while at least one trip surface reports a live session.
  bool get isTripActive => _activeTripCount > 0;

  /// Live trip surfaces call `setTripActive(true)` in init and
  /// `setTripActive(false)` in dispose (ref-counted for stacked sheets).
  void setTripActive(bool active) {
    if (active) {
      _activeTripCount++;
    } else if (_activeTripCount > 0) {
      _activeTripCount--;
    }
  }

  /// Synchronous snapshot of the current config for cold-start capture.
  GlobalMapConfig snapshotConfig() => currentConfig;

  /// Disposes stream subscription (for test tearDown).
  void dispose() {
    _subscription?.cancel();
  }
}
