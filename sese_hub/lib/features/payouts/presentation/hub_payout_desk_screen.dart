import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:sese_core/sese_core.dart';

/// Payout Desk: Weekly Payout Queue + read-only audit view over `payout_requests`.
///
/// Tab 1: Weekly Payout Queue (users with balance >= `minPayoutThreshold`).
/// Tab 2: Audit Log (automated Paystack `payout_requests` requests).
class HubPayoutDeskScreen extends StatefulWidget {
  const HubPayoutDeskScreen({super.key});

  @override
  State<HubPayoutDeskScreen> createState() => _HubPayoutDeskScreenState();
}

class _HubPayoutDeskScreenState extends State<HubPayoutDeskScreen>
    with SingleTickerProviderStateMixin {
  String _filter = 'all';
  late TabController _tabController;
  final PayoutQueueService _queueService = const PayoutQueueService();
  final FinancialConfigService _finService = const FinancialConfigService();
  double _minPayoutThreshold = 20000.0;
  bool _loadingFinConfig = true;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 2, vsync: this);
    _loadFinancialConfig();
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  Future<void> _loadFinancialConfig() async {
    final cfg = await _finService.getConfig();
    if (!mounted) return;
    setState(() {
      _minPayoutThreshold = cfg.minPayoutThreshold;
      _loadingFinConfig = false;
    });
  }

  FirebaseFirestore? get _db {
    try {
      return FirebaseFirestore.instance;
    } catch (_) {
      // Widget tests run with no Firebase app: degrade to an empty desk
      // rather than throwing during build (repo-wide convention).
      return null;
    }
  }

  Stream<QuerySnapshot<Map<String, dynamic>>> _auditStream() {
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
      appBar: AppBar(
        title: const Text('Payout Desk'),
        bottom: TabBar(
          controller: _tabController,
          tabs: const [
            Tab(icon: Icon(Icons.queue_outlined), text: 'Weekly Payout Queue'),
            Tab(icon: Icon(Icons.history_outlined), text: 'Audit Log'),
          ],
        ),
      ),
      body: TabBarView(
        controller: _tabController,
        children: [
          _buildWeeklyQueueTab(),
          _buildAuditLogTab(),
        ],
      ),
    );
  }

  Widget _buildWeeklyQueueTab() {
    if (_loadingFinConfig) {
      return const Center(child: CircularProgressIndicator());
    }
    return StreamBuilder<List<PayoutQueueEntry>>(
      stream: _queueService.queueStream(minPayoutThreshold: _minPayoutThreshold),
      builder: (context, snap) {
        if (snap.connectionState == ConnectionState.waiting) {
          return const Center(child: CircularProgressIndicator());
        }
        if (snap.hasError) {
          return Center(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Text(
                'Could not load payout queue: ${snap.error}',
                textAlign: TextAlign.center,
              ),
            ),
          );
        }
        final entries = snap.data ?? [];
        if (entries.isEmpty) {
          return Center(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Text(
                'No users currently eligible for weekly payout (min ₦${_minPayoutThreshold.toStringAsFixed(0)}).',
                style: const TextStyle(color: Colors.grey),
                textAlign: TextAlign.center,
              ),
            ),
          );
        }
        return ListView.separated(
          padding: const EdgeInsets.all(12),
          itemCount: entries.length,
          separatorBuilder: (_, _) => const SizedBox(height: 8),
          itemBuilder: (context, i) {
            final messenger = ScaffoldMessenger.of(context);
            final entry = entries[i];
            return _QueueRow(
              entry: entry,
              onMarkProcessed: () async {
                try {
                  await _queueService.markPayout(
                    userId: entry.userId,
                    status: 'disbursed',
                  );
                  if (!mounted) return;
                  messenger.showSnackBar(
                    SnackBar(
                      content: Text('Payout for ${entry.fullName} marked processed.'),
                      backgroundColor: Colors.green.shade800,
                    ),
                  );
                } catch (e) {
                  if (!mounted) return;
                  messenger.showSnackBar(
                    SnackBar(content: Text('Failed to update payout status: $e')),
                  );
                }
              },
            );
          },
        );
      },
    );
  }

  Widget _buildAuditLogTab() {
    return Column(
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
            stream: _auditStream(),
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
    );
  }
}

class _QueueRow extends StatelessWidget {
  final PayoutQueueEntry entry;
  final VoidCallback onMarkProcessed;

  const _QueueRow({
    required this.entry,
    required this.onMarkProcessed,
  });

  @override
  Widget build(BuildContext context) {
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
                    entry.fullName,
                    style: const TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
                Text(
                  '₦${entry.balance.toStringAsFixed(2)}',
                  style: TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.bold,
                    color: Colors.green.shade800,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 6),
            Text(
              'Bank: ${entry.bankName.isNotEmpty ? entry.bankName : "Not specified"}',
              style: const TextStyle(fontSize: 13),
            ),
            Text(
              'Account Number: ${entry.accountNumber.isNotEmpty ? entry.accountNumber : "N/A"}',
              style: const TextStyle(fontSize: 13),
            ),
            Text(
              'Verified Name: ${entry.accountName.isNotEmpty ? entry.accountName : "Unverified"}',
              style: const TextStyle(fontSize: 13, color: Colors.black87),
            ),
            const SizedBox(height: 10),
            // Wrap (not Row+Spacer) so the status chip and action never
            // squeeze each other on narrow phones — they flow to two lines.
            Wrap(
              spacing: 8,
              runSpacing: 8,
              alignment: WrapAlignment.spaceBetween,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                Chip(
                  label: Text(
                    entry.payoutStatus.toUpperCase(),
                    style: const TextStyle(fontSize: 10, fontWeight: FontWeight.bold),
                    softWrap: false,
                  ),
                  backgroundColor: entry.isPaid
                      ? Colors.green.shade100
                      : Colors.orange.shade100,
                  visualDensity: VisualDensity.compact,
                ),
                if (!entry.isPaid)
                  ElevatedButton.icon(
                    onPressed: onMarkProcessed,
                    icon: const Icon(Icons.check_circle_outline, size: 16),
                    label: const Text(
                      'Mark Processed',
                      softWrap: false,
                    ),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.green.shade800,
                      foregroundColor: Colors.white,
                    ),
                  ),
              ],
            ),
          ],
        ),
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
