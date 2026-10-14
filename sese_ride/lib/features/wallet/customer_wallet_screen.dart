import 'package:flutter/material.dart';
import 'package:sese_core/sese_core.dart';

import '../payments/payment_service.dart';
import '../payments/top_up_sheet.dart';
import 'p2p_transfer_sheet.dart';
import 'withdrawal_sheet.dart';

import 'sese_coin_header.dart';

/// Wallet & Payments for every user (customers and drivers): live balance,
/// Paystack top-up, and transaction history.
///
/// Balance unit is kobo (integer-exact). All money movement settles
/// server-side; this screen only reads streams and opens Paystack checkout.
class CustomerWalletScreen extends StatefulWidget {
  final AppUser user;

  /// Test seam: inject a fake service in widget tests.
  final PaymentService? payments;

  const CustomerWalletScreen({super.key, required this.user, this.payments});

  @override
  State<CustomerWalletScreen> createState() => _CustomerWalletScreenState();
}

class _CustomerWalletScreenState extends State<CustomerWalletScreen> {
  late final PaymentService _payments =
      widget.payments ?? PaymentService();

  Future<void> _topUp() async {
    final credited =
        await showTopUpSheet(context, _payments, widget.user);
    if (credited && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Wallet credited successfully.')),
      );
    }
  }

  int _currentBalanceKobo = 0;

  Future<void> _withdraw() async {
    if (_currentBalanceKobo <= 0) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Insufficient balance for withdrawal.'),
          backgroundColor: Colors.red,
        ),
      );
      return;
    }
    final request = await WithdrawalSheet.show(
      context,
      user: widget.user,
    );
    if (request == null || !mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          request.isCompleted
              ? '${PaymentService.formatNaira(request.amountKobo / 100.0)} sent to ${request.accountName}.'
              : 'Withdrawal requested for ${PaymentService.formatNaira(request.amountKobo / 100.0)}.',
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
    final displayName =
        widget.user.fullName.isEmpty ? 'Rider' : widget.user.fullName;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Wallet & Payments'),
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
          Card(
            elevation: 2,
            child: Padding(
              padding: const EdgeInsets.all(20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Wallet Balance',
                    style: TextStyle(color: Colors.grey),
                  ),
                  const SizedBox(height: 4),
                  StreamBuilder<int>(
                    stream: _payments
                        .walletBalanceKoboStream(widget.user.uid),
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
                  const SizedBox(height: 8),
                  Text(
                    'Hi $displayName, manage your funds or send money to SeSe users.',
                    style: const TextStyle(fontSize: 12, color: Colors.grey),
                  ),
                  const SizedBox(height: 16),
                  Row(
                    children: [
                      Expanded(
                        child: FilledButton.icon(
                          key: const Key('wallet_top_up_button'),
                          icon: const Icon(Icons.add, size: 18),
                          label: const Text('Add Money'),
                          onPressed: _topUp,
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: OutlinedButton.icon(
                          key: const Key('wallet_withdraw_button'),
                          icon: const Icon(Icons.account_balance_outlined, size: 18),
                          label: const Text('Withdraw'),
                          onPressed: _withdraw,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  SizedBox(
                    width: double.infinity,
                    child: FilledButton.tonalIcon(
                      key: const Key('wallet_p2p_button'),
                      icon: const Icon(Icons.send_to_mobile_outlined, size: 18),
                      label: const Text('Send to User (P2P)'),
                      onPressed: _transfer,
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 12),
          SeseCoinConvertCard(uid: widget.user.uid),
          const SizedBox(height: 12),
          const ListTile(
            leading: Icon(Icons.credit_card_outlined),
            title: Text('Payment methods'),
            subtitle: Text('Pay with card, transfer, or USSD via Paystack'),
          ),
          const SizedBox(height: 12),
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 8),
            child: Text('Transactions',
                style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
          ),
          StreamBuilder<List<WalletTransaction>>(
            stream:
                _payments.walletHistoryStream(widget.user.uid),
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
                  subtitle:
                      Text('Top-ups and earnings will appear here'),
                );
              }
              return Column(
                children: [
                  for (final tx in items)
                    Card(
                      margin: const EdgeInsets.only(bottom: 8),
                      child: ListTile(
                        leading: CircleAvatar(
                          backgroundColor:
                              Colors.green.shade50,
                          child: Icon(
                            tx.type.contains('topup') ||
                                    tx.type.contains('top_up')
                                ? Icons.arrow_downward
                                : Icons.payments_outlined,
                            color: Colors.green.shade800,
                            size: 20,
                          ),
                        ),
                        title: Text(tx.label,
                            style: const TextStyle(
                                fontWeight: FontWeight.w600, fontSize: 14)),
                        subtitle: Text(
                          tx.createdAt != null
                              ? tx.createdAt!.toLocal().toString().split('.').first
                              : tx.paymentReference,
                          style: const TextStyle(fontSize: 12),
                        ),
                        trailing: Text(
                          '+${PaymentService.formatNaira(tx.amountNaira)}',
                          style: TextStyle(
                              fontWeight: FontWeight.bold,
                              color: Colors.green.shade800),
                        ),
                      ),
                    ),
                ],
              );
            },
          ),
        ],
      ),
    );
  }
}

/// Bottom-sheet variant used when the wallet is opened as a sheet instead
/// of a full screen push. Shows the live balance with a shortcut to top up.
Future<void> showWalletBalanceSheet(
  BuildContext context,
  AppUser user, {
  PaymentService? payments,
}) {
  final service = payments ?? PaymentService();
  return showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    builder: (sheetContext) {
      return SafeArea(
        // 16px gutters: balance + CTA span edge-to-edge on phones.
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  const Icon(Icons.account_balance_wallet_outlined),
                  const SizedBox(width: 12),
                  const Expanded(
                    child: Text(
                      'Wallet Balance',
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                  TextButton(
                    onPressed: () {
                      Navigator.of(sheetContext).pop();
                      Navigator.of(context).push(
                        MaterialPageRoute(
                          builder: (_) => CustomerWalletScreen(
                              user: user, payments: service),
                        ),
                      );
                    },
                    child: const Text('View all'),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              StreamBuilder<int>(
                stream: service.walletBalanceKoboStream(user.uid),
                builder: (context, snap) => Text(
                  PaymentService.formatNaira((snap.data ?? 0) / 100.0),
                  style: const TextStyle(
                      fontSize: 32, fontWeight: FontWeight.bold),
                ),
              ),
              const SizedBox(height: 4),
              const Text(
                'Manage balance and payment methods',
                style: TextStyle(color: Colors.grey),
              ),
            ],
          ),
        ),
      );
    },
  );
}
