import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:share_plus/share_plus.dart';
import 'package:sese_core/sese_core.dart';

import 'my_referrals_screen.dart';

/// Dedicated Referral Hub inside the Account/Menu tab.
///
/// Shows the user's unique code, copy + share actions, and a live earnings
/// card (total referrals, active commissions, coins earned).
class ReferralHubScreen extends StatelessWidget {
  final AppUser user;

  const ReferralHubScreen({super.key, required this.user});

  Stream<String> _codeStream() {
    // Drivers live under `drivers/`, everyone else under `users/`.
    Stream<String> streamFor(String collection) {
      return FirebaseFirestore.instance
          .collection(collection)
          .doc(user.uid)
          .snapshots()
          .map((s) => (s.data()?['referralCode'] ?? '').toString());
    }

    if (user.role == UserRole.driver) {
      return streamFor('drivers').asyncMap((code) async {
        if (code.isNotEmpty) return code;
        try {
          final fallback = await FirebaseFirestore.instance
              .collection('users')
              .doc(user.uid)
              .get();
          return ((fallback.data()?['referralCode'] ?? '').toString());
        } catch (_) {
          return '';
        }
      });
    }
    return streamFor('users');
  }

  Future<void> _copy(BuildContext context, String code) async {
    if (code.isEmpty) return;
    await Clipboard.setData(ClipboardData(text: code));
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Referral code copied.')),
      );
    }
  }

  Future<void> _share(BuildContext context, String code) async {
    if (code.isEmpty) return;
    final box = context.findRenderObject() as RenderBox?;
    final origin =
        box != null ? (box.localToGlobal(Offset.zero) & box.size) : null;
    await SharePlus.instance.share(
      ShareParams(
        text: 'Ride with me on SeSe! Use my referral code $code when you sign '
            'up. Earn bonuses on every trip. #SeSeRide',
        subject: 'My SeSe referral code: $code',
        sharePositionOrigin: origin,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final referralService = const ReferralService();
    return Scaffold(
      appBar: AppBar(
        title: const Text('Referral Hub'),
        actions: [
          SettingsInfoButton(
            tooltipId: 'menu_referral',
            userId: user.uid,
            title: 'Refer & Earn',
            description:
                'Share your referral code with friends and drivers to earn lifetime commission bonus coins.',
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          StreamBuilder<String>(
            stream: _codeStream(),
            builder: (context, snap) {
              final code = snap.data ?? '';
              return Card(
                child: Padding(
                  padding: const EdgeInsets.all(20),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text('Your referral code',
                          style: TextStyle(color: Colors.grey)),
                      const SizedBox(height: 4),
                      Text(
                        code.isEmpty ? '…' : code,
                        style: const TextStyle(
                          fontSize: 36,
                          fontWeight: FontWeight.bold,
                          letterSpacing: 2,
                        ),
                      ),
                      const SizedBox(height: 12),
                      Row(
                        children: [
                          Expanded(
                            child: FilledButton.icon(
                              key: const Key('referral_copy_button'),
                              icon: const Icon(Icons.copy),
                              label: const Text('Copy Code'),
                              onPressed: code.isEmpty
                                  ? null
                                  : () => _copy(context, code),
                            ),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: OutlinedButton.icon(
                              key: const Key('referral_share_button'),
                              icon: const Icon(Icons.share),
                              label: const Text('Share'),
                              onPressed: code.isEmpty
                                  ? null
                                  : () => _share(context, code),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              );
            },
          ),
          const SizedBox(height: 12),
          StreamBuilder<ReferralStats>(
            stream: referralService.statsStream(user.uid),
            builder: (context, snap) {
              final stats = snap.data ?? const ReferralStats();
              return Card(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Row(
                    mainAxisAlignment:
                        MainAxisAlignment.spaceAround,
                    children: [
                      _Stat(
                          label: 'Referrals',
                          value: '${stats.totalReferrals}'),
                      _Stat(
                          label: 'Active',
                          value: '${stats.activeReferrals}'),
                      _Stat(
                          label: 'Coins earned',
                          value:
                              '₦${stats.totalCoinsEarned.toStringAsFixed(0)}'),
                    ],
                  ),
                ),
              );
            },
          ),
          const SizedBox(height: 12),
          FilledButton.tonalIcon(
            icon: const Icon(Icons.people_outline),
            label: const Text('View My Referrals'),
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute(
                builder: (_) =>
                    MyReferralsScreen(user: user),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _Stat extends StatelessWidget {
  final String label;
  final String value;

  const _Stat({required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Text(value,
            style: const TextStyle(
                fontSize: 18, fontWeight: FontWeight.bold)),
        Text(label,
            style:
                const TextStyle(fontSize: 12, color: Colors.grey)),
      ],
    );
  }
}
