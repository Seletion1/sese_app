import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:flutter/material.dart';
import 'package:sese_core/sese_core.dart';
import '../../dashboard/services/hub_pending_counts_service.dart';
import '../../../widgets/hub_badge.dart';

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
  bool _processingBatch = false;

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

  Future<void> _approveWeeklyPayout(
      BuildContext context, PayoutQueueEntry entry) async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      final res = await FirebaseFunctions.instance
          .httpsCallable('approveWeeklyPayout')
          .call({'userId': entry.userId});
      final data = Map<String, dynamic>.from(res.data as Map? ?? {});
      if (!mounted) return;
      messenger.showSnackBar(
        SnackBar(
          content: Text(
              'Weekly payout approved for ${entry.fullName}! Ref: ${data['transferReference'] ?? 'Completed'}'),
          backgroundColor: Colors.green.shade800,
        ),
      );
    } catch (e) {
      if (!mounted) return;
      debugPrint('approveWeeklyPayout error: $e');
      messenger.showSnackBar(
        SnackBar(
          content: Text('Weekly payout failed: $e'),
          backgroundColor: Colors.red.shade800,
        ),
      );
    }
  }

  Future<void> _approveAllWeeklyPayouts(
      BuildContext context, List<PayoutQueueEntry> entries) async {
    final messenger = ScaffoldMessenger.of(context);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Approve All Weekly Payouts?'),
        content: Text(
          'This will trigger fee-free Paystack transfers for all ${entries.length} eligible users in the weekly queue.\n\nAre you sure you want to proceed?',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            style: ElevatedButton.styleFrom(backgroundColor: Colors.green.shade800),
            child: const Text('Confirm & Approve All'),
          ),
        ],
      ),
    );

    if (confirmed != true || !mounted) return;

    setState(() => _processingBatch = true);
    try {
      final res = await FirebaseFunctions.instance
          .httpsCallable('approveAllWeeklyPayouts')
          .call({});
      final data = Map<String, dynamic>.from(res.data as Map? ?? {});
      final processed = data['processed'] ?? 0;
      if (!mounted) return;
      messenger.showSnackBar(
        SnackBar(
          content: Text('Batch weekly payouts processed: $processed users.'),
          backgroundColor: Colors.green.shade800,
        ),
      );
    } catch (e) {
      if (!mounted) return;
      messenger.showSnackBar(
        SnackBar(
          content: Text('Batch weekly payout error: $e'),
          backgroundColor: Colors.red.shade800,
        ),
      );
    } finally {
      if (mounted) setState(() => _processingBatch = false);
    }
  }

  void _showUserLedgerModal(
    BuildContext context, {
    required String userId,
    required String fullName,
    required String bankName,
    required String accountNumber,
    required String accountName,
  }) {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      showDragHandle: true,
      builder: (_) => _UserLedgerModal(
        userId: userId,
        fullName: fullName,
        bankName: bankName,
        accountNumber: accountNumber,
        accountName: accountName,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Payout Desk'),
        bottom: TabBar(
          controller: _tabController,
          tabs: [
            const Tab(icon: Icon(Icons.queue_outlined), text: 'Weekly Payout Queue'),
            Tab(
              icon: StreamBuilder<int>(
                stream: HubPendingCountsService().pendingPayoutsCountStream,
                builder: (context, snap) {
                  final count = snap.data ?? 0;
                  if (count <= 0) return const Icon(Icons.history_outlined);
                  return Badge(
                    label: Text(count > 99 ? '99+' : '$count'),
                    backgroundColor: Colors.red.shade700,
                    child: const Icon(Icons.history_outlined),
                  );
                },
              ),
              text: 'Audit Log',
            ),
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
      return const SeseListSkeleton(itemCount: 4);
    }
    return StreamBuilder<List<PayoutQueueEntry>>(
      stream: _queueService.queueStream(minPayoutThreshold: _minPayoutThreshold),
      builder: (context, snap) {
        if (snap.connectionState == ConnectionState.waiting && !snap.hasData) {
          return const SeseListSkeleton(itemCount: 4);
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

        final totalBalance = entries.fold<double>(0, (acc, e) => acc + e.balance);

        return ListView(
          padding: const EdgeInsets.all(12),
          children: [
            Card(
              elevation: 2,
              color: Colors.green.shade50,
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        const Icon(Icons.account_balance_wallet, color: Colors.green),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            'Weekly Staged Payouts (${entries.length} Users)',
                            style: const TextStyle(
                              fontWeight: FontWeight.bold,
                              fontSize: 16,
                            ),
                          ),
                        ),
                        Text(
                          '₦${totalBalance.toStringAsFixed(2)}',
                          style: TextStyle(
                            fontSize: 18,
                            fontWeight: FontWeight.bold,
                            color: Colors.green.shade900,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    const Text(
                      'Fee-Free Weekly Settlement • Click "Approve Weekly Payout" to execute 100% full payout via Paystack.',
                      style: TextStyle(fontSize: 12, color: Colors.black87),
                    ),
                    const SizedBox(height: 12),
                    ElevatedButton.icon(
                      key: const Key('approve_all_weekly_button'),
                      onPressed: _processingBatch
                          ? null
                          : () => _approveAllWeeklyPayouts(context, entries),
                      icon: _processingBatch
                          ? const SizedBox(
                              width: 16,
                              height: 16,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                color: Colors.white,
                              ),
                            )
                          : const Icon(Icons.playlist_add_check, size: 18),
                      label: Text(
                        _processingBatch
                            ? 'Processing Batch...'
                            : 'Approve All Weekly Payouts',
                      ),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.green.shade800,
                        foregroundColor: Colors.white,
                        minimumSize: const Size.fromHeight(42),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 12),
            for (final entry in entries) ...[
              _QueueRow(
                entry: entry,
                onApprove: () => _approveWeeklyPayout(context, entry),
                onViewLedger: () => _showUserLedgerModal(
                  context,
                  userId: entry.userId,
                  fullName: entry.fullName,
                  bankName: entry.bankName,
                  accountNumber: entry.accountNumber,
                  accountName: entry.accountName,
                ),
              ),
              const SizedBox(height: 8),
            ],
          ],
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
                    label: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(f[0].toUpperCase() + f.substring(1)),
                        if (f == 'pending')
                          HubCountBadge.stream(
                            stream: HubPendingCountsService().pendingPayoutsCountStream,
                            padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                            fontSize: 10,
                          ),
                      ],
                    ),
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
              if (snap.connectionState == ConnectionState.waiting && !snap.hasData) {
                return const SeseListSkeleton(itemCount: 4);
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
                itemBuilder: (context, i) {
                  final data = docs[i].data();
                  final userId = (data['userId'] ?? '').toString();
                  final accountName = (data['accountName'] ?? '').toString();
                  final bankName = (data['bankName'] ?? data['bankCode'] ?? '').toString();
                  final accountNumber = (data['accountNumber'] ?? '').toString();
                  return _PayoutRow(
                    data: data,
                    onViewLedger: () => _showUserLedgerModal(
                      context,
                      userId: userId,
                      fullName: accountName.isNotEmpty ? accountName : userId,
                      bankName: bankName,
                      accountNumber: accountNumber,
                      accountName: accountName,
                    ),
                  );
                },
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
  final VoidCallback onApprove;
  final VoidCallback onViewLedger;

  const _QueueRow({
    required this.entry,
    required this.onApprove,
    required this.onViewLedger,
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
            Wrap(
              spacing: 8,
              runSpacing: 8,
              alignment: WrapAlignment.spaceBetween,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                OutlinedButton.icon(
                  onPressed: onViewLedger,
                  icon: const Icon(Icons.receipt_long_outlined, size: 16),
                  label: const Text('View Ledger & Profile', style: TextStyle(fontSize: 12)),
                ),
                ElevatedButton.icon(
                  onPressed: onApprove,
                  icon: const Icon(Icons.check_circle_outline, size: 16),
                  label: const Text('Approve Weekly Payout', softWrap: false),
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
  final VoidCallback onViewLedger;

  const _PayoutRow({
    required this.data,
    required this.onViewLedger,
  });

  @override
  Widget build(BuildContext context) {
    final status = (data['status'] ?? 'pending').toString();
    final requestedKobo = safeNum(data['requestedAmountKobo'] ?? data['amountKobo'])?.toInt() ?? 0;
    final feeKobo = safeNum(data['feeKobo'])?.toInt() ?? 0;
    final netKobo = safeNum(data['netAmountKobo'] ?? data['amountKobo'])?.toInt() ?? requestedKobo;
    final payoutType = (data['payoutType'] ?? 'instant_adhoc').toString();

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
      child: InkWell(
        onTap: onViewLedger,
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Net Paid: ₦${(netKobo / 100).toStringAsFixed(2)}',
                          style: const TextStyle(
                            fontSize: 17,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        Text(
                          payoutType == 'weekly_payout'
                              ? 'Weekly Fee-Free Payout (₦${(requestedKobo / 100).toStringAsFixed(2)})'
                              : 'Instant Ad-Hoc (Requested: ₦${(requestedKobo / 100).toStringAsFixed(2)} • Fee: ₦${(feeKobo / 100).toStringAsFixed(2)})',
                          style: TextStyle(fontSize: 11, color: Colors.grey.shade700),
                        ),
                      ],
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
              const SizedBox(height: 6),
              Text(
                '$accountName • $bankName $accountNumber',
                style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w500),
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
      ),
    );
  }
}

/// Detailed User Ledger & Audit Modal displaying full money-in/out transaction history.
class _UserLedgerModal extends StatelessWidget {
  final String userId;
  final String fullName;
  final String bankName;
  final String accountNumber;
  final String accountName;

  const _UserLedgerModal({
    required this.userId,
    required this.fullName,
    required this.bankName,
    required this.accountNumber,
    required this.accountName,
  });

  @override
  Widget build(BuildContext context) {
    final db = FirebaseFirestore.instance;
    return Scaffold(
      appBar: AppBar(
        title: Text('Ledger History — $fullName'),
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Card(
            color: Theme.of(context).colorScheme.surfaceContainerHighest,
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('User ID: $userId', style: const TextStyle(fontSize: 12, color: Colors.grey)),
                  const SizedBox(height: 4),
                  Text('Bank: ${bankName.isNotEmpty ? bankName : "N/A"}', style: const TextStyle(fontWeight: FontWeight.w600)),
                  Text('Account: ${accountNumber.isNotEmpty ? accountNumber : "N/A"}', style: const TextStyle(fontWeight: FontWeight.w600)),
                  Text('Verified Name: ${accountName.isNotEmpty ? accountName : "N/A"}', style: const TextStyle(fontWeight: FontWeight.bold, color: Colors.green)),
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),
          const Text('Money-In / Out Ledger History', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
          const SizedBox(height: 8),
          StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
            stream: db
                .collection('wallets')
                .doc(userId)
                .collection('transactions')
                .orderBy('createdAt', descending: true)
                .limit(50)
                .snapshots(),
            builder: (context, snap) {
              if (snap.connectionState == ConnectionState.waiting && !snap.hasData) {
                return const SeseListSkeleton(itemCount: 4);
              }
              final docs = snap.data?.docs ?? [];
              if (docs.isEmpty) {
                return const ListTile(
                  leading: Icon(Icons.receipt_long_outlined),
                  title: Text('No ledger transactions recorded.'),
                );
              }
              return Column(
                children: [
                  for (final d in docs) _LedgerTile(data: d.data()),
                ],
              );
            },
          ),
        ],
      ),
    );
  }
}

class _LedgerTile extends StatelessWidget {
  final Map<String, dynamic> data;

  const _LedgerTile({required this.data});

  @override
  Widget build(BuildContext context) {
    final type = (data['type'] ?? 'transaction').toString();
    final amountKobo = safeNum(data['amountKobo'] ?? data['amount'])?.toInt() ?? 0;
    final status = (data['status'] ?? 'completed').toString();
    final isCredit = type.contains('topup') || type.contains('credit') || type.contains('settlement');
    final color = isCredit ? Colors.green.shade800 : Colors.red.shade800;
    final created = data['createdAt'];
    DateTime? when;
    try {
      when = (created as dynamic)?.toDate() as DateTime?;
    } catch (_) {}

    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: ListTile(
        leading: CircleAvatar(
          backgroundColor: isCredit ? Colors.green.shade50 : Colors.red.shade50,
          child: Icon(
            isCredit ? Icons.arrow_downward : Icons.arrow_upward,
            color: color,
            size: 20,
          ),
        ),
        title: Text(type.replaceAll('_', ' ').toUpperCase(), style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
        subtitle: Text(
          when != null ? when.toLocal().toString().split('.').first : 'Status: $status',
          style: const TextStyle(fontSize: 11, color: Colors.grey),
        ),
        trailing: Text(
          '${isCredit ? '+' : '-'}₦${(amountKobo / 100).toStringAsFixed(2)}',
          style: TextStyle(fontWeight: FontWeight.bold, color: color, fontSize: 15),
        ),
      ),
    );
  }
}
