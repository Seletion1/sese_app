import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:sese_core/sese_core.dart';

import '../trips/presentation/live_trip_screen.dart';
import '../trips/services/trip_service.dart';

/// Notification types that are **inbox-worthy** (sensitive or actionable).
///
/// Mirrors the server-side `INBOX_TYPES` set in `functions/src/trips.ts`.
/// Only these types are ever written to `users/{uid}/notifications` by the
/// backend; transient trip-status events (e.g. `driver_arrived`) are
/// FCM-push-only and are intentionally excluded from the inbox so that
/// both customer and driver notification bells stay uncluttered.
const Set<String> _kInboxTypes = {
  'delivery_pin_issued',
  'cash_settlement_requested',
  'trip_needs_customer_action',
  'driver_counter_bid',
  'trip_chat_message',
  'broadcast',
  'P2P_TRANSFER_RECEIVED',
  'split_payment_request',
  'support_escalated',
  'support_reply',
};

/// Returns the icon most relevant for [type].
///
/// Covers the full `INBOX_TYPES` set from `functions/src/trips.ts`.
/// Every sensitive notification type gets a distinct visual cue so both
/// customers and drivers can instantly identify the nature of a message
/// without reading the body.  Unrecognised types (those outside
/// [_kInboxTypes]) fall back to a generic bell.
IconData _iconForType(String type) {
  // Guard: unrecognised types outside the allow-list get a plain bell.
  if (!_kInboxTypes.contains(type)) return Icons.notifications_outlined;
  switch (type) {
    case 'delivery_pin_issued':
      return Icons.pin_outlined;
    case 'cash_settlement_requested':
      return Icons.payments_outlined;
    case 'trip_needs_customer_action':
      return Icons.warning_amber_rounded;
    case 'driver_counter_bid':
      return Icons.local_offer_outlined;
    case 'trip_chat_message':
      return Icons.chat_bubble_outline;
    case 'broadcast':
      return Icons.campaign_outlined;
    case 'P2P_TRANSFER_RECEIVED':
      return Icons.account_balance_wallet_outlined;
    case 'split_payment_request':
      return Icons.group_outlined;
    case 'support_escalated':
    case 'support_reply':
      return Icons.support_agent_outlined;
    default:
      return Icons.notifications_outlined;
  }
}

/// Single inbox entry backed by `users/{uid}/notifications/{id}`.
///
/// Written exclusively by backend Cloud Functions for high-value,
/// non-transient event types only (see [_kInboxTypes]). Clients only flip
/// [isRead]. Unknown/missing fields degrade to empty strings — never a throw.
class InboxNotification {
  final String id;
  final String title;
  final String body;
  final String type;
  final String? tripId;
  final String? driverId;
  final String? driverName;
  final String? driverPhoto;
  final double? driverRating;
  final String? offeredFare;
  final String? offeredFareFormatted;
  final String? etaMinutes;
  final String? vehicleModel;
  final String? vehicleColor;
  final String? plateNumber;
  final String? vehicleDetails;
  final bool isRead;
  final DateTime? createdAt;

  const InboxNotification({
    required this.id,
    required this.title,
    required this.body,
    required this.type,
    this.tripId,
    this.driverId,
    this.driverName,
    this.driverPhoto,
    this.driverRating,
    this.offeredFare,
    this.offeredFareFormatted,
    this.etaMinutes,
    this.vehicleModel,
    this.vehicleColor,
    this.plateNumber,
    this.vehicleDetails,
    required this.isRead,
    required this.createdAt,
  });

  /// Parses a numeric value that may be persisted as int, double, string,
  /// or (in legacy docs) a wrapped object — never throws.
  static double? _toDouble(dynamic value) {
    if (value == null) return null;
    if (value is num) return value.toDouble();
    if (value is String) return double.tryParse(value.trim());
    if (value is Map && value['value'] != null) {
      return _toDouble(value['value']);
    }
    return double.tryParse(value.toString());
  }

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
      tripId: data['tripId']?.toString(),
      driverId: data['driverId']?.toString(),
      driverName: data['driverName']?.toString(),
      driverPhoto: data['driverPhoto']?.toString(),
      driverRating: _toDouble(data['driverRating']),
      offeredFare: data['offeredFare']?.toString(),
      offeredFareFormatted: data['offeredFareFormatted']?.toString(),
      etaMinutes: data['etaMinutes']?.toString(),
      vehicleModel: data['vehicleModel']?.toString(),
      vehicleColor: data['vehicleColor']?.toString(),
      plateNumber: data['plateNumber']?.toString(),
      vehicleDetails: data['vehicleDetails']?.toString(),
      isRead: data['isRead'] == true,
      createdAt: at,
    );
  }
}

/// Chronological inbox of sensitive announcements and alerts for one user.
///
/// Source: `users/{userId}/notifications` (newest first). Only types listed
/// in [_kInboxTypes] are ever written here — transient trip-status events
/// like "Driver arrived" are FCM-push-only and never reach this screen.
/// Tapping an item marks it read (`isRead: true`) and opens the full detail.
///
/// Used for **both** customer and driver accounts — the same Firestore
/// subcollection pattern applies to all user roles.
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
            return const SeseListSkeleton(itemCount: 5);
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
                      'Important alerts — PINs, offers, broadcasts, and '
                      'support messages — will appear here.',
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
                    _iconForType(n.type),
                    color: n.isRead ? Colors.grey.shade600 : Colors.black,
                    size: 20,
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
class _NotificationDetailSheet extends StatefulWidget {
  final InboxNotification item;

  const _NotificationDetailSheet({required this.item});

  @override
  State<_NotificationDetailSheet> createState() =>
      _NotificationDetailSheetState();
}

class _NotificationDetailSheetState extends State<_NotificationDetailSheet> {
  bool _busy = false;

  Future<void> _acceptBid() async {
    final tripId = widget.item.tripId;
    final driverId = widget.item.driverId;
    if (tripId == null || driverId == null) return;
    setState(() => _busy = true);
    try {
      await FirestoreTripRepository().acceptBid(tripId, driverId);
      if (mounted) {
        Navigator.of(context).pop();
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Offer accepted! Driver has been dispatched.'),
            backgroundColor: Color(0xFF059669),
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Unable to accept offer right now. Please try again.'),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _rejectBid() async {
    final tripId = widget.item.tripId;
    final driverId = widget.item.driverId;
    if (tripId == null || driverId == null) return;
    setState(() => _busy = true);
    try {
      await FirestoreTripRepository().rejectBid(tripId, driverId);
      if (mounted) {
        Navigator.of(context).pop();
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Offer declined.')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Unable to decline offer right now. Please try again.'),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final item = widget.item;
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
            Row(
              children: [
                CircleAvatar(
                  radius: 18,
                  backgroundColor: AppColors.seseGold.withValues(alpha: 0.15),
                  child: Icon(
                    _iconForType(item.type),
                    color: AppColors.seseGold,
                    size: 18,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    item.title.isEmpty ? 'Notification' : item.title,
                    style: const TextStyle(
                        fontSize: 18, fontWeight: FontWeight.bold),
                  ),
                ),
              ],
            ),
            if (when.isNotEmpty) ...[
              const SizedBox(height: 6),
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
            if (item.type == 'driver_counter_bid' &&
                item.tripId != null &&
                item.driverId != null) ...[
              const SizedBox(height: 16),
              Container(
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  color: Theme.of(context).cardColor,
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(color: Colors.grey.withValues(alpha: 0.2)),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.05),
                      blurRadius: 10,
                      offset: const Offset(0, 4),
                    ),
                  ],
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        UserAvatar(
                          displayName: item.driverName ?? 'Driver',
                          photoUrl: item.driverPhoto,
                          radius: 20,
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                item.driverName ?? 'Driver',
                                style: const TextStyle(
                                  fontWeight: FontWeight.bold,
                                  fontSize: 14,
                                ),
                              ),
                              Row(
                                children: [
                                  if ((item.driverRating ?? 0) > 0) ...[
                                    const Icon(Icons.star,
                                        size: 12, color: Colors.amber),
                                    const SizedBox(width: 2),
                                    Text(
                                      item.driverRating!.toStringAsFixed(1),
                                      style: const TextStyle(
                                          fontSize: 11, color: Colors.grey),
                                    ),
                                    const SizedBox(width: 6),
                                  ],
                                  Text(
                                    '~${item.etaMinutes ?? 5} min away',
                                    style: TextStyle(
                                      fontSize: 11,
                                      fontWeight: FontWeight.w600,
                                      color:
                                          Theme.of(context).colorScheme.primary,
                                    ),
                                  ),
                                ],
                              ),
                            ],
                          ),
                        ),
                        Text(
                          item.offeredFareFormatted ??
                              '₦${item.offeredFare ?? ""}',
                          style: TextStyle(
                            fontSize: 18,
                            fontWeight: FontWeight.bold,
                            color: Theme.of(context).colorScheme.primary,
                          ),
                        ),
                      ],
                    ),
                    if (item.vehicleDetails != null &&
                        item.vehicleDetails!.isNotEmpty) ...[
                      const SizedBox(height: 8),
                      Row(
                        children: [
                          const Icon(Icons.directions_car,
                              size: 14, color: Colors.grey),
                          const SizedBox(width: 4),
                          Expanded(
                            child: Text(
                              item.vehicleDetails!,
                              style: const TextStyle(
                                  fontSize: 12, color: Colors.grey),
                            ),
                          ),
                        ],
                      ),
                    ],
                    const SizedBox(height: 14),
                    Row(
                      children: [
                        Expanded(
                          child: FilledButton.icon(
                            icon: _busy
                                ? const SizedBox(
                                    width: 16,
                                    height: 16,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                      color: Colors.white,
                                    ),
                                  )
                                : const Icon(Icons.check, size: 18),
                            label: const Text('Accept Offer'),
                            style: FilledButton.styleFrom(
                              backgroundColor: Colors.green.shade700,
                              minimumSize: const Size.fromHeight(42),
                            ),
                            onPressed: _busy ? null : _acceptBid,
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: OutlinedButton.icon(
                            icon: const Icon(Icons.close, size: 18),
                            label: const Text('Reject'),
                            style: OutlinedButton.styleFrom(
                              minimumSize: const Size.fromHeight(42),
                            ),
                            onPressed: _busy ? null : _rejectBid,
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 10),
              SizedBox(
                width: double.infinity,
                child: TextButton.icon(
                  icon: const Icon(Icons.map_outlined),
                  label: const Text('View Live Trip on Map'),
                  onPressed: () {
                    Navigator.of(context).pop();
                    Navigator.of(context).push(
                      MaterialPageRoute(
                        builder: (_) => LiveTripScreen(
                          tripId: item.tripId!,
                          repository: FirestoreTripRepository(),
                        ),
                      ),
                    );
                  },
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// Top-right bell with a live unread badge. Pushes [NotificationInboxScreen].
///
/// Reads `users/{uid}/notifications` where `isRead == false`.  The badge
/// hides at zero.  Best-effort in tests/offline (renders a plain bell).
///
/// Used for both customer and driver accounts; the Firestore path is
/// identical for all user roles.
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
