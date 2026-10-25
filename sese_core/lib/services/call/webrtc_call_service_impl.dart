import 'dart:async';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:permission_handler/permission_handler.dart';

import 'call_config_repository.dart';
import 'i_call_service.dart';

/// Self-hosted WebRTC calling service utilizing Cloud Firestore as the signaling bridge.
///
/// Features:
/// - Peer-to-peer audio calling with end-to-end DTLS/SRTP encryption.
/// - NAT traversal via Google STUN servers.
/// - No proprietary or third-party WebSocket server required.
/// - Full microphone mute, hardware loudspeaker toggling, and connection state streams.
class WebRtcCallServiceImpl implements ICallService {
  @override
  final CallProviderType providerType = CallProviderType.webrtc;

  final FirebaseFirestore _firestore;
  final CallConfigRepository _configRepo;

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

  WebRtcCallServiceImpl({
    FirebaseFirestore? firestore,
    CallConfigRepository? configRepo,
  })  : _firestore = firestore ?? FirebaseFirestore.instance,
        _configRepo = configRepo ?? CallConfigRepository.instance;

  @override
  CallState get currentState => _currentState;

  @override
  CallSession? get currentSession => _currentSession;

  @override
  Stream<CallState> get stateStream => _stateController.stream;

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

    return {
      'iceServers': iceServers,
      'sdpSemantics': 'unified-plan',
    };
  }

  Future<bool> _requestMicrophonePermission() async {
    final status = await Permission.microphone.request();
    return status.isGranted;
  }

  @override
  Future<void> startCall({
    required String targetUserId,
    required String callId,
    String? targetUserName,
    String? targetUserAvatar,
    Map<String, dynamic>? metadata,
  }) async {
    if (_currentUserId == null) {
      throw StateError('WebRtcCallServiceImpl: Call service not initialized with current user.');
    }

    final hasMic = await _requestMicrophonePermission();
    if (!hasMic) {
      _setCallState(CallState.error);
      throw Exception('Microphone permission denied.');
    }

    _currentSession = CallSession(
      callId: callId,
      callerId: _currentUserId!,
      callerName: _displayName ?? 'Caller',
      callerAvatar: _avatarUrl,
      receiverId: targetUserId,
      receiverName: targetUserName ?? 'User',
      receiverAvatar: targetUserAvatar,
      provider: CallProviderType.webrtc,
      state: CallState.outgoing,
      startedAt: DateTime.now(),
      metadata: metadata ?? {},
    );
    _setCallState(CallState.outgoing);

    try {
      // 1. Capture local audio track
      _localStream = await navigator.mediaDevices.getUserMedia({
        'audio': {
          'echoCancellation': true,
          'noiseSuppression': true,
          'autoGainControl': true,
        },
        'video': false,
      });

      // 2. Instantiate WebRTC Peer Connection
      _peerConnection = await createPeerConnection(_buildIceServersConfig());

      // 3. Register local audio tracks
      for (final track in _localStream!.getAudioTracks()) {
        await _peerConnection!.addTrack(track, _localStream!);
      }

      // 4. Listen for remote audio track
      _peerConnection!.onTrack = (RTCTrackEvent event) {
        if (event.streams.isNotEmpty) {
          _remoteStream = event.streams[0];
        }
      };

      // 5. Stream ICE candidates to Firestore subcollection
      final callDocRef = _firestore.collection('calls').doc(callId);
      final callerCandidatesCol = callDocRef.collection('callerCandidates');

      _peerConnection!.onIceCandidate = (RTCIceCandidate candidate) {
        if (candidate.candidate != null && candidate.candidate!.isNotEmpty) {
          callerCandidatesCol.add({
            'candidate': candidate.candidate,
            'sdpMid': candidate.sdpMid,
            'sdpMLineIndex': candidate.sdpMLineIndex,
            'createdAt': FieldValue.serverTimestamp(),
          });
        }
      };

      // 6. Generate SDP Offer
      final offer = await _peerConnection!.createOffer({
        'offerToReceiveAudio': 1,
        'offerToReceiveVideo': 0,
      });
      await _peerConnection!.setLocalDescription(offer);

      // 7. Publish call invitation document to Firestore
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
        'offer': {
          'type': offer.type,
          'sdp': offer.sdp,
        },
        'provider': CallProviderType.webrtc.name,
        'createdAt': FieldValue.serverTimestamp(),
        'metadata': metadata ?? {},
      });

      // 8. Listen for remote answer
      _callDocSub = callDocRef.snapshots().listen((snapshot) async {
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
      });

      // 9. Listen for Callee ICE candidates
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
    } catch (e) {
      debugPrint('WebRtcCallServiceImpl: failed to start call: $e');
      await endCall(reason: 'Call initialization error: $e');
      rethrow;
    }
  }

  @override
  Future<void> answerCall(String callId) async {
    final hasMic = await _requestMicrophonePermission();
    if (!hasMic) {
      _setCallState(CallState.error);
      throw Exception('Microphone permission denied.');
    }

    _setCallState(CallState.connecting);

    try {
      final callDocRef = _firestore.collection('calls').doc(callId);
      final callDoc = await callDocRef.get();
      final data = callDoc.data();

      if (!callDoc.exists || data == null) {
        throw Exception('Call session document not found: $callId');
      }

      final offerMap = data['offer'] as Map<String, dynamic>?;
      if (offerMap == null) {
        throw Exception('Invalid call document: offer missing');
      }

      // 1. Capture local audio track
      _localStream = await navigator.mediaDevices.getUserMedia({
        'audio': {
          'echoCancellation': true,
          'noiseSuppression': true,
          'autoGainControl': true,
        },
        'video': false,
      });

      // 2. Instantiate WebRTC Peer Connection
      _peerConnection = await createPeerConnection(_buildIceServersConfig());

      // 3. Register local audio tracks
      for (final track in _localStream!.getAudioTracks()) {
        await _peerConnection!.addTrack(track, _localStream!);
      }

      // 4. Remote track listener
      _peerConnection!.onTrack = (RTCTrackEvent event) {
        if (event.streams.isNotEmpty) {
          _remoteStream = event.streams[0];
        }
      };

      // 5. Send Callee ICE candidates to Firestore
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

      // 6. Set remote description from caller's offer
      final rtcOffer = RTCSessionDescription(
        offerMap['sdp']?.toString(),
        offerMap['type']?.toString(),
      );
      await _peerConnection!.setRemoteDescription(rtcOffer);

      // 7. Create and set local answer
      final answer = await _peerConnection!.createAnswer({
        'offerToReceiveAudio': 1,
        'offerToReceiveVideo': 0,
      });
      await _peerConnection!.setLocalDescription(answer);

      // 8. Publish answer to Firestore
      await callDocRef.update({
        'answer': {
          'type': answer.type,
          'sdp': answer.sdp,
        },
        'status': 'connected',
        'answeredAt': FieldValue.serverTimestamp(),
      });

      // 9. Listen for caller candidates
      final callerCandidatesCol = callDocRef.collection('callerCandidates');
      _candidatesSub = callerCandidatesCol.snapshots().listen((snapshot) {
        for (final change in snapshot.docChanges) {
          if (change.type == DocumentChangeType.added) {
            final candData = change.doc.data();
            if (candData != null && _peerConnection != null) {
              final candidate = RTCIceCandidate(
                candData['candidate']?.toString(),
                candData['sdpMid']?.toString(),
                candData['sdpMLineIndex'] is int ? candData['sdpMLineIndex'] as int : 0,
              );
              _peerConnection!.addCandidate(candidate);
            }
          }
        }
      });

      _startCallTimer();
      _setCallState(CallState.connected);
    } catch (e) {
      debugPrint('WebRtcCallServiceImpl: failed to answer call: $e');
      await endCall(reason: 'Answer error: $e');
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
      for (final track in _localStream!.getAudioTracks()) {
        track.enabled = !muted;
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
      debugPrint('WebRtcCallServiceImpl: loudspeaker toggle error: $e');
    }
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
        // Document may have already been closed or deleted
      }
    }

    await _callDocSub?.cancel();
    _callDocSub = null;
    await _candidatesSub?.cancel();
    _candidatesSub = null;

    if (_localStream != null) {
      for (final track in _localStream!.getTracks()) {
        track.stop();
      }
      await _localStream!.dispose();
      _localStream = null;
    }

    if (_remoteStream != null) {
      await _remoteStream!.dispose();
      _remoteStream = null;
    }

    if (_peerConnection != null) {
      await _peerConnection!.close();
      await _peerConnection!.dispose();
      _peerConnection = null;
    }

    _isMuted = false;
    _isSpeakerOn = false;
    _setCallState(CallState.ended);
    _currentSession = null;
    _connectedAt = null;

    // Reset back to idle shortly after ending
    Future.delayed(const Duration(milliseconds: 600), () {
      if (_currentState == CallState.ended) {
        _setCallState(CallState.idle);
      }
    });
  }

  @override
  Future<void> dispose() async {
    await endCall(reason: 'Service disposed');
    await _stateController.close();
    await _durationController.close();
  }
}
