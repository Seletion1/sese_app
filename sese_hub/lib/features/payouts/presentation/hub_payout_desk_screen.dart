import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';

/// Payout Desk: read-only audit view over `payout_requests`.
///
/// Withdrawals are fully automated (`processWalletWithdrawal` debits,
/// Paystack transfers, webhook settles, failures auto-refund). This desk
/// exists for oversight and support follow-up: which payouts are pending,
/// which completed, which failed or were refunded — and to whom.
///
/// Deliberately action-free: there is no "approve" or "retry" button because
/// there is no manual step in the flow. A failed payout already refunded the
/// user; the user simply requests again. Adding hub-initiated money movement
/// would need its own callable + audit design, not a button on a list.
class HubPayoutDeskScreen extends StatefulWidget {
  const HubPayoutDeskScreen({super.key});

  @override
  State<HubPayoutDeskScreen> createState() => _HubPayoutDeskScreenState();
}

class _HubPayoutDeskScreenState extends State<HubPayoutDeskScreen> {
  String _filter = 'all';

  FirebaseFirestore? get _db {
    try {
      return FirebaseFirestore.instance;
    } catch (_) {
      // Widget tests run with no Firebase app: degrade to an empty desk
      // rather than throwing during build (repo-wide convention).
      return null;
    }
  }

  Stream<QuerySnapshot<Map<String, dynamic>>> _stream() {
    final db = _db;
    if (db == null) {
      return const Stream.empty();
    }
    var q = db
        .collection('payout_requests')
        .orderBy('createdAt', descending: true)
        .limit(100);
    if (_filter != 'all') {
      q = q.where('status', isEqualTo: _filter);
    }
    return q.snapshots();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Payout Desk')),
      body: Column(
        children: [
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.fromLTRB(12, 12, 12, 4),
            child: Row(
              children: [
                for (final f in const [
                  'all',
                  'pending',
                  'completed',
                  'failed',
                  'refunded'
                ])
                  Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: ChoiceChip(
                      key: Key('payout_filter_$f'),
                      label: Text(f[0].toUpperCase() + f.substring(1)),
                      selected: _filter == f,
                      onSelected: (_) => setState(() => _filter = f),
                    ),
                  ),
              ],
            ),
          ),
          Expanded(
            child: StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
              stream: _stream(),
              builder: (context, snap) {
                if (snap.connectionState == ConnectionState.waiting) {
                  return const Center(child: CircularProgressIndicator());
                }
                if (snap.hasError) {
                  return Center(
                    child: Padding(
                      padding: const EdgeInsets.all(24),
                      child: Text(
                        'Could not load payouts (${(snap.error as Object).toString().split(':').first}). '
                        'The processPayouts scope is required.',
                        textAlign: TextAlign.center,
                      ),
                    ),
                  );
                }
                final docs = snap.data?.docs ?? [];
                if (docs.isEmpty) {
                  return const Center(
                    child: Text(
                      'No payout requests in this state.',
                      style: TextStyle(color: Colors.grey),
                    ),
                  );
                }
                return ListView.separated(
                  padding: const EdgeInsets.all(12),
                  itemCount: docs.length,
                  separatorBuilder: (_, _) => const SizedBox(height: 8),
                  itemBuilder: (context, i) =>
                      _PayoutRow(data: docs[i].data()),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

class _PayoutRow extends StatelessWidget {
  final Map<String, dynamic> data;

  const _PayoutRow({required this.data});

  @override
  Widget build(BuildContext context) {
    final status = (data['status'] ?? 'pending').toString();
    final amountKobo = (data['amountKobo'] as num?)?.toInt() ?? 0;
    final accountName = (data['accountName'] ?? '').toString();
    final bankName = (data['bankName'] ?? data['bankCode'] ?? '').toString();
    final accountNumber = (data['accountNumber'] ?? '').toString();
    final userId = (data['userId'] ?? '').toString();
    final failure = (data['failureReason'] ?? '').toString();
    final created = data['createdAt'];
    DateTime? when;
    try {
      when = (created as dynamic)?.toDate() as DateTime?;
    } catch (_) {}

    final Color chipColor;
    switch (status) {
      case 'completed':
        chipColor = Colors.green.shade700;
        break;
      case 'failed':
      case 'refunded':
        chipColor = Colors.red.shade700;
        break;
      default:
        chipColor = Colors.orange.shade800;
    }

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    '₦${(amountKobo / 100).toStringAsFixed(2)}',
                    style: const TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
                Chip(
                  side: BorderSide.none,
                  backgroundColor: chipColor.withValues(alpha: 0.12),
                  label: Text(
                    status.toUpperCase(),
                    style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.bold,
                      color: chipColor,
                    ),
                  ),
                  visualDensity: VisualDensity.compact,
                ),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              '$accountName • $bankName $accountNumber',
              style: const TextStyle(fontSize: 13),
            ),
            Text(
              'User: ${userId.length > 12 ? '${userId.substring(0, 12)}…' : userId}'
              '${when != null ? ' • ${when.toLocal().toString().split('.').first}' : ''}',
              style: const TextStyle(fontSize: 12, color: Colors.grey),
            ),
            if (failure.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(
                  failure,
                  style: TextStyle(
                    fontSize: 12,
                    color: Colors.red.shade800,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
