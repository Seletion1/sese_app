import 'package:flutter/material.dart';
import 'package:sese_core/sese_core.dart';

import '../payments/payment_service.dart';
import '../payments/top_up_sheet.dart';

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

  @override
  Widget build(BuildContext context) {
    final displayName =
        widget.user.fullName.isEmpty ? 'Rider' : widget.user.fullName;
    return Scaffold(
      appBar: AppBar(title: const Text('Wallet & Payments')),
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
                      return Text(
                        PaymentService.formatNaira(kobo / 100.0),
                        style: const TextStyle(
                          fontSize: 32,
                          fontWeight: FontWeight.bold,
                        ),
                      );
                    },
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'Hi $displayName, top up your wallet for faster checkout.',
                    style: const TextStyle(fontSize: 12, color: Colors.grey),
                  ),
                  const SizedBox(height: 16),
                  SizedBox(
                    width: double.infinity,
                    child: FilledButton.icon(
                      key: const Key('wallet_top_up_button'),
                      icon: const Icon(Icons.add),
                      label: const Text('Top Up'),
                      onPressed: _topUp,
                    ),
                  ),
                ],
              ),
            ),
          ),
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
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
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
