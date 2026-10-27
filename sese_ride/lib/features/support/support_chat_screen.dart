import 'dart:async';
import 'dart:io';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:record/record.dart';
import 'package:sese_core/sese_core.dart';

import 'support_chat_service.dart';

/// Firebase-native AI support chat for sese_ride (customer & driver).
///
/// Session lifecycle (status field on `support_chats/{chatId}`):
///   ai_active        → AI handles the conversation via Cloud Function.
///   pending_agent    → User escalated; waiting for a hub agent to claim.
///   agent_connected  → Hub agent is live in the thread.
///   resolved         → Session closed; input is locked on both sides.
class SupportChatScreen extends StatefulWidget {
  final AppUser user;

  /// 'driver' | 'customer'. Stored on new sessions as `userRole`.
  final String userRole;

  /// Test seam: inject a stub service in widget tests.
  final SupportChatService? service;

  const SupportChatScreen({
    super.key,
    required this.user,
    required this.userRole,
    this.service,
  });

  @override
  State<SupportChatScreen> createState() => _SupportChatScreenState();
}

class _SupportChatScreenState extends State<SupportChatScreen> {
  late final SupportChatService _chat =
      widget.service ?? SupportChatService();
  final _inputCtrl = TextEditingController();
  final _scrollCtrl = ScrollController();

  Future<String>? _sessionFuture;
  String? _chatId;
  String? _sessionError;
  bool _waiting = false;
  bool _sending = false;
  bool _uploading = false;
  int _seenCount = 0;

  @override
  void initState() {
    super.initState();
    _openSession();
  }

  void _openSession() {
    setState(() {
      _chatId = null;
      _sessionError = null;
    });
    final future = _chat.openOrCreateSession(
      userId: widget.user.uid,
      userRole: widget.userRole,
      userName: widget.user.fullName,
    );
    _sessionFuture = future;
    future.then(
      (id) {
        if (mounted) setState(() => _chatId = id);
      },
      onError: (Object e) {
        // Keep the real reason. A blanket "check your connection" hid a
        // permission-denied as a connectivity problem, which sent debugging in
        // the wrong direction entirely.
        debugPrint('SupportChatScreen: open session failed: $e');
        if (mounted) {
          setState(() {
            _sessionError = e is SupportChatException
                ? e.userMessage
                : 'Could not open support chat.';
          });
        }
      },
    );
  }

  @override
  void dispose() {
    _inputCtrl.dispose();
    _scrollCtrl.dispose();
    super.dispose();
  }

  void _scrollToEnd() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scrollCtrl.hasClients) return;
      _scrollCtrl.animateTo(
        _scrollCtrl.position.maxScrollExtent,
        duration: const Duration(milliseconds: 250),
        curve: Curves.easeOut,
      );
    });
  }

  // ---------------------------------------------------------------------------
  // Escalate to human agent
  // ---------------------------------------------------------------------------

  Future<void> _requestHumanAgent(String chatId) async {
    if (_sending) return;
    setState(() => _sending = true);
    try {
      await _chat.requestHumanAgent(
        chatId: chatId,
        userId: widget.user.uid,
      );
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
              'Connecting you to an available support agent in Sese Hub…'),
        ),
      );
    } on SupportChatException catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(e.userMessage)));
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  // ---------------------------------------------------------------------------
  // Send a user message
  // ---------------------------------------------------------------------------

  Future<void> _send(String chatId, String status) async {
    final text = _inputCtrl.text.trim();
    if (text.isEmpty || _sending) return;
    if (SupportChatStatus.isLocked(status)) return;
    setState(() {
      _sending = true;
      _waiting = true;
    });
    _inputCtrl.clear();
    try {
      await _chat.sendMessage(
        chatId: chatId,
        userId: widget.user.uid,
        text: text,
      );
    } on SupportChatException catch (e) {
      if (!mounted) return;
      setState(() => _waiting = false);
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(e.userMessage)));
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  /// Picks a photo and sends it to the thread.
  Future<void> _pickAndSendImage(String chatId, String status) async {
    if (SupportChatStatus.isLocked(status)) return;
    // Runtime permission handshake BEFORE the native picker (otherwise the
    // gallery can open dead on first install with no error surfaced).
    final permission =
        await MediaPermissionService.ensureFor(ImageSource.gallery);
    if (!mounted) return;
    if (permission != MediaPermissionOutcome.granted) {
      await MediaPermissionService.promptIfPermanentlyDenied(context);
      return;
    }
    XFile? picked;
    try {
      picked = await ImageCompressionService.pickAndCompressImage(
        source: ImageSource.gallery,
      );
    } catch (e) {
      debugPrint('SupportChatScreen: image pick failed: $e');
    }
    if (picked == null || !mounted) return;

    setState(() {
      _uploading = true;
      _waiting = true;
    });
    try {
      await _chat.sendImage(
        chatId: chatId,
        userId: widget.user.uid,
        file: picked,
        caption: _inputCtrl.text.trim(),
      );
      _inputCtrl.clear();
    } on SupportChatException catch (e) {
      if (!mounted) return;
      setState(() => _waiting = false);
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(e.userMessage)));
    } finally {
      if (mounted) setState(() => _uploading = false);
    }
  }

  /// Uploads a voice note and sends it as an audio message.
  Future<void> _sendVoiceNote(
    String chatId,
    String status, {
    required String filePath,
    required int durationSeconds,
  }) async {
    if (SupportChatStatus.isLocked(status)) return;
    if (filePath.isEmpty) return;
    setState(() {
      _uploading = true;
      _waiting = true;
    });
    try {
      final bytes = await File(filePath).readAsBytes();
      await _chat.sendVoiceNote(
        chatId: chatId,
        userId: widget.user.uid,
        audioBytes: bytes,
        durationSeconds: durationSeconds,
      );
    } on SupportChatException catch (e) {
      if (!mounted) return;
      setState(() => _waiting = false);
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(e.userMessage)));
    } catch (e) {
      if (!mounted) return;
      setState(() => _waiting = false);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Could not send voice note. Try again.')),
      );
    } finally {
      if (mounted) setState(() => _uploading = false);
    }
  }

  // ---------------------------------------------------------------------------
  // Build
  // ---------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: const Text('SeSe Assistant'),
        actions: [
          if (_chatId != null)
            StreamBuilder<String>(
              stream: _chat.statusStream(_chatId!),
              builder: (context, statusSnap) {
                final status =
                    statusSnap.data ?? SupportChatStatus.aiActive;
                // Show "Connect to Agent" only while AI is handling.
                if (status != SupportChatStatus.aiActive) {
                  return const SizedBox.shrink();
                }
                return IconButton(
                  key: const Key('connect_human_button'),
                  icon: const Icon(Icons.support_agent_outlined),
                  tooltip: 'Connect to Human Agent',
                  onPressed:
                      _sending ? null : () => _requestHumanAgent(_chatId!),
                );
              },
            ),
        ],
      ),
      body: FutureBuilder<String>(
        future: _sessionFuture,
        builder: (context, sessionSnap) {
          if (sessionSnap.connectionState == ConnectionState.waiting) {
            return const Center(child: CircularProgressIndicator());
          }
          if (sessionSnap.hasError || sessionSnap.data == null) {
            final reason = _sessionError ?? 'Could not open support chat.';
            return Center(
              child: Padding(
                padding: const EdgeInsets.all(32),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.support_agent, size: 56, color: Colors.grey),
                    const SizedBox(height: 12),
                    const Text(
                      'Could not open support chat.',
                      style: TextStyle(fontWeight: FontWeight.bold),
                    ),
                    const SizedBox(height: 8),
                    // Surface the actual cause instead of guessing at the
                    // network. A permission error and a connectivity error
                    // need completely different fixes.
                    Text(
                      reason,
                      textAlign: TextAlign.center,
                      style: const TextStyle(fontSize: 13),
                    ),
                    const SizedBox(height: 16),
                    FilledButton(
                      onPressed: _openSession,
                      child: const Text('Retry'),
                    ),
                  ],
                ),
              ),
            );
          }
          final chatId = sessionSnap.data!;
          return StreamBuilder<String>(
            stream: _chat.statusStream(chatId),
            builder: (context, statusSnap) {
              final status =
                  statusSnap.data ?? SupportChatStatus.aiActive;
              final isHuman = SupportChatStatus.isHumanInvolved(status);
              final isResolved = SupportChatStatus.isResolved(status);
              final isLocked = SupportChatStatus.isLocked(status);

              return Column(
                children: [
                  // ── Status banner ──────────────────────────────────────────
                  if (status == SupportChatStatus.pendingAgent)
                    _StatusBanner(
                      key: const Key('pending_agent_banner'),
                      icon: Icons.hourglass_top_outlined,
                      color: scheme.secondaryContainer,
                      textColor: scheme.onSecondaryContainer,
                      message:
                          'Looking for an available support agent…',
                    ),
                  if (status == SupportChatStatus.agentConnected)
                    _StatusBanner(
                      key: const Key('agent_connected_banner'),
                      icon: Icons.support_agent,
                      color: scheme.tertiaryContainer,
                      textColor: scheme.onTertiaryContainer,
                      message:
                          'Connected to a Support Agent — an admin will reply here.',
                    ),
                  if (isResolved)
                    _StatusBanner(
                      key: const Key('resolved_banner'),
                      icon: Icons.check_circle_outline,
                      color: scheme.surfaceContainerHighest,
                      textColor: scheme.onSurfaceVariant,
                      message: 'This chat has been resolved and closed.',
                    ),

                  // CSAT prompt — only after an agent closes the chat, and
                  // only until a rating exists (the stream drives that, so a
                  // rebuild never re-asks someone who already rated).
                  if (isResolved) _CsatPrompt(chatId: chatId, chat: _chat),

                  // ── Messages list ──────────────────────────────────────────
                  Expanded(
                    child: StreamBuilder<List<SupportMessage>>(
                      stream: _chat.messagesStream(chatId),
                      builder: (context, msgSnap) {
                        final messages =
                            msgSnap.data ?? const <SupportMessage>[];
                        if (messages.isNotEmpty &&
                            messages.last.senderType != 'user' &&
                            _waiting) {
                          _waiting = false;
                        }
                        if (messages.length != _seenCount) {
                          if (_seenCount != 0 &&
                              messages.isNotEmpty &&
                              messages.last.senderType != 'user') {
                            // ignore: discarded_futures
                            AppSoundService.instance
                                .playIncomingMessageSound();
                          }
                          _seenCount = messages.length;
                          _scrollToEnd();
                        }
                        if (messages.isEmpty && !_waiting) {
                          return Center(
                            child: Padding(
                              padding: const EdgeInsets.all(32),
                              child: Column(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Icon(Icons.smart_toy_outlined,
                                      size: 56, color: scheme.primary),
                                  const SizedBox(height: 12),
                                  const Text(
                                    'Hi! I can help with payouts, trip issues, '
                                    'wallet queries, app navigation and more.',
                                    textAlign: TextAlign.center,
                                  ),
                                ],
                              ),
                            ),
                          );
                        }
                        return ListView.builder(
                          controller: _scrollCtrl,
                          padding: const EdgeInsets.all(12),
                          itemCount:
                              messages.length + (_waiting ? 1 : 0),
                          itemBuilder: (context, i) {
                            if (_waiting && i == messages.length) {
                              return const _TypingIndicator();
                            }
                            return _Bubble(message: messages[i]);
                          },
                        );
                      },
                    ),
                  ),

                  // ── Input bar ──────────────────────────────────────────────
                  SafeArea(
                    top: false,
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(12, 4, 12, 12),
                      child: isLocked
                          ? Container(
                              padding: const EdgeInsets.symmetric(
                                  vertical: 14, horizontal: 16),
                              decoration: BoxDecoration(
                                color: scheme.surfaceContainerHighest,
                                borderRadius: BorderRadius.circular(24),
                              ),
                              child: Text(
                                'This chat is closed.',
                                style: TextStyle(
                                    color: scheme.onSurfaceVariant,
                                    fontSize: 14),
                                textAlign: TextAlign.center,
                              ),
                            )
                          : Row(
                              children: [
                                Expanded(
                                  child: TextField(
                                    key: const Key('support_input'),
                                    controller: _inputCtrl,
                                    enabled: !isLocked,
                                    minLines: 1,
                                    maxLines: 4,
                                    textInputAction: TextInputAction.send,
                                    onSubmitted: (_) =>
                                        _send(chatId, status),
                                    decoration: InputDecoration(
                                      hintText: isHuman
                                          ? 'Message the support agent…'
                                          : 'Ask about payouts, trips, wallet…',
                                      filled: true,
                                      fillColor: Colors.grey.shade100,
                                      border: OutlineInputBorder(
                                        borderRadius:
                                            BorderRadius.circular(24),
                                        borderSide: BorderSide.none,
                                      ),
                                      contentPadding:
                                          const EdgeInsets.symmetric(
                                              horizontal: 16, vertical: 10),
                                    ),
                                  ),
                                ),
                                const SizedBox(width: 8),
                                IconButton(
                                  key: const Key('support_attach_image'),
                                  tooltip: 'Send a photo',
                                  icon: _uploading
                                      ? const SizedBox(
                                          width: 20,
                                          height: 20,
                                          child: CircularProgressIndicator(
                                              strokeWidth: 2),
                                        )
                                      : const Icon(Icons.add_a_photo_outlined),
                                  onPressed: (isLocked || _sending || _uploading)
                                      ? null
                                      : () => _pickAndSendImage(chatId, status),
                                ),
                                const SizedBox(width: 4),
                                _VoiceNoteRecorderButton(
                                  enabled: !isLocked && !_sending && !_uploading,
                                  onVoiceNote: (path, durationSec) =>
                                      _sendVoiceNote(
                                    chatId,
                                    status,
                                    filePath: path,
                                    durationSeconds: durationSec,
                                  ),
                                ),
                                const SizedBox(width: 8),
                                FilledButton(
                                  key: const Key('support_send_button'),
                                  style: FilledButton.styleFrom(
                                    shape: const CircleBorder(),
                                    padding: const EdgeInsets.all(12),
                                  ),
                                  onPressed: _sending
                                      ? null
                                      : () => _send(chatId, status),
                                  child: _sending
                                      ? const SizedBox(
                                          width: 20,
                                          height: 20,
                                          child: CircularProgressIndicator(
                                              strokeWidth: 2,
                                              color: Colors.white),
                                        )
                                      : const Icon(Icons.send),
                                ),
                              ],
                            ),
                    ),
                  ),
                ],
              );
            },
          );
        },
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Voice Note Recorder Button
// ---------------------------------------------------------------------------

/// Tap-to-record voice note button in the support chat composer.
///
/// Tap to start recording, tap again to stop and send. Shows a recording
/// timer and a cancel option while active. Uses [AudioRecorder] from
/// `package:record` for cross-platform AAC/M4A capture.
class _VoiceNoteRecorderButton extends StatefulWidget {
  final bool enabled;
  final void Function(String filePath, int durationSeconds) onVoiceNote;

  const _VoiceNoteRecorderButton({
    required this.enabled,
    required this.onVoiceNote,
  });

  @override
  State<_VoiceNoteRecorderButton> createState() =>
      _VoiceNoteRecorderButtonState();
}

class _VoiceNoteRecorderButtonState extends State<_VoiceNoteRecorderButton> {
  final _recorder = AudioRecorder();
  bool _recording = false;
  bool _busy = false;
  String? _recordingPath;
  int _elapsedSeconds = 0;
  Timer? _timer;

  @override
  void dispose() {
    _timer?.cancel();
    _recorder.dispose();
    super.dispose();
  }

  Future<void> _startRecording() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      // Request mic permission explicitly — needed on Android 12+ and iOS.
      final status = await Permission.microphone.request();
      if (!mounted) return;
      if (!status.isGranted) {
        if (status.isPermanentlyDenied) {
          await openAppSettings();
        } else {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Microphone permission is required to send voice notes.'),
            ),
          );
        }
        return;
      }
      final hasPermission = await _recorder.hasPermission();
      if (!hasPermission || !mounted) return;

      final dir = Directory.systemTemp;
      final path =
          '${dir.path}/sese_voicenote_${DateTime.now().millisecondsSinceEpoch}.m4a';
      await _recorder.start(
        const RecordConfig(encoder: AudioEncoder.aacLc, bitRate: 64000),
        path: path,
      );
      _recordingPath = path;
      _elapsedSeconds = 0;
      _timer = Timer.periodic(const Duration(seconds: 1), (_) {
        if (mounted) setState(() => _elapsedSeconds++);
      });
      if (mounted) setState(() => _recording = true);
    } catch (e) {
      debugPrint('_VoiceNoteRecorderButton: start failed: $e');
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Could not start recording.')),
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _stopAndSend() async {
    if (_busy) return;
    setState(() => _busy = true);
    _timer?.cancel();
    _timer = null;
    try {
      final path = await _recorder.stop();
      final duration = _elapsedSeconds;
      if (mounted) setState(() => _recording = false);
      if (path == null || path.isEmpty) return;
      widget.onVoiceNote(path, duration);
    } catch (e) {
      debugPrint('_VoiceNoteRecorderButton: stop failed: $e');
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Could not finish recording.')),
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _cancel() async {
    _timer?.cancel();
    _timer = null;
    try {
      await _recorder.stop();
      // Delete the temp file silently.
      if (_recordingPath != null) {
        try {
          await File(_recordingPath!).delete();
        } catch (_) {}
        _recordingPath = null;
      }
    } catch (_) {}
    if (mounted) setState(() => _recording = false);
  }

  String _formatDuration(int seconds) {
    final m = seconds ~/ 60;
    final s = seconds % 60;
    return '${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    if (_recording) {
      // Recording mode: show timer + cancel + send icons.
      return Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          IconButton(
            tooltip: 'Cancel',
            icon: const Icon(Icons.delete_outline, color: Colors.grey),
            onPressed: _busy ? null : _cancel,
          ),
          Text(
            _formatDuration(_elapsedSeconds),
            style: const TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w600,
              color: Colors.red,
            ),
          ),
          IconButton(
            key: const Key('support_voice_send'),
            tooltip: 'Send voice note',
            icon: _busy
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.send, color: Colors.green),
            onPressed: _busy ? null : _stopAndSend,
          ),
        ],
      );
    }
    return IconButton(
      key: const Key('support_voice_button'),
      tooltip: 'Send a voice note',
      icon: _busy
          ? const SizedBox(
              width: 20,
              height: 20,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : const Icon(Icons.mic_none_outlined),
      onPressed: widget.enabled && !_busy ? _startRecording : null,
    );
  }
}

// ---------------------------------------------------------------------------
// Status Banner
// ---------------------------------------------------------------------------

class _StatusBanner extends StatelessWidget {
  final IconData icon;
  final Color color;
  final Color textColor;
  final String message;

  const _StatusBanner({
    super.key,
    required this.icon,
    required this.color,
    required this.textColor,
    required this.message,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      color: color,
      child: Row(
        children: [
          Icon(icon, size: 16, color: textColor),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              message,
              style: TextStyle(
                  fontSize: 12,
                  color: textColor,
                  fontWeight: FontWeight.w600),
            ),
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Chat Bubble
// ---------------------------------------------------------------------------

class _Bubble extends StatelessWidget {
  final SupportMessage message;

  const _Bubble({required this.message});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final mine = message.isMine;
    return Align(
      alignment: mine ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 4),
        padding:
            const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        constraints: BoxConstraints(
            maxWidth: MediaQuery.sizeOf(context).width * 0.78),
        decoration: BoxDecoration(
          color: mine ? scheme.primary : scheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(16).copyWith(
            bottomRight: mine ? Radius.zero : null,
            bottomLeft: mine ? null : Radius.zero,
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            if (!mine)
              Text(
                message.senderLabel,
                style: TextStyle(
                    fontSize: 10,
                    fontWeight: FontWeight.bold,
                    color: scheme.primary),
              ),
            if (message.isImage)
              // Bounded so a tall photo cannot push the whole thread off
              // screen. Tapping opens it full size.
              GestureDetector(
                onTap: () => _openImage(context, message.imageUrl!),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(10),
                    child: Image.network(
                      message.imageUrl!,
                      key: Key('support_image_${message.id}'),
                      width: 220,
                      height: 220,
                      fit: BoxFit.cover,
                      // A dead URL must not break the thread: show a
                      // placeholder rather than a red error box mid-chat.
                      errorBuilder: (_, _, _) => Container(
                      width: 220,
                      height: 120,
                      color: scheme.surfaceContainerHighest,
                      child: const Icon(Icons.broken_image_outlined),
                    ),
                    loadingBuilder: (_, child, progress) => progress == null
                        ? child
                        : Container(
                            width: 220,
                            height: 120,
                            color: scheme.surfaceContainerHighest,
                            child: const Center(
                              child: SizedBox(
                                width: 20,
                                height: 20,
                                child: CircularProgressIndicator(
                                    strokeWidth: 2),
                              ),
                            ),
                          ),
                  ),
                ),
              ),
            if (message.isImage && message.text.isNotEmpty)
              const SizedBox(height: 6),
            if (message.isAudio)
              _AudioPlayerBubble(
                key: Key('audio_${message.id}'),
                audioUrl: message.audioUrl!,
                durationSeconds: message.durationSeconds ?? 0,
                isMine: mine,
              ),
            if (message.text.isNotEmpty)
              Text(
                message.text,
                style: TextStyle(
                    color: mine ? scheme.onPrimary : scheme.onSurface,
                    fontSize: 14),
              ),
          ],
        ),
      ),
    );
  }

  /// Opens a support photo full-screen for inspection.
  void _openImage(BuildContext context, String url) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => Scaffold(
          backgroundColor: Colors.black,
          appBar: AppBar(backgroundColor: Colors.black),
          body: Center(
            child: InteractiveViewer(
              child: Image.network(
                url,
                errorBuilder: (_, _, _) => const Icon(
                  Icons.broken_image_outlined,
                  color: Colors.white70,
                  size: 48,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Audio Player Bubble
// ---------------------------------------------------------------------------

/// Inline audio player for voice note messages in the support thread.
///
/// Shows a play/pause button, a progress slider, and the recorded duration.
/// Uses [AudioPlayer] from `package:audioplayers` — no native platform views,
/// just Dart FFI bindings so it works safely on all devices including Nokia G20.
class _AudioPlayerBubble extends StatefulWidget {
  final String audioUrl;
  final int durationSeconds;
  final bool isMine;

  const _AudioPlayerBubble({
    super.key,
    required this.audioUrl,
    required this.durationSeconds,
    required this.isMine,
  });

  @override
  State<_AudioPlayerBubble> createState() => _AudioPlayerBubbleState();
}

class _AudioPlayerBubbleState extends State<_AudioPlayerBubble> {
  final _player = AudioPlayer();
  PlayerState _state = PlayerState.stopped;
  Duration _position = Duration.zero;
  late Duration _total;
  StreamSubscription<PlayerState>? _stateSub;
  StreamSubscription<Duration>? _posSub;

  @override
  void initState() {
    super.initState();
    _total = Duration(seconds: widget.durationSeconds.clamp(1, 3600));
    _stateSub = _player.onPlayerStateChanged.listen((s) {
      if (mounted) setState(() => _state = s);
    });
    _posSub = _player.onPositionChanged.listen((d) {
      if (mounted) setState(() => _position = d);
    });
    _player.onPlayerComplete.listen((_) {
      if (mounted) setState(() => _position = Duration.zero);
    });
  }

  @override
  void dispose() {
    _stateSub?.cancel();
    _posSub?.cancel();
    _player.dispose();
    super.dispose();
  }

  Future<void> _togglePlay() async {
    try {
      if (_state == PlayerState.playing) {
        await _player.pause();
      } else {
        await _player.play(UrlSource(widget.audioUrl));
      }
    } catch (e) {
      debugPrint('_AudioPlayerBubble: playback error: $e');
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Could not play voice note.')),
      );
    }
  }

  String _fmt(Duration d) {
    final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return '$m:$s';
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final playing = _state == PlayerState.playing;
    final fgColor = widget.isMine ? scheme.onPrimary : scheme.onSurface;
    final sliderActive =
        widget.isMine ? scheme.onPrimary : scheme.primary;
    final totalSecs = _total.inSeconds.toDouble().clamp(1.0, double.infinity);
    final posSecs = _position.inSeconds.toDouble().clamp(0.0, totalSecs);

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        IconButton(
          padding: EdgeInsets.zero,
          constraints: const BoxConstraints(),
          icon: Icon(
            playing ? Icons.pause_circle_filled : Icons.play_circle_filled,
            size: 36,
            color: fgColor,
          ),
          onPressed: _togglePlay,
        ),
        const SizedBox(width: 4),
        Flexible(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              SliderTheme(
                data: SliderThemeData(
                  activeTrackColor: sliderActive,
                  inactiveTrackColor: fgColor.withValues(alpha: 0.35),
                  thumbColor: sliderActive,
                  overlayShape: SliderComponentShape.noOverlay,
                  thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6),
                  trackHeight: 3,
                ),
                child: Slider(
                  value: posSecs,
                  min: 0,
                  max: totalSecs,
                  onChanged: (v) async {
                    await _player.seek(Duration(seconds: v.toInt()));
                  },
                ),
              ),
              Padding(
                padding: const EdgeInsets.only(left: 4),
                child: Text(
                  playing ? _fmt(_position) : _fmt(_total),
                  style: TextStyle(fontSize: 11, color: fgColor.withValues(alpha: 0.75)),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// CSAT — 1-5 star rating shown once an agent resolves the chat
// ---------------------------------------------------------------------------

/// Asks the user to rate the support experience, then shows their submitted
/// rating inline.
///
/// Reads `csatRating` from the chat document, so the prompt disappears the
/// moment a rating lands and never re-appears for the same chat — including
/// across app restarts, which a local-only flag could not guarantee.
class _CsatPrompt extends StatefulWidget {
  final String chatId;
  final SupportChatService chat;

  const _CsatPrompt({required this.chatId, required this.chat});

  @override
  State<_CsatPrompt> createState() => _CsatPromptState();
}

class _CsatPromptState extends State<_CsatPrompt> {
  int? _hovered;
  bool _saving = false;

  Future<void> _rate(int stars) async {
    if (_saving) return;
    setState(() => _saving = true);
    try {
      await widget.chat.submitRating(chatId: widget.chatId, rating: stars);
    } on SupportChatException catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(e.userMessage)));
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return StreamBuilder<int?>(
      stream: widget.chat.ratingStream(widget.chatId),
      builder: (context, snap) {
        final existing = snap.data;
        if (existing != null) {
          return Container(
            key: const Key('csat_thanks'),
            width: double.infinity,
            padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 16),
            color: scheme.surfaceContainerHighest,
            // Wrap (not Row) so stars + label flow to two lines on narrow
            // phones instead of overflowing or squeezing the text.
            child: Wrap(
              alignment: WrapAlignment.center,
              crossAxisAlignment: WrapCrossAlignment.center,
              spacing: 2,
              runSpacing: 4,
              children: [
                for (var i = 1; i <= 5; i++)
                  Icon(
                    i <= existing ? Icons.star : Icons.star_border,
                    size: 18,
                    color: i <= existing ? Colors.amber.shade700 : scheme.outline,
                  ),
                const SizedBox(width: 8),
                Text(
                  'Thanks for rating your support chat.',
                  style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
                  softWrap: true,
                  textAlign: TextAlign.center,
                ),
              ],
            ),
          );
        }

        return Container(
          key: const Key('csat_prompt'),
          width: double.infinity,
          padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 16),
          color: scheme.surfaceContainerHighest,
          // Wrap (not Row) so the label + 5 star buttons flow to two lines
          // on narrow phones instead of overflowing.
          child: Wrap(
            alignment: WrapAlignment.center,
            crossAxisAlignment: WrapCrossAlignment.center,
            spacing: 2,
            runSpacing: 4,
            children: [
              Text(
                'Rate this support chat:',
                style: TextStyle(fontSize: 13, color: scheme.onSurfaceVariant),
                softWrap: true,
              ),
              const SizedBox(width: 8),
              for (var i = 1; i <= 5; i++)
                IconButton(
                  key: Key('csat_star_$i'),
                  padding: const EdgeInsets.symmetric(horizontal: 2),
                  constraints: const BoxConstraints(),
                  iconSize: 24,
                  tooltip: '$i star${i == 1 ? '' : 's'}',
                  onPressed: _saving ? null : () => _rate(i),
                  icon: Icon(
                    _hovered != null && i <= _hovered!
                        ? Icons.star
                        : Icons.star_border,
                    color: Colors.amber.shade700,
                  ),
                  onHover: (v) => setState(() => _hovered = v ? i : null),
                ),
            ],
          ),
        );
      },
    );
  }
}

// ---------------------------------------------------------------------------
// Typing Indicator
// ---------------------------------------------------------------------------

class _TypingIndicator extends StatefulWidget {
  const _TypingIndicator();

  @override
  State<_TypingIndicator> createState() => _TypingIndicatorState();
}

class _TypingIndicatorState extends State<_TypingIndicator>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 900),
  )..repeat();

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Align(
      alignment: Alignment.centerLeft,
      child: Container(
        key: const Key('typing_indicator'),
        margin: const EdgeInsets.symmetric(vertical: 4),
        padding:
            const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        decoration: BoxDecoration(
          color: scheme.surfaceContainerHighest,
          borderRadius:
              BorderRadius.circular(16).copyWith(bottomLeft: Radius.zero),
        ),
        child: AnimatedBuilder(
          animation: _ctrl,
          builder: (context, child) => Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (var i = 0; i < 3; i++)
                Container(
                  width: 7,
                  height: 7,
                  margin: EdgeInsets.only(right: i == 2 ? 0 : 4),
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: scheme.onSurfaceVariant.withValues(
                        alpha: 0.35 +
                            0.65 *
                                ((_ctrl.value * 3 - i) % 3 / 3)
                                    .clamp(0.0, 1.0)),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
