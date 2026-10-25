import 'package:flutter/material.dart';
import 'package:sese_core/sese_core.dart';

import '../payments/payment_service.dart';
import '../payments/top_up_sheet.dart';
import 'p2p_transfer_sheet.dart';
import 'transaction_pin_prompt.dart';
import 'withdrawal_sheet.dart';

import 'sese_coin_header.dart';

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

  Future<void> _transfer() async {
    final name = await P2pTransferSheet.show(context, user: widget.user);
    if (name == null || !mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('Sent. $name has been credited.')),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Wallet & Earnings'),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 16),
            child: Center(child: SeseCoinHeader(uid: widget.user.uid)),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          _buildBalanceCard(context),
          const SizedBox(height: 12),
          _SplitInvitesCard(userId: widget.user.uid),
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
              builder: (context, snap) {
                final kobo = snap.data ?? 0;
                _currentBalanceKobo = kobo;
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      PaymentService.formatNaira(kobo / 100.0),
                      style: const TextStyle(
                        fontSize: 32,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(height: 2),
                    MultiCurrencyDisplay.fromKobo(
                      amountKobo: kobo,
                      targetCurrencyCode: 'USD',
                      baseStyle: TextStyle(
                        fontSize: 14,
                        color: Colors.grey.shade700,
                        fontWeight: FontWeight.w500,
                      ),
                      inline: false,
                    ),
                  ],
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
            const SizedBox(height: 12),
            SizedBox(
              width: double.infinity,
              child: TextButton.icon(
                key: const Key('wallet_p2p_button'),
                icon: const Icon(Icons.send_to_mobile_outlined, size: 18),
                label: const Text('Send to a SeSe user'),
                onPressed: _transfer,
              ),
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
        if (snap.connectionState == ConnectionState.waiting) {
          return const Center(
              child: Padding(
            padding: EdgeInsets.all(24),
            child: CircularProgressIndicator(),
          ));
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


/// Pending split-payment invites addressed to this user.
///
/// Streams the user's unanswered part rows; Accept/Decline calls
/// `respondSplitPayment`. When the user's acceptance completes the set, the
/// card settles inline via `settleSplitPayment` (idempotent — safe to
/// retry). Renders nothing when empty.
class _SplitInvitesCard extends StatefulWidget {
  final String userId;

  const _SplitInvitesCard({required this.userId});

  @override
  State<_SplitInvitesCard> createState() => _SplitInvitesCardState();
}

class _SplitInvitesCardState extends State<_SplitInvitesCard> {
  final SplitService _service = const SplitService();
  final Set<String> _busy = {};

  Future<void> _respond(String splitId, bool accept) async {
    if (_busy.contains(splitId)) return;
    setState(() => _busy.add(splitId));
    try {
      // The last acceptance flips the intent to `ready` — settle inline so
      // money never hangs waiting for someone to trigger it. Settlement is
      // idempotent server-side, so a retry after a timeout is safe. The
      // execution run is authorized by the settler's transaction PIN.
      final ready = await _service.respond(splitId: splitId, accept: accept);
      if (ready) {
        if (!mounted) return;
        final transactionPin = await TransactionPinPrompt.collectPin(
          context,
          uid: widget.userId,
        );
        if (transactionPin == null || transactionPin.isEmpty) {
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(
                content: Text(
                    'Split is ready — settle it from your invites when ready.'),
              ),
            );
          }
          return;
        }
        await _service.settle(
            splitId: splitId, transactionPin: transactionPin);
      }
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(accept
              ? (ready
                  ? 'Split settled — every share moved.'
                  : 'Share accepted. The split settles once everyone accepts.')
              : 'Split declined.'),
        ),
      );
    } on SplitException catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(e.message)),
      );
    } finally {
      if (mounted) setState(() => _busy.remove(splitId));
    }
  }

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<List<Map<String, dynamic>>>(
      stream: _service.incomingInvitesStream(widget.userId),
      builder: (context, snap) {
        final invites = snap.data ?? const <Map<String, dynamic>>[];
        if (invites.isEmpty) return const SizedBox.shrink();
        return Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Row(
                  children: [
                    Icon(Icons.group_add_outlined),
                    SizedBox(width: 8),
                    Text('Split fare invites',
                        style: TextStyle(fontWeight: FontWeight.bold)),
                  ],
                ),
                const SizedBox(height: 8),
                for (final inv in invites)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    // LayoutBuilder stacks the actions below the amount on
                    // narrow phones so the share text keeps word-wrap instead
                    // of squeezing beside two buttons.
                    child: LayoutBuilder(
                      builder: (context, constraints) {
                        final amount = Text(
                          'Your share: ${PaymentService.formatNaira(((inv['shareKobo'] as num?)?.toInt() ?? 0) / 100.0)}',
                          style:
                              const TextStyle(fontWeight: FontWeight.w600),
                          softWrap: true,
                        );
                        final actions = Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            TextButton(
                              key: Key(
                                  'split_decline_${inv['splitId']}'),
                              onPressed: _busy
                                      .contains(inv['splitId'])
                                  ? null
                                  : () => _respond(
                                      inv['splitId'] as String, false),
                              style: TextButton.styleFrom(
                                visualDensity: VisualDensity.compact,
                              ),
                              child: const Text('Decline', softWrap: false),
                            ),
                            const SizedBox(width: 4),
                            FilledButton(
                              key: Key(
                                  'split_accept_${inv['splitId']}'),
                              onPressed: _busy
                                      .contains(inv['splitId'])
                                  ? null
                                  : () => _respond(
                                      inv['splitId'] as String, true),
                              style: FilledButton.styleFrom(
                                visualDensity: VisualDensity.compact,
                              ),
                              child: const Text('Accept', softWrap: false),
                            ),
                          ],
                        );
                        if (constraints.maxWidth < 380) {
                          return Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              amount,
                              const SizedBox(height: 6),
                              Align(
                                alignment: Alignment.centerRight,
                                child: actions,
                              ),
                            ],
                          );
                        }
                        return Row(
                          children: [
                            Expanded(child: amount),
                            const SizedBox(width: 8),
                            Flexible(child: actions),
                          ],
                        );
                      },
                    ),
                  ),
                const Text(
                  'Accepting agrees to your share. No money moves until '
                  'settlement.',
                  style: TextStyle(fontSize: 11, color: Colors.grey),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}
