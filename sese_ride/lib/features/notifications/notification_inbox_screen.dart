import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:sese_core/sese_core.dart';

/// Single inbox entry backed by `users/{uid}/notifications/{id}`.
///
/// Written exclusively by backend Cloud Functions (`sendTargetedBroadcast`,
/// support escalations); clients only flip [isRead]. Unknown/missing fields
/// degrade to empty strings — never a throw.
class InboxNotification {
  final String id;
  final String title;
  final String body;
  final String type;
  final bool isRead;
  final DateTime? createdAt;

  const InboxNotification({
    required this.id,
    required this.title,
    required this.body,
    required this.type,
    required this.isRead,
    required this.createdAt,
  });

  factory InboxNotification.fromDoc(
      DocumentSnapshot<Map<String, dynamic>> doc) {
    final data = doc.data() ?? {};
    DateTime? at;
    final raw = data['createdAt'];
    try {
      if (raw is Timestamp) at = raw.toDate();
      if (raw is String) at = DateTime.tryParse(raw);
    } catch (_) {}
    return InboxNotification(
      id: doc.id,
      title: (data['title'] ?? '').toString(),
      body: (data['body'] ?? '').toString(),
      type: (data['type'] ?? 'broadcast').toString(),
      isRead: data['isRead'] == true,
      createdAt: at,
    );
  }
}

/// Chronological inbox of announcements and alerts for one user.
///
/// Source: `users/{userId}/notifications` (newest first). Tapping an item
/// marks it read (`isRead: true`) and opens the full message detail sheet.
class NotificationInboxScreen extends StatelessWidget {
  final String userId;

  const NotificationInboxScreen({super.key, required this.userId});

  CollectionReference<Map<String, dynamic>>? _colOrNull() {
    if (userId.isEmpty) return null;
    try {
      return FirebaseFirestore.instance
          .collection('users')
          .doc(userId)
          .collection('notifications');
    } catch (_) {
      return null;
    }
  }

  Future<void> _markRead(BuildContext context, InboxNotification n) async {
    final col = _colOrNull();
    if (n.isRead || col == null) return;
    try {
      await col.doc(n.id).update({'isRead': true});
    } catch (e) {
      debugPrint('NotificationInbox mark-read failed: $e');
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Could not mark as read.')),
        );
      }
    }
  }

  void _openDetail(BuildContext context, InboxNotification n) {
    // ignore: discarded_futures
    _markRead(context, n);
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      useSafeArea: true,
      builder: (ctx) => _NotificationDetailSheet(item: n),
    );
  }

  @override
  Widget build(BuildContext context) {
    final col = _colOrNull();
    if (col == null) {
      return const Scaffold(
        body: Center(child: Text('Sign in to view notifications.')),
      );
    }
    return Scaffold(
      appBar: const SeseAppBar(title: 'Notifications'),
      body: StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
        stream: col.orderBy('createdAt', descending: true).snapshots(),
        builder: (context, snap) {
          if (snap.hasError) {
            return const Center(
              child: Text('Could not load notifications. Try again.'),
            );
          }
          if (snap.connectionState == ConnectionState.waiting &&
              !snap.hasData) {
            return const Center(child: CircularProgressIndicator());
          }
          final items = (snap.data?.docs ?? [])
              .map(InboxNotification.fromDoc)
              .toList();
          if (items.isEmpty) {
            return const Center(
              child: Padding(
                padding: EdgeInsets.all(32),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.notifications_none_outlined, size: 56),
                    SizedBox(height: 12),
                    Text(
                      'No notifications yet',
                      style:
                          TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                    ),
                    SizedBox(height: 4),
                    Text(
                      'Announcements and trip alerts will appear here.',
                      textAlign: TextAlign.center,
                    ),
                  ],
                ),
              ),
            );
          }
          return ListView.separated(
            padding: const EdgeInsets.symmetric(vertical: 8),
            itemCount: items.length,
            separatorBuilder: (_, _) => const Divider(height: 1),
            itemBuilder: (context, i) {
              final n = items[i];
              return ListTile(
                key: Key('inbox_item_${n.id}'),
                leading: CircleAvatar(
                  backgroundColor: n.isRead
                      ? Colors.grey.shade300
                      : AppColors.seseGold,
                  child: Icon(
                    n.type == 'broadcast'
                        ? Icons.campaign_outlined
                        : Icons.notifications_outlined,
                    color: n.isRead ? Colors.grey.shade600 : Colors.black,
                  ),
                ),
                title: Text(
                  n.title.isEmpty ? '(No title)' : n.title,
                  style: TextStyle(
                    fontWeight:
                        n.isRead ? FontWeight.normal : FontWeight.bold,
                  ),
                ),
                subtitle: Text(
                  n.body,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
                trailing: n.isRead
                    ? null
                    : Container(
                        width: 10,
                        height: 10,
                        decoration: const BoxDecoration(
                          color: AppColors.seseGold,
                          shape: BoxShape.circle,
                        ),
                      ),
                onTap: () => _openDetail(context, n),
              );
            },
          );
        },
      ),
    );
  }
}

/// Full message detail: title, timestamp, and the complete body text.
class _NotificationDetailSheet extends StatelessWidget {
  final InboxNotification item;

  const _NotificationDetailSheet({required this.item});

  @override
  Widget build(BuildContext context) {
    final at = item.createdAt;
    final when = at == null
        ? ''
        : '${at.day}/${at.month}/${at.year} ${at.hour.toString().padLeft(2, '0')}:${at.minute.toString().padLeft(2, '0')}';
    // 16px gutters: detail text + actions span edge-to-edge on phones.
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              item.title.isEmpty ? 'Notification' : item.title,
              style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
            ),
            if (when.isNotEmpty) ...[
              const SizedBox(height: 4),
              Text(when, style: const TextStyle(color: Colors.grey)),
            ],
            const SizedBox(height: 12),
            Flexible(
              child: SingleChildScrollView(
                child: Text(
                  item.body.isEmpty ? 'No details provided.' : item.body,
                  style: const TextStyle(fontSize: 15),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Top-right bell with a live unread badge. Pushes [NotificationInboxScreen].
///
/// Reads `users/{uid}/notifications` where `isRead == false`; the badge
/// hides at zero. Best-effort in tests/offline (renders a plain bell).
class NotificationBellButton extends StatelessWidget {
  final String uid;

  const NotificationBellButton({super.key, required this.uid});

  void _open(BuildContext context) {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => NotificationInboxScreen(userId: uid),
      ),
    );
  }

  /// Null when Firebase isn't initialized (tests/offline) — renders a
  /// plain bell instead of throwing `[core/no-app]`.
  Stream<QuerySnapshot<Map<String, dynamic>>>? _unreadStream() {
    if (uid.isEmpty) return null;
    try {
      return FirebaseFirestore.instance
          .collection('users')
          .doc(uid)
          .collection('notifications')
          .where('isRead', isEqualTo: false)
          .snapshots();
    } catch (_) {
      return null;
    }
  }

  @override
  Widget build(BuildContext context) {
    final bell = IconButton(
      key: const Key('notification_bell'),
      icon: const Icon(Icons.notifications_outlined),
      tooltip: 'Notifications',
      onPressed: () => _open(context),
    );
    return StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
      stream: _unreadStream(),
      builder: (context, snap) {
        final unread = snap.hasData ? snap.data!.docs.length : 0;
        if (unread <= 0) return bell;
        return Badge(
          label: Text(unread > 99 ? '99+' : '$unread'),
          child: bell,
        );
      },
    );
  }
}
