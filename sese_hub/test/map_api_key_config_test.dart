import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sese_core/sese_core.dart';
import 'package:sese_hub/features/settings/calling_config_screen.dart';
import 'package:sese_hub/features/settings/map_api_key_config_screen.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _FakeApiKeysService extends ApiKeysService {
  ApiKeysConfig config;
  bool saveCalled = false;

  _FakeApiKeysService([this.config = const ApiKeysConfig()]);

  @override
  Future<ApiKeysConfig> fetchApiKeys() async => config;

  @override
  Future<void> saveApiKeys(ApiKeysConfig newConfig) async {
    saveCalled = true;
    config = newConfig;
  }
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  testWidgets('MapApiKeyConfigScreen renders all form fields and controls', (tester) async {
    tester.view.physicalSize = const Size(1280, 1800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    final fakeService = _FakeApiKeysService(
      const ApiKeysConfig(
        activeMapProvider: 'google',
        googleAndroidKey: 'AIzaFakeAndroidKey',
        googleIosKey: 'AIzaFakeIosKey',
        googleWebKey: 'AIzaFakeWebKey',
        mapboxAndroidToken: 'pk.fakeAndroidToken',
        mapboxIosToken: 'pk.fakeIosToken',
        mapboxWebToken: 'pk.fakeWebToken',
      ),
    );

    await tester.pumpWidget(
      MaterialApp(
        home: MapApiKeyConfigScreen(apiKeysService: fakeService),
      ),
    );

    await tester.pumpAndSettle();

    // Verify Title & Top Actions
    expect(find.text('Map & API Key Management'), findsOneWidget);
    expect(find.byKey(const Key('map_api_keys_save_button')), findsOneWidget);

    // Verify Form Input Fields
    expect(find.byKey(const Key('input_google_maps_android_key')), findsOneWidget);
    expect(find.byKey(const Key('input_google_maps_ios_key')), findsOneWidget);
    expect(find.byKey(const Key('input_google_maps_web_key')), findsOneWidget);

    expect(find.byKey(const Key('input_mapbox_android_token')), findsOneWidget);
    expect(find.byKey(const Key('input_mapbox_ios_token')), findsOneWidget);
    expect(find.byKey(const Key('input_mapbox_web_token')), findsOneWidget);

    // Verify Provider Selection options
    expect(find.text('Google Maps'), findsOneWidget);
    expect(find.text('Mapbox'), findsOneWidget);
  });

  testWidgets('Validation blocks saving when all credentials are empty', (tester) async {
    final fakeService = _FakeApiKeysService(
      const ApiKeysConfig(
        activeMapProvider: 'google',
        googleAndroidKey: '',
        googleIosKey: '',
        googleWebKey: '',
        mapboxAndroidToken: '',
        mapboxIosToken: '',
        mapboxWebToken: '',
      ),
    );

    await tester.pumpWidget(
      MaterialApp(
        home: MapApiKeyConfigScreen(apiKeysService: fakeService),
      ),
    );

    await tester.pumpAndSettle();

    // Attempt save with empty keys
    await tester.tap(find.byKey(const Key('map_api_keys_save_button')));
    await tester.pumpAndSettle();

    expect(fakeService.saveCalled, isFalse);
    expect(
      find.text('Cannot save empty configuration. Please provide at least one valid API key or token.'),
      findsOneWidget,
    );
  });

  testWidgets('Successfully saves configuration and updates Firestore service', (tester) async {
    final fakeService = _FakeApiKeysService(
      const ApiKeysConfig(
        activeMapProvider: 'google',
        googleAndroidKey: 'AIzaInitialAndroid',
      ),
    );

    await tester.pumpWidget(
      MaterialApp(
        home: MapApiKeyConfigScreen(apiKeysService: fakeService),
      ),
    );

    await tester.pumpAndSettle();

    // Scroll to and enter updated key
    final androidKeyFinder = find.byKey(const Key('input_google_maps_android_key'));
    await tester.dragUntilVisible(
      androidKeyFinder,
      find.byType(ListView),
      const Offset(0, -300),
    );
    await tester.pumpAndSettle();
    await tester.enterText(
      androidKeyFinder,
      'AIzaUpdatedAndroidKey123',
    );

    await tester.tap(find.byKey(const Key('map_api_keys_save_button')));
    await tester.pumpAndSettle();

    expect(fakeService.saveCalled, isTrue);
    expect(fakeService.config.googleAndroidKey, 'AIzaUpdatedAndroidKey123');
    expect(find.text('Map & API Key configuration saved successfully!'), findsOneWidget);
  });

  testWidgets('CallingConfigScreen and MapApiKeyConfigScreen render without overflow on 360px narrow screen', (tester) async {
    tester.view.physicalSize = const Size(360, 780);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      const MaterialApp(
        home: CallingConfigScreen(),
      ),
    );
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
    await tester.pumpAndSettle();
    expect(find.text('Calling & VoIP Settings'), findsOneWidget);
    final pipelineFinder = find.text('Test In-App Call Pipeline');
    await tester.dragUntilVisible(
      pipelineFinder,
      find.byType(Scrollable).first,
      const Offset(0, -300),
    );
    await tester.pumpAndSettle();
    expect(pipelineFinder, findsOneWidget);

    final fakeService = _FakeApiKeysService(
      const ApiKeysConfig(
        activeMapProvider: 'google',
        googleAndroidKey: 'AIzaTest',
      ),
    );
    await tester.pumpWidget(
      MaterialApp(
        home: MapApiKeyConfigScreen(apiKeysService: fakeService),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Google Maps'), findsOneWidget);
    expect(find.text('Mapbox'), findsOneWidget);
    final resetBtnFinder = find.byKey(const Key('reset_usage_counters_btn'));
    await tester.dragUntilVisible(
      resetBtnFinder,
      find.byType(ListView),
      const Offset(0, -300),
    );
    await tester.pumpAndSettle();
    expect(resetBtnFinder, findsOneWidget);
  });
}
