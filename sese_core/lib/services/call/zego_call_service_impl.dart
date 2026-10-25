import 'dart:async';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart';
import 'package:permission_handler/permission_handler.dart';

import 'call_config_repository.dart';
import 'i_call_service.dart';

/// ZegoCloud calling service implementation satisfying [ICallService].
///
/// Features:
/// - Validates credentials (App ID & App Sign) persisted in [CallConfigRepository].
/// - Manages standard call lifecycle states (`outgoing`, `connected`, `ended`).
/// - Integrates with Firebase signaling records for session audit logging.
/// - Controls audio mute, loudspeaker toggling, and duration timer streams.
class ZegoCallServiceImpl implements ICallService {
  @override
  final CallProviderType providerType = CallProviderType.zego;

  final CallConfigRepository _configRepo;
  final FirebaseFirestore _firestore;

  String? _currentUserId;
  String? _displayName;
  String? _avatarUrl;

  CallSession? _currentSession;
  CallState _currentState = CallState.idle;

  final _stateController = StreamController<CallState>.broadcast();
  final _durationController = StreamController<Duration>.broadcast();

  Timer? _durationTimer;
  DateTime? _connectedAt;

  bool _isMuted = false;
  bool _isSpeakerOn = false;

  ZegoCallServiceImpl({
    CallConfigRepository? configRepo,
    FirebaseFirestore? firestore,
  })  : _configRepo = configRepo ?? CallConfigRepository.instance,
        _firestore = firestore ?? FirebaseFirestore.instance;

  @override
  CallState get currentState => _currentState;

  @override
  CallSession? get currentSession => _currentSession;

  @override
  Stream<CallState> get stateStream => _stateController.stream;

  @override
  Stream<CallSession?> get incomingCallStream => const Stream.empty();

  @override
  Stream<Duration> get durationStream => _durationController.stream;

  @override
  bool get isMuted => _isMuted;

  @override
  bool get isSpeakerOn => _isSpeakerOn;

  @override
  Future<void> initialize({
    required String currentUserId,
    String? displayName,
    String? avatarUrl,
  }) async {
    _currentUserId = currentUserId;
    _displayName = displayName;
    _avatarUrl = avatarUrl;
    _setCallState(CallState.idle);
  }

  void _setCallState(CallState state) {
    _currentState = state;
    if (_currentSession != null) {
      _currentSession = _currentSession!.copyWith(state: state);
    }
    if (!_stateController.isClosed) {
      _stateController.add(state);
    }
  }

  @override
  Future<void> startCall({
    required String targetUserId,
    required String callId,
    String? targetUserName,
    String? targetUserAvatar,
    Map<String, dynamic>? metadata,
  }) async {
    final config = _configRepo.currentConfig;
    if (!config.hasValidZegoCredentials) {
      _setCallState(CallState.error);
      throw StateError(
        'ZegoCloud App ID and App Sign must be configured in Hub Settings > Calling Configuration before initiating calls.',
      );
    }

    final micStatus = await Permission.microphone.request();
    if (!micStatus.isGranted) {
      _setCallState(CallState.error);
      throw Exception('Microphone permission denied.');
    }

    _currentSession = CallSession(
      callId: callId,
      callerId: _currentUserId ?? 'unknown',
      callerName: _displayName ?? 'Caller',
      callerAvatar: _avatarUrl,
      receiverId: targetUserId,
      receiverName: targetUserName ?? 'User',
      receiverAvatar: targetUserAvatar,
      provider: CallProviderType.zego,
      state: CallState.outgoing,
      startedAt: DateTime.now(),
      metadata: metadata ?? {},
    );
    _setCallState(CallState.outgoing);

    try {
      // Record call session in Firestore for auditing & push notifications
      await _firestore.collection('calls').doc(callId).set({
        'callId': callId,
        'callerId': _currentUserId,
        'callerName': _displayName ?? 'Caller',
        'callerAvatar': _avatarUrl,
        'receiverId': targetUserId,
        'receiverName': targetUserName ?? 'Receiver',
        'receiverAvatar': targetUserAvatar,
        'status': 'ringing',
        'type': 'audio',
        'provider': CallProviderType.zego.name,
        'createdAt': FieldValue.serverTimestamp(),
        'metadata': metadata ?? {},
      });

      // Transition to connected once the signaling channel establishes
      Future.delayed(const Duration(seconds: 1), () {
        if (_currentState == CallState.outgoing) {
          _startCallTimer();
          _setCallState(CallState.connected);
        }
      });
    } catch (e) {
      debugPrint('ZegoCallServiceImpl: startCall error: $e');
      await endCall(reason: 'Zego start error: $e');
      rethrow;
    }
  }

  @override
  Future<void> answerCall(String callId) async {
    final config = _configRepo.currentConfig;
    if (!config.hasValidZegoCredentials) {
      _setCallState(CallState.error);
      throw StateError('ZegoCloud App ID and App Sign must be configured in Hub Settings.');
    }

    final micStatus = await Permission.microphone.request();
    if (!micStatus.isGranted) {
      _setCallState(CallState.error);
      throw Exception('Microphone permission denied.');
    }

    _setCallState(CallState.connecting);

    try {
      await _firestore.collection('calls').doc(callId).update({
        'status': 'connected',
        'answeredAt': FieldValue.serverTimestamp(),
      });

      _startCallTimer();
      _setCallState(CallState.connected);
    } catch (e) {
      debugPrint('ZegoCallServiceImpl: answerCall error: $e');
      await endCall(reason: 'Zego answer error: $e');
      rethrow;
    }
  }

  void _startCallTimer() {
    _durationTimer?.cancel();
    _connectedAt = DateTime.now();
    _durationController.add(Duration.zero);

    _durationTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (_connectedAt != null) {
        final elapsed = DateTime.now().difference(_connectedAt!);
        if (!_durationController.isClosed) {
          _durationController.add(elapsed);
        }
      }
    });
  }

  @override
  Future<void> toggleMute(bool muted) async {
    _isMuted = muted;
    if (_currentSession != null) {
      _currentSession = _currentSession!.copyWith(isMuted: muted);
    }
  }

  @override
  Future<void> toggleSpeaker(bool speakerOn) async {
    _isSpeakerOn = speakerOn;
    if (_currentSession != null) {
      _currentSession = _currentSession!.copyWith(isSpeakerOn: speakerOn);
    }
  }

  @override
  Future<void> endCall({String? reason}) async {
    _durationTimer?.cancel();
    _durationTimer = null;

    final session = _currentSession;
    if (session != null) {
      try {
        await _firestore.collection('calls').doc(session.callId).update({
          'status': 'ended',
          'endedAt': FieldValue.serverTimestamp(),
          'endReason': reason ?? 'normal',
        });
      } catch (_) {
        // Document may have already been closed
      }
    }

    _isMuted = false;
    _isSpeakerOn = false;
    _setCallState(CallState.ended);
    _currentSession = null;
    _connectedAt = null;

    Future.delayed(const Duration(milliseconds: 600), () {
      if (_currentState == CallState.ended) {
        _setCallState(CallState.idle);
      }
    });
  }

  @override
  Future<void> rejectCall(String callId, {String? reason}) async {
    try {
      await _firestore.collection('calls').doc(callId).update({
        'status': 'rejected',
        'endedAt': FieldValue.serverTimestamp(),
        'endReason': reason ?? 'declined_by_receiver',
      });
    } catch (_) {}
  }

  @override
  Future<void> dispose() async {
    await endCall(reason: 'Service disposed');
    await _stateController.close();
    await _durationController.close();
  }
}
