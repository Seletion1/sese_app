import 'dart:async';
import 'package:flutter/material.dart';

import '../services/app_sound_service.dart';
import '../services/call/call_service_manager.dart';
import '../services/call/i_call_service.dart';
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
  StreamSubscription<CallSession?>? _incomingSub;
  CallSession? _incomingSession;
  Timer? _ringTimer;

  @override
  void initState() {
    super.initState();
    _incomingSub = _callManager.incomingCallStream.listen((session) {
      if (!mounted) return;
      if (session != null && session.state == CallState.incoming) {
        if (_incomingSession?.callId != session.callId) {
          setState(() => _incomingSession = session);
          _startRingtone();
        }
      } else {
        if (_incomingSession != null) {
          _stopRingtone();
          setState(() => _incomingSession = null);
        }
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
    _stopRingtone();
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
    _stopRingtone();
    setState(() => _incomingSession = null);
    // ignore: discarded_futures
    _callManager.rejectCall(session.callId);
  }

  @override
  void dispose() {
    _stopRingtone();
    _incomingSub?.cancel();
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
          ),
      ],
    );
  }
}
