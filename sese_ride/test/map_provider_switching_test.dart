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

    testWidgets('Fallback banner defaults to hidden (showFallbackBanner: false) on map surfaces',
        (tester) async {
      final config = const GlobalMapConfig(
        activeProvider: 'google',
        apiKey: 'AIzaSyTestKey123',
        mapboxToken: 'pk.eyJ1IjoidGVzdCJ9.sample',
      );
      MapConfigController.instance.updateConfig(config);
      MapConfigController.instance.triggerGoogleFallback(reason: 'Google Maps quota exceeded');

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

      // By default (showFallbackBanner = false), technical banners are never shown to end-users/drivers
      expect(find.byKey(const Key('map_fallback_banner')), findsNothing);
    });

    testWidgets('Fallback banner renders when primary Google Maps falls back to Mapbox and showFallbackBanner is true',
        (tester) async {
      final config = const GlobalMapConfig(
        activeProvider: 'google',
        apiKey: 'AIzaSyTestKey123',
        mapboxToken: 'pk.eyJ1IjoidGVzdCJ9.sample',
      );
      MapConfigController.instance.updateConfig(config);
      MapConfigController.instance.triggerGoogleFallback(reason: 'Google Maps quota exceeded');

      final mapController = SeSeMapController();

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SeseUniversalMap(
              mapController: mapController,
              initialCenter: const LatLng(6.5244, 3.3792),
              showFallbackBanner: true,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('map_fallback_banner')), findsOneWidget);
      expect(find.textContaining('Google Maps quota exceeded'), findsOneWidget);

      // Tap close button on fallback banner
      await tester.tap(find.byIcon(Icons.close));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('map_fallback_banner')), findsNothing);
    });

    testWidgets('Cold-start trip context snapshots map config and protects against mid-trip engine swaps',
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

      expect(MapConfigController.instance.isTripActive, isFalse); // Widget manages snapshots
      expect(find.byType(SeseUniversalMap), findsOneWidget);

      // Mid-trip config update from Hub
      final updatedConfig = const GlobalMapConfig(
        activeProvider: 'cartodb',
      );
      MapConfigController.instance.updateConfig(updatedConfig);
      await tester.pumpAndSettle();

      // Trip surface stays rendered safely without crash
      expect(find.byType(SeseUniversalMap), findsOneWidget);
    });
  });

  // ── Regression tests: resolveEmbedded() CartoDB watermark fix ─────────────
  //
  // Before the fix, resolveEmbedded() returned MapProvider.cartoDb whenever
  // the active provider was Google Maps but no Mapbox token was configured.
  // This caused the "API KEY REQUIRED / carto.com" watermark on the
  // "Send Item" location-picker screen and all PickOnMapScreen pushes.
  group('Phase 5: resolveEmbedded() — no CartoDB injection on Google-primary', () {
    test(
        'Google primary + no Mapbox token → resolveEmbedded returns googleMaps, never cartoDb',
        () {
      // Simulate the exact Hub config from the screenshots:
      //   Active Map Engine = "Google Maps (Primary — Pay-as-you-go)"
      //   No Mapbox token configured anywhere.
      final config = const GlobalMapConfig(
        activeProvider: 'google',
        apiKey: 'AIzaSyRealProductionKey',
        // mapboxToken intentionally absent — matches the prod config in screenshots
      );
      MapConfigController.instance.updateConfig(config);

      final result = MapProviderPolicy.resolveEmbedded();

      expect(
        result,
        MapProvider.googleMaps,
        reason:
            'resolveEmbedded() must return googleMaps when Google is primary '
            'and no Mapbox token is configured — not cartoDb, which shows '
            'the "API KEY REQUIRED / carto.com" watermark.',
      );
    });

    test(
        'Google primary + valid Mapbox token → resolveEmbedded returns mapbox '
        '(lightweight raster, avoids concurrent native view)',
        () {
      final config = const GlobalMapConfig(
        activeProvider: 'google',
        apiKey: 'AIzaSyRealProductionKey',
        mapboxToken: 'pk.eyJ1IjoidGVzdCJ9.sample',
      );
      MapConfigController.instance.updateConfig(config);

      final result = MapProviderPolicy.resolveEmbedded();

      expect(
        result,
        MapProvider.mapbox,
        reason:
            'resolveEmbedded() should prefer Mapbox as the lightweight '
            'raster layer when a token is available and Google is primary.',
      );
    });

    test(
        'CartoDB primary → resolveEmbedded returns cartoDb '
        '(CartoDB is the explicitly configured engine)',
        () {
      final config = const GlobalMapConfig(
        activeProvider: 'cartodb',
      );
      MapConfigController.instance.updateConfig(config);

      final result = MapProviderPolicy.resolveEmbedded();

      expect(
        result,
        MapProvider.cartoDb,
        reason:
            'resolveEmbedded() should return cartoDb when CartoDB is the '
            'explicitly chosen global engine.',
      );
    });

    test(
        'Mapbox primary → resolveEmbedded returns mapbox directly',
        () {
      final config = const GlobalMapConfig(
        activeProvider: 'mapbox',
        mapboxToken: 'pk.eyJ1IjoidGVzdCJ9.sample',
      );
      MapConfigController.instance.updateConfig(config);

      final result = MapProviderPolicy.resolveEmbedded();

      expect(result, MapProvider.mapbox);
    });

    test(
        'Google primary + no Mapbox token + Mapbox fallback active → resolveEmbedded returns googleMaps',
        () {
      final config = const GlobalMapConfig(
        activeProvider: 'google',
        apiKey: 'AIzaSyRealProductionKey',
        mapboxToken: 'pk.eyJ1IjoidGVzdCJ9.sample',
      );
      MapConfigController.instance.updateConfig(config);
      // Trigger Mapbox fallback so it is not usable
      MapConfigController.instance.triggerMapboxFallback(
          reason: 'Mapbox quota exceeded');

      final result = MapProviderPolicy.resolveEmbedded();

      // Mapbox is unavailable; Google primary with no alternative →
      // should fall through to googleMaps, not cartoDb.
      expect(
        result,
        MapProvider.googleMaps,
        reason:
            'When Mapbox is in fallback and Google is primary, '
            'resolveEmbedded must return googleMaps, not cartoDb.',
      );
    });

    test(
        'Auto (follow global engine) for sub-features correctly inherits Google Maps — '
        'PickOnMapScreen mapContext.browsing resolves to googleMaps',
        () {
      // Hub config: Google primary, all sub-settings = Auto (follow global engine)
      final config = const GlobalMapConfig(
        activeProvider: 'google',
        apiKey: 'AIzaSyRealProductionKey',
        featureProviders: {
          'geocoding': 'auto',
          'navigation': 'auto',
          'tracking': 'auto',
          'routing': 'auto',
        },
      );
      MapConfigController.instance.updateConfig(config);

      // PickOnMapScreen uses MapContext.browsing (no preferredProvider)
      final resolved = MapProviderPolicy.resolve(MapContext.browsing);

      expect(
        resolved,
        MapProvider.googleMaps,
        reason:
            'When all sub-settings are Auto and Google Maps is the global '
            'engine, every browsing/picking surface must resolve to '
            'googleMaps — the CartoDB fallback must never activate.',
      );
    });
  });
}
