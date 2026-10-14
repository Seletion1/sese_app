import 'package:flutter/material.dart';
import 'package:sese_core/sese_core.dart';

/// Wallet-guard bottom sheet shown when a driver is below the dynamic
/// `minWalletBalanceToOnline` threshold.
Future<void> showInsufficientWalletSheet({
  required BuildContext context,
  required double requiredMinimum,
  required VoidCallback onTopUp,
}) {
  final amount = '₦${requiredMinimum.toStringAsFixed(2)}';
  return showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    shape: const RoundedRectangleBorder(
      borderRadius:
          BorderRadius.vertical(top: Radius.circular(20)),
    ),
    builder: (ctx) => SafeArea(
      // 16px gutters so the CTA spans edge-to-edge on phones.
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Icon(Icons.account_balance_wallet_outlined,
                size: 40, color: Color(0xFFEAA200)),
            const SizedBox(height: 12),
            const Text(
              'Insufficient Wallet Balance',
              textAlign: TextAlign.center,
              style:
                  TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 8),
            Text(
              'A minimum wallet balance of $amount is required to '
              'receive orders. Please top up your wallet to continue.',
              textAlign: TextAlign.center,
              style:
                  const TextStyle(fontSize: 14, color: Colors.grey),
            ),
            const SizedBox(height: 16),
            FilledButton.icon(
              key: const Key('guard_top_up_cta'),
              icon: const Icon(Icons.add),
              label: const Text('Top Up Wallet'),
              style: FilledButton.styleFrom(
                  minimumSize: const Size.fromHeight(50)),
              onPressed: () {
                Navigator.of(ctx).pop();
                onTopUp();
              },
            ),
            const SizedBox(height: 8),
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: const Text('Not now'),
            ),
          ],
        ),
      ),
    ),
  );
}

/// Client-side wallet guard: true when [mainBalance] clears the dynamic
/// online threshold.
bool canGoOnline(double mainBalance, FinancialConfig config) =>
    mainBalance >= config.minWalletBalanceToOnline;
