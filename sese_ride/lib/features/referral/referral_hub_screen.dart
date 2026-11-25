import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:share_plus/share_plus.dart';
import 'package:sese_core/sese_core.dart';

/// Dedicated Referral Hub inside the Account/Menu tab.
///
/// Shows the user's unique code, live accumulated Sese Credits balance,
/// and copy + share actions.
class ReferralHubScreen extends StatelessWidget {
  final AppUser user;

  const ReferralHubScreen({super.key, required this.user});

  Stream<({bool isVerified, String memberId})> _memberStatusStream() {
    try {
      final collection = user.role == UserRole.driver ? 'drivers' : 'users';
      return FirebaseFirestore.instance
          .collection(collection)
          .doc(user.uid)
          .snapshots()
          .map((s) {
        final data = s.data();
        if (data == null) {
          return (
            isVerified: user.isVerified,
            memberId: user.sequentialId,
          );
        }
        final status = (data['verificationStatus'] ?? '').toString().toLowerCase();
        final custStatus =
            (data['customerVerificationStatus'] ?? '').toString().toLowerCase();
        final isVerified = data['isProfileVerified'] == true ||
            data['isVerifiedCustomer'] == true ||
            status == 'verified' ||
            status == 'approved' ||
            custStatus == 'verified' ||
            custStatus == 'approved';
        final memberId = (data['sequentialId'] ?? '').toString().trim();
        return (isVerified: isVerified, memberId: memberId);
      });
    } catch (_) {
      return Stream.value((
        isVerified: user.isVerified,
        memberId: user.sequentialId,
      ));
    }
  }

  Stream<double> _seseCreditsStream() {
    try {
      return FirebaseFirestore.instance
          .collection('wallets')
          .doc(user.uid)
          .snapshots()
          .map((s) {
        final data = s.data();
        if (data == null) return 0.0;
        return (data['seseCredits'] as num?)?.toDouble() ?? 0.0;
      });
    } catch (_) {
      return Stream.value(0.0);
    }
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
        text: 'Ride with me on SeSe! Use my referral code $code when you sign up. #SeSeRide',
        subject: 'My SeSe referral code: $code',
        sharePositionOrigin: origin,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Referral Credits'),
        actions: [
          SettingsInfoButton(
            tooltipId: 'menu_referral',
            userId: user.uid,
            title: 'Invite Friends',
            description:
                'Share your referral code with friends and drivers to earn 1% Sese Credits on every completed trip.',
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          // ── Accumulated Sese Credits Card ────────────────────────────────
          StreamBuilder<double>(
            stream: _seseCreditsStream(),
            builder: (context, snap) {
              final credits = snap.data ?? 0.0;
              return Card(
                color: Colors.amber.shade50.withOpacity(0.9),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(16),
                  side: BorderSide(color: Colors.amber.shade300, width: 1),
                ),
                child: Padding(
                  padding: const EdgeInsets.all(20),
                  child: Row(
                    children: [
                      Container(
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: Colors.amber.shade100,
                          shape: BoxShape.circle,
                        ),
                        child: const Icon(Icons.card_giftcard, color: Colors.amber, size: 28),
                      ),
                      const SizedBox(width: 16),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Text(
                              'Accumulated Sese Credits',
                              style: TextStyle(
                                fontSize: 13,
                                fontWeight: FontWeight.w500,
                                color: Colors.black54,
                              ),
                            ),
                            const SizedBox(height: 2),
                            Text(
                              '₦${credits.toStringAsFixed(2)}',
                              style: const TextStyle(
                                fontSize: 26,
                                fontWeight: FontWeight.bold,
                                color: Colors.black87,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              );
            },
          ),
          const SizedBox(height: 16),

          // ── Unified Member ID / Referral Code Card (Verified Only) ────────
          StreamBuilder<({bool isVerified, String memberId})>(
            stream: _memberStatusStream(),
            initialData: (
              isVerified: user.isVerified,
              memberId: user.sequentialId,
            ),
            builder: (context, snap) {
              final state = snap.data ??
                  (isVerified: user.isVerified, memberId: user.sequentialId);
              final isVerifiedWithId =
                  state.isVerified && state.memberId.isNotEmpty;

              if (!isVerifiedWithId) {
                return Card(
                  key: const Key('referral_verification_prompt_card'),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(16),
                    side: BorderSide(color: Colors.amber.shade200),
                  ),
                  child: Padding(
                    padding: const EdgeInsets.all(20),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Icon(
                              Icons.verified_user_outlined,
                              color: Colors.amber.shade800,
                              size: 24,
                            ),
                            const SizedBox(width: 10),
                            const Expanded(
                              child: Text(
                                'Account Verification Required',
                                style: TextStyle(
                                  fontSize: 16,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 10),
                        Text(
                          'Verify your account first to receive your official SeSe Member ID and refer friends to earn 1% Sese Credits.',
                          style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                                color: Colors.grey[700],
                                height: 1.4,
                              ),
                        ),
                      ],
                    ),
                  ),
                );
              }

              final code = state.memberId;
              return Card(
                key: const Key('referral_code_card'),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(16),
                ),
                child: Padding(
                  padding: const EdgeInsets.all(20),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        'Your Referral Code (Member ID)',
                        style: TextStyle(
                            color: Colors.grey, fontWeight: FontWeight.w500),
                      ),
                      const SizedBox(height: 6),
                      Text(
                        code,
                        style: const TextStyle(
                          fontSize: 36,
                          fontWeight: FontWeight.bold,
                          letterSpacing: 2,
                        ),
                      ),
                      const SizedBox(height: 16),
                      Row(
                        children: [
                          Expanded(
                            child: FilledButton.icon(
                              key: const Key('referral_copy_button'),
                              icon: const Icon(Icons.copy),
                              label: const Text('Copy Code'),
                              onPressed: () => _copy(context, code),
                            ),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: OutlinedButton.icon(
                              key: const Key('referral_share_button'),
                              icon: const Icon(Icons.share),
                              label: const Text('Share'),
                              onPressed: () => _share(context, code),
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
          const SizedBox(height: 16),

          // ── Program Rules Card ──────────────────────────────────────────
          Card(
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(16),
            ),
            child: const Padding(
              padding: EdgeInsets.all(20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'How Sese Credits Work',
                    style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                  ),
                  SizedBox(height: 12),
                  _RuleRow(
                    icon: Icons.percent,
                    title: '1% Credit on Completed Trips',
                    description:
                        'Earn 1% Sese Credits on every completed trip made by users and drivers you refer.',
                  ),
                  SizedBox(height: 12),
                  _RuleRow(
                    icon: Icons.discount_outlined,
                    title: 'Automatic Trip Discounts',
                    description:
                        'For passengers, Sese Credits automatically apply as a Trip Discount at checkout.',
                  ),
                  SizedBox(height: 12),
                  _RuleRow(
                    icon: Icons.build_circle_outlined,
                    title: 'Platform Fee Offset',
                    description:
                        'For drivers, Sese Credits directly offset platform commission fees on future trips.',
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _RuleRow extends StatelessWidget {
  final IconData icon;
  final String title;
  final String description;

  const _RuleRow({
    required this.icon,
    required this.title,
    required this.description,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, size: 20, color: Colors.amber.shade700),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13),
              ),
              const SizedBox(height: 2),
              Text(
                description,
                style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
              ),
            ],
          ),
        ),
      ],
    );
  }
}
