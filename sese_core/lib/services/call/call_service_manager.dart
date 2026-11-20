import 'dart:async';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart';

import 'agora_call_service_impl.dart';
import 'call_config_repository.dart';
import 'i_call_service.dart';
import 'webrtc_call_service_impl.dart';

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
    _webrtcService.onConnectionFailed = (reason) {
      if (_configRepo.currentConfig.routingMode == CallRoutingMode.smartFallback &&
          !_isFallbackActive &&
          _currentState != CallState.connected &&
          _currentState != CallState.ended) {
        debugPrint('CallServiceManager: WebRTC ICE/connection failure ($reason). Triggering smart fallback to Agora...');
        _executeFallbackToAgora(reason: reason);
      }
    };
  }

  late final CallConfigRepository _configRepo;
  late final WebRtcCallServiceImpl _webrtcService;
  late final AgoraCallServiceImpl _agoraService;

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
  final Set<String> _terminalCallIds = {};

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

    // Forward incoming call events from WebRTC (Firestore /calls stream)
    await _serviceIncomingSub?.cancel();
    _serviceIncomingSub = _webrtcService.incomingCallStream.listen((session) {
      if (session != null && _terminalCallIds.contains(session.callId)) {
        return; // Ignore calls already rejected or ended
      }
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
    final newMode = (newProvider == CallProviderType.agora)
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

      // If in automatic mode and WebRTC emitted error before connecting, trigger silent fallback to Agora
      if (_configRepo.currentConfig.routingMode == CallRoutingMode.smartFallback &&
          !_isFallbackActive &&
          service == _webrtcService &&
          (state == CallState.error)) {
        debugPrint('CallServiceManager: WebRTC reported error before connection. Triggering smart fallback to Agora...');
        _executeFallbackToAgora(reason: 'WebRTC call error transition');
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

    // 3. Automatic Mode (Default): WebRTC Primary -> Agora Fallback.
    // Attempts WebRTC (Firebase signaling) first. If WebRTC fails to connect or times out,
    // automatically falls back to Agora RTC behind the scenes.
    _isFallbackActive = false;
    _currentActiveProvider = CallProviderType.webrtc;
    _pipeServiceEvents(_webrtcService);

    final timeoutSec = _configRepo.currentConfig.fallbackTimeoutSeconds;
    _fallbackTimer?.cancel();
    _fallbackTimer = Timer(Duration(seconds: timeoutSec), () {
      if (_currentState != CallState.connected && _currentState != CallState.ended) {
        debugPrint('CallServiceManager [AutoMode]: WebRTC connection watchdog timed out after $timeoutSec s.');
        _executeFallbackToAgora(reason: 'WebRTC connection timed out after $timeoutSec s');
      }
    });

    try {
      await _webrtcService.startCall(
        targetUserId: targetUserId,
        callId: callId,
        targetUserName: targetUserName,
        targetUserAvatar: targetUserAvatar,
        metadata: metadata,
      );
    } catch (e) {
      debugPrint('CallServiceManager [AutoMode]: WebRTC startCall exception: $e');
      await _executeFallbackToAgora(reason: 'WebRTC startCall exception: $e');
    }
  }

  /// Triggers a seamless, silent fallback to Agora without dropping the call UI.
  Future<void> _executeFallbackToAgora({required String reason}) async {
    if (_isFallbackActive || _currentState == CallState.connected || _currentState == CallState.ended) {
      return;
    }

    _isFallbackActive = true;
    _fallbackTimer?.cancel();
    _fallbackTimer = null;

    debugPrint('CallServiceManager [SmartFallback]: Seamlessly falling back to Agora RTC ($reason)...');

    // Abort local WebRTC session without closing the overall call document
    await _webrtcService.abortForFallback();

    // Switch active provider to Agora
    _currentActiveProvider = CallProviderType.agora;
    _pipeServiceEvents(_agoraService);

    // Notify Firestore signaling document that provider has fallen back to Agora
    if (_lastCallId != null && _safeFirestore != null) {
      try {
        await _safeFirestore!.collection('calls').doc(_lastCallId).update({
          'provider': CallProviderType.agora.name,
          'fallback': true,
          'fallbackReason': reason,
          'fallbackAt': FieldValue.serverTimestamp(),
        });
      } catch (e) {
        debugPrint('CallServiceManager: failed to sync fallback to Firestore: $e');
      }
    }

    _currentState = CallState.connecting;
    if (_currentSession != null) {
      _currentSession = _currentSession!.copyWith(
        provider: CallProviderType.agora,
        isFallbackActive: true,
        state: CallState.connecting,
      );
    }
    _stateController.add(CallState.connecting);

    try {
      await _agoraService.startCall(
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
      debugPrint('CallServiceManager [SmartFallback]: Fallback to Agora failed: $e');
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

    // Automatic mode: check signaling document for provider selection or fallback
    String providerStr = 'webrtc';
    if (_safeFirestore != null) {
      try {
        final doc = await _safeFirestore!.collection('calls').doc(callId).get();
        if (doc.exists) {
          final prov = doc.data()?['provider']?.toString().toLowerCase();
          if (prov == 'agora') {
            providerStr = 'agora';
          }
        }
      } catch (_) {}
    }

    if (providerStr == 'agora') {
      _currentActiveProvider = CallProviderType.agora;
      _pipeServiceEvents(_agoraService);
      await _agoraService.answerCall(callId);
      return;
    }

    // Default auto: answer on WebRTC, with failover to Agora if answering fails
    _currentActiveProvider = CallProviderType.webrtc;
    _pipeServiceEvents(_webrtcService);
    try {
      await _webrtcService.answerCall(callId);
    } catch (e) {
      if (mode == CallRoutingMode.smartFallback) {
        debugPrint('CallServiceManager: Answering WebRTC failed: $e. Dropping over to Agora...');
        _currentActiveProvider = CallProviderType.agora;
        _isFallbackActive = true;
        _pipeServiceEvents(_agoraService);
        await _agoraService.answerCall(callId);
      } else {
        rethrow;
      }
    }
  }

  @override
  Future<void> rejectCall(String callId, {String? reason}) async {
    _terminalCallIds.add(callId);
    _fallbackTimer?.cancel();
    _fallbackTimer = null;

    // Immediately dismiss any incoming overlay locally
    if (!_incomingCallController.isClosed) {
      _incomingCallController.add(null);
    }

    if (_safeFirestore != null) {
      try {
        await _safeFirestore!.collection('calls').doc(callId).update({
          'status': 'rejected',
          'endedAt': FieldValue.serverTimestamp(),
          'endReason': reason ?? 'declined_by_receiver',
          'updatedAt': FieldValue.serverTimestamp(),
        });
      } catch (_) {}
    }

    await _webrtcService.rejectCall(callId, reason: reason);
    await _agoraService.rejectCall(callId, reason: reason);
  }

  @override
  Future<void> endCall({String? reason}) async {
    _fallbackTimer?.cancel();
    _fallbackTimer = null;
    _isFallbackActive = false;

    // Immediately dismiss any incoming overlay locally
    if (!_incomingCallController.isClosed) {
      _incomingCallController.add(null);
    }

    // Terminate signaling document in Firestore immediately to prevent any loop or re-ringing
    final callId = _lastCallId ?? _currentSession?.callId;
    if (callId != null) {
      _terminalCallIds.add(callId);
      if (_safeFirestore != null) {
        try {
          await _safeFirestore!.collection('calls').doc(callId).update({
            'status': 'ended',
            'endedAt': FieldValue.serverTimestamp(),
            'endReason': reason ?? 'normal',
            'updatedAt': FieldValue.serverTimestamp(),
          });
        } catch (_) {}
      }
    }

    // Cleanly terminate both services so no hardware tracks or background listeners linger
    try {
      await _webrtcService.endCall(reason: reason);
    } catch (_) {}
    try {
      await _agoraService.endCall(reason: reason);
    } catch (_) {}

    _currentState = CallState.ended;
    _currentSession = null;
    if (!_stateController.isClosed) {
      _stateController.add(CallState.ended);
    }
    Future.delayed(const Duration(milliseconds: 600), () {
      if (_currentState == CallState.ended) {
        _currentState = CallState.idle;
        if (!_stateController.isClosed) {
          _stateController.add(CallState.idle);
        }
      }
    });
  }

  @override
  Future<void> endTripCalls(String tripId, {String? reason}) async {
    _fallbackTimer?.cancel();
    _fallbackTimer = null;
    _isFallbackActive = false;
    _terminalCallIds.add(tripId);

    if (!_incomingCallController.isClosed) {
      _incomingCallController.add(null);
    }

    await _webrtcService.endTripCalls(tripId, reason: reason);
    await _agoraService.endTripCalls(tripId, reason: reason);
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
  }
}
