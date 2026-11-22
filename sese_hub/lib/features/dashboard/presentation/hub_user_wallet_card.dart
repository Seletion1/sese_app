import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:sese_core/sese_core.dart';

/// Admin & Staff Hub view exposing the unified wallet balance and live
/// transaction history for any user.
///
/// Reads `wallets/{uid}` directly — no client-side coin/dual-wallet logic.
/// The balance shown is the single source of truth written by Cloud Functions.
/// Admin & Staff Hub view exposing the isolated wallet balance and live
/// transaction history for any user strictly scoped by role and sequential ID.
///
/// Prevents cross-role ledger mixing (e.g. driver commissions appearing on
/// customer or hub staff profile views).
class HubUserWalletCard extends StatelessWidget {
  final String userId;
  final String? role;
  final String? sequentialId;
  final String? targetLabel;
  final FirebaseFirestore? firestore;

  const HubUserWalletCard({
    super.key,
    required this.userId,
    this.role,
    this.sequentialId,
    this.targetLabel,
    this.firestore,
  });

  FirebaseFirestore? get _db {
    try {
      return firestore ?? FirebaseFirestore.instance;
    } catch (_) {
      return null;
    }
  }

  String get _effectiveRole {
    if (role != null && role!.trim().isNotEmpty) {
      final r = role!.trim().toLowerCase();
      if (r == 'driver' || r == 'sd') return 'driver';
      if (r == 'customer' || r == 'sc') return 'customer';
      if (r == 'hub' || r == 'staff' || r == 'sh') return 'hub';
    }
    if (sequentialId != null && sequentialId!.trim().isNotEmpty) {
      final seq = sequentialId!.trim().toUpperCase();
      if (seq.startsWith('SD')) return 'driver';
      if (seq.startsWith('SC')) return 'customer';
      if (seq.startsWith('SH')) return 'hub';
    }
    return 'all';
  }

  String get _cardTitle {
    if (targetLabel != null && targetLabel!.isNotEmpty) {
      return targetLabel!;
    }
    final effRole = _effectiveRole;
    final seq = sequentialId?.trim() ?? '';
    if (effRole == 'hub') {
      return seq.isNotEmpty ? 'Staff Ledger • $seq' : 'Hub Staff Ledger';
    }
    if (effRole == 'driver') {
      return seq.isNotEmpty ? 'Driver Wallet • $seq' : 'Driver Wallet & Balance';
    }
    if (effRole == 'customer') {
      return seq.isNotEmpty ? 'Customer Wallet • $seq' : 'Customer Wallet & Balance';
    }
    return 'User Wallet & Balance';
  }

  static String _formatNaira(double amount) {
    final isNegative = amount < 0;
    final absAmount = amount.abs();
    final intPart = absAmount.floor();
    final decimalPart =
        ((absAmount - intPart) * 100).round().toString().padLeft(2, '0');
    final formattedInt = intPart.toString().replaceAllMapped(
      RegExp(r'(\d{1,3})(?=(\d{3})+(?!\d))'),
      (Match m) => '${m[1]},',
    );
    final prefix = isNegative ? '-₦' : '₦';
    return '$prefix$formattedInt.$decimalPart';
  }

  /// Reads role-isolated wallet balance.
  ///
  /// - `hub`: reads staffBalance/hubBalance (never driver debt or customer balance).
  /// - `driver`: reads driverBalance (falls back to mainWalletBalance if driver doc).
  /// - `customer`: reads customerBalance (falls back to mainWalletBalance if customer doc).
  Stream<double> _balanceStream() {
    final db = _db;
    if (db == null || userId.isEmpty) return Stream.value(0.0);
    final effRole = _effectiveRole;

    return db.collection('wallets').doc(userId).snapshots().map((doc) {
      final data = doc.data();
      if (data == null) return 0.0;

      if (effRole == 'hub') {
        if (data['staffBalance'] is num) {
          return (data['staffBalance'] as num).toDouble();
        }
        if (data['hubBalance'] is num) {
          return (data['hubBalance'] as num).toDouble();
        }
        // Staff has no separate wallet balance; do NOT leak driver or customer balance!
        return 0.0;
      }

      if (effRole == 'driver') {
        if (data['driverBalance'] is num) {
          return (data['driverBalance'] as num).toDouble();
        }
        if (data['mainWalletBalance'] is num) {
          return (data['mainWalletBalance'] as num).toDouble();
        }
        if (data['balance'] is num) {
          return (data['balance'] as num).toDouble() / 100.0;
        }
        return 0.0;
      }

      if (effRole == 'customer') {
        if (data['customerBalance'] is num) {
          return (data['customerBalance'] as num).toDouble();
        }
        if (data['mainWalletBalance'] is num) {
          return (data['mainWalletBalance'] as num).toDouble();
        }
        if (data['balance'] is num) {
          return (data['balance'] as num).toDouble() / 100.0;
        }
        return 0.0;
      }

      if (data['mainWalletBalance'] is num) {
        return (data['mainWalletBalance'] as num).toDouble();
      }
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

    final effRole = _effectiveRole;
    final cardKeySuffix = '${userId}_$effRole';

    return Card(
      key: Key('hub_user_wallet_card_$cardKeySuffix'),
      margin: const EdgeInsets.symmetric(vertical: 8),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  effRole == 'hub'
                      ? Icons.shield_outlined
                      : effRole == 'driver'
                          ? Icons.local_taxi_outlined
                          : Icons.account_balance_wallet_outlined,
                  size: 20,
                  color: effRole == 'hub'
                      ? const Color(0xFFE2B714)
                      : effRole == 'driver'
                          ? Colors.orange
                          : null,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    _cardTitle,
                    style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
            const Divider(height: 24),
            StreamBuilder<double>(
              stream: _balanceStream(),
              builder: (context, snap) {
                final balance = snap.data ?? 0.0;
                final isNegative = balance < 0;
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
                      Text(
                        effRole == 'hub'
                            ? 'Ledger Balance:'
                            : 'Wallet Balance:',
                        style: const TextStyle(fontWeight: FontWeight.w600),
                      ),
                      Text(
                        _formatNaira(balance),
                        style: TextStyle(
                          fontWeight: FontWeight.bold,
                          fontSize: 16,
                          color: isNegative
                              ? Colors.red.shade700
                              : (balance > 0 ? Colors.green.shade700 : Colors.grey.shade700),
                        ),
                      ),
                    ],
                  ),
                );
              },
            ),
            const SizedBox(height: 16),
            Text(
              effRole == 'hub'
                  ? 'Staff Ledger Records'
                  : 'Transaction History',
              style: const TextStyle(fontSize: 14, fontWeight: FontWeight.bold),
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

    final effRole = _effectiveRole;

    return StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
      stream: db
          .collection('wallets')
          .doc(userId)
          .collection('transactions')
          .orderBy('createdAt', descending: true)
          .limit(50)
          .snapshots(),
      builder: (context, snap) {
        if (snap.connectionState == ConnectionState.waiting && !snap.hasData) {
          return const SeseListSkeleton(itemCount: 3);
        }
        final rawDocs = snap.data?.docs ?? [];

        // STRICT IN-MEMORY ROLE FILTERING:
        final docs = rawDocs.where((d) {
          final data = d.data();
          final txRole = (data['role'] ?? '').toString().toLowerCase();
          final txRoleId = (data['roleId'] ?? '').toString().toUpperCase();
          final type = (data['type'] ?? '').toString().toLowerCase();

          if (effRole == 'hub') {
            final isHub = txRole == 'hub' ||
                txRole == 'staff' ||
                txRoleId.startsWith('SH') ||
                type.contains('staff') ||
                type.contains('disbursement');
            final isDriverOrCust = txRole == 'driver' ||
                txRole == 'customer' ||
                txRoleId.startsWith('SD') ||
                txRoleId.startsWith('SC') ||
                type.contains('escrow') ||
                type.contains('commission') ||
                type.contains('debt') ||
                type.contains('fare');
            return isHub && !isDriverOrCust;
          }

          if (effRole == 'driver') {
            final isDriver = txRole == 'driver' ||
                txRoleId.startsWith('SD') ||
                type.contains('commission') ||
                type.contains('debt') ||
                type.contains('payout') ||
                type.contains('streak') ||
                (type.contains('fare') && !type.contains('ride_payment'));
            final isCustomerOnly = txRole == 'customer' ||
                txRoleId.startsWith('SC') ||
                type == 'trip_payment' ||
                type == 'customer_topup';
            return isDriver && !isCustomerOnly;
          }

          if (effRole == 'customer') {
            final isCustomer = txRole == 'customer' ||
                txRoleId.startsWith('SC') ||
                type == 'trip_payment' ||
                type == 'customer_topup' ||
                type == 'trip_escrow_hold' ||
                type == 'trip_escrow_refund';
            final isDriverOnly = txRole == 'driver' ||
                txRoleId.startsWith('SD') ||
                type.contains('commission') ||
                type.contains('debt') ||
                type.contains('payout');
            return isCustomer && !isDriverOnly;
          }

          return true;
        }).take(20).toList();

        if (docs.isEmpty) {
          return Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Text(
              effRole == 'hub'
                  ? 'No staff ledger transactions recorded for ${sequentialId ?? 'SH0001'}.'
                  : effRole == 'driver'
                      ? 'No driver transactions recorded for ${sequentialId ?? 'Driver'}.'
                      : effRole == 'customer'
                          ? 'No customer transactions recorded for ${sequentialId ?? 'Customer'}.'
                          : 'No wallet transactions recorded.',
              style: const TextStyle(color: Colors.grey, fontSize: 13),
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
                '${isCredit ? '+' : '-'}${_formatNaira(amount.abs())}',
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
