import 'dart:async';
import 'package:flutter/material.dart';

import '../services/app_sound_service.dart';
import '../services/call/call_service_manager.dart';
import '../services/call/i_call_service.dart';
import '../services/push_notification_service.dart';
import 'in_app_call_screen.dart';

/// Global overlay widget that listens to [CallServiceManager.incomingCallStream]
/// and presents an interactive top incoming-call invitation banner across any screen.
///
/// Features:
/// - Real-time incoming VoIP detection from Cloud Firestore signaling.
/// - Repeating ringtone audio notification until answered or dismissed.
/// - One-tap Accept that immediately transitions into [InAppCallScreen] (WebRTC/Zego).
/// - One-tap Decline that updates Firestore status to 'rejected' and silences audio.
/// - Auto-dismissal when caller cancels before the recipient answers.
class IncomingCallOverlay extends StatefulWidget {
  final Widget child;

  /// Global navigator key used to push [InAppCallScreen] when the call is accepted
  /// from outside or above the [Navigator] hierarchy (e.g. within [MaterialApp.builder]).
  static final GlobalKey<NavigatorState> navigatorKey = GlobalKey<NavigatorState>();

  /// Optional instance override for navigatorKey.
  final GlobalKey<NavigatorState>? navKey;

  const IncomingCallOverlay({
    super.key,
    required this.child,
    this.navKey,
  });

  @override
  State<IncomingCallOverlay> createState() => _IncomingCallOverlayState();
}

class _IncomingCallOverlayState extends State<IncomingCallOverlay> {
  final CallServiceManager _callManager = CallServiceManager.instance;
  final Set<String> _handledCallIds = {};
  StreamSubscription<CallSession?>? _incomingSub;
  StreamSubscription<CallState>? _callStateSub;
  StreamSubscription<Duration>? _callDurationSub;
  CallSession? _incomingSession;
  CallState _callState = CallState.idle;
  Duration _callDuration = Duration.zero;
  Timer? _ringTimer;
  Timer? _expiryTimer;

  @override
  void initState() {
    super.initState();
    _callState = _callManager.currentState;
    _callDuration = _callManager.currentDuration;
    _callManager.isCallUiExpanded.addListener(_onCallUiExpandedChanged);

    _callStateSub = _callManager.stateStream.listen((state) {
      if (!mounted) return;
      setState(() {
        _callState = state;
        if (state == CallState.idle || state == CallState.ended) {
          _callDuration = Duration.zero;
        }
      });
    });

    _callDurationSub = _callManager.durationStream.listen((duration) {
      if (!mounted) return;
      setState(() => _callDuration = duration);
    });

    _incomingSub = _callManager.incomingCallStream.listen((session) {
      if (!mounted) return;
      if (session != null && session.state == CallState.incoming) {
        // 1. Guard against showing calls that the user already accepted or declined
        if (_handledCallIds.contains(session.callId)) {
          return;
        }
        // 2. Guard against showing banner when user is already in a call or call screen
        if (_callManager.currentState != CallState.idle &&
            _callManager.currentState != CallState.incoming) {
          return;
        }
        // 3. Guard against showing expired/stale calls (> 35s old)
        if (session.isRingingExpired) {
          return;
        }

        if (_incomingSession?.callId != session.callId) {
          setState(() => _incomingSession = session);
          _startRingtone();
          _startExpiryTimer(session);
          unawaited(PushNotificationService.showIncomingCallNotification(
            callId: session.callId,
            callerId: session.callerId,
            callerName: session.callerName,
            callerAvatar: session.callerAvatar,
          ));
        }
      } else {
        if (_incomingSession != null) {
          _stopRingtone();
          _expiryTimer?.cancel();
          unawaited(PushNotificationService.cancelIncomingCallNotification());
          setState(() => _incomingSession = null);
        }
      }
    });
  }

  void _startExpiryTimer(CallSession session) {
    _expiryTimer?.cancel();
    final elapsed = DateTime.now().difference(session.startedAt).inSeconds;
    final remainingSeconds = (35 - elapsed).clamp(1, 35);
    _expiryTimer = Timer(Duration(seconds: remainingSeconds), () {
      if (!mounted) return;
      if (_incomingSession?.callId == session.callId) {
        _declineCall();
      }
    });
  }

  void _startRingtone() {
    _ringTimer?.cancel();
    // Play initial ringtone immediately
    // ignore: discarded_futures
    AppSoundService.instance.playIncomingMessageSound();
    // Repeat every 2.5 seconds while ringing
    _ringTimer = Timer.periodic(const Duration(milliseconds: 2500), (_) {
      if (_incomingSession != null) {
        // ignore: discarded_futures
        AppSoundService.instance.playIncomingMessageSound();
      } else {
        _stopRingtone();
      }
    });
  }

  void _stopRingtone() {
    _ringTimer?.cancel();
    _ringTimer = null;
  }

  void _acceptCall() {
    final session = _incomingSession;
    if (session == null) return;
    _handledCallIds.add(session.callId);
    _stopRingtone();
    _expiryTimer?.cancel();
    unawaited(PushNotificationService.cancelIncomingCallNotification());
    setState(() => _incomingSession = null);

    final navState = widget.navKey?.currentState ??
        IncomingCallOverlay.navigatorKey.currentState ??
        Navigator.maybeOf(context);

    if (navState == null) {
      debugPrint('IncomingCallOverlay: Cannot push InAppCallScreen — no Navigator found.');
      return;
    }

    navState.push(
      MaterialPageRoute(
        fullscreenDialog: true,
        builder: (_) => InAppCallScreen(
          callId: session.callId,
          targetUserId: session.callerId,
          targetUserName: session.callerName,
          targetUserAvatar: session.callerAvatar,
          isIncoming: true,
          metadata: session.metadata,
        ),
      ),
    );
  }

  void _declineCall() {
    final session = _incomingSession;
    if (session == null) return;
    _handledCallIds.add(session.callId);
    _stopRingtone();
    _expiryTimer?.cancel();
    unawaited(PushNotificationService.cancelIncomingCallNotification());
    setState(() => _incomingSession = null);
    // ignore: discarded_futures
    _callManager.rejectCall(session.callId, reason: 'declined_from_overlay');
  }

  void _onCallUiExpandedChanged() {
    if (mounted) setState(() {});
  }

  bool get _hasMinimizedActiveCall {
    final active = _callState == CallState.outgoing ||
        _callState == CallState.connecting ||
        _callState == CallState.connected ||
        _callState == CallState.reconnecting;
    return active &&
        !_callManager.isCallUiExpanded.value &&
        _callManager.currentSession != null;
  }

  String _formatDuration(Duration d) {
    final minutes = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final seconds = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return d.inHours > 0 ? '${d.inHours}:$minutes:$seconds' : '$minutes:$seconds';
  }

  String _miniBarStatusLabel() {
    switch (_callState) {
      case CallState.outgoing:
        return 'Ringing...';
      case CallState.connecting:
        return 'Connecting...';
      case CallState.reconnecting:
        return 'Reconnecting...';
      case CallState.connected:
        return _formatDuration(_callDuration);
      default:
        return 'In Call';
    }
  }

  void _expandActiveCall() {
    final session = _callManager.currentSession;
    if (session == null) return;
    final navState = widget.navKey?.currentState ??
        IncomingCallOverlay.navigatorKey.currentState ??
        Navigator.maybeOf(context);
    if (navState == null) return;

    final isCaller = session.callerId == _callManager.currentUserId;
    final peerId = isCaller ? session.receiverId : session.callerId;
    final peerName = isCaller ? session.receiverName : session.callerName;
    final peerAvatar = isCaller ? session.receiverAvatar : session.callerAvatar;

    navState.push(
      MaterialPageRoute(
        fullscreenDialog: true,
        builder: (_) => InAppCallScreen(
          callId: session.callId,
          targetUserId: peerId,
          targetUserName: peerName,
          targetUserAvatar: peerAvatar,
          isIncoming: !isCaller,
          metadata: session.metadata,
        ),
      ),
    );
  }

  @override
  void dispose() {
    _callManager.isCallUiExpanded.removeListener(_onCallUiExpandedChanged);
    _stopRingtone();
    _expiryTimer?.cancel();
    _incomingSub?.cancel();
    _callStateSub?.cancel();
    _callDurationSub?.cancel();
    unawaited(PushNotificationService.cancelIncomingCallNotification());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final topPadding = MediaQuery.maybePaddingOf(context)?.top ?? 0.0;

    return Stack(
      children: [
        widget.child,
        if (_incomingSession != null)
          Positioned(
            top: topPadding + 8,
            left: 12,
            right: 12,
            child: Material(
              elevation: 12,
              borderRadius: BorderRadius.circular(16),
              color: const Color(0xFF0F172A), // Dark obsidian blue
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                child: Row(
                  children: [
                    // Avatar circle
                    Container(
                      width: 46,
                      height: 46,
                      decoration: BoxDecoration(
                        color: const Color(0xFF1E293B),
                        shape: BoxShape.circle,
                        border: Border.all(color: Colors.greenAccent, width: 2),
                      ),
                      child: Center(
                        child: Text(
                          _incomingSession!.callerName.isNotEmpty
                              ? _incomingSession!.callerName[0].toUpperCase()
                              : '?',
                          style: const TextStyle(
                            color: Colors.white,
                            fontWeight: FontWeight.bold,
                            fontSize: 20,
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            _incomingSession!.callerName,
                            style: const TextStyle(
                              color: Colors.white,
                              fontWeight: FontWeight.bold,
                              fontSize: 15,
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          const SizedBox(height: 2),
                          const Row(
                            children: [
                              Icon(
                                Icons.wifi_calling_3_rounded,
                                color: Colors.greenAccent,
                                size: 13,
                              ),
                              SizedBox(width: 4),
                              Flexible(
                                child: Text(
                                  'Incoming voice call...',
                                  style: TextStyle(
                                    color: Colors.greenAccent,
                                    fontSize: 12,
                                    fontWeight: FontWeight.w500,
                                  ),
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 8),
                    // Decline button
                    GestureDetector(
                      key: const Key('incoming_call_decline_button'),
                      onTap: _declineCall,
                      child: Container(
                        width: 42,
                        height: 42,
                        decoration: const BoxDecoration(
                          color: Color(0xFFEF4444),
                          shape: BoxShape.circle,
                        ),
                        child: const Icon(
                          Icons.call_end,
                          color: Colors.white,
                          size: 20,
                        ),
                      ),
                    ),
                    const SizedBox(width: 10),
                    // Accept button
                    GestureDetector(
                      key: const Key('incoming_call_accept_button'),
                      onTap: _acceptCall,
                      child: Container(
                        width: 42,
                        height: 42,
                        decoration: const BoxDecoration(
                          color: Color(0xFF10B981),
                          shape: BoxShape.circle,
                        ),
                        child: const Icon(
                          Icons.call,
                          color: Colors.white,
                          size: 20,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          )
        else if (_hasMinimizedActiveCall)
          Positioned(
            top: topPadding + 8,
            left: 16,
            right: 16,
            child: Material(
              key: const Key('minimized_call_pill'),
              elevation: 10,
              borderRadius: BorderRadius.circular(28),
              color: const Color(0xFF0F172A),
              child: InkWell(
                borderRadius: BorderRadius.circular(28),
                onTap: _expandActiveCall,
                child: Padding(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                  child: Row(
                    children: [
                      Container(
                        width: 10,
                        height: 10,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: _callState == CallState.connected
                              ? Colors.greenAccent
                              : Colors.amberAccent,
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              () {
                                final s = _callManager.currentSession!;
                                final isCaller =
                                    s.callerId == _callManager.currentUserId;
                                return isCaller ? s.receiverName : s.callerName;
                              }(),
                              style: const TextStyle(
                                color: Colors.white,
                                fontWeight: FontWeight.w600,
                                fontSize: 13,
                              ),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                            Text(
                              '${_miniBarStatusLabel()} • Tap to return to call',
                              style: TextStyle(
                                color: _callState == CallState.connected
                                    ? Colors.greenAccent
                                    : Colors.white70,
                                fontSize: 11,
                                fontWeight: FontWeight.w500,
                              ),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ],
                        ),
                      ),
                      IconButton(
                        key: const Key('minimized_call_mute_button'),
                        icon: Icon(
                          _callManager.isMuted
                              ? Icons.mic_off_rounded
                              : Icons.mic_rounded,
                          color: _callManager.isMuted
                              ? Colors.amberAccent
                              : Colors.white,
                          size: 20,
                        ),
                        onPressed: () async {
                          await _callManager.toggleMute(!_callManager.isMuted);
                          if (mounted) setState(() {});
                        },
                        tooltip: _callManager.isMuted ? 'Unmute' : 'Mute',
                        visualDensity: VisualDensity.compact,
                      ),
                      const SizedBox(width: 4),
                      GestureDetector(
                        key: const Key('minimized_call_hangup_button'),
                        onTap: () {
                          unawaited(_callManager.endCall(
                              reason: 'User tapped hangup from mini-bar'));
                        },
                        child: Container(
                          width: 34,
                          height: 34,
                          decoration: const BoxDecoration(
                            color: Color(0xFFEF4444),
                            shape: BoxShape.circle,
                          ),
                          child: const Icon(
                            Icons.call_end_rounded,
                            color: Colors.white,
                            size: 18,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }
}
