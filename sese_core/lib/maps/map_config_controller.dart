import 'dart:async';

import 'package:flutter/foundation.dart';

import '../services/remote_keys_service.dart';
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

  StreamSubscription<GlobalMapConfig>? _subscription;

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
      _googleUsageCount >= currentConfig.googleMonthlyCap;
  bool get isMapboxQuotaExceeded =>
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

  /// Increments usage counter for [provider] and triggers fallback if cap is hit.
  void incrementUsage(MapProviderType provider) {
    switch (provider) {
      case MapProviderType.google:
        _googleUsageCount++;
        if (_googleUsageCount >= currentConfig.googleMonthlyCap) {
          debugPrint('MapConfigController: Google Maps free cap reached ($_googleUsageCount). Switching to Mapbox buffer.');
          configNotifier.value = configNotifier.value;
        }
        break;
      case MapProviderType.mapbox:
        _mapboxUsageCount++;
        if (_mapboxUsageCount >= currentConfig.mapboxMonthlyCap) {
          debugPrint('MapConfigController: Mapbox buffer cap reached ($_mapboxUsageCount). Switching to Google Pay-As-You-Go.');
          configNotifier.value = configNotifier.value;
        }
        break;
    }
  }

  /// Manually resets usage counters (e.g. from Admin Hub).
  void resetUsageCounters() {
    _googleUsageCount = 0;
    _mapboxUsageCount = 0;
    _isGoogleFallbackActive = false;
    _isMapboxFallbackActive = false;
    _googleFallbackReason = null;
    _mapboxFallbackReason = null;
    resetCircuitBreaker();
    configNotifier.value = configNotifier.value;
    debugPrint('MapConfigController: Usage counters and fallbacks reset.');
  }

  /// Backwards-compat alias — always false now that OSM is deprecated.
  bool get isOsm => false;
  bool get isCartoDb => false;

  // ── Stream init ────────────────────────────────────────────────────────────

  void _initStream() {
    try {
      _subscription = const RemoteKeysService().streamGlobalMapConfig().listen(
        (config) {
          configNotifier.value = config;
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
  MapProviderType _resolveChain(String providerCode, GlobalMapConfig cfg) {
    final requested = MapProviderType.fromCode(providerCode);

    // If explicit requested provider is Mapbox:
    if (requested == MapProviderType.mapbox) {
      if (cfg.hasValidMapboxToken && !_isMapboxFallbackActive && !isMapboxQuotaExceeded) {
        return MapProviderType.mapbox;
      }
      return MapProviderType.google; // Fallback to Google Payg
    }

    // Default 'google' / 'auto' path:
    // Phase 1: Google Free Tier
    final canUseGoogleFree = !isGoogleFallbackActive && cfg.hasValidApiKey && !isGoogleQuotaExceeded;
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

  /// Resolves effective active map provider type.
  MapProviderType get effectiveProviderType =>
      _resolveChain(currentConfig.normalizedProvider, currentConfig);

  /// Effective provider for a single feature area ([MapFeature]).
  MapProviderType providerTypeForFeature(MapFeature feature) {
    final pinned = currentConfig.featureProviderRaw(feature);
    if (pinned == 'auto') return effectiveProviderType;
    return _resolveChain(pinned, currentConfig);
  }

  bool get isGoogle => effectiveProviderType == MapProviderType.google;
  bool get isMapbox => effectiveProviderType == MapProviderType.mapbox;

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
