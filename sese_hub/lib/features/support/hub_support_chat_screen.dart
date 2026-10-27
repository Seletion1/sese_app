import 'dart:async';

import 'package:audioplayers/audioplayers.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:sese_core/sese_core.dart';

import '../auth/hub_session_guard.dart';

/// Admin Live Escalation Hub for sese_hub.
///
/// Features:
/// 1. Support Request Queue:
///    - Live stream watching `support_chats` where `status == 'pending_agent'`.
///    - Renders incoming tickets in a real-time queue.
/// 2. First-Come-First-Served Claim System:
///    - When an admin agent taps "Claim Chat", a Firestore transaction runs:
///      - Verifies the ticket is still pending
///      - Sets `assignedAgentId = currentAdminUid`
///      - Updates `status = 'agent_connected'`
///    - Immediately opens the live chat thread between user and admin.
/// 3. Live Chat Thread:
///    - Streams `support_chats/{chatId}/messages`.
///    - Shows user/AI/agent messages with distinct styling.
///    - Allows admin to send messages (`senderType = 'agent'`).
/// 4. Session Closure:
///    - "Resolve & Close Chat" button sets `status = 'resolved'`.
///    - Locks input on both ends and archives the session.
class HubSupportChatScreen extends StatefulWidget {
  final FirebaseFirestore? firestore;
  final FirebaseAuth? auth;

  const HubSupportChatScreen({
    super.key,
    this.firestore,
    this.auth,
  });

  @override
  State<HubSupportChatScreen> createState() => _HubSupportChatScreenState();
}

class _HubSupportChatScreenState extends State<HubSupportChatScreen>
    with SingleTickerProviderStateMixin {
  late TabController _tabController;
  final _inputCtrl = TextEditingController();
  final _scrollCtrl = ScrollController();

  String? _selectedChatId;
  int _seenMessageCount = 0;
  bool _isClaiming = false;
  bool _isSending = false;
  bool _isResolving = false;

  FirebaseFirestore get _db {
    return widget.firestore ?? FirebaseFirestore.instance;
  }

  String get _currentAdminUid {
    final auth = widget.auth ?? FirebaseAuth.instance;
    return auth.currentUser?.uid ?? 'hub_admin';
  }

  String get _currentAdminName {
    final auth = widget.auth ?? FirebaseAuth.instance;
    return auth.currentUser?.displayName ??
        auth.currentUser?.email ??
        'Support Agent';
  }

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 2, vsync: this);
    // Force-refresh the ID token BEFORE the support WatchStreams open.
    ensureFreshHubIdToken();
  }

  @override
  void dispose() {
    _tabController.dispose();
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
  // Data Streams
  // ---------------------------------------------------------------------------

  /// Stream of pending chats awaiting a human agent.
  Stream<QuerySnapshot<Map<String, dynamic>>> _pendingQueueStream() {
    try {
      return _db
          .collection('support_chats')
          .where('status', isEqualTo: 'pending_agent')
          .snapshots();
    } catch (_) {
      return const Stream.empty();
    }
  }

  /// Stream of active or claimed chats (agent_connected or resolved).
  Stream<QuerySnapshot<Map<String, dynamic>>> _activeChatsStream() {
    try {
      return _db
          .collection('support_chats')
          .where('status', whereIn: ['agent_connected', 'resolved'])
          .snapshots();
    } catch (_) {
      return const Stream.empty();
    }
  }

  /// Stream of messages for the selected chat.
  Stream<QuerySnapshot<Map<String, dynamic>>> _messagesStream(String chatId) {
    try {
      return _db
          .collection('support_chats')
          .doc(chatId)
          .collection('messages')
          .orderBy('timestamp')
          .snapshots();
    } catch (_) {
      return const Stream.empty();
    }
  }

  /// Live document stream for selected chat metadata (to observe status transitions).
  Stream<DocumentSnapshot<Map<String, dynamic>>> _chatDocStream(String chatId) {
    try {
      return _db.collection('support_chats').doc(chatId).snapshots();
    } catch (_) {
      return const Stream.empty();
    }
  }

  // ---------------------------------------------------------------------------
  // Actions: Claim, Send, Resolve
  // ---------------------------------------------------------------------------

  /// First-come-first-served claim system via Firestore transaction.
  /// Atomic "Claim & Join" lock: the transaction verifies BOTH that the
  /// chat is still `pending_agent` AND that no agent is assigned yet, so
  /// two agents tapping the same millisecond cannot both join.
  Future<void> _claimChat(String chatId, {required bool isMobile}) async {
    if (_isClaiming) return;
    setState(() => _isClaiming = true);

    final chatRef = _db.collection('support_chats').doc(chatId);
    final adminUid = _currentAdminUid;
    final adminName = _currentAdminName;

    try {
      await _db.runTransaction((tx) async {
        final snap = await tx.get(chatRef);
        if (!snap.exists) {
          throw Exception('Chat session no longer exists.');
        }
        final data = snap.data()!;
        final currentStatus = data['status'] as String?;
        final assigned = (data['assignedAgentId'] ?? '').toString();

        if (currentStatus != 'pending_agent' || assigned.isNotEmpty) {
          throw Exception('This chat was already claimed by another agent.');
        }

        tx.update(chatRef, {
          'assignedAgentId': adminUid,
          'status': 'agent_connected',
          'updatedAt': FieldValue.serverTimestamp(),
          'lastMessage': '$adminName joined the chat.',
        });

        // Add system/agent greeting message to the subcollection
        final msgRef = chatRef.collection('messages').doc();
        tx.set(msgRef, {
          'senderId': adminUid,
          'senderType': 'agent',
          'text':
              'Hello! I am $adminName from SeSe Support. How can I help you today?',
          'timestamp': FieldValue.serverTimestamp(),
        });
      });

      if (!mounted) return;
      _openChatDetail(chatId, isMobile: isMobile);

      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Chat claimed successfully! Live thread opened.'),
          backgroundColor: Colors.green,
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Claim failed: ${e.toString().replaceAll('Exception: ', '')}'),
          backgroundColor: Colors.red,
        ),
      );
    } finally {
      if (mounted) setState(() => _isClaiming = false);
    }
  }

  void _openChatDetail(String chatId, {required bool isMobile}) {
    setState(() {
      _selectedChatId = chatId;
      _seenMessageCount = 0;
    });

    if (isMobile) {
      Navigator.of(context).push(
        MaterialPageRoute(
          builder: (ctx) => Scaffold(
            appBar: AppBar(
              title: const Text('Live Support Chat'),
            ),
            body: _buildLiveChatPane(chatId, isMobile: true),
          ),
        ),
      );
    }
  }

  /// Sends a reply as admin agent.
  Future<void> _sendMessage(String chatId) async {
    final text = _inputCtrl.text.trim();
    if (text.isEmpty || _isSending) return;

    setState(() => _isSending = true);
    _inputCtrl.clear();

    final adminUid = _currentAdminUid;
    final chatRef = _db.collection('support_chats').doc(chatId);

    try {
      final batch = _db.batch();
      final msgRef = chatRef.collection('messages').doc();

      batch.set(msgRef, {
        'senderId': adminUid,
        'senderType': 'agent',
        'type': 'text',
        'text': text,
        'timestamp': FieldValue.serverTimestamp(),
      });

      batch.update(chatRef, {
        'lastMessage': text,
        'updatedAt': FieldValue.serverTimestamp(),
      });

      await batch.commit();
      _scrollToEnd();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Failed to send message: $e')),
      );
    } finally {
      if (mounted) setState(() => _isSending = false);
    }
  }

  /// Sends a photo as admin agent.
  ///
  /// Uploads via the shared [SupportMediaService] (same path/MIME policy as
  /// the user app), then writes a `type: 'image'` message. A failed write
  /// deletes the orphaned upload. Images only — audio types are rejected by
  /// the Firestore rules on every chat.
  Future<void> _sendImage(String chatId, String userId) async {
    if (_isSending) return;
    final media = const SupportMediaService();
    final picked = await media.pickPhoto();
    if (!mounted) return;
    if (picked == null || picked.path.isEmpty) {
      // No-op unless the denial was permanent (cancel/plain-denial return
      // silently — the OS already dialogued).
      await MediaPermissionService.promptIfPermanentlyDenied(context);
      return;
    }

    setState(() => _isSending = true);
    final storagePath = SupportMediaService.pathFor(userId, 'agent.jpg');

    String url;
    try {
      url = await media.upload(file: picked, storagePath: storagePath);
    } on SupportMediaException catch (e) {
      if (!mounted) return;
      setState(() => _isSending = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(e.message)),
      );
      return;
    }

    try {
      final chatRef = _db.collection('support_chats').doc(chatId);
      final batch = _db.batch();
      batch.set(chatRef.collection('messages').doc(), {
        'senderId': _currentAdminUid,
        'senderType': 'agent',
        'type': 'image',
        'text': _inputCtrl.text.trim(),
        'imageUrl': url,
        'timestamp': FieldValue.serverTimestamp(),
      });
      batch.update(chatRef, {
        'lastMessage': '📷 Photo',
        'updatedAt': FieldValue.serverTimestamp(),
      });
      await batch.commit();
      _inputCtrl.clear();
      _scrollToEnd();
    } catch (_) {
      await media.deleteQuietly(storagePath);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Could not send that photo.')),
      );
    } finally {
      if (mounted) setState(() => _isSending = false);
    }
  }

  /// Resolves and archives the chat session.
  Future<void> _resolveAndCloseChat(String chatId) async {
    if (_isResolving) return;

    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Resolve & Close Chat?'),
        content: const Text(
          'This will mark the session as resolved and lock inputs for both you and the user.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Colors.red.shade700),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Resolve & Close'),
          ),
        ],
      ),
    );

    if (confirm != true || !mounted) return;

    setState(() => _isResolving = true);
    final chatRef = _db.collection('support_chats').doc(chatId);
    final adminUid = _currentAdminUid;

    try {
      final batch = _db.batch();
      final msgRef = chatRef.collection('messages').doc();

      batch.set(msgRef, {
        'senderId': adminUid,
        'senderType': 'agent',
        'text': 'This support session has been resolved and closed. Thank you for choosing SeSe!',
        'timestamp': FieldValue.serverTimestamp(),
      });

      batch.update(chatRef, {
        'status': 'resolved',
        'updatedAt': FieldValue.serverTimestamp(),
        'lastMessage': 'Chat resolved and closed.',
      });

      await batch.commit();

      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Session resolved and closed.'),
          backgroundColor: Colors.blueGrey,
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Failed to resolve chat: $e')),
      );
    } finally {
      if (mounted) setState(() => _isResolving = false);
    }
  }

  // ---------------------------------------------------------------------------
  // Build Methods
  // ---------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final isMobile = MediaQuery.of(context).size.width < 768;

    if (isMobile) {
      return Scaffold(
        appBar: AppBar(
          title: const Text('Support Desk & Live Escalation'),
        ),
        body: _buildTabsView(isMobile: true),
      );
    }

    return Scaffold(
      appBar: AppBar(
        title: const Text('Support Desk & Live Escalation'),
      ),
      body: Row(
        children: [
          // Left Sidebar: Queue & Active Chats
          SizedBox(
            width: 360,
            child: _buildTabsView(isMobile: false),
          ),
          // Right Main Area: Live Chat Thread
          Expanded(
            child: _selectedChatId == null
                ? const Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.forum_outlined, size: 64, color: Colors.grey),
                        SizedBox(height: 16),
                        Text(
                          'Select a chat or claim a pending request to begin',
                          style: TextStyle(fontSize: 16, color: Colors.grey),
                        ),
                      ],
                    ),
                  )
                : _buildLiveChatPane(_selectedChatId!, isMobile: false),
          ),
        ],
      ),
    );
  }

  Widget _buildTabsView({required bool isMobile}) {
    return Column(
      children: [
        TabBar(
          controller: _tabController,
          tabs: [
            Tab(
              child: StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
                stream: _pendingQueueStream(),
                builder: (context, snap) {
                  // Badge stays quiet on session errors — the queue tab
                  // below renders HubSessionExpiredView (single sign-out).
                  if (snap.hasError &&
                      isHubSessionExpiredError(snap.error)) {
                    return const Text('Queue');
                  }
                  final count = snap.data?.docs.length ?? 0;
                  return Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      const Text('Queue'),
                      if (count > 0) ...[
                        const SizedBox(width: 6),
                        Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 6, vertical: 2),
                          decoration: BoxDecoration(
                            color: Colors.red,
                            borderRadius: BorderRadius.circular(10),
                          ),
                          child: Text(
                            '$count',
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 11,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ),
                      ],
                    ],
                  );
                },
              ),
            ),
            const Tab(text: 'Active Chats'),
          ],
        ),
        Expanded(
          child: TabBarView(
            controller: _tabController,
            children: [
              _buildPendingQueueTab(isMobile: isMobile),
              _buildActiveChatsTab(isMobile: isMobile),
            ],
          ),
        ),
      ],
    );
  }

  // ---------------------------------------------------------------------------
  // Pending Queue Tab
  // ---------------------------------------------------------------------------

  Widget _buildPendingQueueTab({required bool isMobile}) {
    return StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
      stream: _pendingQueueStream(),
      builder: (context, snapshot) {
        if (snapshot.hasError &&
            isHubSessionExpiredError(snapshot.error)) {
          return const HubSessionExpiredView(
              contextLabel: 'support queue');
        }
        if (snapshot.connectionState == ConnectionState.waiting) {
          return const Center(child: CircularProgressIndicator());
        }
        final docs = snapshot.data?.docs ?? [];
        // Sort newest updated/created first in memory
        final sortedDocs = List<QueryDocumentSnapshot<Map<String, dynamic>>>.from(docs)
          ..sort((a, b) {
            final aTime = (a.data()['updatedAt'] ?? a.data()['createdAt']) as Timestamp?;
            final bTime = (b.data()['updatedAt'] ?? b.data()['createdAt']) as Timestamp?;
            if (aTime == null || bTime == null) return 0;
            return bTime.compareTo(aTime);
          });

        if (sortedDocs.isEmpty) {
          return const Center(
            child: Padding(
              padding: EdgeInsets.all(24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.check_circle_outline, size: 48, color: Colors.green),
                  SizedBox(height: 12),
                  Text(
                    'Queue is clear',
                    style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
                  ),
                  SizedBox(height: 4),
                  Text(
                    'No incoming escalation requests.',
                    style: TextStyle(color: Colors.grey, fontSize: 13),
                  ),
                ],
              ),
            ),
          );
        }

        return ListView.separated(
          itemCount: sortedDocs.length,
          separatorBuilder: (_, _) => const SizedBox(height: 8),
          itemBuilder: (context, index) {
            final doc = sortedDocs[index];
            final data = doc.data();
            final chatId = doc.id;
            final userName = (data['userName'] ?? 'Customer').toString();
            final userRole = (data['userRole'] ?? 'customer').toString();
            final lastMessage = (data['lastMessage'] ?? '').toString();
            final isSelected = chatId == _selectedChatId;

            return ListTile(
              key: Key('queue_item_$chatId'),
              selected: isSelected,
              selectedTileColor: Theme.of(context).colorScheme.primaryContainer.withValues(alpha: 0.2),
              leading: CircleAvatar(
                backgroundColor: userRole == 'driver'
                    ? Colors.amber.shade700
                    : Colors.blue.shade700,
                child: Icon(
                  userRole == 'driver' ? Icons.directions_car : Icons.person,
                  color: Colors.white,
                  size: 20,
                ),
              ),
              title: Row(
                children: [
                  Expanded(
                    child: Text(
                      userName,
                      style: const TextStyle(fontWeight: FontWeight.bold),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                    decoration: BoxDecoration(
                      color: Colors.orange.shade100,
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: Text(
                      userRole.toUpperCase(),
                      style: TextStyle(
                        fontSize: 10,
                        fontWeight: FontWeight.bold,
                        color: Colors.orange.shade900,
                      ),
                    ),
                  ),
                ],
              ),
              subtitle: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const SizedBox(height: 4),
                  Text(
                    lastMessage.isNotEmpty
                        ? lastMessage
                        : 'Customer requested human agent.',
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 12),
                  ),
                  const SizedBox(height: 8),
                  SizedBox(
                    width: double.infinity,
                    child: FilledButton.icon(
                      key: Key('claim_chat_button_$chatId'),
                      icon: const Icon(Icons.touch_app, size: 16),
                      label: const Text('Claim Chat'),
                      style: FilledButton.styleFrom(
                        padding: const EdgeInsets.symmetric(vertical: 6),
                        visualDensity: VisualDensity.compact,
                      ),
                      onPressed: _isClaiming ? null : () => _claimChat(chatId, isMobile: isMobile),
                    ),
                  ),
                ],
              ),
              onTap: () => _openChatDetail(chatId, isMobile: isMobile),
            );
          },
        );
      },
    );
  }

  // ---------------------------------------------------------------------------
  // Active / Claimed Chats Tab
  // ---------------------------------------------------------------------------

  Widget _buildActiveChatsTab({required bool isMobile}) {
    return StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
      stream: _activeChatsStream(),
      builder: (context, snapshot) {
        if (snapshot.hasError &&
            isHubSessionExpiredError(snapshot.error)) {
          return const HubSessionExpiredView(
              contextLabel: 'active chats');
        }
        if (snapshot.connectionState == ConnectionState.waiting) {
          return const Center(child: CircularProgressIndicator());
        }
        final docs = snapshot.data?.docs ?? [];
        final sortedDocs = List<QueryDocumentSnapshot<Map<String, dynamic>>>.from(docs)
          ..sort((a, b) {
            final aTime = (a.data()['updatedAt'] ?? a.data()['createdAt']) as Timestamp?;
            final bTime = (b.data()['updatedAt'] ?? b.data()['createdAt']) as Timestamp?;
            if (aTime == null || bTime == null) return 0;
            return bTime.compareTo(aTime);
          });

        if (sortedDocs.isEmpty) {
          return const Center(
            child: Text(
              'No active or resolved sessions.',
              style: TextStyle(color: Colors.grey),
            ),
          );
        }

        return ListView.separated(
          itemCount: sortedDocs.length,
          separatorBuilder: (_, _) => const SizedBox(height: 8),
          itemBuilder: (context, index) {
            final doc = sortedDocs[index];
            final data = doc.data();
            final chatId = doc.id;
            final userName = (data['userName'] ?? 'User').toString();
            final userRole = (data['userRole'] ?? 'customer').toString();
            final status = (data['status'] ?? '').toString();
            final lastMessage = (data['lastMessage'] ?? '').toString();
            final isResolved = status == 'resolved';
            final isSelected = chatId == _selectedChatId;

            return ListTile(
              selected: isSelected,
              leading: CircleAvatar(
                backgroundColor: isResolved ? Colors.grey : Colors.green.shade600,
                child: Icon(
                  isResolved ? Icons.archive : Icons.headset_mic,
                  color: Colors.white,
                  size: 20,
                ),
              ),
              title: Row(
                children: [
                  Expanded(
                    child: Text(
                      userName,
                      style: const TextStyle(fontWeight: FontWeight.bold),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                    decoration: BoxDecoration(
                      color: isResolved ? Colors.grey.shade200 : Colors.green.shade100,
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: Text(
                      isResolved ? 'RESOLVED' : 'CONNECTED',
                      style: TextStyle(
                        fontSize: 9,
                        fontWeight: FontWeight.bold,
                        color: isResolved ? Colors.grey.shade700 : Colors.green.shade900,
                      ),
                    ),
                  ),
                ],
              ),
              subtitle: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    '$userRole • $lastMessage',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 12),
                  ),
                  // CSAT stars once the user rates a resolved chat. Driven
                  // by the live doc (ratingStream equivalent), so it appears
                  // here the moment the user submits — no refresh needed.
                  if (isResolved)
                    _CsatStars(rating: (data['csatRating'] as num?)?.toInt()),
                ],
              ),
              onTap: () => _openChatDetail(chatId, isMobile: isMobile),
            );
          },
        );
      },
    );
  }

  // ---------------------------------------------------------------------------
  // Live Chat Pane
  // ---------------------------------------------------------------------------

  Widget _buildLiveChatPane(String chatId, {bool isMobile = false}) {
    return StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
      stream: _chatDocStream(chatId),
      builder: (context, docSnap) {
        if (docSnap.hasError &&
            isHubSessionExpiredError(docSnap.error)) {
          return const HubSessionExpiredView(contextLabel: 'chat thread');
        }
        final data = docSnap.data?.data() ?? {};
        final status = (data['status'] ?? 'pending_agent').toString();
        final userName = (data['userName'] ?? 'Customer').toString();
        final userRole = (data['userRole'] ?? 'customer').toString();
        final isResolved = status == 'resolved';
        final isPending = status == 'pending_agent';
        final isConnected = status == 'agent_connected';

        return Column(
          children: [
            // Chat Header — stacks actions below identity on narrow phones
            // so the name/role text keeps word-wrap instead of squeezing
            // beside Claim/Resolve buttons.
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.surfaceContainerHighest.withValues(alpha: 0.5),
              ),
              child: LayoutBuilder(
                builder: (context, constraints) {
                  final identity = Row(
                    children: [
                      CircleAvatar(
                        child: Icon(
                          userRole == 'driver' ? Icons.directions_car : Icons.person,
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              userName,
                              style: const TextStyle(
                                fontSize: 16,
                                fontWeight: FontWeight.bold,
                              ),
                              softWrap: true,
                            ),
                            Text(
                              'Role: ${userRole.toUpperCase()} | Chat ID: ${chatId.substring(0, chatId.length > 8 ? 8 : chatId.length)}',
                              style: TextStyle(
                                fontSize: 12,
                                color: Theme.of(context).colorScheme.onSurfaceVariant,
                              ),
                              softWrap: true,
                            ),
                          ],
                        ),
                      ),
                    ],
                  );
                  // Status & Action buttons
                  final actions = Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      if (isPending)
                        FilledButton.icon(
                          key: const Key('claim_chat_header_button'),
                          icon: const Icon(Icons.touch_app, size: 16),
                          label: const Text('Claim Chat'),
                          onPressed: _isClaiming ? null : () => _claimChat(chatId, isMobile: false),
                        ),
                      if (isConnected) ...[
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                          decoration: BoxDecoration(
                            color: Colors.green.shade100,
                            borderRadius: BorderRadius.circular(6),
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(Icons.lens, size: 8, color: Colors.green.shade800),
                              const SizedBox(width: 6),
                              Text(
                                'Live Session',
                                style: TextStyle(
                                  fontSize: 12,
                                  fontWeight: FontWeight.bold,
                                  color: Colors.green.shade900,
                                ),
                                softWrap: false,
                              ),
                            ],
                          ),
                        ),
                        FilledButton.icon(
                          key: const Key('resolve_close_chat_button'),
                          icon: const Icon(Icons.check_circle, size: 16),
                          label: const Text('Resolve & Close Chat'),
                          style: FilledButton.styleFrom(
                            backgroundColor: Colors.red.shade700,
                            foregroundColor: Colors.white,
                          ),
                          onPressed: _isResolving ? null : () => _resolveAndCloseChat(chatId),
                        ),
                      ],
                      if (isResolved)
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                          decoration: BoxDecoration(
                            color: Colors.grey.shade200,
                            borderRadius: BorderRadius.circular(6),
                          ),
                          child: const Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(Icons.archive, size: 16, color: Colors.grey),
                              SizedBox(width: 6),
                              Text(
                                'Resolved & Closed',
                                style: TextStyle(
                                  fontSize: 12,
                                  fontWeight: FontWeight.bold,
                                  color: Colors.black87,
                                ),
                                softWrap: false,
                              ),
                            ],
                          ),
                        ),
                    ],
                  );
                  if (constraints.maxWidth < 560) {
                    return Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        identity,
                        const SizedBox(height: 10),
                        actions,
                      ],
                    );
                  }
                  return Row(
                    children: [
                      Expanded(child: identity),
                      const SizedBox(width: 12),
                      Flexible(child: actions),
                    ],
                  );
                },
              ),
            ),

            // Messages List
            Expanded(
              child: StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
                stream: _messagesStream(chatId),
                builder: (context, msgSnap) {
                  if (msgSnap.hasError &&
                      isHubSessionExpiredError(msgSnap.error)) {
                    return const HubSessionExpiredView(
                        contextLabel: 'chat messages');
                  }
                  final docs = msgSnap.data?.docs ?? [];

                  // Incoming message sound notification
                  if (docs.length != _seenMessageCount) {
                    if (_seenMessageCount != 0 && docs.isNotEmpty) {
                      final last = docs.last.data();
                      final senderType = (last['senderType'] ?? '').toString();
                      if (senderType == 'user') {
                        // ignore: discarded_futures
                        AppSoundService.instance.playIncomingMessageSound();
                      }
                    }
                    _seenMessageCount = docs.length;
                    _scrollToEnd();
                  }

                  if (docs.isEmpty) {
                    return const Center(child: Text('No messages yet.'));
                  }

                  return ListView.builder(
                    controller: _scrollCtrl,
                    padding: const EdgeInsets.all(16),
                    itemCount: docs.length,
                    itemBuilder: (context, i) {
                      final m = docs[i].data();
                      final senderType = (m['senderType'] ??
                              (m['sender'] == 'admin' ? 'agent' : 'user'))
                          .toString();
                      final text = (m['text'] ?? '').toString();
                      final imageUrl = (m['imageUrl'] ?? '').toString();
                      final audioUrl = (m['audioUrl'] ?? '').toString();
                      final rawDuration = m['durationSeconds'] ?? m['duration'];
                      final durationSeconds = rawDuration is num
                          ? rawDuration.toInt()
                          : (int.tryParse(rawDuration?.toString() ?? '') ?? 0);
                      final type = (m['type'] ?? '').toString();
                      final isAudio = type == 'audio' || audioUrl.isNotEmpty;
                      final isAgent = senderType == 'agent';
                      final isAi = senderType == 'ai' || senderType == 'ai_assistant';

                      return Align(
                        alignment: isAgent
                            ? Alignment.centerRight
                            : Alignment.centerLeft,
                        child: Container(
                          margin: const EdgeInsets.symmetric(vertical: 4),
                          padding: const EdgeInsets.symmetric(
                              horizontal: 14, vertical: 10),
                          constraints: BoxConstraints(
                            maxWidth: MediaQuery.sizeOf(context).width * 0.55,
                          ),
                          decoration: BoxDecoration(
                            color: isAgent
                                ? Theme.of(context).colorScheme.primary
                                : isAi
                                    ? Theme.of(context).colorScheme.tertiaryContainer
                                    : Theme.of(context).colorScheme.surfaceContainerHighest,
                            borderRadius: BorderRadius.circular(14).copyWith(
                              bottomRight: isAgent ? Radius.zero : null,
                              bottomLeft: isAgent ? null : Radius.zero,
                            ),
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Text(
                                isAgent
                                    ? 'You (Agent)'
                                    : isAi
                                        ? 'SeSe Assistant (AI)'
                                        : userName,
                                style: TextStyle(
                                  fontSize: 10,
                                  fontWeight: FontWeight.bold,
                                  color: isAgent
                                      ? Theme.of(context).colorScheme.onPrimary.withValues(alpha: 0.8)
                                      : isAi
                                          ? Theme.of(context).colorScheme.onTertiaryContainer
                                          : Theme.of(context).colorScheme.primary,
                                ),
                              ),
                              const SizedBox(height: 3),
                              if (imageUrl.isNotEmpty)
                                Padding(
                                  padding:
                                      const EdgeInsets.only(bottom: 6),
                                  child: ClipRRect(
                                    borderRadius: BorderRadius.circular(8),
                                    child: Image.network(
                                      imageUrl,
                                      width: 220,
                                      height: 160,
                                      cacheWidth: 440,
                                      cacheHeight: 320,
                                      fit: BoxFit.cover,
                                      errorBuilder: (_, _, _) =>
                                          const SizedBox(
                                        width: 220,
                                        height: 80,
                                        child: Icon(Icons
                                            .broken_image_outlined),
                                      ),
                                    ),
                                  ),
                                ),
                              if (isAudio && audioUrl.isNotEmpty)
                                Padding(
                                  padding: const EdgeInsets.symmetric(vertical: 4),
                                  child: _HubAudioPlayerBubble(
                                    key: Key('hub_audio_${docs[i].id}'),
                                    audioUrl: audioUrl,
                                    durationSeconds: durationSeconds,
                                    isAgent: isAgent,
                                  ),
                                ),
                              if (text.isNotEmpty)
                                Text(
                                  text,
                                  style: TextStyle(
                                    fontSize: 14,
                                    color: isAgent
                                        ? Theme.of(context).colorScheme.onPrimary
                                        : isAi
                                            ? Theme.of(context).colorScheme.onTertiaryContainer
                                            : Theme.of(context).colorScheme.onSurface,
                                  ),
                                ),
                            ],
                          ),
                        ),
                      );
                    },
                  );
                },
              ),
            ),

            // Input Bar
            SafeArea(
              top: false,
              child: Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.surface,
                ),
                child: isResolved
                    ? Container(
                        width: double.infinity,
                        padding: const EdgeInsets.symmetric(vertical: 12),
                        alignment: Alignment.center,
                        decoration: BoxDecoration(
                          color: Theme.of(context).colorScheme.surfaceContainerHighest,
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Text(
                          'This chat session has been resolved and closed.',
                          style: TextStyle(
                            color: Theme.of(context).colorScheme.onSurfaceVariant,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                      )
                    : isPending
                        ? Container(
                            width: double.infinity,
                            padding: const EdgeInsets.symmetric(vertical: 12),
                            alignment: Alignment.center,
                            decoration: BoxDecoration(
                              color: Colors.amber.shade50,
                              borderRadius: BorderRadius.circular(8),
                            ),
                            child: Row(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                Icon(Icons.info_outline, size: 16, color: Colors.amber.shade900),
                                const SizedBox(width: 8),
                                Text(
                                  'Claim this chat to respond to the user.',
                                  style: TextStyle(
                                    color: Colors.amber.shade900,
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                              ],
                            ),
                          )
                        : Row(
                            children: [
                              IconButton(
                                key: const Key('admin_attach_image'),
                                tooltip: 'Send a photo',
                                icon: const Icon(
                                    Icons.add_a_photo_outlined),
                                onPressed: _isSending
                                    ? null
                                    : () => _sendImage(
                                        chatId,
                                        (data['userId'] ?? '').toString()),
                              ),
                              const SizedBox(width: 4),
                              Expanded(
                                child: TextField(
                                  key: const Key('admin_reply_input'),
                                  controller: _inputCtrl,
                                  minLines: 1,
                                  maxLines: 4,
                                  decoration: InputDecoration(
                                    hintText: 'Reply as Support Agent…',
                                    contentPadding: const EdgeInsets.symmetric(
                                      horizontal: 16,
                                      vertical: 10,
                                    ),
                                  ),
                                  onSubmitted: (_) => _sendMessage(chatId),
                                ),
                              ),
                              const SizedBox(width: 8),
                              FilledButton(
                                key: const Key('admin_send_button'),
                                style: FilledButton.styleFrom(
                                  shape: const CircleBorder(),
                                  padding: const EdgeInsets.all(12),
                                ),
                                onPressed: _isSending ? null : () => _sendMessage(chatId),
                                child: _isSending
                                    ? const SizedBox(
                                        width: 20,
                                        height: 20,
                                        child: CircularProgressIndicator(
                                          strokeWidth: 2,
                                          color: Colors.white,
                                        ),
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
  }
}

/// Read-only CSAT stars for a resolved chat row.
///
/// Renders nothing when no rating exists yet (null) — the row simply shows
/// no stars until the user submits, rather than a misleading empty row.
class _CsatStars extends StatelessWidget {
  final int? rating;

  const _CsatStars({required this.rating});

  @override
  Widget build(BuildContext context) {
    final stars = rating;
    if (stars == null || stars < 1 || stars > 5) {
      return const SizedBox.shrink();
    }
    return Padding(
      padding: const EdgeInsets.only(top: 2),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (var i = 1; i <= 5; i++)
            Icon(
              i <= stars ? Icons.star : Icons.star_border,
              size: 14,
              color: Colors.amber.shade700,
            ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Hub Audio Player Bubble
// ---------------------------------------------------------------------------

class _HubAudioPlayerBubble extends StatefulWidget {
  final String audioUrl;
  final int durationSeconds;
  final bool isAgent;

  const _HubAudioPlayerBubble({
    super.key,
    required this.audioUrl,
    required this.durationSeconds,
    required this.isAgent,
  });

  @override
  State<_HubAudioPlayerBubble> createState() => _HubAudioPlayerBubbleState();
}

class _HubAudioPlayerBubbleState extends State<_HubAudioPlayerBubble> {
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
      debugPrint('_HubAudioPlayerBubble: playback error: $e');
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Could not play audio message.')),
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
    final fgColor = widget.isAgent ? scheme.onPrimary : scheme.onSurface;
    final sliderActive = widget.isAgent ? scheme.onPrimary : scheme.primary;
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
            size: 34,
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
                  thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 5),
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
                  style: TextStyle(
                    fontSize: 11,
                    color: fgColor.withValues(alpha: 0.75),
                  ),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}
