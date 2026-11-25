import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sese_core/sese_core.dart';

void main() {
  group('ApiKeysConfig & MapConfigController cap-based fallback', () {
    test('defaults have zero hardcoded keys and standard monthly caps', () {
      const cfg = ApiKeysConfig();
      expect(cfg.googleAndroidKey, isEmpty);
      expect(cfg.googleIosKey, isEmpty);
      expect(cfg.googleWebKey, isEmpty);
      expect(cfg.mapboxAndroidToken, isEmpty);
      expect(cfg.autoFallback, isTrue);
      expect(cfg.googleMonthlyCap, 20000);
      expect(cfg.mapboxMonthlyCap, 50000);
      expect(cfg.effectiveProvider, 'google');
    });

    test('fromMap resolves platform-restricted keys and auto-switches to Mapbox when cap reached', () {
      final month = ApiKeysConfig.currentUtcMonthKey();
      final cfg = ApiKeysConfig.fromMap({
        'active_map_provider': 'google',
        'auto_fallback': true,
        'google_monthly_cap': 20000,
        'mapbox_monthly_cap': 50000,
        'google_calls': 20000,
        'mapbox_calls': 12,
        'last_synced_month': month,
        'google_maps': {
          'android_key': 'AIza_android',
          'ios_key': 'AIza_ios',
          'web_key': 'AIza_web',
        },
        'mapbox': {
          'android_token': 'pk.android',
          'ios_token': 'pk.ios',
          'web_token': 'pk.web',
        },
      });

      expect(cfg.googleKeyForPlatform(TargetPlatform.android, isWeb: false), 'AIza_android');
      expect(cfg.googleKeyForPlatform(TargetPlatform.iOS, isWeb: false), 'AIza_ios');
      expect(cfg.googleKeyForPlatform(TargetPlatform.android, isWeb: true), 'AIza_web');
      expect(cfg.mapboxTokenForPlatform(TargetPlatform.android, isWeb: false), 'pk.android');
      expect(cfg.isGoogleCapReached, isTrue);
      expect(cfg.effectiveProvider, 'mapbox');
    });

    test('counters roll over to 0 and revert to Google Maps on a new UTC month', () {
      final cfg = ApiKeysConfig.fromMap({
        'active_map_provider': 'google',
        'auto_fallback': true,
        'google_monthly_cap': 20000,
        'google_calls': 25000,
        'last_synced_month': '1999-01',
      });

      expect(cfg.effectiveGoogleCalls, 0);
      expect(cfg.isGoogleCapReached, isFalse);
      expect(cfg.effectiveProvider, 'google');
    });

    test('MapConfigController switches to Mapbox on cap and reverts on reset', () {
      final ctrl = MapConfigController.instance;
      ctrl.resetUsageCounters(persist: false);

      final month = ApiKeysConfig.currentUtcMonthKey();
      ctrl.applyApiKeysConfig(ApiKeysConfig(
        activeMapProvider: 'google',
        autoFallback: true,
        googleMonthlyCap: 2,
        mapboxMonthlyCap: 10,
        googleCalls: 1,
        lastSyncedMonth: month,
        googleAndroidKey: 'AIza_test',
        mapboxAndroidToken: 'pk.test',
        googleWebKey: 'AIza_test',
        mapboxWebToken: 'pk.test',
      ));

      expect(ctrl.effectiveProviderType, MapProviderType.google);

      ctrl.incrementUsage(MapProviderType.google, persist: false);
      expect(ctrl.googleUsageCount, 2);
      expect(ctrl.isGoogleQuotaExceeded, isTrue);
      expect(ctrl.effectiveProviderType, MapProviderType.mapbox);

      ctrl.resetUsageCounters(persist: false);
      expect(ctrl.googleUsageCount, 0);
      expect(ctrl.isGoogleQuotaExceeded, isFalse);
      expect(ctrl.effectiveProviderType, MapProviderType.google);
    });
  });
}
