import 'dart:async';

import 'package:flutter/foundation.dart';

import '../models/api_keys_config.dart';
import '../services/api_keys_service.dart';
import 'global_map_config.dart';

/// Centralized state manager for the global map engine configuration and billing hierarchy.
///
/// Hierarchy logic:
///   1. **Phase 1 (Google Free Tier)**: Use Google Maps until [googleMonthlyCap] is reached.
///   2. **Phase 2 (Mapbox Buffer)**: Switch to Mapbox to consume free tier buffer until [mapboxMonthlyCap].
///   3. **Phase 3 (Google Pay-As-You-Go)**: Switch back to Google Maps (preferred billed engine).
///   4. **Phase 4 (Monthly Reset)**: Resets at the start of each UTC calendar month.
///
/// Manual override ([GlobalMapConfig.manualOverrideProvider]) allows admins in Hub to:
///   - Force Google Maps exclusively ('google')
///   - Force Mapbox exclusively ('mapbox')
///   - Run in Automatic mode ('auto')
///
/// Managed dynamically via Hub Firestore `/system_config/remote_keys`.
class MapConfigController {
  static final MapConfigController instance = MapConfigController._();

  MapConfigController._() {
    _initStream();
  }

  /// Reactive notifier holding the latest [GlobalMapConfig].
  final ValueNotifier<GlobalMapConfig> configNotifier =
      ValueNotifier<GlobalMapConfig>(const GlobalMapConfig());

  StreamSubscription<ApiKeysConfig>? _subscription;
  ApiKeysConfig _latestApiKeys = const ApiKeysConfig();
  bool _hasApiKeysSnapshot = false;
  bool _autoFallback = true;

  ApiKeysConfig get latestApiKeys => _latestApiKeys;
  bool get autoFallbackEnabled => _autoFallback;

  // ── Google fallback state ──────────────────────────────────────────────────

  bool _isGoogleFallbackActive = false;
  String? _googleFallbackReason;

  // ── Mapbox fallback state ──────────────────────────────────────────────────

  bool _isMapboxFallbackActive = false;
  String? _mapboxFallbackReason;

  // ── Circuit breaker: Google Maps protection ───────────────────────────────

  DateTime? _circuitOpenedAt;
  static const int _circuitTripThreshold = 10;
  int _tileErrorCount = 0;
  bool _circuitOpen = false;

  // ── Usage counter state ───────────────────────────────────────────────────

  int _googleUsageCount = 0;
  int _mapboxUsageCount = 0;

  // ── Accessors ──────────────────────────────────────────────────────────────

  /// The current synchronous snapshot of the map configuration.
  GlobalMapConfig get currentConfig => configNotifier.value;

  int get googleUsageCount => _googleUsageCount;
  int get mapboxUsageCount => _mapboxUsageCount;

  bool get isGoogleQuotaExceeded =>
      _autoFallback &&
      currentConfig.googleMonthlyCap > 0 &&
      _googleUsageCount >= currentConfig.googleMonthlyCap;
  bool get isMapboxQuotaExceeded =>
      _autoFallback &&
      currentConfig.mapboxMonthlyCap > 0 &&
      _mapboxUsageCount >= currentConfig.mapboxMonthlyCap;

  bool get isGoogleFallbackActive =>
      _isGoogleFallbackActive || _circuitOpen;
  String? get fallbackReason {
    if (_circuitOpen) {
      return 'Google Maps circuit breaker open (tile errors). Resets monthly.';
    }
    if (isGoogleQuotaExceeded) {
      return 'Google Maps monthly free tier cap (${currentConfig.googleMonthlyCap}) reached. Buffering on Mapbox.';
    }
    return _googleFallbackReason;
  }

  bool get isMapboxFallbackActive =>
      _isMapboxFallbackActive || isMapboxQuotaExceeded;
  String? get mapboxFallbackReason {
    if (isMapboxQuotaExceeded) {
      return 'Mapbox monthly buffer cap (${currentConfig.mapboxMonthlyCap}) reached. Falling back to Google PAYG.';
    }
    return _mapboxFallbackReason;
  }

  /// Increments usage counter for [provider], triggers fallback if cap is hit,
  /// and persists the increment to `system_config/api_keys` via Cloud Function.
  void incrementUsage(MapProviderType provider, {bool persist = true}) {
    switch (provider) {
      case MapProviderType.google:
        _googleUsageCount++;
        if (persist) {
          // ignore: discarded_futures
          const ApiKeysService().recordMapUsage('google');
        }
        if (isGoogleQuotaExceeded) {
          debugPrint('MapConfigController: Google Maps free cap reached ($_googleUsageCount). Switching to Mapbox buffer.');
          configNotifier.value = _hasApiKeysSnapshot
              ? _buildEffectiveConfigFromApiKeys(_latestApiKeys)
              : configNotifier.value;
        }
        break;
      case MapProviderType.mapbox:
        _mapboxUsageCount++;
        if (persist) {
          // ignore: discarded_futures
          const ApiKeysService().recordMapUsage('mapbox');
        }
        if (isMapboxQuotaExceeded) {
          debugPrint('MapConfigController: Mapbox buffer cap reached ($_mapboxUsageCount). Switching to Google Pay-As-You-Go.');
          configNotifier.value = _hasApiKeysSnapshot
              ? _buildEffectiveConfigFromApiKeys(_latestApiKeys)
              : configNotifier.value;
        }
        break;
    }
  }

  /// Manually resets usage counters (locally and in `system_config/api_keys`).
  void resetUsageCounters({bool persist = true}) {
    _googleUsageCount = 0;
    _mapboxUsageCount = 0;
    _isGoogleFallbackActive = false;
    _isMapboxFallbackActive = false;
    _googleFallbackReason = null;
    _mapboxFallbackReason = null;
    resetCircuitBreaker();
    if (persist) {
      // ignore: discarded_futures
      const ApiKeysService().resetUsageCounters();
    }
    configNotifier.value = _hasApiKeysSnapshot
        ? _buildEffectiveConfigFromApiKeys(_latestApiKeys)
        : configNotifier.value;
    debugPrint('MapConfigController: Usage counters and fallbacks reset.');
  }

  /// Backwards-compat alias — always false now that OSM is deprecated.
  bool get isOsm => false;
  bool get isCartoDb => false;

  // ── Stream init ────────────────────────────────────────────────────────────

  void _initStream() {
    try {
      _subscription = const ApiKeysService().streamApiKeys().listen(
        applyApiKeysConfig,
        onError: (e) {
          debugPrint('MapConfigController stream error: $e');
        },
      );
    } catch (e) {
      debugPrint('MapConfigController initStream warning: $e');
    }
  }

  GlobalMapConfig _buildEffectiveConfigFromApiKeys(ApiKeysConfig apiKeys) {
    final googleKey = apiKeys.googleKeyForPlatform(defaultTargetPlatform);
    final mapboxToken = apiKeys.mapboxTokenForPlatform(defaultTargetPlatform);
    final effective = apiKeys.effectiveProvider;
    return GlobalMapConfig(
      activeProvider: effective,
      apiKey: googleKey,
      mapboxToken: mapboxToken.isNotEmpty ? mapboxToken : null,
      googleWebKey: apiKeys.googleWebKey.trim(),
      mapboxWebToken: apiKeys.mapboxWebToken.trim(),
      manualOverrideProvider: apiKeys.autoFallback ? '' : apiKeys.normalizedProvider,
      googleMonthlyCap: apiKeys.googleMonthlyCap,
      mapboxMonthlyCap: apiKeys.mapboxMonthlyCap,
    );
  }

  /// Applies an [ApiKeysConfig] snapshot from `system_config/api_keys`,
  /// syncing live counters, auto-fallback state, and platform credentials.
  void applyApiKeysConfig(ApiKeysConfig apiKeys) {
    _hasApiKeysSnapshot = true;
    _latestApiKeys = apiKeys;
    _autoFallback = apiKeys.autoFallback;
    _googleUsageCount = apiKeys.effectiveGoogleCalls;
    _mapboxUsageCount = apiKeys.effectiveMapboxCalls;

    final config = _buildEffectiveConfigFromApiKeys(apiKeys);
    configNotifier.value = config;
    if (!config.isGoogle || config.hasValidApiKey) {
      _isGoogleFallbackActive = false;
      _googleFallbackReason = null;
    }
  }

  // ── Config update ──────────────────────────────────────────────────────────

  /// Manually updates or overrides the configuration (used by Hub or tests).
  void updateConfig(GlobalMapConfig newConfig) {
    _hasApiKeysSnapshot = false;
    configNotifier.value = newConfig;
    if (!newConfig.isGoogle || newConfig.hasValidApiKey) {
      _isGoogleFallbackActive = false;
      _googleFallbackReason = null;
    }
  }

  // ── Fallback triggers ──────────────────────────────────────────────────────

  void triggerGoogleFallback({String reason = 'Google Maps unavailable'}) {
    if (!_isGoogleFallbackActive) {
      _isGoogleFallbackActive = true;
      _googleFallbackReason = reason;
      debugPrint('MapConfigController: Google fallback active — $reason');
      configNotifier.value = configNotifier.value;
    }
  }

  void resetGoogleFallback() {
    if (_isGoogleFallbackActive) {
      _isGoogleFallbackActive = false;
      _googleFallbackReason = null;
      configNotifier.value = configNotifier.value;
    }
  }

  void triggerMapboxFallback({String reason = 'Mapbox unavailable'}) {
    if (!_isMapboxFallbackActive) {
      _isMapboxFallbackActive = true;
      _mapboxFallbackReason = reason;
      debugPrint('MapConfigController: Mapbox fallback active — $reason');
      configNotifier.value = configNotifier.value;
    }
  }

  void resetMapboxFallback() {
    if (_isMapboxFallbackActive) {
      _isMapboxFallbackActive = false;
      _mapboxFallbackReason = null;
      configNotifier.value = configNotifier.value;
    }
  }

  // ── Circuit breaker ────────────────────────────────────────────────────────

  void recordGoogleTileError() {
    _checkCircuitMonthlyReset();
    _tileErrorCount++;
    if (!_circuitOpen && _tileErrorCount >= _circuitTripThreshold) {
      _circuitOpen = true;
      _circuitOpenedAt = DateTime.now().toUtc();
      debugPrint('MapConfigController: Google circuit breaker tripped after $_tileErrorCount tile errors.');
      triggerGoogleFallback(reason: 'Google Maps quota/tile errors detected. Circuit breaker active.');
    }
  }

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
    final resetDate = DateTime.utc(
      opened.month == 12 ? opened.year + 1 : opened.year,
      opened.month == 12 ? 1 : opened.month + 1,
    );
    if (now.isAfter(resetDate)) {
      debugPrint('MapConfigController: Google circuit breaker auto-reset (new month).');
      resetCircuitBreaker();
    }
  }

  // ── Effective provider resolution ──────────────────────────────────────────

  /// Core 4-phase resolution strategy:
  ///
  /// Priority order:
  /// 1. Manual Admin Override ([manualOverrideProvider]): Handled via [GlobalMapConfig.normalizedProvider].
  /// 2. Automatic billing hierarchy:
  ///    - Phase 1: Google Maps (Primary) — active while Google calls < free cap AND no fallback active.
  ///    - Phase 2: Mapbox (Buffer) — active when Google cap is hit (or Google unavailable), while Mapbox calls < free cap AND token valid AND no Mapbox fallback.
  ///    - Phase 3: Google Maps (Pay-As-You-Go) — active when Mapbox free cap is hit or Mapbox fails. (We prefer Google billing over Mapbox billing).
  MapProviderType? _resolveChain(String providerCode, GlobalMapConfig cfg) {
    if (!cfg.hasAnyValidProvider) {
      return null;
    }

    final requested = MapProviderType.fromCode(providerCode);
    final isForced = cfg.isForcedMode;

    // If explicit requested provider is Mapbox:
    if (requested == MapProviderType.mapbox) {
      if (cfg.hasValidMapboxToken) {
        if (isForced) {
          return MapProviderType.mapbox;
        }
        if (!_isMapboxFallbackActive && !isMapboxQuotaExceeded) {
          return MapProviderType.mapbox;
        }
        if (cfg.hasValidGoogleKey && !isGoogleFallbackActive) {
          return MapProviderType.google; // Fallback to Google PAYG only if configured
        }
        return MapProviderType.mapbox;
      }
      // Primary Mapbox lacks an active token in SeseHub -> only fall back if
      // auto-fallback is enabled; forced mode stays strictly unconfigured.
      if (isForced) return null;
      return cfg.hasValidGoogleKey ? MapProviderType.google : null;
    }

    // Default 'google' / 'auto' path:
    if (cfg.hasValidGoogleKey) {
      if (isForced) {
        return MapProviderType.google;
      }
      // Phase 1: Google Free Tier
      final canUseGoogleFree = !isGoogleFallbackActive && !isGoogleQuotaExceeded;
      if (canUseGoogleFree) {
        return MapProviderType.google;
      }

      // Phase 2: Mapbox Buffer (when Google free cap hit or Google temporarily unavailable)
      final canUseMapboxBuffer = !_isMapboxFallbackActive && cfg.hasValidMapboxToken && !isMapboxQuotaExceeded;
      if (canUseMapboxBuffer) {
        return MapProviderType.mapbox;
      }

      // Phase 3: Google Pay-As-You-Go overflow
      return MapProviderType.google;
    }

    // Primary Google lacks an active key in SeseHub -> only fall back if
    // auto-fallback is enabled; forced mode stays strictly unconfigured.
    if (isForced) return null;
    return cfg.hasValidMapboxToken ? MapProviderType.mapbox : null;
  }

  /// Resolves effective active map provider type, or `null` when no provider has
  /// an active API key/token configured in SeseHub.
  MapProviderType? get effectiveProviderTypeOrNull =>
      _resolveChain(currentConfig.normalizedProvider, currentConfig);

  /// Resolves effective active map provider type.
  MapProviderType get effectiveProviderType =>
      effectiveProviderTypeOrNull ?? MapProviderType.google;

  /// Effective provider for a single feature area ([MapFeature]), or `null`
  /// when no provider has an active API key/token configured in SeseHub.
  MapProviderType? providerTypeForFeatureOrNull(MapFeature feature) {
    final pinned = currentConfig.featureProviderRaw(feature);
    if (pinned == 'auto') return effectiveProviderTypeOrNull;
    return _resolveChain(pinned, currentConfig);
  }

  /// Effective provider for a single feature area ([MapFeature]).
  MapProviderType providerTypeForFeature(MapFeature feature) =>
      providerTypeForFeatureOrNull(feature) ?? MapProviderType.google;

  bool get hasActiveProvider => effectiveProviderTypeOrNull != null;
  bool get isUnconfigured => effectiveProviderTypeOrNull == null;
  bool get isForcedMode => currentConfig.isForcedMode;
  bool get isGoogle => effectiveProviderTypeOrNull == MapProviderType.google;
  bool get isMapbox => effectiveProviderTypeOrNull == MapProviderType.mapbox;

  // ── Geocoding feature-pin enforcement ────────────────────────────────────

  bool get geocodingGoogleOnly =>
      currentConfig.featureProviderRaw(MapFeature.geocoding) == 'google';

  bool get geocodingNominatimOnly => false;

  // ── Cold-start & mid-trip protection ─────────────────────────────────────

  int _activeTripCount = 0;

  bool get isTripActive => _activeTripCount > 0;

  void setTripActive(bool active) {
    if (active) {
      _activeTripCount++;
    } else if (_activeTripCount > 0) {
      _activeTripCount--;
    }
  }

  GlobalMapConfig snapshotConfig() => currentConfig;

  void dispose() {
    _subscription?.cancel();
  }
}
