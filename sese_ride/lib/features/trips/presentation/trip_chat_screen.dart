import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:sese_core/sese_core.dart';

import '../services/trip_chat_service.dart';

/// In-app tri-party trip chat (Customer ↔ Recipient relay ↔ Assigned
/// Driver, plus hub support readers).
///
/// Text + photo messages only — there is deliberately no voice-note
/// recorder anywhere (rules reject audio types). Phone numbers shown here
/// obey the viewer's "Hide Phone Number" toggle ([PrivacyMasking]).
class TripChatScreen extends StatefulWidget {
  final String tripId;
  final String currentUid;

  /// Role of the local sender: `customer` | `driver` (+ `recipient`
  /// relay-posted from the customer app).
  final String senderRole;

  /// Display name + phone of the other party (masked when hidden).
  final String peerName;
  final String peerPhone;
  final bool hidePhones;

  /// Test seam: inject a stub service in widget tests.
  final TripChatService? service;

  const TripChatScreen({
    super.key,
    required this.tripId,
    required this.currentUid,
    required this.senderRole,
    this.peerName = 'Trip chat',
    this.peerPhone = '',
    this.hidePhones = false,
    this.service,
  });

  @override
  State<TripChatScreen> createState() => _TripChatScreenState();
}

class _TripChatScreenState extends State<TripChatScreen> {
  late final TripChatService _chat = widget.service ?? TripChatService();
  final _inputCtrl = TextEditingController();
  final _scrollCtrl = ScrollController();
  bool _sending = false;
  bool _uploadingPhoto = false;

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

  Future<void> _send() async {
    final text = _inputCtrl.text.trim();
    if (text.isEmpty || _sending) return;
    setState(() => _sending = true);
    _inputCtrl.clear();
    try {
      await _chat.sendText(
        tripId: widget.tripId,
        senderId: widget.currentUid,
        senderRole: widget.senderRole,
        text: text,
      );
      _scrollToEnd();
    } on TripChatException catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(e.userMessage)));
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  Future<void> _sendPhoto() async {
    if (_uploadingPhoto || _sending) return;
    setState(() => _uploadingPhoto = true);
    try {
      final file = await ImagePicker().pickImage(
        source: ImageSource.gallery,
        maxWidth: 1600,
        imageQuality: 85,
      );
      if (file == null || !mounted) return;
      await _chat.sendImage(
        tripId: widget.tripId,
        senderId: widget.currentUid,
        senderRole: widget.senderRole,
        localPath: file.path,
      );
      _scrollToEnd();
    } on TripChatException catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(e.userMessage)));
    } finally {
      if (mounted) setState(() => _uploadingPhoto = false);
    }
  }

  String _roleLabel(String role) {
    switch (role) {
      case 'driver':
        return 'Driver';
      case 'recipient':
        return 'Recipient';
      case 'support':
        return 'Support';
      default:
        return 'Customer';
    }
  }

  @override
  Widget build(BuildContext context) {
    final peerSubtitle = widget.peerPhone.isEmpty
        ? 'Customer · Recipient · Driver'
        : PrivacyMasking.display(widget.peerPhone, hide: widget.hidePhones);
    return Scaffold(
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(widget.peerName, overflow: TextOverflow.ellipsis),
            Text(peerSubtitle,
                style:
                    const TextStyle(fontSize: 11, fontWeight: FontWeight.w400)),
          ],
        ),
      ),
      body: Column(
        children: [
          Expanded(
            child: StreamBuilder<List<TripChatMessage>>(
              stream: _chat.messagesStream(widget.tripId),
              builder: (context, snapshot) {
                final messages = snapshot.data ?? const <TripChatMessage>[];
                if (snapshot.connectionState == ConnectionState.waiting &&
                    messages.isEmpty) {
                  return const Center(child: CircularProgressIndicator());
                }
                if (messages.isEmpty) {
                  return const Center(
                    child: Padding(
                      padding: EdgeInsets.all(24),
                      child: Text(
                        'Say hello — coordinate pickup and drop-off here. '
                        'Photos welcome; voice notes are disabled.',
                        textAlign: TextAlign.center,
                        style: TextStyle(color: Colors.grey),
                      ),
                    ),
                  );
                }
                WidgetsBinding.instance.addPostFrameCallback((_) {
                  if (mounted && _scrollCtrl.hasClients) {
                    _scrollCtrl.jumpTo(
                        _scrollCtrl.position.maxScrollExtent);
                  }
                });
                return ListView.builder(
                  controller: _scrollCtrl,
                  padding: const EdgeInsets.all(12),
                  itemCount: messages.length,
                  itemBuilder: (context, i) =>
                      _Bubble(message: messages[i], mine: messages[i].senderId == widget.currentUid, roleLabel: _roleLabel(messages[i].senderRole)),
                );
              },
            ),
          ),
          SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 4, 12, 12),
              child: Row(
                children: [
                  IconButton(
                    key: const Key('trip_chat_photo_button'),
                    tooltip: 'Send photo',
                    icon: _uploadingPhoto
                        ? const SizedBox(
                            width: 20,
                            height: 20,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.photo_outlined),
                    onPressed:
                        (_uploadingPhoto || _sending) ? null : _sendPhoto,
                  ),
                  Expanded(
                    child: TextField(
                      key: const Key('trip_chat_input'),
                      controller: _inputCtrl,
                      minLines: 1,
                      maxLines: 4,
                      textInputAction: TextInputAction.send,
                      onSubmitted: (_) => _send(),
                      decoration: InputDecoration(
                        hintText: 'Message trip chat…',
                        filled: true,
                        fillColor: Colors.grey.shade100,
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(24),
                          borderSide: BorderSide.none,
                        ),
                        contentPadding: const EdgeInsets.symmetric(
                            horizontal: 16, vertical: 10),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  FilledButton(
                    key: const Key('trip_chat_send_button'),
                    style: FilledButton.styleFrom(
                      shape: const CircleBorder(),
                      padding: const EdgeInsets.all(12),
                    ),
                    onPressed: _sending ? null : _send,
                    child: _sending
                        ? const SizedBox(
                            width: 20,
                            height: 20,
                            child: CircularProgressIndicator(
                                strokeWidth: 2, color: Colors.white),
                          )
                        : const Icon(Icons.send),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _Bubble extends StatelessWidget {
  final TripChatMessage message;
  final bool mine;
  final String roleLabel;

  const _Bubble(
      {required this.message, required this.mine, required this.roleLabel});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final bg = mine ? scheme.primary : scheme.surfaceContainerHighest;
    final fg = mine ? scheme.onPrimary : scheme.onSurface;
    return Align(
      alignment: mine ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.only(bottom: 8),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        constraints: BoxConstraints(
            maxWidth: MediaQuery.sizeOf(context).width * 0.75),
        decoration: BoxDecoration(
          color: bg,
          borderRadius: BorderRadius.circular(16),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            if (!mine)
              Text(roleLabel,
                  style: TextStyle(
                      fontSize: 10,
                      fontWeight: FontWeight.bold,
                      color: fg.withValues(alpha: 0.8))),
            if (message.isImage)
              ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: Image.network(
                  message.imageUrl,
                  fit: BoxFit.cover,
                  errorBuilder: (_, _, _) => const Icon(
                      Icons.broken_image_outlined,
                      size: 48,
                      color: Colors.grey),
                ),
              )
            else
              Text(message.text, style: TextStyle(color: fg, fontSize: 14)),
          ],
        ),
      ),
    );
  }
}
