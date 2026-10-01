import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:sese_core/sese_core.dart';

import '../customer/presentation/customer_verification_screen.dart';
import '../customer/services/driver_to_customer_sync.dart';
import '../driver/presentation/driver_fleet_screen.dart';
import '../driver/presentation/driver_onboarding_screen.dart';
import '../driver/services/driver_fleet_service.dart';
import '../settings/role_controller.dart';
import '../settings/screens/settings_screen.dart';
import '../support/support_chat_screen.dart';
import '../wallet/customer_wallet_screen.dart';
import '../../widgets/verified_badge.dart';
import 'driver_home_shell.dart';
import 'profile_details_screen.dart';

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
  /// True while the async Firestore eligibility check is in flight.
  bool _evaluatingSwitch = false;

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

  Future<void> _handleSwitchToDriver() async {
    setState(() => _evaluatingSwitch = true);
    final scenario =
        await RoleController.instance.evaluateDriverEligibility(widget.user.uid);
    if (!mounted) return;
    setState(() => _evaluatingSwitch = false);

    final authRepo = widget.auth ?? FirebaseAuthRepository();

    switch (scenario) {
      case DriverOnboardingScenario.scenarioA:
        RoleController.instance.setCurrentRole(UserRole.driver);
        Navigator.of(context).pushAndRemoveUntil(
          MaterialPageRoute(
            builder: (_) => DriverHomeShell(user: widget.user, auth: authRepo),
          ),
          (route) => false,
        );
        break;

      case DriverOnboardingScenario.scenarioB:
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'Please add and verify a vehicle before going online as a driver.',
            ),
            backgroundColor: AppColors.seseGold,
          ),
        );
        Navigator.of(context).push(
          MaterialPageRoute(
            builder: (_) => DriverFleetScreen(
              fleetService: DriverFleetService(),
              driverId: widget.user.uid,
            ),
          ),
        );
        break;

      case DriverOnboardingScenario.scenarioC:
        await showDialog<void>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: const Text('Complete Driver Profile'),
            content: const Text(
              'Complete Driver Profile to start earning. Submit your personal information and identity verification.',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(ctx).pop(),
                child: const Text('Later'),
              ),
              FilledButton(
                style: FilledButton.styleFrom(
                  backgroundColor: AppColors.seseGold,
                  foregroundColor: Colors.black,
                ),
                onPressed: () {
                  Navigator.of(ctx).pop();
                  Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (_) => DriverOnboardingScreen(
                        user: widget.user,
                        auth: authRepo,
                      ),
                    ),
                  );
                },
                child: const Text('Get Started'),
              ),
            ],
          ),
        );
        break;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Profile')),
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

          return SingleChildScrollView(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
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

                // ── Switch to Driver ──────────────────────────────────────
                Card(
                  color: Theme.of(context).brightness == Brightness.dark
                      ? Theme.of(context)
                          .colorScheme
                          .surfaceContainerHighest
                      : AppColors.seseGoldLight.withValues(alpha: 0.5),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                    side: BorderSide.none,
                  ),
                  child: ListTile(
                    key: const Key('switch_to_driver_tile'),
                    leading: const Icon(Icons.two_wheeler,
                        color: AppColors.seseGold, size: 28),
                    title: const Text(
                      'Switch to Driver Mode',
                      style: TextStyle(fontWeight: FontWeight.bold),
                    ),
                    subtitle: const Text(
                      'Earn on your schedule with verified driver dispatch',
                      style: TextStyle(fontSize: 12),
                    ),
                    trailing: _evaluatingSwitch
                        ? const SizedBox(
                            width: 20,
                            height: 20,
                            child:
                                CircularProgressIndicator(strokeWidth: 2))
                        : const Icon(Icons.swap_horiz,
                            color: AppColors.seseGold),
                    onTap:
                        _evaluatingSwitch ? null : _handleSwitchToDriver,
                  ),
                ),

                const SizedBox(height: 8),

                // ── Trip history ──────────────────────────────────────────
                ListTile(
                  leading: const Icon(Icons.history),
                  title: const Text('Trip history'),
                  subtitle: const Text('Completed trips appear here'),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => widget.onSelectTab?.call(0),
                ),
                const SizedBox(height: 12),

                // ── Wallet ────────────────────────────────────────────────
                ListTile(
                  leading:
                      const Icon(Icons.account_balance_wallet_outlined),
                  title: const Text('Wallet & Payments'),
                  subtitle:
                      const Text('Manage balance and payment methods'),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => Navigator.of(context).push(MaterialPageRoute(
                    builder: (_) =>
                        CustomerWalletScreen(user: widget.user),
                  )),
                ),
                const SizedBox(height: 12),

                // ── Verify Account tile ───────────────────────────────────
                // Approved drivers see a green "Account Verified" badge
                // instead of the KYC prompt; their driver KYC is synced and
                // re-submission is disabled for them.
                ListTile(
                  leading: Icon(
                    showVerified
                        ? Icons.verified
                        : Icons.verified_outlined,
                    color: showVerified
                        ? AppColors.seseGold
                        : null,
                  ),
                  title: Text(
                    (driverVerified && !isVerified)
                        ? 'Account Verified'
                        : 'Verify Account',
                  ),
                  subtitle: Text(
                    isVerified
                        ? 'Verified — instant driver matches'
                        : driverVerified
                            ? 'Driver KYC synced — no further action needed'
                            : isPending
                                ? 'Verification pending review by our team'
                                : isRejected
                                    ? 'Rejected — tap to edit & re-submit'
                                    : 'Submit KYC documents for instant matches',
                    style: TextStyle(
                      color: isRejected ? Colors.red.shade700 : null,
                    ),
                  ),
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
                ListTile(
                  key: const Key('customer_settings_tile'),
                  leading: const Icon(Icons.settings_outlined),
                  title: const Text('Settings'),
                  subtitle: const Text('Theme, privacy, account'),
                  trailing: const Icon(Icons.chevron_right),
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
                  title: const Text('Help & Support'),
                  subtitle: const Text('Customer care and FAQs'),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () =>
                      showSupportContactSheet(context, widget.user),
                ),
              ],
            ),
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
              padding: EdgeInsets.fromLTRB(20, 8, 20, 4),
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
