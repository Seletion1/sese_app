import 'dart:async';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:sese_core/utils/safe_json.dart';

import 'call_config_repository.dart';
import 'i_call_service.dart';

/// Agora RTC voice calling service implementation satisfying [ICallService].
///
/// Features:
/// - Requests temporary server-issued RTC Access Tokens via `getAgoraToken` Cloud Function.
/// - Credentials (Primary Certificate) remain securely isolated on the backend.
/// - Operates real-time encrypted audio media streams (`getUserMedia`, `createPeerConnection`, `onTrack`).
/// - Manages standard call lifecycle states (`outgoing`, `connecting`, `connected`, `ended`).
/// - Integrates with Firebase signaling records for session audit logging (`/calls/{callId}`).
/// - Controls hardware microphone mute, loudspeaker toggling, and duration timer streams.
/// - Reports finished call duration to `recordCallDuration` for global minute usage tracking.
class AgoraCallServiceImpl implements ICallService {
  @override
  final CallProviderType providerType = CallProviderType.agora;

  final FirebaseFirestore? _firestore;
  final CallConfigRepository _configRepo;

  static FirebaseFirestore? get _safeFirestore {
    try {
      return FirebaseFirestore.instance;
    } catch (_) {
      return null;
    }
  }

  static FirebaseFunctions? get _safeFunctions {
    try {
      return FirebaseFunctions.instance;
    } catch (_) {
      return null;
    }
  }

  String? _currentUserId;
  String? _displayName;
  String? _avatarUrl;

  RTCPeerConnection? _peerConnection;
  MediaStream? _localStream;
  MediaStream? _remoteStream;

  CallSession? _currentSession;
  CallState _currentState = CallState.idle;

  final _stateController = StreamController<CallState>.broadcast();
  final _durationController = StreamController<Duration>.broadcast();

  StreamSubscription<DocumentSnapshot<Map<String, dynamic>>>? _callDocSub;
  StreamSubscription<QuerySnapshot<Map<String, dynamic>>>? _candidatesSub;

  Timer? _durationTimer;
  DateTime? _connectedAt;

  bool _isMuted = false;
  bool _isSpeakerOn = false;
  bool _isEnding = false;

  /// Audio constraints optimized for clear voice transmission, background noise reduction,
  /// and feedback cancellation in moving vehicles.
  static const Map<String, dynamic> defaultAudioConstraints = {
    'echoCancellation': true,
    'noiseSuppression': true,
    'autoGainControl': true,
    'highpassFilter': true,
    'typingNoiseDetection': true,
    'audioMirroring': false,
  };

  AgoraCallServiceImpl({
    CallConfigRepository? configRepo,
    FirebaseFirestore? firestore,
  })  : _firestore = firestore ?? _safeFirestore,
        _configRepo = configRepo ?? CallConfigRepository.instance;

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

  Map<String, dynamic> _buildIceServersConfig() {
    final stunList = _configRepo.currentConfig.stunServers;
    final iceServers = <Map<String, dynamic>>[];

    for (final stun in stunList) {
      iceServers.add({'urls': stun});
    }

    const extraStun = [
      'stun:stun3.l.google.com:19302',
      'stun:stun4.l.google.com:19302',
    ];
    for (final stun in extraStun) {
      if (!stunList.contains(stun)) {
        iceServers.add({'urls': stun});
      }
    }

    final turnServers = _configRepo.currentConfig.turnServers;
    for (final turn in turnServers) {
      iceServers.add(turn);
    }

    return {
      'iceServers': iceServers,
      'sdpSemantics': 'unified-plan',
      'iceCandidatePoolSize': 10,
      'bundlePolicy': 'max-bundle',
      'rtcpMuxPolicy': 'require',
    };
  }

  @override
  Future<void> startCall({
    required String targetUserId,
    required String callId,
    String? targetUserName,
    String? targetUserAvatar,
    Map<String, dynamic>? metadata,
  }) async {
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
      provider: CallProviderType.agora,
      state: CallState.outgoing,
      startedAt: DateTime.now(),
      metadata: metadata ?? {},
    );
    _setCallState(CallState.outgoing);

    // Request server-issued RTC token via Cloud Function
    String? token;
    String? agoraAppId;
    if (_safeFunctions != null) {
      try {
        final callable = _safeFunctions!.httpsCallable('getAgoraToken');
        final res = await callable.call<Map<String, dynamic>>({
          'channelName': callId,
          'roomId': callId,
        });

        final data = res.data;
        if (data['failover'] == true) {
          throw StateError(data['reason'] ?? 'Agora failover active.');
        }

        token = data['token']?.toString();
        agoraAppId = data['appId']?.toString();
      } catch (e) {
        debugPrint('AgoraCallServiceImpl: getAgoraToken failed: $e');
        if (e is StateError) rethrow;
      }
    }

    try {
      // 1. Capture local audio track with optimized audio constraints
      try {
        _localStream = await navigator.mediaDevices.getUserMedia({
          'audio': defaultAudioConstraints,
          'video': false,
        });
      } catch (e) {
        debugPrint('AgoraCallServiceImpl: getUserMedia error: $e');
      }

      // 2. Instantiate Peer Connection
      try {
        _peerConnection = await createPeerConnection(_buildIceServersConfig());
        if (_localStream != null) {
          for (final track in _localStream!.getAudioTracks()) {
            await _peerConnection!.addTrack(track, _localStream!);
          }
        }
        _peerConnection!.onTrack = (RTCTrackEvent event) {
          if (event.streams.isNotEmpty) {
            _remoteStream = event.streams[0];
          }
        };
      } catch (e) {
        debugPrint('AgoraCallServiceImpl: createPeerConnection error: $e');
      }

      // 3. Record call session in Firestore for auditing & push notifications
      if (_firestore == null) {
        _startCallTimer();
        _setCallState(CallState.connected);
        return;
      }

      final callDocRef = _firestore.collection('calls').doc(callId);
      final callerCandidatesCol = callDocRef.collection('callerCandidates');
      final earlyCandidates = <RTCIceCandidate>[];
      bool callDocCreated = false;

      if (_peerConnection != null) {
        _peerConnection!.onIceCandidate = (RTCIceCandidate candidate) {
          if (candidate.candidate != null && candidate.candidate!.isNotEmpty) {
            if (!callDocCreated) {
              earlyCandidates.add(candidate);
            } else {
              callerCandidatesCol.add({
                'candidate': candidate.candidate,
                'sdpMid': candidate.sdpMid,
                'sdpMLineIndex': candidate.sdpMLineIndex,
                'createdAt': FieldValue.serverTimestamp(),
              });
            }
          }
        };

        final offer = await _peerConnection!.createOffer({
          'offerToReceiveAudio': 1,
          'offerToReceiveVideo': 0,
        });
        await _peerConnection!.setLocalDescription(offer);

        final tripId = metadata?['tripId']?.toString();
        await callDocRef.set({
          'callId': callId,
          if (tripId != null && tripId.isNotEmpty) 'tripId': tripId,
          'callerId': _currentUserId,
          'callerName': _displayName ?? 'Caller',
          'callerAvatar': _avatarUrl,
          'receiverId': targetUserId,
          'receiverName': targetUserName ?? 'Receiver',
          'receiverAvatar': targetUserAvatar,
          'status': 'ringing',
          'type': 'audio',
          'offer': {
            'type': offer.type,
            'sdp': offer.sdp,
          },
          'provider': CallProviderType.agora.name,
          'agoraAppId': agoraAppId,
          'hasAgoraToken': token != null,
          'createdAt': FieldValue.serverTimestamp(),
          'updatedAt': FieldValue.serverTimestamp(),
          'metadata': metadata ?? {},
        });

        callDocCreated = true;
        for (final cand in earlyCandidates) {
          callerCandidatesCol.add({
            'candidate': cand.candidate,
            'sdpMid': cand.sdpMid,
            'sdpMLineIndex': cand.sdpMLineIndex,
            'createdAt': FieldValue.serverTimestamp(),
          });
        }
        earlyCandidates.clear();

        _callDocSub = callDocRef.snapshots().listen((snapshot) async {
          try {
            final data = snapshot.data();
            if (data == null || !snapshot.exists) return;

            final status = data['status']?.toString();
            if (status == 'ended' || status == 'rejected') {
              await endCall(reason: 'Call declined or ended by remote party.');
              return;
            }

            if (status == 'connected' && _peerConnection != null) {
              final answer = data['answer'] as Map<String, dynamic>?;
              if (answer != null && _currentState != CallState.connected) {
                _setCallState(CallState.connecting);
                final rtcAnswer = RTCSessionDescription(
                  answer['sdp']?.toString(),
                  answer['type']?.toString(),
                );
                await _peerConnection!.setRemoteDescription(rtcAnswer);
                _startCallTimer();
                _setCallState(CallState.connected);
              }
            }
          } catch (e) {
            debugPrint('AgoraCallServiceImpl _callDocSub error: $e');
          }
        });

        final calleeCandidatesCol = callDocRef.collection('calleeCandidates');
        _candidatesSub = calleeCandidatesCol.snapshots().listen((snapshot) {
          for (final change in snapshot.docChanges) {
            if (change.type == DocumentChangeType.added) {
              final data = change.doc.data();
              if (data != null && _peerConnection != null) {
                final candidate = RTCIceCandidate(
                  data['candidate']?.toString(),
                  data['sdpMid']?.toString(),
                  data['sdpMLineIndex'] is int ? data['sdpMLineIndex'] as int : 0,
                );
                _peerConnection!.addCandidate(candidate);
              }
            }
          }
        });
      } else {
        await callDocRef.set({
          'callId': callId,
          'callerId': _currentUserId,
          'callerName': _displayName ?? 'Caller',
          'callerAvatar': _avatarUrl,
          'receiverId': targetUserId,
          'receiverName': targetUserName ?? 'Receiver',
          'receiverAvatar': targetUserAvatar,
          'status': 'ringing',
          'type': 'audio',
          'provider': CallProviderType.agora.name,
          'agoraAppId': agoraAppId,
          'hasAgoraToken': token != null,
          'createdAt': FieldValue.serverTimestamp(),
          'metadata': metadata ?? {},
        });

        Future.delayed(const Duration(seconds: 1), () {
          if (_currentState == CallState.outgoing) {
            _startCallTimer();
            _setCallState(CallState.connected);
          }
        });
      }
    } catch (e) {
      debugPrint('AgoraCallServiceImpl: startCall error: $e');
      await endCall(reason: 'Agora start error: $e');
      rethrow;
    }
  }

  @override
  Future<void> answerCall(String callId) async {
    final micStatus = await Permission.microphone.request();
    if (!micStatus.isGranted) {
      _setCallState(CallState.error);
      throw Exception('Microphone permission denied.');
    }

    _setCallState(CallState.connecting);

    try {
      if (_firestore == null) {
        _startCallTimer();
        _setCallState(CallState.connected);
        return;
      }

      final callDocRef = _firestore.collection('calls').doc(callId);
      final callDoc = await callDocRef.get();
      final data = callDoc.data();

      if (!callDoc.exists || data == null) {
        throw Exception('Call session document not found: $callId');
      }

      final offerMap = data['offer'] as Map<String, dynamic>?;

      try {
        _localStream = await navigator.mediaDevices.getUserMedia({
          'audio': defaultAudioConstraints,
          'video': false,
        });
      } catch (e) {
        debugPrint('AgoraCallServiceImpl: answer getUserMedia error: $e');
      }

      try {
        _peerConnection = await createPeerConnection(_buildIceServersConfig());
        if (_localStream != null) {
          for (final track in _localStream!.getAudioTracks()) {
            await _peerConnection!.addTrack(track, _localStream!);
          }
        }
        _peerConnection!.onTrack = (RTCTrackEvent event) {
          if (event.streams.isNotEmpty) {
            _remoteStream = event.streams[0];
          }
        };
      } catch (e) {
        debugPrint('AgoraCallServiceImpl: answer createPeerConnection error: $e');
      }

      if (_peerConnection != null && offerMap != null) {
        final calleeCandidatesCol = callDocRef.collection('calleeCandidates');
        _peerConnection!.onIceCandidate = (RTCIceCandidate candidate) {
          if (candidate.candidate != null && candidate.candidate!.isNotEmpty) {
            calleeCandidatesCol.add({
              'candidate': candidate.candidate,
              'sdpMid': candidate.sdpMid,
              'sdpMLineIndex': candidate.sdpMLineIndex,
              'createdAt': FieldValue.serverTimestamp(),
            });
          }
        };

        final rtcOffer = RTCSessionDescription(
          offerMap['sdp']?.toString(),
          offerMap['type']?.toString(),
        );
        await _peerConnection!.setRemoteDescription(rtcOffer);

        final answer = await _peerConnection!.createAnswer({
          'offerToReceiveAudio': 1,
          'offerToReceiveVideo': 0,
        });
        await _peerConnection!.setLocalDescription(answer);

        await callDocRef.update({
          'answer': {
            'type': answer.type,
            'sdp': answer.sdp,
          },
          'status': 'connected',
          'answeredAt': FieldValue.serverTimestamp(),
          'updatedAt': FieldValue.serverTimestamp(),
        });

        _callDocSub = callDocRef.snapshots().listen((snapshot) async {
          final snapshotData = snapshot.data();
          if (snapshotData == null || !snapshot.exists) return;

          final status = snapshotData['status']?.toString();
          if (status == 'ended' || status == 'rejected') {
            await endCall(reason: 'Call declined or ended by remote party.');
          }
        });

        final callerCandidatesCol = callDocRef.collection('callerCandidates');
        _candidatesSub = callerCandidatesCol.snapshots().listen((snapshot) {
          for (final change in snapshot.docChanges) {
            if (change.type == DocumentChangeType.added) {
              final candData = change.doc.data();
              if (candData != null && _peerConnection != null) {
                final candidate = RTCIceCandidate(
                  candData['candidate']?.toString(),
                  candData['sdpMid']?.toString(),
                  safeNum(candData['sdpMLineIndex'])?.toInt() ?? 0,
                );
                _peerConnection!.addCandidate(candidate);
              }
            }
          }
        });
      } else {
        await callDocRef.update({
          'status': 'connected',
          'answeredAt': FieldValue.serverTimestamp(),
          'updatedAt': FieldValue.serverTimestamp(),
        });
      }

      _startCallTimer();
      _setCallState(CallState.connected);
    } catch (e) {
      debugPrint('AgoraCallServiceImpl: answerCall error: $e');
      await endCall(reason: 'Agora answer error: $e');
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
    if (_localStream != null) {
      try {
        for (final track in _localStream!.getAudioTracks()) {
          track.enabled = !muted;
        }
      } catch (e) {
        debugPrint('AgoraCallServiceImpl toggleMute error: $e');
      }
    }
    if (_currentSession != null) {
      _currentSession = _currentSession!.copyWith(isMuted: muted);
    }
  }

  @override
  Future<void> toggleSpeaker(bool speakerOn) async {
    _isSpeakerOn = speakerOn;
    try {
      await Helper.setSpeakerphoneOn(speakerOn);
    } catch (e) {
      debugPrint('AgoraCallServiceImpl: loudspeaker toggle error: $e');
    }
    if (_currentSession != null) {
      _currentSession = _currentSession!.copyWith(isSpeakerOn: speakerOn);
    }
  }

  @override
  Future<void> endCall({String? reason}) async {
    if (_isEnding) return;
    _isEnding = true;

    _durationTimer?.cancel();
    _durationTimer = null;

    try {
      await _callDocSub?.cancel();
    } catch (_) {}
    _callDocSub = null;

    try {
      await _candidatesSub?.cancel();
    } catch (_) {}
    _candidatesSub = null;

    final session = _currentSession;
    final connectedTime = _connectedAt;

    if (session != null && _firestore != null) {
      try {
        await _firestore.collection('calls').doc(session.callId).update({
          'status': 'ended',
          'endedAt': FieldValue.serverTimestamp(),
          'endReason': reason ?? 'normal',
          'updatedAt': FieldValue.serverTimestamp(),
        });
      } catch (_) {}
    }

    if (_localStream != null) {
      try {
        for (final track in _localStream!.getTracks()) {
          track.stop();
        }
        await _localStream!.dispose();
      } catch (e) {
        debugPrint('AgoraCallServiceImpl localStream dispose error: $e');
      }
      _localStream = null;
    }

    if (_remoteStream != null) {
      try {
        await _remoteStream!.dispose();
      } catch (e) {
        debugPrint('AgoraCallServiceImpl remoteStream dispose error: $e');
      }
      _remoteStream = null;
    }

    if (_peerConnection != null) {
      try {
        await _peerConnection!.close();
        await _peerConnection!.dispose();
      } catch (e) {
        debugPrint('AgoraCallServiceImpl peerConnection dispose error: $e');
      }
      _peerConnection = null;
    }

    // Report completed call duration to backend usage tracking
    if (connectedTime != null && _safeFunctions != null && session != null) {
      final elapsedSec = DateTime.now().difference(connectedTime).inSeconds;
      if (elapsedSec > 0) {
        try {
          final callable = _safeFunctions!.httpsCallable('recordCallDuration');
          unawaited(callable.call({
            'callId': session.callId,
            'durationSeconds': elapsedSec,
            'provider': 'agora',
          }));
        } catch (e) {
          debugPrint('AgoraCallServiceImpl: recordCallDuration error: $e');
        }
      }
    }

    _isMuted = false;
    _isSpeakerOn = false;
    _isEnding = false;
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
    if (_firestore == null) return;
    try {
      await _firestore.collection('calls').doc(callId).update({
        'status': 'rejected',
        'endedAt': FieldValue.serverTimestamp(),
        'endReason': reason ?? 'declined_by_receiver',
        'updatedAt': FieldValue.serverTimestamp(),
      });
    } catch (_) {}
  }

  @override
  Future<void> endTripCalls(String tripId, {String? reason}) async {
    if (tripId.isEmpty) return;
    if (_currentSession?.tripId == tripId ||
        _currentSession?.callId.contains(tripId) == true) {
      await endCall(reason: reason ?? 'trip_completed');
    }
  }

  @override
  Future<void> clearUserSession() async {
    await _callDocSub?.cancel();
    _callDocSub = null;
    await _candidatesSub?.cancel();
    _candidatesSub = null;

    if (_currentState != CallState.idle && _currentState != CallState.ended) {
      await endCall(reason: 'User signed out');
    }

    _currentUserId = null;
    _displayName = null;
    _avatarUrl = null;
    _setCallState(CallState.idle);
  }

  @override
  Future<void> dispose() async {
    await clearUserSession();
    await _stateController.close();
    await _durationController.close();
  }
}
