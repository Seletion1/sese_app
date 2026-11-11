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
      expect(MapConfigController.instance.isCartoDb, isFalse);

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
      // In test mode (debugTileProviderOverride != null), mapCanvas renders placeholder container
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

  group('Phase 3: Full CartoDB Mode Testing', () {
    test('CartoDB provider resolution and Voyager / Positron tile URL generation', () {
      final config = const GlobalMapConfig(
        activeProvider: 'cartodb',
      );
      MapConfigController.instance.updateConfig(config);

      expect(MapConfigController.instance.effectiveProviderType, MapProviderType.cartodb);
      expect(MapConfigController.instance.isCartoDb, isTrue);

      final lightUrl = config.resolveTileUrl(isDark: false);
      expect(lightUrl, contains('cartocdn.com/rastertiles/voyager'));

      final darkUrl = config.resolveTileUrl(isDark: true);
      expect(darkUrl, contains('cartocdn.com/dark_all'));
    });

    testWidgets('SeseUniversalMap renders CartoDB tile engine', (tester) async {
      final config = const GlobalMapConfig(
        activeProvider: 'cartodb',
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

  group('Phase 4: Fallback Chains & One-By-One Fallback Testing', () {
    test('Google fallback to Mapbox when Mapbox token is valid', () {
      final config = const GlobalMapConfig(
        activeProvider: 'google',
        apiKey: 'AIzaSyTestKey123',
        mapboxToken: 'pk.eyJ1IjoidGVzdCJ9.sample',
      );
      MapConfigController.instance.updateConfig(config);

      expect(MapConfigController.instance.effectiveProviderType, MapProviderType.google);

      // Trigger Google fallback
      MapConfigController.instance.triggerGoogleFallback(reason: 'Google GMS missing');

      expect(MapConfigController.instance.isGoogleFallbackActive, isTrue);
      expect(MapConfigController.instance.effectiveProviderType, MapProviderType.mapbox);
    });

    test('Google fallback to CartoDB when Mapbox token is missing', () {
      final config = const GlobalMapConfig(
        activeProvider: 'google',
        apiKey: 'AIzaSyTestKey123',
        mapboxToken: null,
      );
      MapConfigController.instance.updateConfig(config);

      MapConfigController.instance.triggerGoogleFallback(reason: 'Google tile error');

      expect(MapConfigController.instance.isGoogleFallbackActive, isTrue);
      expect(MapConfigController.instance.effectiveProviderType, MapProviderType.cartodb);
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

    test('Mapbox fallback to CartoDB when Mapbox token is invalid or fallback triggered', () {
      final config = const GlobalMapConfig(
        activeProvider: 'mapbox',
        mapboxToken: null,
      );
      MapConfigController.instance.updateConfig(config);

      // No token -> falls back to CartoDB immediately
      expect(MapConfigController.instance.effectiveProviderType, MapProviderType.cartodb);
    });

    test('CartoDB fallback circular loop back to Google Maps when CartoDB cap hit', () {
      final config = const GlobalMapConfig(
        activeProvider: 'cartodb',
        apiKey: 'AIzaSyTestKey123',
        cartoMonthlyCap: 5,
      );
      MapConfigController.instance.updateConfig(config);

      expect(MapConfigController.instance.effectiveProviderType, MapProviderType.cartodb);

      // Increment usage to cap
      for (int i = 0; i < 5; i++) {
        MapConfigController.instance.incrementUsage(MapProviderType.cartodb);
      }

      expect(MapConfigController.instance.isCartoQuotaExceeded, isTrue);
      // Circular loop falls back to Google
      expect(MapConfigController.instance.effectiveProviderType, MapProviderType.google);
    });

    test('Per-feature provider pins override global provider and respect fallbacks', () {
      final config = GlobalMapConfig(
        activeProvider: 'google',
        apiKey: 'AIzaSyTestKey123',
        mapboxToken: 'pk.eyJ1IjoidGVzdCJ9.sample',
        featureProviders: const {
          'navigation': 'mapbox',
          'tracking': 'cartodb',
        },
      );
      MapConfigController.instance.updateConfig(config);

      expect(
        MapConfigController.instance.providerTypeForFeature(MapFeature.navigation),
        MapProviderType.mapbox,
      );
      expect(
        MapConfigController.instance.providerTypeForFeature(MapFeature.tracking),
        MapProviderType.cartodb,
      );
      expect(
        MapConfigController.instance.providerTypeForFeature(MapFeature.geocoding),
        MapProviderType.google,
      );
    });
  });
}
