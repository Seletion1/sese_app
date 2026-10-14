import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:sese_core/sese_core.dart';

import '../customer/presentation/customer_verification_screen.dart';
import '../customer/services/driver_to_customer_sync.dart';
import '../settings/screens/settings_screen.dart';
import '../support/support_chat_screen.dart';
import '../wallet/bank_details_screen.dart';
import '../wallet/customer_wallet_screen.dart';
import '../../widgets/verified_badge.dart';
import '../referral/referral_hub_screen.dart';
import 'profile_details_screen.dart';
import 'saved_places_screen.dart';
import 'security_pin_screen.dart';

/// Customer Profile tab: account details + preferences + sign-out.
///
/// Profile header card is tappable — opens [ProfileDetailsScreen].
/// Verification tile reflects live status from Firestore and passes
/// current status + rejection reason into [CustomerVerificationScreen].
class CustomerProfileScreen extends StatefulWidget {
  final AppUser user;
  final AuthRepository? auth;

  /// Switches the shell's bottom navigation tab (e.g. `call(0)` jumps to
  /// the Trips tab). Wired by [CustomerHomeShell]; null when standalone.
  final ValueChanged<int>? onSelectTab;

  const CustomerProfileScreen({
    super.key,
    required this.user,
    this.auth,
    this.onSelectTab,
  });

  @override
  State<CustomerProfileScreen> createState() => _CustomerProfileScreenState();
}

class _CustomerProfileScreenState extends State<CustomerProfileScreen> {
  /// True when `drivers/{uid}` is an approved driver profile. Approved
  /// drivers are treated as verified customers (driver KYC synced) and do
  /// not see redundant KYC prompts.
  bool _isApprovedDriver = false;

  @override
  void initState() {
    super.initState();
    // Mirror an approved driver's profile/KYC into users/{uid} and pick up
    // the approved-driver flag for the Verify tile below. Safe to run in
    // widget tests: Firestore failures resolve to false, never a throw.
    Future.wait([
      DriverToCustomerSync.isApprovedDriver(widget.user.uid),
      DriverToCustomerSync.syncIfApprovedDriver(widget.user.uid),
    ]).then((results) {
      if (!mounted) return;
      if (results.any((r) => r == true)) {
        setState(() => _isApprovedDriver = true);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: const SeseAppBar(title: 'Profile'),
      body: StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
        stream: _userStream(widget.user.uid),
        builder: (context, snapshot) {
          final data = snapshot.data?.data();
          final kycStatus =
              (data?[CustomerVerification.fieldStatus] ?? '').toString();
          final isVerified = CustomerVerification.isVerified(kycStatus);
          final isPending = CustomerVerification.isPending(kycStatus);
          final isRejected = kycStatus == CustomerVerification.rejected;
          // Approved drivers inherit verified-customer standing from their
          // synced driver KYC even before the users/{uid} flags land.
          final driverVerified = _isApprovedDriver;
          final showVerified = isVerified || driverVerified;
          final rejectionReason =
              (data?[CustomerVerification.fieldRejectionReason] ?? '').toString();
          final userStream = _userStream(widget.user.uid);

          return ListView(
            physics: const AlwaysScrollableScrollPhysics(),
            padding: EdgeInsets.fromLTRB(
              16,
              12,
              16,
              32 + MediaQuery.viewPaddingOf(context).bottom,
            ),
            children: [
                // ── Profile header card (tappable → ProfileDetailsScreen) ──
                InkWell(
                  borderRadius: BorderRadius.circular(12),
                  onTap: () => Navigator.of(context).push(MaterialPageRoute(
                    builder: (_) => ProfileDetailsScreen(
                      user: widget.user,
                      userStream: userStream,
                    ),
                  )),
                  child: Card(
                    child: Padding(
                      padding: const EdgeInsets.all(20),
                      child: Row(
                        children: [
                          UserAvatar(
                            displayName: widget.user.fullName,
                            photoUrl: widget.user.photoUrl,
                            radius: 28,
                          ),
                          const SizedBox(width: 16),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Row(
                                  children: [
                                    Flexible(
                                      child: Text(
                                        widget.user.fullName.isEmpty
                                            ? 'Rider'
                                            : widget.user.fullName,
                                        style: const TextStyle(
                                          fontSize: 18,
                                          fontWeight: FontWeight.bold,
                                        ),
                                      ),
                                    ),
                                    const SizedBox(width: 6),
                                    VerifiedBadge(
                                      variant: VerifiedBadgeVariant.icon,
                                      show: showVerified,
                                    ),
                                  ],
                                ),
                                if (widget.user.email.isNotEmpty)
                                  Text(widget.user.email,
                                      style: const TextStyle(
                                          color: Colors.grey)),
                                if (widget.user.phoneNumber.isNotEmpty)
                                  Text(widget.user.phoneNumber,
                                      style: const TextStyle(
                                          color: Colors.grey)),
                              ],
                            ),
                          ),
                          const Icon(Icons.chevron_right, color: Colors.grey),
                        ],
                      ),
                    ),
                  ),
                ),

                const SizedBox(height: 8),

                // ── Trip history ──────────────────────────────────────────
                SettingsTile(
                  leading: const Icon(Icons.history),
                  title: 'Trip history',
                  infoDescription: 'Completed trips and ride receipts appear here.',
                  onTap: () => widget.onSelectTab?.call(0),
                ),
                const SizedBox(height: 12),

                // ── Wallet ────────────────────────────────────────────────
                SettingsTile(
                  leading:
                      const Icon(Icons.account_balance_wallet_outlined),
                  title: 'Wallet & Payments',
                  infoDescription: 'Manage balance, payment cards, and transaction history.',
                  onTap: () => Navigator.of(context).push(MaterialPageRoute(
                    builder: (_) =>
                        CustomerWalletScreen(user: widget.user),
                  )),
                ),
                const SizedBox(height: 12),

                // ── Saved Places ─────────────────────────────────────────
                SettingsTile(
                  tileKey: const Key('customer_saved_places_tile'),
                  leading: const Icon(Icons.bookmark_border_outlined,
                      color: AppColors.seseGold),
                  title: 'Saved Places',
                  infoDescription: 'Set Home and Work addresses for fast one-tap booking.',
                  onTap: () => Navigator.of(context).push(MaterialPageRoute(
                    builder: (_) => SavedPlacesScreen(uid: widget.user.uid),
                  )),
                ),
                const SizedBox(height: 12),

                // ── Bank & Payout Details ────────────────────────────────
                SettingsTile(
                  tileKey: const Key('customer_bank_details_tile'),
                  leading: const Icon(Icons.account_balance_outlined),
                  title: 'Bank & Payout Details',
                  infoDescription: 'Link your bank account for secure fund withdrawals.',
                  onTap: () => Navigator.of(context).push(MaterialPageRoute(
                    builder: (_) =>
                        BankDetailsScreen(uid: widget.user.uid),
                  )),
                ),
                const SizedBox(height: 12),

                // ── Security PIN ─────────────────────────────────────────
                SettingsTile(
                  tileKey: const Key('customer_security_pin_tile'),
                  leading: const Icon(Icons.lock_outline),
                  title: 'Security PIN',
                  infoDescription: 'Protect your account and wallet transfers with a 4-digit PIN.',
                  onTap: () => Navigator.of(context).push(MaterialPageRoute(
                    builder: (_) =>
                        SecurityPinScreen(uid: widget.user.uid),
                  )),
                ),
                const SizedBox(height: 12),

                // ── Refer & Earn ──────────────────────────────────────────
                SettingsTile(
                  tileKey: const Key('customer_referral_tile'),
                  leading: const Icon(Icons.card_giftcard_outlined,
                      color: AppColors.seseGold),
                  title: 'Refer & Earn',
                  infoDescription: 'Invite friends & earn 1% bonus on every completed trip.',
                  onTap: () => Navigator.of(context).push(MaterialPageRoute(
                    builder: (_) => ReferralHubScreen(user: widget.user),
                  )),
                ),
                const SizedBox(height: 12),

                // ── Verify Account tile ───────────────────────────────────
                // Approved drivers see a green "Account Verified" badge
                // instead of the KYC prompt; their driver KYC is synced and
                // re-submission is disabled for them.
                SettingsTile(
                  leading: Icon(
                    showVerified
                        ? Icons.verified
                        : Icons.verified_outlined,
                    color: showVerified
                        ? AppColors.seseGold
                        : null,
                  ),
                  title: (driverVerified && !isVerified)
                      ? 'Account Verified'
                      : 'Verify Account',
                  infoDescription: isVerified
                      ? 'Verified — instant driver matches.'
                      : driverVerified
                          ? 'Driver KYC synced — no further action needed.'
                          : isPending
                              ? 'Verification pending review by our team.'
                              : isRejected
                                  ? 'Rejected — tap to edit & re-submit.'
                                  : 'Submit KYC documents for instant matches.',
                  trailing: showVerified
                      ? const Icon(Icons.check_circle,
                          color: Colors.green)
                      : isPending
                          ? const Icon(Icons.hourglass_top_outlined,
                              color: Colors.orange)
                          : const Icon(Icons.chevron_right),
                  onTap: (driverVerified && !isVerified)
                      ? null
                      : () => Navigator.of(context).push(MaterialPageRoute(
                            builder: (_) => CustomerVerificationScreen(
                              user: widget.user,
                              currentStatus: kycStatus,
                              rejectionReason: rejectionReason.isEmpty
                                  ? null
                                  : rejectionReason,
                            ),
                          )),
                ),
                const SizedBox(height: 12),

                // ── Settings ──────────────────────────────────────────────
                // Theme, privacy, sign-out, and account deletion live here,
                // not inline — the profile stays focused on identity.
                SettingsTile(
                  tileKey: const Key('customer_settings_tile'),
                  leading: const Icon(Icons.settings_outlined),
                  title: 'Settings',
                  infoDescription: 'Theme, phone privacy, and account security.',
                  onTap: () => Navigator.of(context).push(MaterialPageRoute(
                    builder: (_) => SettingsScreen(
                      user: widget.user,
                      auth: widget.auth ?? FirebaseAuthRepository(),
                      isDriver: false,
                    ),
                  )),
                ),
                const SizedBox(height: 12),

                // ── Support ───────────────────────────────────────────────
                ListTile(
                  leading: const Icon(Icons.help_outline),
                  title: Builder(
                    builder: (ctx) => Row(children: [
                      const Text('Help & Support'),
                      const SizedBox(width: 6),
                      Tooltip(
                        message: 'Customer care and FAQs',
                        triggerMode: TooltipTriggerMode.tap,
                        child: Icon(Icons.info_outline, size: 15,
                            color: Theme.of(ctx).colorScheme.onSurfaceVariant.withValues(alpha: 0.45)),
                      ),
                    ]),
                  ),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () =>
                      showSupportContactSheet(context, widget.user),
                ),
                const SizedBox(height: 16),
            ],
          );
        },
      ),
    );
  }
}

/// Live Firestore stream for `users/{uid}`.
Stream<DocumentSnapshot<Map<String, dynamic>>>? _userStream(String uid) {
  if (uid.isEmpty) return null;
  try {
    return FirebaseFirestore.instance
        .collection('users')
        .doc(uid)
        .snapshots();
  } catch (_) {
    return null;
  }
}

// NOTE: showThemePickerSheet moved to sese_core/lib/theme/theme_controller.dart
// so Menu, Settings, and profile screens can share it without import cycles.

// ── Support contact sheet ─────────────────────────────────────────────────────

Future<void> showSupportContactSheet(BuildContext context, AppUser user) {
  return showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    builder: (sheetContext) {
      return SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Padding(
              // 16px gutters match the profile ListView (16) so the sheet
              // header spans edge-to-edge with the rows below.
              padding: EdgeInsets.fromLTRB(16, 8, 16, 4),
              child: Text('Help & Support',
                  style: TextStyle(
                      fontSize: 16, fontWeight: FontWeight.bold)),
            ),
            ListTile(
              key: const Key('chat_support_ai_tile'),
              leading: const Icon(Icons.smart_toy_outlined),
              title: const Text('Chat with SeSe Assistant'),
              subtitle: const Text('AI help + human agent backup'),
              trailing: const Icon(Icons.chevron_right),
              onTap: () {
                Navigator.of(sheetContext).pop();
                Navigator.of(context).push(MaterialPageRoute(
                  builder: (_) =>
                      SupportChatScreen(user: user, userRole: 'customer'),
                ));
              },
            ),
            const SizedBox(height: 12),
            const ExpansionTile(
              leading: Icon(Icons.help_outline),
              title: Text('How do I book a ride?'),
              children: [
                Padding(
                  padding: EdgeInsets.all(16),
                  child: Text(
                    'Go to Home, enter pickup and drop-off, pick a ride tier, '
                    'confirm contact numbers, then tap Confirm & Book Ride.',
                  ),
                ),
              ],
            ),
            const ExpansionTile(
              leading: Icon(Icons.help_outline),
              title: Text('How do I pay?'),
              children: [
                Padding(
                  padding: EdgeInsets.all(16),
                  child: Text(
                    'Pay with cash or your wallet balance. Top up anytime '
                    'from Wallet & Payments.',
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
          ],
        ),
      );
    },
  );
}
