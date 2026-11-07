import 'package:flutter/material.dart';
import 'package:sese_core/sese_core.dart';

import '../payments/payment_service.dart';
import '../payments/top_up_sheet.dart';
import 'withdrawal_sheet.dart';

/// Single unified Wallet & Earnings screen for drivers: live balance with
/// Top Up (Paystack) and Withdraw/Payout actions, the full chronological
/// credit/debit ledger, and recent hub-processed payouts.
///
/// Balance unit is kobo (integer-exact). All money movement settles
/// server-side; this screen only reads streams and opens checkout.
class WalletScreen extends StatefulWidget {
  final AppUser user;

  /// Test seams.
  final PaymentService? payments;
  final WithdrawalService? withdrawals;

  const WalletScreen({
    super.key,
    required this.user,
    this.payments,
    this.withdrawals,
  });

  @override
  State<WalletScreen> createState() => WalletScreenState();
}

/// Exposed for widget tests (balance stream, ledger rendering).
class WalletScreenState extends State<WalletScreen> {
  late final PaymentService _payments =
      widget.payments ?? PaymentService();

  int _currentBalanceKobo = 0;

  Future<void> _topUp() async {
    final credited =
        await showTopUpSheet(context, _payments, widget.user);
    if (credited && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Wallet credited successfully.')),
      );
    }
  }

  Future<void> _withdraw() async {
    // 1. Check walletBalance. If <= 0, display warning.
    if (_currentBalanceKobo <= 0) {
      ScaffoldMessenger.of(context).removeCurrentSnackBar();
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Insufficient balance for withdrawal.'),
          backgroundColor: Colors.red,
        ),
      );
      return;
    }

    // 2. If walletBalance > 0, open the WithdrawalBottomSheet.
    final request = await WithdrawalSheet.show(
      context,
      user: widget.user,
      service: widget.withdrawals,
    );
    if (request == null || !mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          request.isCompleted
              ? '${PaymentService.formatNaira(request.amountKobo / 100.0)} '
                  'sent to ${request.accountName}.'
              : 'Withdrawal requested. '
                  '${PaymentService.formatNaira(request.amountKobo / 100.0)} '
                  'is on its way to ${request.accountName}.',
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Wallet & Earnings'),
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          _buildBalanceCard(context),
          const SizedBox(height: 12),
          _buildPayoutsCard(),
          const SizedBox(height: 12),
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 8),
            child: Text('Transaction history',
                style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
          ),
          _buildLedger(),
        ],
      ),
    );
  }

  Widget _buildBalanceCard(BuildContext context) {
    return Card(
      elevation: 2,
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Wallet Balance',
                style: TextStyle(color: Colors.grey)),
            const SizedBox(height: 4),
            StreamBuilder<int>(
              stream:
                  _payments.walletBalanceKoboStream(widget.user.uid),
              initialData: LocalCacheService.instance
                      .getInt('wallet_balance_kobo_${widget.user.uid}') ??
                  0,
              builder: (context, snap) {
                final kobo = snap.data ?? 0;
                _currentBalanceKobo = kobo;
                return Text(
                  PaymentService.formatNaira(kobo / 100.0),
                  style: const TextStyle(
                    fontSize: 32,
                    fontWeight: FontWeight.bold,
                  ),
                );
              },
            ),
            const SizedBox(height: 16),
            Row(
              children: [
                Expanded(
                  child: FilledButton.icon(
                    key: const Key('wallet_top_up_button'),
                    icon: const Icon(Icons.add),
                    label: const Text('+ Top Up'),
                    onPressed: _topUp,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: OutlinedButton.icon(
                    key: const Key('wallet_withdraw_button'),
                    icon: const Icon(Icons.account_balance_outlined),
                    label: const Text('Withdraw / Payout'),
                    onPressed: _withdraw,
                    style: OutlinedButton.styleFrom(
                      side: BorderSide.none,
                      backgroundColor: Theme.of(context)
                          .colorScheme
                          .surfaceContainerHighest,
                    ),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildPayoutsCard() {    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Row(
              children: [
                Icon(Icons.payments_outlined),
                SizedBox(width: 8),
                Text('Recent payouts',
                    style: TextStyle(fontWeight: FontWeight.bold)),
              ],
            ),
            const SizedBox(height: 8),
            StreamBuilder<List<DriverPayout>>(
              stream: _payments.driverPayoutsStream(widget.user.uid),
              builder: (context, snap) {
                final items = snap.data ?? const <DriverPayout>[];
                if (items.isEmpty) {
                  return const Text(
                    'No payouts yet — withdrawals are processed by '
                    'operations after you request one.',
                    style: TextStyle(fontSize: 12, color: Colors.grey),
                  );
                }
                return Column(
                  children: [
                    for (final p in items.take(3))
                      ListTile(
                        contentPadding: EdgeInsets.zero,
                        dense: true,
                        leading: const Icon(Icons.check_circle_outline),
                        title: Text(
                          PaymentService.formatNaira(p.amountNaira),
                          style: const TextStyle(
                              fontWeight: FontWeight.w600),
                        ),
                        subtitle: Text(
                          p.createdAt != null
                              ? p.createdAt!
                                  .toLocal()
                                  .toString()
                                  .split('.')
                                  .first
                              : p.reference,
                          style: const TextStyle(fontSize: 12),
                        ),
                        trailing: Chip(
                          side: BorderSide.none,
                          label: Text(
                            p.status.toUpperCase(),
                            style: const TextStyle(fontSize: 11),
                          ),
                          visualDensity: VisualDensity.compact,
                        ),
                      ),
                  ],
                );
              },
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildLedger() {
    return StreamBuilder<List<WalletTransaction>>(
      stream: _payments.walletHistoryStream(widget.user.uid, limit: 50),
      builder: (context, snap) {
        if (snap.connectionState == ConnectionState.waiting && !snap.hasData) {
          return const SeseListSkeleton(itemCount: 4);
        }
        final items = snap.data ?? const <WalletTransaction>[];
        if (items.isEmpty) {
          return const ListTile(
            leading: Icon(Icons.receipt_long_outlined),
            title: Text('No transactions yet'),
            subtitle: Text('Top-ups and trip earnings will appear here'),
          );
        }
        return Column(
          children: [
            for (final tx in items) _LedgerRow(tx: tx),
          ],
        );
      },
    );
  }
}

class _LedgerRow extends StatelessWidget {  final WalletTransaction tx;

  const _LedgerRow({required this.tx});

  @override
  Widget build(BuildContext context) {
    final credit = tx.isCredit;
    final color = credit ? Colors.green.shade800 : Colors.red.shade800;
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: ListTile(
        leading: CircleAvatar(
          backgroundColor:
              credit ? Colors.green.shade50 : Colors.red.shade50,
          child: Icon(
            credit ? Icons.arrow_downward : Icons.arrow_upward,
            color: color,
            size: 20,
          ),
        ),
        title: Text(tx.displayLabel(driverView: true),
            style:
                const TextStyle(fontWeight: FontWeight.w600, fontSize: 14)),
        subtitle: Text(
          tx.createdAt != null
              ? tx.createdAt!.toLocal().toString().split('.').first
              : tx.paymentReference,
          style: const TextStyle(fontSize: 12),
        ),
        trailing: Text(
          tx.signedAmount,
          style: TextStyle(fontWeight: FontWeight.bold, color: color),
        ),
      ),
    );
  }
}
