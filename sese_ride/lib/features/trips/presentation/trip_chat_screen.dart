import 'package:flutter/material.dart';
import 'package:sese_core/sese_core.dart';

import '../../../core/services/call_service.dart';
import '../services/trip_chat_service.dart';

/// In-app tri-party trip chat (Customer ↔ Recipient relay ↔ Assigned
/// Driver, plus hub support readers).
///
/// Text + photo messages only — there is deliberately no voice-note
/// recorder anywhere (rules reject audio types). Phone numbers shown here
/// obey the viewer's "Hide Phone Number" toggle ([PrivacyMasking]).
///
/// When [receiverPhone] / [receiverName] are supplied the screen renders a
/// two-tab selector so the driver can switch between the Pickup / Booker
/// conversation and the Drop-off Receiver conversation without navigating
/// away. The tab bar is hidden when there is only one contact.
class TripChatScreen extends StatefulWidget {
  final String tripId;
  final String currentUid;

  /// Role of the local sender: `customer` | `driver` (+ `recipient`
  /// relay-posted from the customer app).
  final String senderRole;

  /// Display name + phone of the booker / pickup contact (first tab).
  final String peerName;
  final String peerPhone;
  final bool hidePhones;

  /// Optional drop-off receiver contact shown on the second tab.
  /// When empty the tab bar is suppressed and the screen behaves as before.
  final String receiverName;
  final String receiverPhone;

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
    this.receiverName = '',
    this.receiverPhone = '',
    this.service,
  });

  @override
  State<TripChatScreen> createState() => _TripChatScreenState();
}

/// State for [TripChatScreen].
///
/// When [TripChatScreen.receiverPhone] is non-empty a [TabController] with
/// two tabs is created: tab 0 = Pickup / Booker, tab 1 = Drop-off Receiver.
/// Each tab renders its own scrollable message list against the same
/// [TripChatService] stream (the server stores all messages under the same
/// `tripId` collection regardless of contact role). The tab bar disappears
/// gracefully when no receiver contact is available.
class _TripChatScreenState extends State<TripChatScreen>
    with SingleTickerProviderStateMixin {
  late final TripChatService _chat = widget.service ?? TripChatService();

  /// Non-null only when a second receiver contact was provided.
  TabController? _tabCtrl;

  final _inputCtrl = TextEditingController();
  final _scrollCtrl = ScrollController();
  bool _sending = false;
  bool _uploadingPhoto = false;

  bool get _hasReceiver => widget.receiverPhone.isNotEmpty;

  @override
  void initState() {
    super.initState();
    if (_hasReceiver) {
      _tabCtrl = TabController(length: 2, vsync: this);
    }
  }

  @override
  void dispose() {
    _tabCtrl?.dispose();
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
    // Runtime permission handshake BEFORE the native picker.
    final permission =
        await MediaPermissionService.ensureFor(ImageSource.gallery);
    if (!mounted) return;
    if (permission != MediaPermissionOutcome.granted) {
      await MediaPermissionService.promptIfPermanentlyDenied(context);
      return;
    }
    setState(() => _uploadingPhoto = true);
    try {
      final file = await ImageCompressionService.pickAndCompressImage(
        source: ImageSource.gallery,
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

  /// Builds the scrollable chat message list for [widget.tripId].
  Widget _buildMessageList() {
    return StreamBuilder<List<TripChatMessage>>(
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
            _scrollCtrl.jumpTo(_scrollCtrl.position.maxScrollExtent);
          }
        });
        return ListView.builder(
          controller: _scrollCtrl,
          padding: const EdgeInsets.all(12),
          itemCount: messages.length,
          itemBuilder: (context, i) => _Bubble(
            message: messages[i],
            mine: messages[i].senderId == widget.currentUid,
            roleLabel: _roleLabel(messages[i].senderRole),
          ),
        );
      },
    );
  }

  /// Compose bar with photo and send actions.
  Widget _buildInputBar() {
    return SafeArea(
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
              onPressed: (_uploadingPhoto || _sending) ? null : _sendPhoto,
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
                  fillColor: Theme.of(context).colorScheme.surfaceContainerHighest,
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
    );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final peerSubtitle = widget.peerPhone.isEmpty
        ? 'Customer · Recipient · Driver'
        : PrivacyMasking.display(widget.peerPhone, hide: widget.hidePhones);

    // Two-tab layout when the drop-off receiver is known.
    if (_hasReceiver && _tabCtrl != null) {
      return Scaffold(
        appBar: AppBar(
          title: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('Trip Chat', overflow: TextOverflow.ellipsis),
              const Text('Pickup · Receiver',
                  style:
                      TextStyle(fontSize: 11, fontWeight: FontWeight.w400)),
            ],
          ),
          actions: [
            IconButton(
              icon: const Icon(Icons.call_rounded),
              tooltip: 'Call contact',
              onPressed: () async {
                final activeIndex = _tabCtrl?.index ?? 0;
                final targetPhone = activeIndex == 1 && widget.receiverPhone.isNotEmpty
                    ? widget.receiverPhone
                    : widget.peerPhone;
                final targetName = activeIndex == 1 && widget.receiverName.isNotEmpty
                    ? widget.receiverName
                    : widget.peerName;
                if (AppCallService.isDialable(targetPhone)) {
                  final ok = await AppCallService.makeCall(targetPhone);
                  if (!ok && context.mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('Could not open phone dialer.')),
                    );
                  }
                } else if (context.mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(content: Text('Phone number for $targetName is not available.')),
                  );
                }
              },
            ),
          ],
          bottom: TabBar(
            key: const Key('trip_chat_tab_bar'),
            controller: _tabCtrl,
            tabs: [
              Tab(
                icon: const Icon(Icons.pin_drop_outlined, size: 18),
                text: widget.peerName.isNotEmpty
                    ? widget.peerName
                    : 'Pickup / Booker',
              ),
              Tab(
                icon: const Icon(Icons.place_outlined, size: 18),
                text: widget.receiverName.isNotEmpty
                    ? widget.receiverName
                    : 'Drop-off Receiver',
              ),
            ],
            labelColor: scheme.primary,
            indicatorColor: scheme.primary,
          ),
        ),
        body: Column(
          children: [
            Expanded(
              child: TabBarView(
                key: const Key('trip_chat_tab_view'),
                controller: _tabCtrl,
                children: [
                  // Tab 0 — Pickup / Booker conversation.
                  _buildMessageList(),
                  // Tab 1 — Drop-off Receiver: show an info banner above the
                  // shared chat stream so the driver knows who they are
                  // addressing when the receiver is a different person.
                  Column(
                    children: [
                      Container(
                        key: const Key('receiver_info_banner'),
                        width: double.infinity,
                        padding: const EdgeInsets.symmetric(
                            horizontal: 16, vertical: 8),
                        color: scheme.secondaryContainer.withValues(alpha: 0.6),
                        child: Text(
                          'Drop-off receiver: '
                          '${PrivacyMasking.display(widget.receiverPhone, hide: widget.hidePhones)}',
                          style: TextStyle(
                            fontSize: 12,
                            color: scheme.onSecondaryContainer,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                      ),
                      Expanded(child: _buildMessageList()),
                    ],
                  ),
                ],
              ),
            ),
            _buildInputBar(),
          ],
        ),
      );
    }

    // Single-party layout (no receiver contact) — identical to original.
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
        actions: [
          if (AppCallService.isDialable(widget.peerPhone))
            IconButton(
              icon: const Icon(Icons.call_rounded),
              tooltip: 'Call ${widget.peerName}',
              onPressed: () async {
                final ok = await AppCallService.makeCall(widget.peerPhone);
                if (!ok && context.mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('Could not open phone dialer.')),
                  );
                }
              },
            ),
        ],
      ),
      body: Column(
        children: [
          Expanded(child: _buildMessageList()),
          _buildInputBar(),
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
