import 'package:flutter_test/flutter_test.dart';
import 'package:sese_core/sese_core.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('CallConfig Model & Serialization Tests', () {
    test('defaults to WebRTC provider and Google public STUN servers', () {
      const config = CallConfig();

      expect(config.providerType, equals(CallProviderType.webrtc));
      expect(config.stunServers, contains('stun:stun.l.google.com:19302'));
      expect(config.stunServers, contains('stun:stun1.l.google.com:19302'));
      expect(config.turnServers, isEmpty);
      expect(config.enableDiagnostics, isFalse);
    });

    test('serializes toMap and deserializes fromMap with STUN and TURN servers', () {
      const c1 = CallConfig(
        stunServers: ['stun:stun.l.google.com:19302'],
        turnServers: [
          {
            'urls': 'turn:relay.sesetech.com:3478?transport=udp',
            'username': 'u',
            'credential': 'p',
          },
        ],
        enableDiagnostics: true,
      );
      final map1 = c1.toMap();
      expect(map1['providerType'], equals('webrtc'));
      expect(map1['stunServers'], equals(['stun:stun.l.google.com:19302']));
      expect(map1['enableDiagnostics'], isTrue);

      final deserialized = CallConfig.fromMap(map1);
      expect(deserialized.providerType, equals(CallProviderType.webrtc));
      expect(deserialized.stunServers, equals(['stun:stun.l.google.com:19302']));
      expect(deserialized.turnServers.length, equals(1));
      expect(
        deserialized.turnServers.first['urls'],
        equals('turn:relay.sesetech.com:3478?transport=udp'),
      );
      expect(deserialized.enableDiagnostics, isTrue);
    });
  });

  group('CallConfigRepository Tests', () {
    setUp(() {
      SharedPreferences.setMockInitialValues({
        'sese_call_stun_servers': ['stun:stun.l.google.com:19302'],
        'sese_call_enable_diagnostics': true,
      });
    });

    test('loads saved preferences on initialize', () async {
      final repo = CallConfigRepository.instance;
      final config = await repo.loadConfig();

      expect(config.providerType, equals(CallProviderType.webrtc));
      expect(config.stunServers, contains('stun:stun.l.google.com:19302'));
      expect(config.enableDiagnostics, isTrue);
    });

    test('saveConfig updates currentConfig and notifies listeners', () async {
      final repo = CallConfigRepository.instance;
      await repo.loadConfig();

      final updated = repo.currentConfig.copyWith(
        enableDiagnostics: false,
      );

      final events = <CallConfig>[];
      final sub = repo.configStream.listen(events.add);

      await repo.saveConfig(updated);
      expect(repo.currentConfig.enableDiagnostics, isFalse);

      await Future.delayed(const Duration(milliseconds: 10));
      expect(events.isNotEmpty, isTrue);
      expect(events.last.enableDiagnostics, isFalse);

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

  group('CallServiceManager WebRTC State Tests', () {
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

    test('initializes with WebRTC provider and idle state', () {
      expect(manager.providerType, equals(CallProviderType.webrtc));
      expect(manager.currentState, equals(CallState.idle));
      expect(manager.isInitialized, isTrue);
      expect(manager.currentUserId, equals('test_user_1'));
    });

    test('rejectCall and endCall reset state cleanly', () async {
      await manager.rejectCall('call_test_1', reason: 'declined');
      expect(manager.currentState, equals(CallState.idle));

      await manager.endCall(reason: 'user_hangup');
      expect(manager.currentState, equals(CallState.ended));
    });

    test('clearUserSession resets state to idle and clears credentials', () async {
      await manager.clearUserSession();
      expect(manager.currentState, equals(CallState.idle));
      expect(manager.currentUserId, isNull);
      expect(manager.isInitialized, isFalse);
    });
  });
}
