import 'dart:async';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart';

import 'call_config_repository.dart';
import 'i_call_service.dart';
import 'webrtc_call_service_impl.dart';

/// Singleton orchestrator for WebRTC in-app voice calling.
///
/// Implements [ICallService] to act as a unified facade for the UI
/// ([InAppCallScreen], [IncomingCallOverlay]).
class CallServiceManager implements ICallService {
  static final CallServiceManager instance = CallServiceManager._internal();

  CallServiceManager._internal() {
    _configRepo = CallConfigRepository.instance;
    _webrtcService = WebRtcCallServiceImpl(configRepo: _configRepo);
  }

  late final CallConfigRepository _configRepo;
  late final WebRtcCallServiceImpl _webrtcService;

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

  StreamSubscription<CallState>? _serviceStateSub;
  StreamSubscription<Duration>? _serviceDurationSub;
  StreamSubscription<CallSession?>? _serviceIncomingSub;
  final Set<String> _terminalCallIds = {};

  final _stateController = StreamController<CallState>.broadcast();
  final _durationController = StreamController<Duration>.broadcast();
  final _incomingCallController = StreamController<CallSession?>.broadcast();

  CallState _currentState = CallState.idle;
  CallSession? _currentSession;
  Duration _currentDuration = Duration.zero;

  /// True while the full-screen [InAppCallScreen] is mounted and visible.
  /// When false during an active call, [IncomingCallOverlay] renders the
  /// persistent floating mini-bar so users can multitask without ending the call.
  final ValueNotifier<bool> isCallUiExpanded = ValueNotifier<bool>(false);

  String? _lastCallId;

  @override
  CallProviderType get providerType => CallProviderType.webrtc;

  /// Active calling provider type.
  CallProviderType get activeProviderType => CallProviderType.webrtc;

  /// True if the manager has been initialized for the current user.
  bool get isInitialized => _initialized;

  /// Active user credentials.
  String? get currentUserId => _currentUserId;
  String? get displayName => _displayName;
  String? get avatarUrl => _avatarUrl;

  @override
  CallState get currentState => _currentState;

  @override
  CallSession? get currentSession =>
      _currentSession ?? _webrtcService.currentSession;

  /// Latest elapsed call duration for the active call session.
  Duration get currentDuration => _currentDuration;

  @override
  Stream<CallState> get stateStream => _stateController.stream;

  @override
  Stream<CallSession?> get incomingCallStream => _incomingCallController.stream;

  @override
  Stream<Duration> get durationStream => _durationController.stream;

  @override
  bool get isMuted => _webrtcService.isMuted;

  @override
  bool get isSpeakerOn => _webrtcService.isSpeakerOn;

  /// Active underlying WebRTC service.
  ICallService get activeProviderService => _webrtcService;

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

    await _serviceIncomingSub?.cancel();
    _serviceIncomingSub = _webrtcService.incomingCallStream.listen((session) {
      if (session != null && _terminalCallIds.contains(session.callId)) {
        return; // Ignore calls already rejected or ended
      }
      if (!_incomingCallController.isClosed) {
        _incomingCallController.add(session);
      }
    });

    _pipeServiceEvents(_webrtcService);
    _initialized = true;
  }

  void _pipeServiceEvents(ICallService service) {
    _serviceStateSub?.cancel();
    _serviceStateSub = service.stateStream.listen((state) {
      _currentState = state;
      _currentSession = service.currentSession;
      if (!_stateController.isClosed) {
        _stateController.add(state);
      }
    });

    _serviceDurationSub?.cancel();
    _serviceDurationSub = service.durationStream.listen((duration) {
      _currentDuration = duration;
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
    _lastCallId = callId;
    _pipeServiceEvents(_webrtcService);
    await _webrtcService.startCall(
      targetUserId: targetUserId,
      callId: callId,
      targetUserName: targetUserName,
      targetUserAvatar: targetUserAvatar,
      metadata: metadata,
    );
  }

  @override
  Future<void> answerCall(String callId) async {
    _lastCallId = callId;
    _pipeServiceEvents(_webrtcService);
    await _webrtcService.answerCall(callId);
  }

  @override
  Future<void> rejectCall(String callId, {String? reason}) async {
    _terminalCallIds.add(callId);

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
  }

  @override
  Future<void> endCall({String? reason}) async {
    if (!_incomingCallController.isClosed) {
      _incomingCallController.add(null);
    }

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

    try {
      await _webrtcService.endCall(reason: reason);
    } catch (e) {
      debugPrint('CallServiceManager: _webrtcService.endCall error: $e');
    }

    _currentState = CallState.ended;
    _currentSession = null;
    _currentDuration = Duration.zero;
    _lastCallId = null;
    isCallUiExpanded.value = false;
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
    if (tripId.isEmpty) return;
    if (_currentSession?.tripId == tripId ||
        _currentSession?.callId.contains(tripId) == true) {
      await endCall(reason: reason ?? 'trip_completed');
    }
    await _webrtcService.endTripCalls(tripId, reason: reason);
  }

  @override
  Future<void> toggleMute(bool muted) async {
    await _webrtcService.toggleMute(muted);
  }

  @override
  Future<void> toggleSpeaker(bool speakerOn) async {
    await _webrtcService.toggleSpeaker(speakerOn);
  }

  @override
  Future<void> clearUserSession() async {
    await _serviceStateSub?.cancel();
    _serviceStateSub = null;
    await _serviceDurationSub?.cancel();
    _serviceDurationSub = null;
    await _serviceIncomingSub?.cancel();
    _serviceIncomingSub = null;

    await _webrtcService.clearUserSession();

    _currentUserId = null;
    _displayName = null;
    _avatarUrl = null;
    _initialized = false;
    _currentState = CallState.idle;
    _currentSession = null;
    _currentDuration = Duration.zero;
    _lastCallId = null;
    isCallUiExpanded.value = false;
    _terminalCallIds.clear();
  }

  @override
  Future<void> dispose() async {
    await clearUserSession();
    await _webrtcService.dispose();
    await _stateController.close();
    await _durationController.close();
    await _incomingCallController.close();
  }
}
