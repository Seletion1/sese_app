import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:sese_core/sese_core.dart';

/// Admin & Staff Hub view exposing the unified wallet balance and live
/// transaction history for any user.
///
/// Reads `wallets/{uid}` directly — no client-side coin/dual-wallet logic.
/// The balance shown is the single source of truth written by Cloud Functions.
class HubUserWalletCard extends StatelessWidget {
  final String userId;
  final FirebaseFirestore? firestore;

  const HubUserWalletCard({
    super.key,
    required this.userId,
    this.firestore,
  });

  FirebaseFirestore? get _db {
    try {
      return firestore ?? FirebaseFirestore.instance;
    } catch (_) {
      return null;
    }
  }

  static String _formatNaira(double amount) {
    final intPart = amount.floor();
    final decimalPart =
        ((amount - intPart) * 100).round().toString().padLeft(2, '0');
    final formattedInt = intPart.toString().replaceAllMapped(
      RegExp(r'(\d{1,3})(?=(\d{3})+(?!\d))'),
      (Match m) => '${m[1]},',
    );
    return '₦$formattedInt.$decimalPart';
  }

  /// Reads the unified wallet balance from `wallets/{uid}`.
  ///
  /// Merges `mainWalletBalance` (Naira float) and the legacy `balance` (kobo
  /// int) field so both old and new Firestore documents are displayed correctly.
  Stream<double> _balanceStream() {
    final db = _db;
    if (db == null || userId.isEmpty) return Stream.value(0.0);
    return db.collection('wallets').doc(userId).snapshots().map((doc) {
      final data = doc.data();
      if (data == null) return 0.0;
      // Prefer the Naira float field written by recent Cloud Functions.
      if (data['mainWalletBalance'] is num) {
        return (data['mainWalletBalance'] as num).toDouble();
      }
      // Legacy documents only carry `balance` in kobo.
      if (data['balance'] is num) {
        return (data['balance'] as num).toDouble() / 100.0;
      }
      return 0.0;
    }).handleError((Object _) => 0.0);
  }

  @override
  Widget build(BuildContext context) {
    if (userId.isEmpty) {
      return const SizedBox.shrink();
    }

    return Card(
      key: Key('hub_user_wallet_card_$userId'),
      margin: const EdgeInsets.symmetric(vertical: 8),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Row(
              children: [
                Icon(Icons.account_balance_wallet_outlined, size: 20),
                SizedBox(width: 8),
                Text(
                  'User Wallet & Balance',
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                ),
              ],
            ),
            const Divider(height: 24),
            StreamBuilder<double>(
              stream: _balanceStream(),
              builder: (context, snap) {
                final balance = snap.data ?? 0.0;
                return Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color:
                        Theme.of(context).colorScheme.surfaceContainerHighest,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      const Text(
                        'Wallet Balance:',
                        style: TextStyle(fontWeight: FontWeight.w600),
                      ),
                      Text(
                        _formatNaira(balance),
                        style: const TextStyle(
                          fontWeight: FontWeight.bold,
                          fontSize: 16,
                          color: Colors.green,
                        ),
                      ),
                    ],
                  ),
                );
              },
            ),
            const SizedBox(height: 16),
            const Text(
              'Transaction History',
              style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 8),
            _buildTransactionHistory(context),
          ],
        ),
      ),
    );
  }

  Widget _buildTransactionHistory(BuildContext context) {
    final db = _db;
    if (db == null) {
      return const Text('Firestore unavailable.',
          style: TextStyle(color: Colors.grey));
    }

    return StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
      stream: db
          .collection('wallets')
          .doc(userId)
          .collection('transactions')
          .orderBy('createdAt', descending: true)
          .limit(20)
          .snapshots(),
      builder: (context, snap) {
        if (snap.connectionState == ConnectionState.waiting && !snap.hasData) {
          return const SeseListSkeleton(itemCount: 3);
        }
        final docs = snap.data?.docs ?? [];
        if (docs.isEmpty) {
          return const Padding(
            padding: EdgeInsets.symmetric(vertical: 8),
            child: Text(
              'No wallet transactions recorded.',
              style: TextStyle(color: Colors.grey, fontSize: 13),
            ),
          );
        }

        return ListView.separated(
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          itemCount: docs.length,
          separatorBuilder: (_, _) => const Divider(height: 1),
          itemBuilder: (context, index) {
            final data = docs[index].data();
            final type = (data['type'] ?? 'transaction').toString();
            final label =
                (data['label'] ?? data['paymentReference'] ?? type).toString();
            final createdAt = data['createdAt'];
            DateTime? dt;
            if (createdAt is Timestamp) dt = createdAt.toDate();

            double amount = 0.0;
            if (data['amountKobo'] is num) {
              amount = (data['amountKobo'] as num).toDouble() / 100.0;
            } else if (data['amount'] is num) {
              amount = (data['amount'] as num).toDouble();
            }

            final isCredit = type.contains('topup') ||
                type.contains('payout') ||
                type.contains('bonus') ||
                type.contains('award') ||
                type.contains('credit');

            return ListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              leading: Icon(
                isCredit ? Icons.arrow_downward : Icons.arrow_upward,
                color: isCredit ? Colors.green : Colors.red,
                size: 18,
              ),
              title: Text(label,
                  style: const TextStyle(
                      fontSize: 13, fontWeight: FontWeight.w500)),
              subtitle: dt != null
                  ? Text('$dt'.split('.').first,
                      style: const TextStyle(fontSize: 11))
                  : null,
              trailing: Text(
                '${isCredit ? '+' : '-'}${_formatNaira(amount)}',
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.bold,
                  color:
                      isCredit ? Colors.green.shade700 : Colors.red.shade700,
                ),
              ),
            );
          },
        );
      },
    );
  }
}
