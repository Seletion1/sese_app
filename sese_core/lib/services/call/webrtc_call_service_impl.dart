import 'dart:async';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:sese_core/utils/safe_json.dart';

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
  final _incomingCallController = StreamController<CallSession?>.broadcast();

  StreamSubscription<DocumentSnapshot<Map<String, dynamic>>>? _callDocSub;
  StreamSubscription<QuerySnapshot<Map<String, dynamic>>>? _candidatesSub;
  StreamSubscription<QuerySnapshot<Map<String, dynamic>>>? _incomingCallsSub;
  Timer? _durationTimer;
  Timer? _iceRecoveryTimer;
  DateTime? _connectedAt;

  bool _isMuted = false;
  bool _isSpeakerOn = false;

  /// Guard flag: prevents re-entrant calls to [endCall] (e.g. the Firestore
  /// status-update triggering the call-document listener while teardown is
  /// already in progress).
  bool _isEnding = false;

  /// Optional listener triggered when WebRTC connection or ICE candidate gathering fails.
  void Function(String reason)? onConnectionFailed;

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

  WebRtcCallServiceImpl({
    FirebaseFirestore? firestore,
    CallConfigRepository? configRepo,
  })  : _firestore = firestore ?? _safeFirestore,
        _configRepo = configRepo ?? CallConfigRepository.instance;

  @override
  CallState get currentState => _currentState;

  @override
  CallSession? get currentSession => _currentSession;

  @override
  Stream<CallState> get stateStream => _stateController.stream;

  @override
  Stream<CallSession?> get incomingCallStream => _incomingCallController.stream;

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

    // Cancel any prior listener before setting up the current user's listener
    await _incomingCallsSub?.cancel();
    if (_firestore != null) {
      _incomingCallsSub = _firestore
          .collection('calls')
          .where('receiverId', isEqualTo: currentUserId)
          .where('status', isEqualTo: 'ringing')
          .snapshots()
          .listen(
        (snapshot) {
          if (snapshot.docs.isEmpty) {
            if (!_incomingCallController.isClosed) {
              _incomingCallController.add(null);
            }
            return;
          }

          final now = DateTime.now();
          QueryDocumentSnapshot<Map<String, dynamic>>? activeDoc;
          Map<String, dynamic>? activeData;
          DateTime? activeStartedAt;

          // Scan ringing call documents:
          // 1. Mark zombie calls (> 35s old) as missed so they never ring again
          // 2. Locate the newest valid unexpired ringing call
          for (final doc in snapshot.docs) {
            final data = doc.data();
            DateTime docCreatedAt = now;
            if (data['createdAt'] is Timestamp) {
              docCreatedAt = (data['createdAt'] as Timestamp).toDate();
            }

            final ageSeconds = now.difference(docCreatedAt).inSeconds;
            if (ageSeconds > 35) {
              // Silently expire zombie call document in Firestore
              doc.reference.update({
                'status': 'missed',
                'endedAt': FieldValue.serverTimestamp(),
                'endReason': 'ringing_timeout',
                'updatedAt': FieldValue.serverTimestamp(),
              }).catchError((_) {});
              continue;
            }

            // Pick the newest unexpired call
            if (activeStartedAt == null || docCreatedAt.isAfter(activeStartedAt)) {
              activeDoc = doc;
              activeData = data;
              activeStartedAt = docCreatedAt;
            }
          }

          if (activeDoc == null || activeData == null) {
            if (!_incomingCallController.isClosed) {
              _incomingCallController.add(null);
            }
            return;
          }

          final session = CallSession(
            callId: activeDoc.id,
            callerId: activeData['callerId']?.toString() ?? '',
            callerName: activeData['callerName']?.toString() ?? 'Caller',
            callerAvatar: activeData['callerAvatar']?.toString(),
            receiverId: currentUserId,
            receiverName: activeData['receiverName']?.toString() ?? 'Receiver',
            receiverAvatar: activeData['receiverAvatar']?.toString(),
            provider: CallProviderType.webrtc,
            state: CallState.incoming,
            startedAt: activeStartedAt ?? now,
            metadata: activeData['metadata'] is Map
                ? Map<String, dynamic>.from(activeData['metadata'] as Map)
                : <String, dynamic>{},
          );

          if (!_incomingCallController.isClosed) {
            _incomingCallController.add(session);
          }
        },
        onError: (e) {
          debugPrint('WebRtcCallServiceImpl: error in incoming calls stream: $e');
        },
      );
    }
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

    // Primary STUN servers (NAT traversal for direct P2P)
    for (final stun in stunList) {
      iceServers.add({'urls': stun});
    }

    // Additional Google STUN for broader NAT coverage
    const extraStun = [
      'stun:stun3.l.google.com:19302',
      'stun:stun4.l.google.com:19302',
    ];
    for (final stun in extraStun) {
      if (!stunList.contains(stun)) {
        iceServers.add({'urls': stun});
      }
    }

    // Public TURN servers for cross-network relay (cellular ↔ Wi-Fi / NAT symmetry)
    // These are open/public TURN servers for fallback when direct P2P fails.
    // For production, replace with your own TURN credentials or a service like
    // Metered (metered.ca) or Twilio TURN for reliability guarantees.
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

  /// Fetches ICE servers (STUN + TURN) from local config and falls back to the
  /// `getIceServers` Cloud Function when no TURN servers are cached locally.
  Future<Map<String, dynamic>> _fetchIceServersConfig() async {
    final baseConfig = _buildIceServersConfig();
    final localTurns = _configRepo.currentConfig.turnServers;
    if (localTurns.isNotEmpty || _safeFunctions == null) {
      return baseConfig;
    }

    try {
      final callable = _safeFunctions!.httpsCallable('getIceServers');
      final res = await callable
          .call<Map<String, dynamic>>()
          .timeout(const Duration(seconds: 3));
      final rawList = res.data['iceServers'];
      if (rawList is List && rawList.isNotEmpty) {
        final serverList = rawList
            .whereType<Map>()
            .map((e) => Map<String, dynamic>.from(e))
            .toList();
        if (serverList.isNotEmpty) {
          debugPrint(
            'WebRtcCallServiceImpl: loaded ${serverList.length} ICE servers from backend (hasTurn=${res.data['hasTurn']})',
          );
          return {
            ...baseConfig,
            'iceServers': serverList,
          };
        }
      }
    } catch (e) {
      debugPrint('WebRtcCallServiceImpl: getIceServers fallback to local STUN ($e)');
    }
    return baseConfig;
  }

  void _attachPeerConnectionListeners() {
    final pc = _peerConnection;
    if (pc == null) return;

    pc.onIceConnectionState = (RTCIceConnectionState state) {
      debugPrint('WebRtcCallServiceImpl: ICE connection state -> $state');
      if (state == RTCIceConnectionState.RTCIceConnectionStateConnected ||
          state == RTCIceConnectionState.RTCIceConnectionStateCompleted) {
        _iceRecoveryTimer?.cancel();
        _iceRecoveryTimer = null;
        if (_currentState != CallState.connected && _currentState != CallState.ended) {
          _startCallTimer();
          _setCallState(CallState.connected);
        }
      } else if (state == RTCIceConnectionState.RTCIceConnectionStateDisconnected) {
        if (_currentState == CallState.connected) {
          _setCallState(CallState.reconnecting);
        }
        _iceRecoveryTimer?.cancel();
        _iceRecoveryTimer = Timer(const Duration(seconds: 6), () {
          if (_currentState == CallState.reconnecting ||
              _currentState == CallState.connecting) {
            onConnectionFailed?.call('ICE connection disconnected and did not recover');
            if (_currentState != CallState.connected && _currentState != CallState.ended) {
              _setCallState(CallState.error);
            }
          }
        });
      } else if (state == RTCIceConnectionState.RTCIceConnectionStateFailed) {
        _iceRecoveryTimer?.cancel();
        _iceRecoveryTimer = null;
        onConnectionFailed?.call('ICE connection failed (carrier NAT may require TURN relay)');
        if (_currentState != CallState.connected && _currentState != CallState.ended) {
          _setCallState(CallState.error);
        }
      }
    };

    pc.onConnectionState = (RTCPeerConnectionState state) {
      debugPrint('WebRtcCallServiceImpl: Peer connection state -> $state');
      if (state == RTCPeerConnectionState.RTCPeerConnectionStateConnected) {
        _iceRecoveryTimer?.cancel();
        _iceRecoveryTimer = null;
        if (_currentState != CallState.connected && _currentState != CallState.ended) {
          _startCallTimer();
          _setCallState(CallState.connected);
        }
      } else if (state == RTCPeerConnectionState.RTCPeerConnectionStateFailed) {
        onConnectionFailed?.call('Peer connection state failed');
        if (_currentState != CallState.connected && _currentState != CallState.ended) {
          _setCallState(CallState.error);
        }
      }
    };

    pc.onTrack = (RTCTrackEvent event) {
      if (event.track.kind == 'audio') {
        event.track.enabled = true;
      }
      if (event.streams.isNotEmpty) {
        _remoteStream = event.streams[0];
        for (final t in _remoteStream!.getAudioTracks()) {
          t.enabled = true;
        }
      }
    };

    pc.onAddStream = (MediaStream stream) {
      _remoteStream = stream;
      for (final t in stream.getAudioTracks()) {
        t.enabled = true;
      }
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
      // 1. Capture local audio track with optimized audio constraints
      _localStream = await navigator.mediaDevices.getUserMedia({
        'audio': defaultAudioConstraints,
        'video': false,
      });
      for (final track in _localStream!.getAudioTracks()) {
        track.enabled = !_isMuted;
      }
      try {
        await Helper.setSpeakerphoneOn(_isSpeakerOn);
      } catch (e) {
        debugPrint('WebRtcCallServiceImpl: setSpeakerphoneOn error: $e');
      }

      // 2. Instantiate WebRTC Peer Connection with STUN + TURN
      final iceConfig = await _fetchIceServersConfig();
      _peerConnection = await createPeerConnection(iceConfig);

      // Listen for ICE/connection state & remote audio tracks
      _attachPeerConnectionListeners();

      // 3. Register local audio tracks
      for (final track in _localStream!.getAudioTracks()) {
        await _peerConnection!.addTrack(track, _localStream!);
      }

      // 5. Stream ICE candidates to Firestore subcollection (buffered until parent callDoc commits)
      if (_firestore == null) {
        debugPrint('WebRtcCallServiceImpl: Firestore unavailable (mock/offline mode).');
        _startCallTimer();
        _setCallState(CallState.connected);
        return;
      }
      final callDocRef = _firestore.collection('calls').doc(callId);
      final callerCandidatesCol = callDocRef.collection('callerCandidates');
      final earlyCandidates = <RTCIceCandidate>[];
      bool callDocCreated = false;

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

      // 6. Generate SDP Offer
      final offer = await _peerConnection!.createOffer({
        'offerToReceiveAudio': 1,
        'offerToReceiveVideo': 0,
      });
      await _peerConnection!.setLocalDescription(offer);

      // 7. Publish call invitation document to Firestore
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
        'provider': CallProviderType.webrtc.name,
        'createdAt': FieldValue.serverTimestamp(),
        'updatedAt': FieldValue.serverTimestamp(),
        'metadata': metadata ?? {},
      });

      // Flush any ICE candidates gathered while parent document was being written
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

      // 8. Listen for remote answer / rejection / end
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
            if (answer != null &&
                _currentState != CallState.connected &&
                _currentState != CallState.connecting) {
              _setCallState(CallState.connecting);
              final rtcAnswer = RTCSessionDescription(
                answer['sdp']?.toString(),
                answer['type']?.toString(),
              );
              await _peerConnection!.setRemoteDescription(rtcAnswer);
            }
          }
        } catch (e) {
          debugPrint('WebRtcCallServiceImpl _callDocSub error: $e');
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
      if (_firestore == null) {
        debugPrint('WebRtcCallServiceImpl: Firestore unavailable (mock/offline mode).');
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

      final currentStatus = data['status']?.toString();
      if (currentStatus == 'ended' ||
          currentStatus == 'rejected' ||
          currentStatus == 'declined' ||
          currentStatus == 'cancelled' ||
          currentStatus == 'missed' ||
          currentStatus == 'failed') {
        throw Exception('Call session has already ended or was dismissed.');
      }

      // Guard against answering an expired call (> 45s)
      if (data['createdAt'] is Timestamp) {
        final created = (data['createdAt'] as Timestamp).toDate();
        if (DateTime.now().difference(created).inSeconds > 45) {
          unawaited(callDocRef.update({
            'status': 'missed',
            'endedAt': FieldValue.serverTimestamp(),
            'endReason': 'ringing_timeout',
            'updatedAt': FieldValue.serverTimestamp(),
          }));
          throw Exception('Call invitation has expired.');
        }
      }

      final offerMap = data['offer'] as Map<String, dynamic>?;
      if (offerMap == null) {
        throw Exception('Invalid call document: offer missing');
      }

      _currentSession = CallSession(
        callId: callId,
        callerId: data['callerId']?.toString() ?? '',
        callerName: data['callerName']?.toString() ?? 'Caller',
        callerAvatar: data['callerAvatar']?.toString(),
        receiverId: _currentUserId ?? '',
        receiverName: _displayName ?? 'Receiver',
        receiverAvatar: _avatarUrl,
        provider: CallProviderType.webrtc,
        state: CallState.connecting,
        startedAt: (data['createdAt'] is Timestamp)
            ? (data['createdAt'] as Timestamp).toDate()
            : DateTime.now(),
        metadata: data['metadata'] is Map
              ? Map<String, dynamic>.from(data['metadata'] as Map)
              : <String, dynamic>{},
      );

      // 1. Capture local audio track with optimized audio constraints
      _localStream = await navigator.mediaDevices.getUserMedia({
        'audio': defaultAudioConstraints,
        'video': false,
      });
      for (final track in _localStream!.getAudioTracks()) {
        track.enabled = !_isMuted;
      }
      try {
        await Helper.setSpeakerphoneOn(_isSpeakerOn);
      } catch (e) {
        debugPrint('WebRtcCallServiceImpl: answer setSpeakerphoneOn error: $e');
      }

      // 2. Instantiate WebRTC Peer Connection with STUN + TURN
      final iceConfig = await _fetchIceServersConfig();
      _peerConnection = await createPeerConnection(iceConfig);

      // Listen for ICE/connection state & remote audio tracks
      _attachPeerConnectionListeners();

      // 3. Register local audio tracks
      for (final track in _localStream!.getAudioTracks()) {
        await _peerConnection!.addTrack(track, _localStream!);
      }

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
        'updatedAt': FieldValue.serverTimestamp(),
      });

      // 9. Listen for caller cancellation or remote hangup
      _callDocSub = callDocRef.snapshots().listen((snapshot) async {
        final data = snapshot.data();
        if (data == null || !snapshot.exists) return;

        final status = data['status']?.toString();
        if (status == 'ended' || status == 'rejected') {
          await endCall(reason: 'Call declined or ended by remote party.');
        }
      });

      // 10. Listen for caller candidates
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

      // Wait for ICE connection state to reach Connected before starting timer.
      _setCallState(CallState.connecting);
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
    // Re-entrant guard: the Firestore status write below triggers _callDocSub,
    // which would call endCall() again. The flag breaks the loop.
    if (_isEnding) return;
    _isEnding = true;

    // Immediately dismiss any incoming overlay or ringtone
    if (!_incomingCallController.isClosed) {
      _incomingCallController.add(null);
    }

    _durationTimer?.cancel();
    _durationTimer = null;
    _iceRecoveryTimer?.cancel();
    _iceRecoveryTimer = null;

    // Cancel Firestore listeners FIRST to prevent the 'ended' write from
    // re-triggering the call-doc listener and looping back into endCall().
    try {
      await _callDocSub?.cancel();
    } catch (_) {}
    _callDocSub = null;

    try {
      await _candidatesSub?.cancel();
    } catch (_) {}
    _candidatesSub = null;

    final session = _currentSession;
    if (session != null && _firestore != null) {
      try {
        await _firestore.collection('calls').doc(session.callId).update({
          'status': 'ended',
          'endedAt': FieldValue.serverTimestamp(),
          'endReason': reason ?? 'normal',
          'updatedAt': FieldValue.serverTimestamp(),
        });
      } catch (_) {
        // Document may have already been closed or deleted — safe to ignore.
      }
    }

    if (_localStream != null) {
      try {
        for (final track in _localStream!.getTracks()) {
          track.stop();
        }
        await _localStream!.dispose();
      } catch (e) {
        debugPrint('WebRtcCallServiceImpl localStream dispose error: $e');
      }
      _localStream = null;
    }

    if (_remoteStream != null) {
      try {
        await _remoteStream!.dispose();
      } catch (e) {
        debugPrint('WebRtcCallServiceImpl remoteStream dispose error: $e');
      }
      _remoteStream = null;
    }

    if (_peerConnection != null) {
      try {
        await _peerConnection!.close();
        await _peerConnection!.dispose();
      } catch (e) {
        debugPrint('WebRtcCallServiceImpl peerConnection dispose error: $e');
      }
      _peerConnection = null;
    }

    _isMuted = false;
    _isSpeakerOn = false;
    _isEnding = false;
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

  /// Aborts the WebRTC media session and cancels listeners cleanly without marking
  /// the call session as ended or updating Firestore `calls/{callId}` status to 'ended',
  /// allowing the third-party provider to assume control of the call seamlessly.
  Future<void> abortForFallback() async {
    _durationTimer?.cancel();
    _durationTimer = null;
    _iceRecoveryTimer?.cancel();
    _iceRecoveryTimer = null;
    _isEnding = false; // Reset so endCall can proceed if called after abort

    try {
      await _callDocSub?.cancel();
    } catch (_) {}
    _callDocSub = null;

    try {
      await _candidatesSub?.cancel();
    } catch (_) {}
    _candidatesSub = null;

    if (_localStream != null) {
      try {
        for (final track in _localStream!.getTracks()) {
          track.stop();
        }
        await _localStream!.dispose();
      } catch (e) {
        debugPrint('WebRtcCallServiceImpl abort localStream error: $e');
      }
      _localStream = null;
    }

    if (_remoteStream != null) {
      try {
        await _remoteStream!.dispose();
      } catch (e) {
        debugPrint('WebRtcCallServiceImpl abort remoteStream error: $e');
      }
      _remoteStream = null;
    }

    if (_peerConnection != null) {
      try {
        await _peerConnection!.close();
        await _peerConnection!.dispose();
      } catch (e) {
        debugPrint('WebRtcCallServiceImpl abort peerConnection error: $e');
      }
      _peerConnection = null;
    }

    _isMuted = false;
    _isSpeakerOn = false;
    _connectedAt = null;
  }

  @override
  Future<void> rejectCall(String callId, {String? reason}) async {
    // Immediately emit null on incoming stream so UI dismisses instantly
    if (!_incomingCallController.isClosed) {
      _incomingCallController.add(null);
    }
    if (_firestore == null) return;
    try {
      await _firestore.collection('calls').doc(callId).update({
        'status': 'rejected',
        'endedAt': FieldValue.serverTimestamp(),
        'endReason': reason ?? 'declined_by_receiver',
        'updatedAt': FieldValue.serverTimestamp(),
      });
    } catch (e) {
      debugPrint('WebRtcCallServiceImpl: failed to reject call $callId: $e');
    }
  }

  @override
  Future<void> endTripCalls(String tripId, {String? reason}) async {
    if (tripId.isEmpty) return;
    if (_currentSession?.tripId == tripId ||
        _currentSession?.callId.contains(tripId) == true) {
      await endCall(reason: reason ?? 'trip_completed');
    }
    if (!_incomingCallController.isClosed) {
      _incomingCallController.add(null);
    }
    if (_firestore != null) {
      try {
        final snap = await _firestore
            .collection('calls')
            .where('metadata.tripId', isEqualTo: tripId)
            .where('status', whereIn: ['ringing', 'connecting', 'connected', 'idle'])
            .get();
        for (final doc in snap.docs) {
          doc.reference.update({
            'status': 'ended',
            'endedAt': FieldValue.serverTimestamp(),
            'endReason': reason ?? 'trip_completed',
            'updatedAt': FieldValue.serverTimestamp(),
          }).catchError((_) {});
        }
      } catch (_) {}
    }
  }

  @override
  Future<void> clearUserSession() async {
    await _incomingCallsSub?.cancel();
    _incomingCallsSub = null;
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
    await _incomingCallController.close();
  }
}
