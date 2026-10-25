import 'dart:async';

/// Available in-app VoIP calling providers supported by the SeSe platform.
enum CallProviderType {
  /// Self-hosted WebRTC calling engine using Cloud Firestore as the signaling bridge.
  ///
  /// Zero 3rd-party vendor cost, end-to-end DTLS/SRTP encrypted audio with
  /// Google STUN servers for NAT traversal.
  webrtc,

  /// Managed calling SDK option powered by ZegoCloud.
  ///
  /// Requires Zego App ID and App Sign configured in Hub Settings.
  zego,
}

/// Lifecycle states of an in-app VoIP call session.
enum CallState {
  /// No call is currently active.
  idle,

  /// Outgoing call initiated; waiting for the remote peer to ring or answer.
  outgoing,

  /// Incoming call received; ringing locally.
  incoming,

  /// Peer answered; establishing WebRTC peer connection / media channels.
  connecting,

  /// Active audio conversation in progress.
  connected,

  /// Network interruption detected; attempting ICE restart or session reconnect.
  reconnecting,

  /// Call terminated normally by either party.
  ended,

  /// Call terminated due to an error (timeout, permission denied, signaling failure).
  error,
}

/// Snapshot of an active or recent in-app VoIP call session.
class CallSession {
  /// Unique identifier for the call session (e.g. `call_{tripId}_{timestamp}`).
  final String callId;

  /// User ID of the party who initiated the call.
  final String callerId;

  /// Display name of the caller.
  final String callerName;

  /// Photo/Avatar URL of the caller.
  final String? callerAvatar;

  /// User ID of the party receiving the call.
  final String receiverId;

  /// Display name of the receiver.
  final String receiverName;

  /// Photo/Avatar URL of the receiver.
  final String? receiverAvatar;

  /// Active calling provider used for this session.
  final CallProviderType provider;

  /// Current state of the call.
  final CallState state;

  /// Timestamp when the call was initiated.
  final DateTime startedAt;

  /// Timestamp when the call connected, if applicable.
  final DateTime? connectedAt;

  /// Timestamp when the call ended, if applicable.
  final DateTime? endedAt;

  /// Whether local microphone is muted.
  final bool isMuted;

  /// Whether device loudspeaker is currently active.
  final bool isSpeakerOn;

  /// Reason for call termination, if applicable.
  final String? endReason;

  /// Optional metadata associated with the call (e.g. `tripId`, `userRole`).
  final Map<String, dynamic> metadata;

  const CallSession({
    required this.callId,
    required this.callerId,
    required this.callerName,
    this.callerAvatar,
    required this.receiverId,
    required this.receiverName,
    this.receiverAvatar,
    required this.provider,
    required this.state,
    required this.startedAt,
    this.connectedAt,
    this.endedAt,
    this.isMuted = false,
    this.isSpeakerOn = false,
    this.endReason,
    this.metadata = const {},
  });

  CallSession copyWith({
    String? callId,
    String? callerId,
    String? callerName,
    String? callerAvatar,
    String? receiverId,
    String? receiverName,
    String? receiverAvatar,
    CallProviderType? provider,
    CallState? state,
    DateTime? startedAt,
    DateTime? connectedAt,
    DateTime? endedAt,
    bool? isMuted,
    bool? isSpeakerOn,
    String? endReason,
    Map<String, dynamic>? metadata,
  }) {
    return CallSession(
      callId: callId ?? this.callId,
      callerId: callerId ?? this.callerId,
      callerName: callerName ?? this.callerName,
      callerAvatar: callerAvatar ?? this.callerAvatar,
      receiverId: receiverId ?? this.receiverId,
      receiverName: receiverName ?? this.receiverName,
      receiverAvatar: receiverAvatar ?? this.receiverAvatar,
      provider: provider ?? this.provider,
      state: state ?? this.state,
      startedAt: startedAt ?? this.startedAt,
      connectedAt: connectedAt ?? this.connectedAt,
      endedAt: endedAt ?? this.endedAt,
      isMuted: isMuted ?? this.isMuted,
      isSpeakerOn: isSpeakerOn ?? this.isSpeakerOn,
      endReason: endReason ?? this.endReason,
      metadata: metadata ?? this.metadata,
    );
  }
}

/// Abstract contract for in-app VoIP calling services.
///
/// Implemented by [WebRtcCallServiceImpl] (self-hosted via Firebase signaling)
/// and [ZegoCallServiceImpl] (managed ZegoCloud SDK).
///
/// Consumers interact exclusively through this interface via [CallServiceManager],
/// allowing transparent hot-swapping of calling providers without touching UI code.
abstract interface class ICallService {
  /// The calling provider type implemented by this service.
  CallProviderType get providerType;

  /// Current call lifecycle state.
  CallState get currentState;

  /// Current active call session, or null if idle.
  CallSession? get currentSession;

  /// Stream of call state transitions for reactive UI updates.
  Stream<CallState> get stateStream;

  /// Stream of elapsed call duration since connection established.
  Stream<Duration> get durationStream;

  /// Whether the local microphone is currently muted.
  bool get isMuted;

  /// Whether the device loudspeaker is currently active.
  bool get isSpeakerOn;

  /// Initializes the calling engine for [currentUserId].
  ///
  /// Must be called once before initiating or receiving calls.
  Future<void> initialize({
    required String currentUserId,
    String? displayName,
    String? avatarUrl,
  });

  /// Initiates an outgoing voice call to [targetUserId] using [callId].
  ///
  /// [targetUserName] and [targetUserAvatar] are optional display metadata
  /// surfaced on the in-call UI.
  Future<void> startCall({
    required String targetUserId,
    required String callId,
    String? targetUserName,
    String? targetUserAvatar,
    Map<String, dynamic>? metadata,
  });

  /// Answers an incoming call identified by [callId].
  Future<void> answerCall(String callId);

  /// Terminates the active call or rejects an incoming call.
  ///
  /// Optional [reason] is recorded for diagnostics and signaling cleanup.
  Future<void> endCall({String? reason});

  /// Toggles the local microphone mute state.
  Future<void> toggleMute(bool muted);

  /// Toggles audio output between the device earpiece and loudspeaker.
  Future<void> toggleSpeaker(bool speakerOn);

  /// Releases all hardware, network, and signaling resources.
  Future<void> dispose();
}
