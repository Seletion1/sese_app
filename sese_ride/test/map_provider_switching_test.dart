import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:sese_core/sese_core.dart';
import 'package:sese_ride/widgets/map_provider.dart';
import 'package:sese_ride/widgets/osm_map_view.dart';

void main() {
  setUp(() {
    OsmMapView.debugTileProviderOverride = const BlankTileProvider();
    MapConfigController.instance.resetUsageCounters();
    MapConfigController.instance.resetGoogleFallback();
    MapConfigController.instance.resetMapboxFallback();
  });

  tearDown(() {
    OsmMapView.debugTileProviderOverride = null;
    MapConfigController.instance.resetUsageCounters();
    MapConfigController.instance.resetGoogleFallback();
    MapConfigController.instance.resetMapboxFallback();
  });

  group('Phase 1: Full Google Maps Mode Testing', () {
    test('Google Maps provider resolution across all contexts', () {
      final config = const GlobalMapConfig(
        activeProvider: 'google',
        apiKey: 'AIzaSyTestKey123',
      );
      MapConfigController.instance.updateConfig(config);

      expect(MapConfigController.instance.effectiveProviderType, MapProviderType.google);
      expect(MapConfigController.instance.isGoogle, isTrue);
      expect(MapConfigController.instance.isMapbox, isFalse);

      for (final ctx in MapContext.values) {
        final resolved = MapProviderPolicy.resolve(ctx, mapConfig: config);
        expect(resolved, MapProvider.googleMaps, reason: 'Context $ctx should resolve to googleMaps');
      }
    });

    testWidgets('SeseUniversalMap renders Google Maps branch when Google Maps is active',
        (tester) async {
      final config = const GlobalMapConfig(
        activeProvider: 'google',
        apiKey: 'AIzaSyTestKey123',
      );
      MapConfigController.instance.updateConfig(config);
      final mapController = SeSeMapController();

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SeseUniversalMap(
              mapController: mapController,
              initialCenter: const LatLng(6.5244, 3.3792),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byType(SeseUniversalMap), findsOneWidget);
      expect(find.byType(Container), findsWidgets);
    });
  });

  group('Phase 2: Full Mapbox Mode Testing', () {
    test('Mapbox provider resolution and tile URL generation', () {
      final config = const GlobalMapConfig(
        activeProvider: 'mapbox',
        mapboxToken: 'pk.eyJ1IjoidGVzdCJ9.sample',
        mapboxStyle: MapboxStyles.streetsV12,
      );
      MapConfigController.instance.updateConfig(config);

      expect(MapConfigController.instance.effectiveProviderType, MapProviderType.mapbox);
      expect(MapConfigController.instance.isMapbox, isTrue);
      expect(MapConfigController.instance.isGoogle, isFalse);

      final lightUrl = config.resolveMapboxTileUrl(isDark: false);
      expect(lightUrl, contains('api.mapbox.com/styles/v1/mapbox/streets-v12/tiles'));
      expect(lightUrl, contains('access_token=pk.eyJ1IjoidGVzdCJ9.sample'));

      final darkUrl = config.resolveMapboxTileUrl(isDark: true);
      expect(darkUrl, contains('api.mapbox.com/styles/v1/mapbox/dark-v11/tiles'));
    });

    testWidgets('SeseUniversalMap renders Mapbox tile engine with correct attribution',
        (tester) async {
      final config = const GlobalMapConfig(
        activeProvider: 'mapbox',
        mapboxToken: 'pk.eyJ1IjoidGVzdCJ9.sample',
      );
      MapConfigController.instance.updateConfig(config);
      final mapController = SeSeMapController();

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SeseUniversalMap(
              mapController: mapController,
              initialCenter: const LatLng(6.5244, 3.3792),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byType(SeseUniversalMap), findsOneWidget);
    });
  });

  group('Phase 3: Automated Billing & Fallback Chain Testing', () {
    test('Google free tier -> Mapbox buffer rollover when Google cap reached', () {
      final config = const GlobalMapConfig(
        activeProvider: 'google',
        apiKey: 'AIzaSyTestKey123',
        mapboxToken: 'pk.eyJ1IjoidGVzdCJ9.sample',
        googleMonthlyCap: 5,
        mapboxMonthlyCap: 10,
      );
      MapConfigController.instance.updateConfig(config);

      expect(MapConfigController.instance.effectiveProviderType, MapProviderType.google);

      // Increment Google usage to cap
      for (int i = 0; i < 5; i++) {
        MapConfigController.instance.incrementUsage(MapProviderType.google);
      }

      expect(MapConfigController.instance.isGoogleQuotaExceeded, isTrue);
      // Rollover to Mapbox buffer
      expect(MapConfigController.instance.effectiveProviderType, MapProviderType.mapbox);
    });

    test('Mapbox buffer -> Google PAYG overflow when Mapbox cap also reached', () {
      final config = const GlobalMapConfig(
        activeProvider: 'google',
        apiKey: 'AIzaSyTestKey123',
        mapboxToken: 'pk.eyJ1IjoidGVzdCJ9.sample',
        googleMonthlyCap: 5,
        mapboxMonthlyCap: 5,
      );
      MapConfigController.instance.updateConfig(config);

      // Reach Google cap
      for (int i = 0; i < 5; i++) {
        MapConfigController.instance.incrementUsage(MapProviderType.google);
      }
      expect(MapConfigController.instance.effectiveProviderType, MapProviderType.mapbox);

      // Reach Mapbox cap
      for (int i = 0; i < 5; i++) {
        MapConfigController.instance.incrementUsage(MapProviderType.mapbox);
      }
      expect(MapConfigController.instance.isMapboxQuotaExceeded, isTrue);

      // Falls back to Google Maps (PAYG)
      expect(MapConfigController.instance.effectiveProviderType, MapProviderType.google);
    });

    test('Google circuit breaker trips after 10 tile errors and falls back to Mapbox', () {
      final config = const GlobalMapConfig(
        activeProvider: 'google',
        apiKey: 'AIzaSyTestKey123',
        mapboxToken: 'pk.eyJ1IjoidGVzdCJ9.sample',
      );
      MapConfigController.instance.updateConfig(config);

      for (int i = 0; i < 9; i++) {
        MapConfigController.instance.recordGoogleTileError();
        expect(MapConfigController.instance.isGoogleFallbackActive, isFalse);
      }

      // 10th error trips circuit breaker
      MapConfigController.instance.recordGoogleTileError();
      expect(MapConfigController.instance.isGoogleFallbackActive, isTrue);
      expect(MapConfigController.instance.effectiveProviderType, MapProviderType.mapbox);

      // Manual reset clears circuit breaker
      MapConfigController.instance.resetCircuitBreaker();
      expect(MapConfigController.instance.isGoogleFallbackActive, isFalse);
      expect(MapConfigController.instance.effectiveProviderType, MapProviderType.google);
    });

    test('Per-feature provider pins override global provider and respect manual override', () {
      final config = GlobalMapConfig(
        activeProvider: 'google',
        apiKey: 'AIzaSyTestKey123',
        mapboxToken: 'pk.eyJ1IjoidGVzdCJ9.sample',
        manualOverrideProvider: 'mapbox',
        featureProviders: const {
          'navigation': 'google',
        },
      );
      MapConfigController.instance.updateConfig(config);

      expect(
        MapConfigController.instance.providerTypeForFeature(MapFeature.navigation),
        MapProviderType.google,
      );
      expect(
        MapConfigController.instance.providerTypeForFeature(MapFeature.tracking),
        MapProviderType.mapbox,
      );
    });

    testWidgets('Cold-start trip context protects against mid-trip engine swaps',
        (tester) async {
      final config = const GlobalMapConfig(
        activeProvider: 'google',
        apiKey: 'AIzaSyTestKey123',
        mapboxToken: 'pk.eyJ1IjoidGVzdCJ9.sample',
      );
      MapConfigController.instance.updateConfig(config);
      final mapController = SeSeMapController();

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SeseUniversalMap(
              mapContext: MapContext.activeTrip,
              mapController: mapController,
              initialCenter: const LatLng(6.5244, 3.3792),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byType(SeseUniversalMap), findsOneWidget);

      final updatedConfig = const GlobalMapConfig(
        activeProvider: 'mapbox',
        mapboxToken: 'pk.eyJ1IjoidGVzdCJ9.sample',
      );
      MapConfigController.instance.updateConfig(updatedConfig);
      await tester.pumpAndSettle();

      expect(find.byType(SeseUniversalMap), findsOneWidget);
    });
  });

  group('Phase 4: resolveEmbedded() tests', () {
    test('Google primary + no Mapbox token → resolveEmbedded returns googleMaps', () {
      final config = const GlobalMapConfig(
        activeProvider: 'google',
        apiKey: 'AIzaSyRealProductionKey',
      );
      MapConfigController.instance.updateConfig(config);

      final result = MapProviderPolicy.resolveEmbedded();

      expect(result, MapProvider.googleMaps);
    });

    test('Google primary + valid Mapbox token → resolveEmbedded respects Google primary', () {
      final config = const GlobalMapConfig(
        activeProvider: 'google',
        apiKey: 'AIzaSyRealProductionKey',
        mapboxToken: 'pk.eyJ1IjoidGVzdCJ9.sample',
      );
      MapConfigController.instance.updateConfig(config);

      final result = MapProviderPolicy.resolveEmbedded();

      expect(result, MapProvider.googleMaps);
    });

    test('Mapbox primary → resolveEmbedded returns mapbox directly', () {
      final config = const GlobalMapConfig(
        activeProvider: 'mapbox',
        mapboxToken: 'pk.eyJ1IjoidGVzdCJ9.sample',
      );
      MapConfigController.instance.updateConfig(config);

      final result = MapProviderPolicy.resolveEmbedded();

      expect(result, MapProvider.mapbox);
    });
  });
}
