import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';

import '../../dashboard/presentation/hub_module_shell.dart';
import '../../staff/services/hub_access_service.dart';

/// Hub screen showing 1 and 2 star ratings auto-routed by [submitTripRating].
/// Operators can acknowledge/resolve each review with an optional note.
class LowRatingReviewsScreen extends StatelessWidget {
  final String staffEmail;

  const LowRatingReviewsScreen({
    super.key,
    this.staffEmail = '',
  });

  @override
  Widget build(BuildContext context) {
    return HubModuleShell(
      title: 'Low-Rating Reviews',
      sections: [
        HubModuleSection(
          id: secRatingsPending,
          title: 'Low Rating Reviews',
          icon: Icons.star_rate_outlined,
          permission: null, // covered by module-level permRatingReviews
          child: _LowRatingReviewsList(staffEmail: staffEmail),
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// List view — streams all low_rating_reviews, with a Pending/All filter.
// ---------------------------------------------------------------------------

class _LowRatingReviewsList extends StatefulWidget {
  final String staffEmail;

  const _LowRatingReviewsList({required this.staffEmail});

  @override
  State<_LowRatingReviewsList> createState() => _LowRatingReviewsListState();
}

class _LowRatingReviewsListState extends State<_LowRatingReviewsList> {
  bool _pendingOnly = true;

  FirebaseFirestore get _db => FirebaseFirestore.instance;

  Stream<QuerySnapshot<Map<String, dynamic>>> get _stream {
    Query<Map<String, dynamic>> q = _db.collection('low_rating_reviews');
    if (_pendingOnly) {
      return q.where('reviewStatus', isEqualTo: 'pending').snapshots();
    }
    return q.orderBy('createdAt', descending: true).snapshots();
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Column(
      children: [
        // ── Filter chips ──────────────────────────────────────────────────
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
          child: Row(
            children: [
              FilterChip(
                label: const Text('Pending'),
                selected: _pendingOnly,
                onSelected: (v) => setState(() => _pendingOnly = v),
              ),
              const SizedBox(width: 8),
              FilterChip(
                label: const Text('All'),
                selected: !_pendingOnly,
                onSelected: (v) => setState(() => _pendingOnly = !v),
              ),
            ],
          ),
        ),
        // ── Live list ─────────────────────────────────────────────────────
        Expanded(
          child: StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
            stream: _stream,
            builder: (context, snap) {
              if (snap.connectionState == ConnectionState.waiting) {
                return const Center(child: CircularProgressIndicator());
              }
              if (snap.hasError) {
                return Center(
                  child: Text('Error loading reviews: ${snap.error}',
                      style: TextStyle(color: colorScheme.error)),
                );
              }
              final docs = (snap.data?.docs ?? []).toList();
              docs.sort((a, b) {
                final dA = a.data()['createdAt'];
                final dB = b.data()['createdAt'];
                DateTime tA = DateTime.fromMillisecondsSinceEpoch(0);
                DateTime tB = DateTime.fromMillisecondsSinceEpoch(0);
                if (dA is Timestamp) tA = dA.toDate();
                if (dB is Timestamp) tB = dB.toDate();
                return tB.compareTo(tA);
              });
              if (docs.isEmpty) {
                return Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.check_circle_outline,
                          size: 56, color: colorScheme.primary),
                      const SizedBox(height: 12),
                      Text(
                        _pendingOnly
                            ? 'No pending low-rating reviews 🎉'
                            : 'No low-rating reviews found.',
                        style: Theme.of(context).textTheme.bodyLarge,
                      ),
                    ],
                  ),
                );
              }
              return ListView.builder(
                padding: const EdgeInsets.all(12),
                itemCount: docs.length,
                itemBuilder: (context, i) => _ReviewCard(
                  doc: docs[i],
                  staffEmail: widget.staffEmail,
                ),
              );
            },
          ),
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// Individual review card
// ---------------------------------------------------------------------------

class _ReviewCard extends StatelessWidget {
  final QueryDocumentSnapshot<Map<String, dynamic>> doc;
  final String staffEmail;
  const _ReviewCard({required this.doc, required this.staffEmail});

  static String _formatTimestamp(Timestamp ts) {
    final dt = ts.toDate().toLocal();
    const months = [
      'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
      'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
    ];
    final d = dt.day.toString().padLeft(2, '0');
    final m = months[dt.month - 1];
    final h = dt.hour.toString().padLeft(2, '0');
    final min = dt.minute.toString().padLeft(2, '0');
    return '$d $m ${dt.year} $h:$min';
  }

  @override
  Widget build(BuildContext context) {
    final data = doc.data();
    final int rating = (data['rating'] as num?)?.toInt() ?? 0;
    final String comment = (data['comment'] ?? '').toString();
    final String tripId =
        (data['sequentialTripId'] ?? data['tripId'] ?? '').toString();
    final String customerName = (data['customerName'] ?? '').toString();
    final String customerPhone = (data['customerPhone'] ?? '').toString();
    final String driverName = (data['driverName'] ?? '').toString();
    final String driverPhone = (data['driverPhone'] ?? '').toString();
    final String serviceType = (data['serviceType'] ?? '').toString();
    final String tripStatus = (data['tripStatus'] ?? '').toString();
    final bool pinVerified = data['deliveryPinVerified'] == true;
    final bool pinSkipped = data['deliveryPinSkipped'] == true;
    final String reviewStatus =
        (data['reviewStatus'] ?? 'pending').toString();
    final String resolutionNote =
        (data['resolutionNote'] ?? '').toString();
    final String reviewedBy = (data['reviewedBy'] ?? '').toString();
    final List<dynamic> reasons = (data['lowRatingReasons'] as List?) ?? [];
    final dynamic createdRaw = data['createdAt'];
    String createdAt = '';
    try {
      final ts = createdRaw as Timestamp;
      createdAt = _formatTimestamp(ts);
    } catch (_) {}

    final isPending = reviewStatus == 'pending';
    final colorScheme = Theme.of(context).colorScheme;

    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // ── Header row: stars + trip ID + status badge ───────────────
            Row(
              children: [
                _StarBadge(rating: rating),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    'Trip $tripId',
                    style: Theme.of(context)
                        .textTheme
                        .titleSmall
                        ?.copyWith(fontWeight: FontWeight.bold),
                  ),
                ),
                _StatusChip(status: reviewStatus),
              ],
            ),
            const SizedBox(height: 10),
            // ── Customer / Driver ─────────────────────────────────────────
            _InfoRow(icon: Icons.person_outline,
                label: 'Customer', value: '$customerName  $customerPhone'),
            _InfoRow(icon: Icons.drive_eta_outlined,
                label: 'Driver', value: '$driverName  $driverPhone'),
            _InfoRow(icon: Icons.local_taxi_outlined,
                label: 'Service', value: serviceType),
            _InfoRow(icon: Icons.info_outline,
                label: 'Trip Status', value: tripStatus),
            if (serviceType.toLowerCase().contains('delivery') ||
                pinVerified ||
                pinSkipped)
              _InfoRow(
                icon: Icons.pin_outlined,
                label: 'Delivery PIN',
                value: pinVerified
                    ? '✅ Verified'
                    : pinSkipped
                        ? '⚠️ Skipped'
                        : 'Not recorded',
              ),
            if (createdAt.isNotEmpty)
              _InfoRow(icon: Icons.access_time, label: 'Submitted', value: createdAt),
            // ── Low rating reason chips ───────────────────────────────────
            if (reasons.isNotEmpty) ...[
              const SizedBox(height: 8),
              Wrap(
                spacing: 6,
                runSpacing: 4,
                children: reasons
                    .map((r) => Chip(
                          label: Text(r.toString(),
                              style: const TextStyle(fontSize: 11)),
                          padding: EdgeInsets.zero,
                          visualDensity: VisualDensity.compact,
                          backgroundColor:
                              colorScheme.errorContainer.withValues(alpha: 0.5),
                        ))
                    .toList(),
              ),
            ],
            // ── Customer comment ──────────────────────────────────────────
            if (comment.isNotEmpty) ...[
              const SizedBox(height: 8),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: colorScheme.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  '"$comment"',
                  style: Theme.of(context)
                      .textTheme
                      .bodySmall
                      ?.copyWith(fontStyle: FontStyle.italic),
                ),
              ),
            ],
            // ── Resolution info (resolved reviews) ────────────────────────
            if (!isPending && resolutionNote.isNotEmpty) ...[
              const SizedBox(height: 8),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: colorScheme.primaryContainer.withValues(alpha: 0.4),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Resolved by $reviewedBy',
                        style: Theme.of(context)
                            .textTheme
                            .labelSmall
                            ?.copyWith(fontWeight: FontWeight.bold)),
                    const SizedBox(height: 4),
                    Text(resolutionNote,
                        style: Theme.of(context).textTheme.bodySmall),
                  ],
                ),
              ),
            ],
            // ── Acknowledge button (pending only) ─────────────────────────
            if (isPending) ...[
              const SizedBox(height: 12),
              Align(
                alignment: Alignment.centerRight,
                child: FilledButton.tonal(
                  onPressed: () =>
                      _showResolveDialog(context, doc.id, data),
                  child: const Text('Acknowledge / Resolve'),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Future<void> _showResolveDialog(
    BuildContext context,
    String reviewId,
    Map<String, dynamic> data,
  ) async {
    final noteCtrl = TextEditingController();
    final reviewerEmail = staffEmail;
    bool saving = false;

    await showDialog<void>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setS) => AlertDialog(
          title: const Text('Resolve Review'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text(
                'Add an optional resolution note, then mark this review resolved.',
              ),
              const SizedBox(height: 12),
              TextField(
                controller: noteCtrl,
                maxLines: 3,
                decoration: const InputDecoration(
                  labelText: 'Resolution note (optional)',
                  border: OutlineInputBorder(),
                ),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: saving ? null : () => Navigator.pop(ctx),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: saving
                  ? null
                  : () async {
                      setS(() => saving = true);
                      try {
                        await FirebaseFirestore.instance
                            .collection('low_rating_reviews')
                            .doc(reviewId)
                            .update({
                          'reviewStatus': 'resolved',
                          'resolutionNote': noteCtrl.text.trim(),
                          'reviewedBy': reviewerEmail,
                          'updatedAt': FieldValue.serverTimestamp(),
                        });
                        if (ctx.mounted) Navigator.pop(ctx);
                      } catch (e) {
                        setS(() => saving = false);
                        if (ctx.mounted) {
                          ScaffoldMessenger.of(ctx).showSnackBar(
                            SnackBar(content: Text('Error: $e')),
                          );
                        }
                      }
                    },
              child: saving
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2))
                  : const Text('Mark Resolved'),
            ),
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Helper widgets
// ---------------------------------------------------------------------------

class _StarBadge extends StatelessWidget {
  final int rating;
  const _StarBadge({required this.rating});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: Colors.red.shade50,
        border: Border.all(color: Colors.red.shade200),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.star_rounded, size: 16, color: Colors.red.shade600),
          const SizedBox(width: 3),
          Text(
            '$rating',
            style: TextStyle(
                fontWeight: FontWeight.bold,
                fontSize: 13,
                color: Colors.red.shade700),
          ),
        ],
      ),
    );
  }
}

class _StatusChip extends StatelessWidget {
  final String status;
  const _StatusChip({required this.status});

  @override
  Widget build(BuildContext context) {
    final isPending = status == 'pending';
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: isPending
            ? Colors.orange.shade50
            : Colors.green.shade50,
        border: Border.all(
            color: isPending ? Colors.orange.shade200 : Colors.green.shade200),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Text(
        isPending ? 'Pending' : 'Resolved',
        style: TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w600,
          color: isPending ? Colors.orange.shade800 : Colors.green.shade800,
        ),
      ),
    );
  }
}

class _InfoRow extends StatelessWidget {
  final IconData icon;
  final String label;
  final String value;

  const _InfoRow({
    required this.icon,
    required this.label,
    required this.value,
  });

  @override
  Widget build(BuildContext context) {
    if (value.trim().isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon,
              size: 15,
              color: Theme.of(context).colorScheme.onSurfaceVariant),
          const SizedBox(width: 6),
          Text('$label: ',
              style: Theme.of(context)
                  .textTheme
                  .bodySmall
                  ?.copyWith(fontWeight: FontWeight.w600)),
          Expanded(
            child: Text(value,
                style: Theme.of(context).textTheme.bodySmall),
          ),
        ],
      ),
    );
  }
}
