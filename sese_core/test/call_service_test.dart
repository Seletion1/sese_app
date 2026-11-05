import 'package:flutter_test/flutter_test.dart';
import 'package:sese_core/sese_core.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('CallConfig Model & Serialization Tests', () {
    test('defaults to smartFallback, 10s timeout, and Google public STUN servers', () {
      const config = CallConfig();

      expect(config.routingMode, equals(CallRoutingMode.smartFallback));
      expect(config.providerType, equals(CallProviderType.webrtc));
      expect(config.fallbackTimeoutSeconds, equals(10));
      expect(config.stunServers, contains('stun:stun.l.google.com:19302'));
      expect(config.stunServers, contains('stun:stun1.l.google.com:19302'));
      expect(config.hasValidZegoCredentials, isFalse);
    });

    test('validates Zego credentials correctly', () {
      const invalidAppId = CallConfig(
        zegoAppId: 0,
        zegoAppSign: '0123456789abcdef0123456789abcdef',
      );
      expect(invalidAppId.hasValidZegoCredentials, isFalse);

      const invalidSign = CallConfig(
        zegoAppId: 123456,
        zegoAppSign: 'too_short',
      );
      expect(invalidSign.hasValidZegoCredentials, isFalse);

      const validConfig = CallConfig(
        zegoAppId: 123456,
        zegoAppSign: '0123456789abcdef0123456789abcdef',
      );
      expect(validConfig.hasValidZegoCredentials, isTrue);
    });

    test('serializes toMap and deserializes fromMap with all 3 routing modes', () {
      // 1. smartFallback
      const c1 = CallConfig(
        routingMode: CallRoutingMode.smartFallback,
        fallbackTimeoutSeconds: 15,
        zegoAppId: 98765,
        zegoAppSign: 'abcdef0123456789abcdef0123456789',
      );
      final map1 = c1.toMap();
      expect(map1['routingMode'], equals('smartFallback'));
      expect(map1['providerType'], equals('webrtc'));
      expect(map1['fallbackTimeoutSeconds'], equals(15));

      final deserialized1 = CallConfig.fromMap(map1);
      expect(deserialized1.routingMode, equals(CallRoutingMode.smartFallback));
      expect(deserialized1.fallbackTimeoutSeconds, equals(15));
      expect(deserialized1.zegoAppId, equals(98765));
      expect(deserialized1.zegoAppSign, equals('abcdef0123456789abcdef0123456789'));

      // 2. customP2pOnly
      const c2 = CallConfig(routingMode: CallRoutingMode.customP2pOnly);
      final deserialized2 = CallConfig.fromMap(c2.toMap());
      expect(deserialized2.routingMode, equals(CallRoutingMode.customP2pOnly));
      expect(deserialized2.providerType, equals(CallProviderType.webrtc));

      // 3. thirdPartyOnly
      const c3 = CallConfig(routingMode: CallRoutingMode.thirdPartyOnly);
      final deserialized3 = CallConfig.fromMap(c3.toMap());
      expect(deserialized3.routingMode, equals(CallRoutingMode.thirdPartyOnly));
      expect(deserialized3.providerType, equals(CallProviderType.zego));
    });

    test('deserialization backward compatibility with legacy providerType', () {
      final legacyZegoMap = {'providerType': 'zego'};
      final cZego = CallConfig.fromMap(legacyZegoMap);
      expect(cZego.routingMode, equals(CallRoutingMode.thirdPartyOnly));
      expect(cZego.providerType, equals(CallProviderType.zego));

      final legacyWebrtcMap = {'providerType': 'webrtc'};
      final cWebrtc = CallConfig.fromMap(legacyWebrtcMap);
      expect(cWebrtc.routingMode, equals(CallRoutingMode.smartFallback));
      expect(cWebrtc.providerType, equals(CallProviderType.webrtc));
    });
  });

  group('CallConfigRepository Tests', () {
    setUp(() {
      SharedPreferences.setMockInitialValues({
        'sese_call_routing_mode': 'customP2pOnly',
        'sese_call_fallback_timeout': 12,
        'sese_call_zego_app_id': 55555,
        'sese_call_zego_app_sign': '0123456789abcdef0123456789abcdef',
      });
    });

    test('loads saved preferences on initialize', () async {
      final repo = CallConfigRepository.instance;
      final config = await repo.loadConfig();

      expect(config.routingMode, equals(CallRoutingMode.customP2pOnly));
      expect(config.fallbackTimeoutSeconds, equals(12));
      expect(config.zegoAppId, equals(55555));
      expect(config.zegoAppSign, equals('0123456789abcdef0123456789abcdef'));
    });

    test('saveConfig updates currentConfig and notifies listeners', () async {
      final repo = CallConfigRepository.instance;
      await repo.loadConfig();

      final updated = repo.currentConfig.copyWith(
        routingMode: CallRoutingMode.smartFallback,
        fallbackTimeoutSeconds: 8,
      );

      final events = <CallConfig>[];
      final sub = repo.configStream.listen(events.add);

      await repo.saveConfig(updated);
      expect(repo.currentConfig.routingMode, equals(CallRoutingMode.smartFallback));
      expect(repo.currentConfig.fallbackTimeoutSeconds, equals(8));

      await Future.delayed(const Duration(milliseconds: 10));
      expect(events.isNotEmpty, isTrue);
      expect(events.last.routingMode, equals(CallRoutingMode.smartFallback));

      await sub.cancel();
    });
  });

  group('WebRtc Optimized Audio Constraints & STUN Config Tests', () {
    test('defaultAudioConstraints include echoCancellation, noiseSuppression, autoGainControl', () {
      expect(WebRtcCallServiceImpl.defaultAudioConstraints['echoCancellation'], isTrue);
      expect(WebRtcCallServiceImpl.defaultAudioConstraints['noiseSuppression'], isTrue);
      expect(WebRtcCallServiceImpl.defaultAudioConstraints['autoGainControl'], isTrue);
      expect(WebRtcCallServiceImpl.defaultAudioConstraints['highpassFilter'], isTrue);
    });

    test('defaultGoogleStunServers includes stun.l.google.com and stun1.l.google.com', () {
      expect(CallConfig.defaultGoogleStunServers, contains('stun:stun.l.google.com:19302'));
      expect(CallConfig.defaultGoogleStunServers, contains('stun:stun1.l.google.com:19302'));
    });
  });

  group('CallServiceManager Routing & Fallback State Tests', () {
    late CallServiceManager manager;

    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      manager = CallServiceManager.instance;
      await manager.initialize(
        currentUserId: 'test_user_1',
        displayName: 'Test Caller',
      );
    });

    tearDown(() async {
      await manager.clearUserSession();
    });

    test('initializes with default routing mode smartFallback', () {
      expect(manager.activeRoutingMode, equals(CallRoutingMode.smartFallback));
      expect(manager.isFallbackActive, isFalse);
      expect(manager.currentState, equals(CallState.idle));
      expect(manager.isInitialized, isTrue);
      expect(manager.currentUserId, equals('test_user_1'));
    });

    test('switchRoutingMode updates active routing policy', () async {
      await manager.switchRoutingMode(CallRoutingMode.thirdPartyOnly);
      expect(manager.activeRoutingMode, equals(CallRoutingMode.thirdPartyOnly));

      await manager.switchRoutingMode(CallRoutingMode.customP2pOnly);
      expect(manager.activeRoutingMode, equals(CallRoutingMode.customP2pOnly));

      await manager.switchRoutingMode(CallRoutingMode.smartFallback);
      expect(manager.activeRoutingMode, equals(CallRoutingMode.smartFallback));
    });

    test('rejectCall and endCall cancel any pending fallback timers and reset state', () async {
      await manager.rejectCall('call_test_1', reason: 'declined');
      expect(manager.isFallbackActive, isFalse);

      await manager.endCall(reason: 'user_hangup');
      expect(manager.isFallbackActive, isFalse);
    });

    test('clearUserSession resets state to idle and clears credentials', () async {
      await manager.clearUserSession();
      expect(manager.currentState, equals(CallState.idle));
      expect(manager.isFallbackActive, isFalse);
      expect(manager.currentUserId, isNull);
      expect(manager.isInitialized, isFalse);
    });
  });
}
