import 'package:flutter/material.dart';
import 'package:sese_core/sese_core.dart';

import '../../payments/sese_service.dart';
import '../../payments/top_up_sheet.dart';

/// Driver Sese Credits screen.
///
/// Exposes non-withdrawable platform service credits used strictly to settle
/// dispatch commissions on completed trips.
/// Drivers purchase Sese Credits via Paystack checkout when their balance
/// is low or negative from cash-trip commissions.
/// Zero withdrawal, zero transfer, and zero cash-out functionality.
class SeseCreditsScreen extends StatelessWidget {
  final AppUser user;

  const SeseCreditsScreen({super.key, required this.user});

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final payments = PaymentService();

    return Scaffold(
      appBar: AppBar(
        title: const Text('Sese Credits'),
        elevation: 0,
      ),
      body: SafeArea(
        child: StreamBuilder<int>(
          stream: payments.walletBalanceKoboStream(user.uid, role: 'driver'),
          builder: (context, snapshot) {
            final balanceKobo = snapshot.data ?? 0;
            final balanceNaira = balanceKobo / 100.0;
            final isLow = balanceNaira < 1.0;

            return SingleChildScrollView(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  // Info banner
                  Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: isDark
                          ? const Color(0xFF1E293B)
                          : const Color(0xFFF1F5F9),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(
                        color: isDark
                            ? const Color(0xFF334155)
                            : const Color(0xFFCBD5E1),
                      ),
                    ),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Icon(
                          Icons.info_outline_rounded,
                          size: 20,
                          color: AppColors.seseGold,
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Text(
                            'Sese Credits are non-withdrawable platform service units '
                            'used strictly to settle dispatch commissions on trips.',
                            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                                  color: isDark ? Colors.grey.shade300 : Colors.grey.shade800,
                                ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 16),

                  // Balance Card
                  Container(
                    padding: const EdgeInsets.all(20),
                    decoration: BoxDecoration(
                      color: isDark
                          ? const Color(0xFF252530)
                          : Colors.white,
                      borderRadius: BorderRadius.circular(20),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withValues(alpha: isDark ? 0.3 : 0.06),
                          blurRadius: 12,
                          offset: const Offset(0, 4),
                        ),
                      ],
                      border: Border.all(
                        color: isLow
                            ? Colors.red.shade400
                            : (isDark ? const Color(0xFF3A3A46) : Colors.grey.shade200),
                        width: isLow ? 1.5 : 1.0,
                      ),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            Text(
                              'SERVICE CREDITS BALANCE',
                              style: Theme.of(context).textTheme.labelSmall?.copyWith(
                                    fontWeight: FontWeight.w700,
                                    letterSpacing: 1.0,
                                    color: Colors.grey,
                                  ),
                            ),
                            Container(
                              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                              decoration: BoxDecoration(
                                color: (isLow ? Colors.red : AppColors.seseGold)
                                    .withValues(alpha: 0.15),
                                borderRadius: BorderRadius.circular(8),
                              ),
                              child: Text(
                                isLow ? 'LOW BALANCE' : 'ACTIVE',
                                style: TextStyle(
                                  fontSize: 11,
                                  fontWeight: FontWeight.bold,
                                  color: isLow ? Colors.red : AppColors.seseGold,
                                ),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 12),
                        Text(
                          '₦${balanceNaira.toStringAsFixed(2)}',
                          style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                                fontWeight: FontWeight.w900,
                                color: isLow ? Colors.red.shade400 : null,
                              ),
                        ),
                        const SizedBox(height: 6),
                        Text(
                          isLow
                              ? 'Top up to keep receiving ride dispatches.'
                              : 'Automatic deduction per completed trip commission.',
                          style: Theme.of(context).textTheme.bodySmall?.copyWith(
                                color: Colors.grey,
                              ),
                        ),
                        const SizedBox(height: 20),
                        SizedBox(
                          width: double.infinity,
                          child: ElevatedButton.icon(
                            key: const Key('top_up_sese_credits_button'),
                            icon: const Icon(Icons.add_circle_outline_rounded),
                            label: const Text('Top Up Sese Credits'),
                            style: ElevatedButton.styleFrom(
                              backgroundColor: AppColors.seseGold,
                              foregroundColor: Colors.black,
                              padding: const EdgeInsets.symmetric(vertical: 14),
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(14),
                              ),
                              elevation: 0,
                            ),
                            onPressed: () {
                              showModalBottomSheet<bool>(
                                context: context,
                                isScrollControlled: true,
                                backgroundColor: Colors.transparent,
                                builder: (_) => TopUpSheet(service: payments, user: user),
                              );
                            },
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 24),

                  // Recent Credits Ledger
                  Text(
                    'RECENT COMMISSION SETTLEMENTS',
                    style: Theme.of(context).textTheme.labelSmall?.copyWith(
                          fontWeight: FontWeight.w700,
                          letterSpacing: 0.8,
                          color: Colors.grey,
                        ),
                  ),
                  const SizedBox(height: 10),
                  StreamBuilder<List<WalletTransaction>>(
                    stream: payments.walletHistoryStream(user.uid, role: 'driver'),
                    builder: (context, txSnap) {
                      final items = txSnap.data ?? const <WalletTransaction>[];
                      if (items.isEmpty) {
                        return Container(
                          padding: const EdgeInsets.symmetric(vertical: 36, horizontal: 16),
                          alignment: Alignment.center,
                          child: Text(
                            'No recent credit movements.',
                            style: Theme.of(context).textTheme.bodyMedium?.copyWith(color: Colors.grey),
                          ),
                        );
                      }

                      return ListView.separated(
                        shrinkWrap: true,
                        physics: const NeverScrollableScrollPhysics(),
                        itemCount: items.length,
                        separatorBuilder: (_, _) => const SizedBox(height: 8),
                        itemBuilder: (context, index) {
                          final tx = items[index];
                          final isCredit = tx.amountNaira > 0;
                          return Container(
                            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                            decoration: BoxDecoration(
                              color: isDark ? const Color(0xFF252530) : Colors.white,
                              borderRadius: BorderRadius.circular(12),
                              border: Border.all(
                                color: isDark ? const Color(0xFF3A3A46) : Colors.grey.shade200,
                              ),
                            ),
                            child: Row(
                              children: [
                                Container(
                                  width: 36,
                                  height: 36,
                                  decoration: BoxDecoration(
                                    color: (isCredit ? Colors.green : Colors.orange)
                                        .withValues(alpha: 0.15),
                                    borderRadius: BorderRadius.circular(10),
                                  ),
                                  child: Icon(
                                    isCredit
                                        ? Icons.add_rounded
                                        : Icons.remove_rounded,
                                    color: isCredit ? Colors.green : Colors.orange,
                                    size: 20,
                                  ),
                                ),
                                const SizedBox(width: 12),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        tx.label,
                                        style: const TextStyle(
                                          fontWeight: FontWeight.w600,
                                          fontSize: 13.5,
                                        ),
                                      ),
                                      if (tx.paymentReference.isNotEmpty)
                                        Text(
                                          tx.paymentReference,
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                          style: Theme.of(context).textTheme.bodySmall?.copyWith(fontSize: 11),
                                        ),
                                    ],
                                  ),
                                ),
                                Text(
                                  '${isCredit ? '+' : ''}₦${tx.amountNaira.abs().toStringAsFixed(2)}',
                                  style: TextStyle(
                                    fontWeight: FontWeight.bold,
                                    fontSize: 14,
                                    color: isCredit ? Colors.green : (isDark ? Colors.white70 : Colors.black87),
                                  ),
                                ),
                              ],
                            ),
                          );
                        },
                      );
                    },
                  ),
                ],
              ),
            );
          },
        ),
      ),
    );
  }
}
