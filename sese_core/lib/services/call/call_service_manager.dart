import 'dart:async';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart';

import 'call_config_repository.dart';
import 'i_call_service.dart';
import 'webrtc_call_service_impl.dart';
import 'zego_call_service_impl.dart';

/// Dynamic factory, singleton orchestrator, and smart-fallback manager for in-app calling.
///
/// Implements [ICallService] to act as a unified facade for the UI ([InAppCallScreen],
/// [IncomingCallOverlay]).
///
/// Supports 3 routing modes configured via Hub Settings / remote config:
/// 1. [CallRoutingMode.customP2pOnly]: Strict self-hosted WebRTC with zero vendor cost.
/// 2. [CallRoutingMode.thirdPartyOnly]: Forced plug-and-play third-party SDK (ZegoCloud).
/// 3. [CallRoutingMode.smartFallback] (Default): Attempts custom WebRTC first using Google STUN
///    servers; if connection fails, times out, or fails ICE gathering due to mobile carrier
///    NAT/firewall blocks, seamlessly drops over to the third-party API backend without
///    dropping the user experience.
class CallServiceManager implements ICallService {
  static final CallServiceManager instance = CallServiceManager._internal();

  CallServiceManager._internal() {
    _configRepo = CallConfigRepository.instance;
    _webrtcService = WebRtcCallServiceImpl(configRepo: _configRepo);
    _zegoService = ZegoCallServiceImpl(configRepo: _configRepo);
  }

  late final CallConfigRepository _configRepo;
  late final WebRtcCallServiceImpl _webrtcService;
  late final ZegoCallServiceImpl _zegoService;

  static FirebaseFirestore? get _safeFirestore {
    try {
      return FirebaseFirestore.instance;
    } catch (_) {
      return null;
    }
  }

  String? _currentUserId;
  String? _displayName;
  String? _avatarUrl;
  bool _initialized = false;

  CallProviderType _currentActiveProvider = CallProviderType.webrtc;
  bool _isFallbackActive = false;

  Timer? _fallbackTimer;
  StreamSubscription<CallConfig>? _configSub;
  StreamSubscription<CallState>? _serviceStateSub;
  StreamSubscription<Duration>? _serviceDurationSub;
  StreamSubscription<CallSession?>? _serviceIncomingSub;

  final _stateController = StreamController<CallState>.broadcast();
  final _durationController = StreamController<Duration>.broadcast();
  final _incomingCallController = StreamController<CallSession?>.broadcast();

  CallState _currentState = CallState.idle;
  CallSession? _currentSession;

  String? _lastTargetUserId;
  String? _lastCallId;
  String? _lastTargetUserName;
  String? _lastTargetUserAvatar;
  Map<String, dynamic>? _lastMetadata;

  @override
  CallProviderType get providerType => _currentActiveProvider;

  /// Current routing mode configured in repository.
  CallRoutingMode get activeRoutingMode => _configRepo.currentConfig.routingMode;

  /// Active calling provider type (for backwards compatibility).
  CallProviderType get activeProviderType => _currentActiveProvider;

  /// True if the manager has been initialized for the current user.
  bool get isInitialized => _initialized;

  /// Active user credentials.
  String? get currentUserId => _currentUserId;
  String? get displayName => _displayName;
  String? get avatarUrl => _avatarUrl;

  /// True if a smart fallback from WebRTC to third-party SDK is currently engaged.
  bool get isFallbackActive => _isFallbackActive;

  @override
  CallState get currentState => _currentState;

  @override
  CallSession? get currentSession => _currentSession ?? activeProviderService.currentSession;

  @override
  Stream<CallState> get stateStream => _stateController.stream;

  @override
  Stream<CallSession?> get incomingCallStream => _incomingCallController.stream;

  @override
  Stream<Duration> get durationStream => _durationController.stream;

  @override
  bool get isMuted => activeProviderService.isMuted;

  @override
  bool get isSpeakerOn => activeProviderService.isSpeakerOn;

  /// The underlying concrete provider service handling the active audio session.
  ICallService get activeProviderService {
    return _currentActiveProvider == CallProviderType.zego ? _zegoService : _webrtcService;
  }

  /// Active service instance (maintains compatibility with callers reading activeService).
  ICallService get activeService => this;

  /// Initializes the calling subsystem for [currentUserId].
  @override
  Future<void> initialize({
    required String currentUserId,
    String? displayName,
    String? avatarUrl,
  }) async {
    _currentUserId = currentUserId;
    _displayName = displayName;
    _avatarUrl = avatarUrl;

    await _configRepo.loadConfig();

    await _webrtcService.initialize(
      currentUserId: currentUserId,
      displayName: displayName,
      avatarUrl: avatarUrl,
    );

    await _zegoService.initialize(
      currentUserId: currentUserId,
      displayName: displayName,
      avatarUrl: avatarUrl,
    );

    // Forward incoming call events from WebRTC (Firestore /calls stream)
    await _serviceIncomingSub?.cancel();
    _serviceIncomingSub = _webrtcService.incomingCallStream.listen((session) {
      if (!_incomingCallController.isClosed) {
        _incomingCallController.add(session);
      }
    });

    _configSub?.cancel();
    _configSub = _configRepo.configStream.listen((config) async {
      debugPrint('CallServiceManager: Active calling config updated -> mode: ${config.routingMode}, provider: ${config.providerType}');
    });

    _initialized = true;
  }

  /// Dynamically updates the active calling routing mode.
  Future<void> switchRoutingMode(CallRoutingMode newMode) async {
    final current = _configRepo.currentConfig;
    if (current.routingMode == newMode) return;

    final updated = current.copyWith(routingMode: newMode);
    await _configRepo.saveConfig(updated);

    if (_initialized && _currentUserId != null) {
      if (newMode == CallRoutingMode.thirdPartyOnly) {
        await _zegoService.initialize(
          currentUserId: _currentUserId!,
          displayName: _displayName,
          avatarUrl: _avatarUrl,
        );
      } else {
        await _webrtcService.initialize(
          currentUserId: _currentUserId!,
          displayName: _displayName,
          avatarUrl: _avatarUrl,
        );
      }
    }
  }

  /// Dynamically switches the active calling provider (backwards compatibility).
  Future<void> switchProvider(CallProviderType newProvider) async {
    final newMode = newProvider == CallProviderType.zego
        ? CallRoutingMode.thirdPartyOnly
        : CallRoutingMode.customP2pOnly;
    await switchRoutingMode(newMode);
  }

  void _pipeServiceEvents(ICallService service) {
    _serviceStateSub?.cancel();
    _serviceStateSub = service.stateStream.listen((state) {
      // If WebRTC connected successfully, cancel watchdog timer
      if (state == CallState.connected) {
        _fallbackTimer?.cancel();
        _fallbackTimer = null;
      }

      // If in smart fallback and WebRTC emitted error before connecting, do not terminate UI
      if (_configRepo.currentConfig.routingMode == CallRoutingMode.smartFallback &&
          !_isFallbackActive &&
          (state == CallState.error) &&
          _configRepo.currentConfig.hasValidZegoCredentials) {
        debugPrint('CallServiceManager: WebRTC reported error before connection. Triggering smart fallback...');
        _executeFallback(reason: 'WebRTC error transition');
        return;
      }

      _currentState = state;
      _currentSession = service.currentSession;
      if (!_stateController.isClosed) {
        _stateController.add(state);
      }
    });

    _serviceDurationSub?.cancel();
    _serviceDurationSub = service.durationStream.listen((duration) {
      if (!_durationController.isClosed) {
        _durationController.add(duration);
      }
    });
  }

  @override
  Future<void> startCall({
    required String targetUserId,
    required String callId,
    String? targetUserName,
    String? targetUserAvatar,
    Map<String, dynamic>? metadata,
  }) async {
    final mode = _configRepo.currentConfig.routingMode;

    _lastTargetUserId = targetUserId;
    _lastCallId = callId;
    _lastTargetUserName = targetUserName;
    _lastTargetUserAvatar = targetUserAvatar;
    _lastMetadata = metadata;

    // 1. Third-Party Only mode: Force ZegoCloud directly
    if (mode == CallRoutingMode.thirdPartyOnly) {
      _currentActiveProvider = CallProviderType.zego;
      _isFallbackActive = false;
      _pipeServiceEvents(_zegoService);
      await _zegoService.startCall(
        targetUserId: targetUserId,
        callId: callId,
        targetUserName: targetUserName,
        targetUserAvatar: targetUserAvatar,
        metadata: metadata,
      );
      return;
    }

    // 2. Custom P2P Only mode: Strict WebRTC
    if (mode == CallRoutingMode.customP2pOnly) {
      _currentActiveProvider = CallProviderType.webrtc;
      _isFallbackActive = false;
      _pipeServiceEvents(_webrtcService);
      await _webrtcService.startCall(
        targetUserId: targetUserId,
        callId: callId,
        targetUserName: targetUserName,
        targetUserAvatar: targetUserAvatar,
        metadata: metadata,
      );
      return;
    }

    // 3. Automatic / Smart Fallback mode (Default):
    // Tries custom WebRTC first. If connection fails or times out, seamlessly drops over to Zego.
    _isFallbackActive = false;
    _currentActiveProvider = CallProviderType.webrtc;
    _pipeServiceEvents(_webrtcService);

    final timeoutSec = _configRepo.currentConfig.fallbackTimeoutSeconds;
    _fallbackTimer?.cancel();
    _fallbackTimer = Timer(Duration(seconds: timeoutSec), () {
      if (_currentState != CallState.connected && _currentState != CallState.ended) {
        debugPrint('CallServiceManager [SmartFallback]: Connection watchdog timed out after $timeoutSec s.');
        _executeFallback(reason: 'WebRTC connection timed out after $timeoutSec s');
      }
    });

    _webrtcService.onConnectionFailed = (reason) {
      if (_currentState != CallState.connected && _currentState != CallState.ended) {
        debugPrint('CallServiceManager [SmartFallback]: WebRTC ICE/connection failure: $reason');
        _executeFallback(reason: reason);
      }
    };

    try {
      await _webrtcService.startCall(
        targetUserId: targetUserId,
        callId: callId,
        targetUserName: targetUserName,
        targetUserAvatar: targetUserAvatar,
        metadata: metadata,
      );
    } catch (e) {
      debugPrint('CallServiceManager [SmartFallback]: WebRTC startCall exception: $e');
      if (_configRepo.currentConfig.hasValidZegoCredentials) {
        await _executeFallback(reason: 'WebRTC startCall exception: $e');
      } else {
        rethrow;
      }
    }
  }

  /// Triggers a seamless fallback to the third-party calling provider without dropping the UI.
  Future<void> _executeFallback({required String reason}) async {
    if (_isFallbackActive || _currentState == CallState.connected || _currentState == CallState.ended) {
      return;
    }

    _isFallbackActive = true;
    _fallbackTimer?.cancel();
    _fallbackTimer = null;

    final config = _configRepo.currentConfig;
    if (!config.hasValidZegoCredentials) {
      debugPrint('CallServiceManager [SmartFallback]: Cannot fall back — ZegoCloud credentials unconfigured.');
      _currentState = CallState.error;
      _stateController.add(CallState.error);
      return;
    }

    debugPrint('CallServiceManager [SmartFallback]: Executing seamless fallback to third-party provider ($reason)...');

    // Abort WebRTC session cleanly without terminating the call lifecycle
    await _webrtcService.abortForFallback();

    // Switch active provider to Zego
    _currentActiveProvider = CallProviderType.zego;
    _pipeServiceEvents(_zegoService);

    // Notify Firestore signaling document that provider has fallen back to Zego
    if (_lastCallId != null && _safeFirestore != null) {
      try {
        await _safeFirestore!.collection('calls').doc(_lastCallId).set({
          'provider': CallProviderType.zego.name,
          'fallback': true,
          'fallbackReason': reason,
          'fallbackAt': FieldValue.serverTimestamp(),
        }, SetOptions(merge: true));
      } catch (e) {
        debugPrint('CallServiceManager: failed to sync fallback to Firestore: $e');
      }
    }

    // Keep session state in connecting so UI transitions cleanly
    _currentState = CallState.connecting;
    if (_currentSession != null) {
      _currentSession = _currentSession!.copyWith(
        provider: CallProviderType.zego,
        isFallbackActive: true,
        state: CallState.connecting,
      );
    }
    _stateController.add(CallState.connecting);

    // Re-initiate call via third-party SDK
    try {
      await _zegoService.startCall(
        targetUserId: _lastTargetUserId!,
        callId: _lastCallId!,
        targetUserName: _lastTargetUserName,
        targetUserAvatar: _lastTargetUserAvatar,
        metadata: {
          ...?_lastMetadata,
          'fallback': true,
          'fallbackReason': reason,
        },
      );
    } catch (e) {
      debugPrint('CallServiceManager [SmartFallback]: Fallback to Zego failed: $e');
      _currentState = CallState.error;
      _stateController.add(CallState.error);
    }
  }

  @override
  Future<void> answerCall(String callId) async {
    final mode = _configRepo.currentConfig.routingMode;

    if (mode == CallRoutingMode.thirdPartyOnly) {
      _currentActiveProvider = CallProviderType.zego;
      _pipeServiceEvents(_zegoService);
      await _zegoService.answerCall(callId);
      return;
    }

    // Check if caller triggered a fallback on this call
    if (_safeFirestore != null) {
      try {
        final doc = await _safeFirestore!.collection('calls').doc(callId).get();
        if (doc.exists && doc.data()?['provider'] == CallProviderType.zego.name) {
          debugPrint('CallServiceManager: Caller triggered fallback to Zego. Answering on Zego...');
          _currentActiveProvider = CallProviderType.zego;
          _isFallbackActive = true;
          _pipeServiceEvents(_zegoService);
          await _zegoService.answerCall(callId);
          return;
        }
      } catch (_) {}
    }

    // Default: answer on WebRTC
    _currentActiveProvider = CallProviderType.webrtc;
    _pipeServiceEvents(_webrtcService);
    try {
      await _webrtcService.answerCall(callId);
    } catch (e) {
      if (mode == CallRoutingMode.smartFallback && _configRepo.currentConfig.hasValidZegoCredentials) {
        debugPrint('CallServiceManager: Answering WebRTC failed: $e. Dropping over to Zego...');
        await _webrtcService.abortForFallback();
        _currentActiveProvider = CallProviderType.zego;
        _isFallbackActive = true;
        _pipeServiceEvents(_zegoService);
        await _zegoService.answerCall(callId);
      } else {
        rethrow;
      }
    }
  }

  @override
  Future<void> rejectCall(String callId, {String? reason}) async {
    _fallbackTimer?.cancel();
    _fallbackTimer = null;
    await activeProviderService.rejectCall(callId, reason: reason);
  }

  @override
  Future<void> endCall({String? reason}) async {
    _fallbackTimer?.cancel();
    _fallbackTimer = null;
    _isFallbackActive = false;
    await activeProviderService.endCall(reason: reason);
  }

  @override
  Future<void> toggleMute(bool muted) async {
    await activeProviderService.toggleMute(muted);
  }

  @override
  Future<void> toggleSpeaker(bool speakerOn) async {
    await activeProviderService.toggleSpeaker(speakerOn);
  }

  @override
  Future<void> clearUserSession() async {
    _fallbackTimer?.cancel();
    _fallbackTimer = null;
    _isFallbackActive = false;
    await _configSub?.cancel();
    _configSub = null;
    await _serviceStateSub?.cancel();
    _serviceStateSub = null;
    await _serviceDurationSub?.cancel();
    _serviceDurationSub = null;
    await _serviceIncomingSub?.cancel();
    _serviceIncomingSub = null;

    await _webrtcService.clearUserSession();
    await _zegoService.clearUserSession();

    _currentUserId = null;
    _displayName = null;
    _avatarUrl = null;
    _currentState = CallState.idle;
    _currentSession = null;
    _initialized = false;
  }

  @override
  Future<void> dispose() async {
    await clearUserSession();
    await _stateController.close();
    await _durationController.close();
    await _incomingCallController.close();
    await _webrtcService.dispose();
    await _zegoService.dispose();
  }
}
