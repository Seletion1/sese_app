import 'dart:async';
import 'package:flutter/material.dart';

import '../services/call/call_service_manager.dart';
import '../services/call/i_call_service.dart';

/// Full-screen in-app VoIP audio call screen.
///
/// Features:
/// - Real-time state transitions (`outgoing`, `connecting`, `connected`, `ended`).
/// - Live call duration counter.
/// - Hardware microphone mute and loudspeaker toggle buttons.
/// - Active provider badge chip reflecting [CallProviderType].
/// - Animated pulsating caller ring effect during dialing.
class InAppCallScreen extends StatefulWidget {
  final String callId;
  final String targetUserId;
  final String targetUserName;
  final String? targetUserAvatar;
  final bool isIncoming;
  final Map<String, dynamic>? metadata;

  const InAppCallScreen({
    super.key,
    required this.callId,
    required this.targetUserId,
    required this.targetUserName,
    this.targetUserAvatar,
    this.isIncoming = false,
    this.metadata,
  });

  /// Convenience helper to push the in-app call screen.
  static Future<void> start({
    required BuildContext context,
    required String callId,
    required String targetUserId,
    required String targetUserName,
    String? targetUserAvatar,
    Map<String, dynamic>? metadata,
  }) {
    return Navigator.of(context).push<void>(
      MaterialPageRoute(
        fullscreenDialog: true,
        builder: (_) => InAppCallScreen(
          callId: callId,
          targetUserId: targetUserId,
          targetUserName: targetUserName,
          targetUserAvatar: targetUserAvatar,
          isIncoming: false,
          metadata: metadata,
        ),
      ),
    );
  }

  @override
  State<InAppCallScreen> createState() => _InAppCallScreenState();
}

class _InAppCallScreenState extends State<InAppCallScreen>
    with SingleTickerProviderStateMixin {
  late final AnimationController _pulseController;
  late final Animation<double> _pulseAnimation;

  final CallServiceManager _callManager = CallServiceManager.instance;
  late final ICallService _service;

  StreamSubscription<CallState>? _stateSub;
  StreamSubscription<Duration>? _durationSub;

  late CallState _state;
  Duration _duration = Duration.zero;
  bool _isMuted = false;
  bool _isSpeakerOn = false;
  String? _errorMessage;

  @override
  void initState() {
    super.initState();
    _state = widget.isIncoming ? CallState.connecting : CallState.outgoing;
    _service = _callManager.activeService;

    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1400),
    )..repeat(reverse: true);

    _pulseAnimation = Tween<double>(begin: 1.0, end: 1.18).animate(
      CurvedAnimation(parent: _pulseController, curve: Curves.easeInOut),
    );

    _stateSub = _service.stateStream.listen((state) {
      if (!mounted) return;
      setState(() => _state = state);

      if (state == CallState.ended) {
        _pulseController.stop();
        Future.delayed(const Duration(milliseconds: 1200), () {
          if (mounted) Navigator.of(context).pop();
        });
      } else if (state == CallState.error) {
        _pulseController.stop();
        setState(() => _errorMessage = 'Call failed to connect');
        Future.delayed(const Duration(seconds: 2), () {
          if (mounted) Navigator.of(context).pop();
        });
      }
    });

    _durationSub = _service.durationStream.listen((duration) {
      if (!mounted) return;
      setState(() => _duration = duration);
    });

    _initiateCall();
  }

  Future<void> _initiateCall() async {
    try {
      if (widget.isIncoming) {
        await _service.answerCall(widget.callId);
      } else {
        await _service.startCall(
          targetUserId: widget.targetUserId,
          callId: widget.callId,
          targetUserName: widget.targetUserName,
          targetUserAvatar: widget.targetUserAvatar,
          metadata: widget.metadata,
        );
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _state = CallState.error;
          _errorMessage = e.toString().replaceFirst('Exception: ', '');
        });
        Future.delayed(const Duration(seconds: 2), () {
          if (mounted) Navigator.of(context).pop();
        });
      }
    }
  }

  Future<void> _toggleMute() async {
    final next = !_isMuted;
    await _service.toggleMute(next);
    if (mounted) setState(() => _isMuted = next);
  }

  Future<void> _toggleSpeaker() async {
    final next = !_isSpeakerOn;
    await _service.toggleSpeaker(next);
    if (mounted) setState(() => _isSpeakerOn = next);
  }

  Future<void> _endCall() async {
    await _service.endCall(reason: 'User tapped hangup');
    if (mounted) Navigator.of(context).pop();
  }

  @override
  void dispose() {
    _pulseController.dispose();
    _stateSub?.cancel();
    _durationSub?.cancel();
    super.dispose();
  }

  String _formatDuration(Duration d) {
    final minutes = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final seconds = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    final hours = d.inHours;
    if (hours > 0) {
      return '$hours:$minutes:$seconds';
    }
    return '$minutes:$seconds';
  }

  String get _statusLabel {
    if (_errorMessage != null) return _errorMessage!;
    switch (_state) {
      case CallState.idle:
        return 'Ready';
      case CallState.outgoing:
        return 'Calling...';
      case CallState.incoming:
        return 'Incoming Call...';
      case CallState.connecting:
        return 'Connecting...';
      case CallState.connected:
        return _formatDuration(_duration);
      case CallState.reconnecting:
        return 'Reconnecting...';
      case CallState.ended:
        return 'Call Ended';
      case CallState.error:
        return 'Call Failed';
    }
  }

  @override
  Widget build(BuildContext context) {
    final providerName = _service.providerType == CallProviderType.webrtc
        ? 'WebRTC P2P (Firebase Signaling)'
        : 'ZegoCloud SDK';

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _endCall();
      },
      child: Scaffold(
        backgroundColor: const Color(0xFF0F172A), // Dark obsidian blue
        body: SafeArea(
          child: Column(
            children: [
              // ── Header / Active Provider Chip ──────────────────────────
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                      decoration: BoxDecoration(
                        color: Colors.white.withValues(alpha: 0.12),
                        borderRadius: BorderRadius.circular(16),
                      ),
                      child: Row(
                        children: [
                          Icon(
                            _service.providerType == CallProviderType.webrtc
                                ? Icons.sync_alt_rounded
                                : Icons.cloud_done_rounded,
                            size: 14,
                            color: Colors.cyanAccent,
                          ),
                          const SizedBox(width: 6),
                          Text(
                            providerName,
                            style: const TextStyle(
                              color: Colors.white70,
                              fontSize: 11,
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                        ],
                      ),
                    ),
                    IconButton(
                      icon: const Icon(Icons.keyboard_arrow_down_rounded, color: Colors.white70),
                      onPressed: _endCall,
                    ),
                  ],
                ),
              ),

              const Spacer(),

              // ── Avatar & Name ──────────────────────────────────────────
              AnimatedBuilder(
                animation: _pulseAnimation,
                builder: (context, child) {
                  final isRinging = _state == CallState.outgoing || _state == CallState.connecting;
                  return Transform.scale(
                    scale: isRinging ? _pulseAnimation.value : 1.0,
                    child: Container(
                      width: 140,
                      height: 140,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: const Color(0xFF1E293B),
                        border: Border.all(
                          color: _state == CallState.connected
                              ? Colors.greenAccent
                              : Colors.cyanAccent.withValues(alpha: 0.6),
                          width: 3,
                        ),
                        boxShadow: [
                          BoxShadow(
                            color: (_state == CallState.connected
                                    ? Colors.greenAccent
                                    : Colors.cyanAccent)
                                .withValues(alpha: 0.25),
                            blurRadius: 28,
                            spreadRadius: 4,
                          ),
                        ],
                      ),
                      child: Center(
                        child: Text(
                          widget.targetUserName.isNotEmpty
                              ? widget.targetUserName[0].toUpperCase()
                              : '?',
                          style: const TextStyle(
                            fontSize: 48,
                            fontWeight: FontWeight.bold,
                            color: Colors.white,
                          ),
                        ),
                      ),
                    ),
                  );
                },
              ),

              const SizedBox(height: 28),

              Text(
                widget.targetUserName,
                style: const TextStyle(
                  fontSize: 24,
                  fontWeight: FontWeight.bold,
                  color: Colors.white,
                  letterSpacing: 0.3,
                ),
              ),

              const SizedBox(height: 8),

              Text(
                _statusLabel,
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: _state == CallState.connected ? FontWeight.bold : FontWeight.w400,
                  color: _state == CallState.connected
                      ? Colors.greenAccent
                      : (_errorMessage != null ? Colors.redAccent : Colors.white60),
                ),
              ),

              const Spacer(),

              // ── In-Call Controls ───────────────────────────────────────
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 36, vertical: 40),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                  children: [
                    // Mic Mute Button
                    _CallControlButton(
                      key: const Key('call_mute_button'),
                      icon: _isMuted ? Icons.mic_off_rounded : Icons.mic_rounded,
                      isActive: _isMuted,
                      label: _isMuted ? 'Muted' : 'Mute',
                      onTap: _toggleMute,
                    ),

                    // End Call Button (Big Red Hangup)
                    GestureDetector(
                      key: const Key('call_hangup_button'),
                      onTap: _endCall,
                      child: Container(
                        width: 72,
                        height: 72,
                        decoration: BoxDecoration(
                          color: Colors.red.shade600,
                          shape: BoxShape.circle,
                          boxShadow: [
                            BoxShadow(
                              color: Colors.red.withValues(alpha: 0.4),
                              blurRadius: 18,
                              spreadRadius: 2,
                            ),
                          ],
                        ),
                        child: const Icon(
                          Icons.call_end_rounded,
                          size: 34,
                          color: Colors.white,
                        ),
                      ),
                    ),

                    // Speakerphone Button
                    _CallControlButton(
                      key: const Key('call_speaker_button'),
                      icon: _isSpeakerOn
                          ? Icons.volume_up_rounded
                          : Icons.volume_down_rounded,
                      isActive: _isSpeakerOn,
                      label: _isSpeakerOn ? 'Speaker' : 'Earpiece',
                      onTap: _toggleSpeaker,
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _CallControlButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final bool isActive;
  final VoidCallback onTap;

  const _CallControlButton({
    super.key,
    required this.icon,
    required this.label,
    required this.isActive,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(32),
          child: Container(
            width: 58,
            height: 58,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: isActive ? Colors.white : Colors.white.withValues(alpha: 0.15),
            ),
            child: Icon(
              icon,
              size: 26,
              color: isActive ? const Color(0xFF0F172A) : Colors.white,
            ),
          ),
        ),
        const SizedBox(height: 8),
        Text(
          label,
          style: const TextStyle(
            color: Colors.white70,
            fontSize: 12,
          ),
        ),
      ],
    );
  }
}
