import 'dart:async';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart';

import 'agora_call_service_impl.dart';
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
/// 1. [CallRoutingMode.smartFallback] (Automatic - Default):
///    Uses Agora RTC Engine as the primary voice provider to leverage its 10,000 free monthly minutes.
///    Monitors global call minute usage in real time. If monthly usage reaches the failover threshold
///    (e.g. 9,900 out of 10,000 mins) or if connection fails/times out, seamlessly fails over to
///    custom native WebRTC without dropping the user experience.
/// 2. [CallRoutingMode.thirdPartyOnly] (Force Agora): Forced Agora RTC Engine.
/// 3. [CallRoutingMode.customP2pOnly] (Force Native WebRTC): Strict self-hosted WebRTC with zero vendor cost.
class CallServiceManager implements ICallService {
  static final CallServiceManager instance = CallServiceManager._internal();

  CallServiceManager._internal() {
    _configRepo = CallConfigRepository.instance;
    _webrtcService = WebRtcCallServiceImpl(configRepo: _configRepo);
    _agoraService = AgoraCallServiceImpl(configRepo: _configRepo);
    _zegoService = ZegoCallServiceImpl(configRepo: _configRepo);
  }

  late final CallConfigRepository _configRepo;
  late final WebRtcCallServiceImpl _webrtcService;
  late final AgoraCallServiceImpl _agoraService;
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

  CallProviderType _currentActiveProvider = CallProviderType.agora;
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

  /// Active calling provider type.
  CallProviderType get activeProviderType => _currentActiveProvider;

  /// True if the manager has been initialized for the current user.
  bool get isInitialized => _initialized;

  /// Active user credentials.
  String? get currentUserId => _currentUserId;
  String? get displayName => _displayName;
  String? get avatarUrl => _avatarUrl;

  /// True if a smart fallback to secondary provider is currently active for this session.
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
    switch (_currentActiveProvider) {
      case CallProviderType.agora:
        return _agoraService;
      case CallProviderType.zego:
        return _zegoService;
      case CallProviderType.webrtc:
        return _webrtcService;
    }
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

    await _agoraService.initialize(
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
      debugPrint('CallServiceManager: Calling config updated -> mode: ${config.routingMode}, provider: ${config.providerType}');
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
        await _agoraService.initialize(
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
    final newMode = (newProvider == CallProviderType.agora || newProvider == CallProviderType.zego)
        ? CallRoutingMode.thirdPartyOnly
        : CallRoutingMode.customP2pOnly;
    await switchRoutingMode(newMode);
  }

  void _pipeServiceEvents(ICallService service) {
    _serviceStateSub?.cancel();
    _serviceStateSub = service.stateStream.listen((state) {
      // If active call connected successfully, cancel watchdog timer
      if (state == CallState.connected) {
        _fallbackTimer?.cancel();
        _fallbackTimer = null;
      }

      // If in automatic mode and primary provider emitted error before connecting, trigger fallback
      if (_configRepo.currentConfig.routingMode == CallRoutingMode.smartFallback &&
          !_isFallbackActive &&
          (state == CallState.error)) {
        debugPrint('CallServiceManager: Primary provider reported error before connection. Triggering smart fallback to WebRTC...');
        _executeFallback(reason: 'Primary call error transition');
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
    final config = _configRepo.currentConfig;

    _lastTargetUserId = targetUserId;
    _lastCallId = callId;
    _lastTargetUserName = targetUserName;
    _lastTargetUserAvatar = targetUserAvatar;
    _lastMetadata = metadata;

    // 1. Force Native WebRTC (Custom P2P Only)
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

    // 2. Force Agora (Third-Party Only)
    if (mode == CallRoutingMode.thirdPartyOnly) {
      _currentActiveProvider = CallProviderType.agora;
      _isFallbackActive = false;
      _pipeServiceEvents(_agoraService);
      await _agoraService.startCall(
        targetUserId: targetUserId,
        callId: callId,
        targetUserName: targetUserName,
        targetUserAvatar: targetUserAvatar,
        metadata: metadata,
      );
      return;
    }

    // 3. Automatic / Smart Fallback mode (Default):
    // Uses Agora primary if minutes < failover threshold & valid credentials exist.
    // If usage reaches threshold (e.g. 9,900/10,000 mins) or connection fails/times out, fails over to WebRTC.
    if (config.isAgoraLimitReached || !config.hasValidAgoraCredentials) {
      debugPrint('CallServiceManager [AutoMode]: Minute threshold reached (${config.agoraCallsUsedMinutesThisMonth}/${config.agoraAutoFailoverThresholdMinutes}) or credentials missing. Auto-routing to WebRTC...');
      _currentActiveProvider = CallProviderType.webrtc;
      _isFallbackActive = true;
      _pipeServiceEvents(_webrtcService);
      await _webrtcService.startCall(
        targetUserId: targetUserId,
        callId: callId,
        targetUserName: targetUserName,
        targetUserAvatar: targetUserAvatar,
        metadata: {
          ...?metadata,
          'autoFailover': true,
          'reason': 'agora_threshold_reached_or_unconfigured',
        },
      );
      return;
    }

    _isFallbackActive = false;
    _currentActiveProvider = CallProviderType.agora;
    _pipeServiceEvents(_agoraService);

    final timeoutSec = _configRepo.currentConfig.fallbackTimeoutSeconds;
    _fallbackTimer?.cancel();
    _fallbackTimer = Timer(Duration(seconds: timeoutSec), () {
      if (_currentState != CallState.connected && _currentState != CallState.ended) {
        debugPrint('CallServiceManager [AutoMode]: Agora connection watchdog timed out after $timeoutSec s.');
        _executeFallback(reason: 'Agora connection timed out after $timeoutSec s');
      }
    });

    try {
      await _agoraService.startCall(
        targetUserId: targetUserId,
        callId: callId,
        targetUserName: targetUserName,
        targetUserAvatar: targetUserAvatar,
        metadata: metadata,
      );
    } catch (e) {
      debugPrint('CallServiceManager [AutoMode]: Agora startCall exception: $e');
      await _executeFallback(reason: 'Agora startCall exception: $e');
    }
  }

  /// Triggers a seamless fallback to the native WebRTC calling provider without dropping the UI.
  Future<void> _executeFallback({required String reason}) async {
    if (_isFallbackActive || _currentState == CallState.connected || _currentState == CallState.ended) {
      return;
    }

    _isFallbackActive = true;
    _fallbackTimer?.cancel();
    _fallbackTimer = null;

    debugPrint('CallServiceManager [SmartFallback]: Executing seamless fallback to native WebRTC ($reason)...');

    // Switch active provider to native WebRTC
    _currentActiveProvider = CallProviderType.webrtc;
    _pipeServiceEvents(_webrtcService);

    // Notify Firestore signaling document that provider has fallen back to WebRTC
    if (_lastCallId != null && _safeFirestore != null) {
      try {
        await _safeFirestore!.collection('calls').doc(_lastCallId).set({
          'provider': CallProviderType.webrtc.name,
          'fallback': true,
          'fallbackReason': reason,
          'fallbackAt': FieldValue.serverTimestamp(),
        }, SetOptions(merge: true));
      } catch (e) {
        debugPrint('CallServiceManager: failed to sync fallback to Firestore: $e');
      }
    }

    _currentState = CallState.connecting;
    if (_currentSession != null) {
      _currentSession = _currentSession!.copyWith(
        provider: CallProviderType.webrtc,
        isFallbackActive: true,
        state: CallState.connecting,
      );
    }
    _stateController.add(CallState.connecting);

    try {
      await _webrtcService.startCall(
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
      debugPrint('CallServiceManager [SmartFallback]: Fallback to WebRTC failed: $e');
      _currentState = CallState.error;
      _stateController.add(CallState.error);
    }
  }

  @override
  Future<void> answerCall(String callId) async {
    final mode = _configRepo.currentConfig.routingMode;

    if (mode == CallRoutingMode.customP2pOnly) {
      _currentActiveProvider = CallProviderType.webrtc;
      _pipeServiceEvents(_webrtcService);
      await _webrtcService.answerCall(callId);
      return;
    }

    if (mode == CallRoutingMode.thirdPartyOnly) {
      _currentActiveProvider = CallProviderType.agora;
      _pipeServiceEvents(_agoraService);
      await _agoraService.answerCall(callId);
      return;
    }

    // Automatic mode: check if caller triggered a fallback or specified provider
    if (_safeFirestore != null) {
      try {
        final doc = await _safeFirestore!.collection('calls').doc(callId).get();
        if (doc.exists) {
          final provStr = doc.data()?['provider']?.toString().toLowerCase();
          if (provStr == 'webrtc') {
            _currentActiveProvider = CallProviderType.webrtc;
            _pipeServiceEvents(_webrtcService);
            await _webrtcService.answerCall(callId);
            return;
          }
        }
      } catch (_) {}
    }

    // Default auto: answer on Agora
    _currentActiveProvider = CallProviderType.agora;
    _pipeServiceEvents(_agoraService);
    try {
      await _agoraService.answerCall(callId);
    } catch (e) {
      if (mode == CallRoutingMode.smartFallback) {
        debugPrint('CallServiceManager: Answering Agora failed: $e. Dropping over to WebRTC...');
        _currentActiveProvider = CallProviderType.webrtc;
        _isFallbackActive = true;
        _pipeServiceEvents(_webrtcService);
        await _webrtcService.answerCall(callId);
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
    await _agoraService.clearUserSession();
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
    await _agoraService.dispose();
    await _zegoService.dispose();
  }
}
