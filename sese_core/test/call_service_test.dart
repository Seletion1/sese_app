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
      expect(config.hasValidAgoraCredentials, isFalse);
      expect(config.hasValidZegoCredentials, isFalse);
    });

    test('validates Agora and Zego credentials correctly', () {
      const invalidAgora = CallConfig(agoraAppId: '');
      expect(invalidAgora.hasValidAgoraCredentials, isFalse);

      const validAgora = CallConfig(agoraAppId: 'cd70ed7adfca42f7bcadc14259a939c4');
      expect(validAgora.hasValidAgoraCredentials, isTrue);

      const invalidZego = CallConfig(
        zegoAppId: 0,
        zegoAppSign: '0123456789abcdef0123456789abcdef',
      );
      expect(invalidZego.hasValidZegoCredentials, isFalse);

      const validZego = CallConfig(
        zegoAppId: 123456,
        zegoAppSign: '0123456789abcdef0123456789abcdef',
      );
      expect(validZego.hasValidZegoCredentials, isTrue);
    });

    test('evaluates isAgoraLimitReached correctly', () {
      const belowLimit = CallConfig(
        agoraCallsUsedMinutesThisMonth: 9800,
        agoraAutoFailoverThresholdMinutes: 9900,
      );
      expect(belowLimit.isAgoraLimitReached, isFalse);

      const atLimit = CallConfig(
        agoraCallsUsedMinutesThisMonth: 9900,
        agoraAutoFailoverThresholdMinutes: 9900,
      );
      expect(atLimit.isAgoraLimitReached, isTrue);

      const overLimit = CallConfig(
        agoraCallsUsedMinutesThisMonth: 9950,
        agoraAutoFailoverThresholdMinutes: 9900,
      );
      expect(overLimit.isAgoraLimitReached, isTrue);
    });

    test('serializes toMap and deserializes fromMap with all 3 routing modes (omits secret certificate)', () {
      // 1. smartFallback
      const c1 = CallConfig(
        routingMode: CallRoutingMode.smartFallback,
        fallbackTimeoutSeconds: 15,
        agoraAppId: 'cd70ed7adfca42f7bcadc14259a939c4',
        agoraAppCertificate: '5e0b3b9e939f4338be3e531e0933831f',
        agoraCallsUsedMinutesThisMonth: 500,
      );
      final map1 = c1.toMap();
      expect(map1['routingMode'], equals('smartFallback'));
      expect(map1['providerType'], equals('webrtc'));
      expect(map1['fallbackTimeoutSeconds'], equals(15));
      expect(map1['agoraAppId'], equals('cd70ed7adfca42f7bcadc14259a939c4'));
      expect(map1.containsKey('agoraAppCertificate'), isFalse);

      final deserialized1 = CallConfig.fromMap(map1);
      expect(deserialized1.routingMode, equals(CallRoutingMode.smartFallback));
      expect(deserialized1.fallbackTimeoutSeconds, equals(15));
      expect(deserialized1.agoraAppId, equals('cd70ed7adfca42f7bcadc14259a939c4'));
      expect(deserialized1.agoraAppCertificate, isNull);

      // 2. customP2pOnly
      const c2 = CallConfig(routingMode: CallRoutingMode.customP2pOnly);
      final deserialized2 = CallConfig.fromMap(c2.toMap());
      expect(deserialized2.routingMode, equals(CallRoutingMode.customP2pOnly));
      expect(deserialized2.providerType, equals(CallProviderType.webrtc));

      // 3. thirdPartyOnly
      const c3 = CallConfig(routingMode: CallRoutingMode.thirdPartyOnly);
      final deserialized3 = CallConfig.fromMap(c3.toMap());
      expect(deserialized3.routingMode, equals(CallRoutingMode.thirdPartyOnly));
      expect(deserialized3.providerType, equals(CallProviderType.agora));
    });

    test('deserialization backward compatibility with legacy providerType and aliases', () {
      final legacyZegoMap = {'providerType': 'zego'};
      final cZego = CallConfig.fromMap(legacyZegoMap);
      expect(cZego.routingMode, equals(CallRoutingMode.thirdPartyOnly));

      final legacyWebrtcMap = {'providerType': 'webrtc'};
      final cWebrtc = CallConfig.fromMap(legacyWebrtcMap);
      expect(cWebrtc.routingMode, equals(CallRoutingMode.smartFallback));

      final aliasAutoMap = {'routingMode': 'auto'};
      final cAuto = CallConfig.fromMap(aliasAutoMap);
      expect(cAuto.routingMode, equals(CallRoutingMode.smartFallback));

      final aliasForceAgora = {'routingMode': 'force_agora'};
      final cForceAgora = CallConfig.fromMap(aliasForceAgora);
      expect(cForceAgora.routingMode, equals(CallRoutingMode.thirdPartyOnly));
    });
  });

  group('CallConfigRepository Tests', () {
    setUp(() {
      SharedPreferences.setMockInitialValues({
        'sese_call_routing_mode': 'customP2pOnly',
        'sese_call_fallback_timeout': 12,
        'sese_call_agora_app_id': 'cd70ed7adfca42f7bcadc14259a939c4',
        'sese_call_agora_used_mins': 120,
      });
    });

    test('loads saved preferences on initialize and purges legacy AppSign', () async {
      final repo = CallConfigRepository.instance;
      final config = await repo.loadConfig();

      expect(config.routingMode, equals(CallRoutingMode.customP2pOnly));
      expect(config.fallbackTimeoutSeconds, equals(12));
      expect(config.agoraAppId, equals('cd70ed7adfca42f7bcadc14259a939c4'));
      expect(config.agoraCallsUsedMinutesThisMonth, equals(120));
      expect(config.agoraAppCertificate, isNull);
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
