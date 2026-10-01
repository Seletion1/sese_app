import 'package:flutter/material.dart';
import 'package:sese_core/sese_core.dart';

/// Detailed referral dashboard: every referred user by name, cumulative
/// earnings from that user, and remaining commission-eligibility countdown.
class MyReferralsScreen extends StatelessWidget {
  final AppUser user;

  const MyReferralsScreen({super.key, required this.user});

  @override
  Widget build(BuildContext context) {
    final service = const ReferralService();
    return Scaffold(
      appBar: AppBar(title: const Text('My Referrals')),
      body: StreamBuilder<List<ReferredUserEntry>>(
        stream: service.referralsStream(user.uid),
        builder: (context, snap) {
          if (snap.connectionState == ConnectionState.waiting) {
            return const Center(
                child: CircularProgressIndicator());
          }
          final items = snap.data ?? const <ReferredUserEntry>[];
          if (items.isEmpty) {
            return const Center(
              child: Padding(
                padding: EdgeInsets.all(24),
                child: Text(
                  'No referrals yet — share your code from the Referral Hub '
                  'to earn 1% on every order they complete.',
                  textAlign: TextAlign.center,
                ),
              ),
            );
          }
          return ListView.separated(
            padding: const EdgeInsets.all(16),
            itemCount: items.length,
            separatorBuilder: (_, _) =>
                const SizedBox(height: 8),
            itemBuilder: (context, i) {
              final e = items[i];
              return Card(
                child: ListTile(
                  leading: CircleAvatar(
                    child: Text(
                      e.fullName.isEmpty
                          ? '?'
                          : e.fullName.trim()[0].toUpperCase(),
                    ),
                  ),
                  title: Text(e.fullName,
                      style: const TextStyle(
                          fontWeight: FontWeight.w600)),
                  subtitle: Column(
                    crossAxisAlignment:
                        CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Total Earned: ₦${e.totalEarned.toStringAsFixed(2)}',
                        style: const TextStyle(
                            fontWeight: FontWeight.w600),
                      ),
                      const SizedBox(height: 2),
                      Row(
                        children: [
                          Icon(
                            e.isActive
                                ? Icons.timer_outlined
                                : Icons.timer_off_outlined,
                            size: 14,
                            color: e.isActive
                                ? Colors.green.shade700
                                : Colors.grey,
                          ),
                          const SizedBox(width: 4),
                          Text(
                            e.isActive
                                ? '${e.daysRemaining} days remaining'
                                : 'Expired',
                            style: TextStyle(
                              fontSize: 12,
                              color: e.isActive
                                  ? Colors.green.shade700
                                  : Colors.grey,
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                  trailing: e.isActive
                      ? const Chip(
                          label: Text('ACTIVE',
                              style: TextStyle(fontSize: 10)),
                          side: BorderSide.none,
                        )
                      : const Chip(
                          label: Text('EXPIRED',
                              style: TextStyle(fontSize: 10)),
                          side: BorderSide.none,
                        ),
                ),
              );
            },
          );
        },
      ),
    );
  }
}
