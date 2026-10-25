import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:sese_core/sese_core.dart';
import '../driver/presentation/driver_dashboard_screen.dart';
import '../driver/presentation/driver_profile_screen.dart';
import '../driver/services/driver_fleet_service.dart';
import '../settings/screens/settings_screen.dart';
import '../referral/referral_hub_screen.dart';
import '../support/support_chat_screen.dart';
import '../trips/presentation/customer_trips_screen.dart';
import '../trips/services/trip_service.dart';
import '../wallet/earnings_screen.dart';
import '../wallet/wallet_screen.dart';

/// Role-gated container strictly for Driver users, scoped to the driver's
/// real authenticated UID.
///
/// Hosts a 4-item [BottomNavigationBar] (Menu | Home | Trips | Help)
/// with an [IndexedStack] so each tab keeps its state (notably the Driver Map
/// / Go Online view) when switching tabs.
class DriverHomeShell extends StatefulWidget {
  final AppUser user;
  final AuthRepository auth;
  final TripRepository? tripRepository;

  const DriverHomeShell({
    super.key,
    required this.user,
    required this.auth,
    this.tripRepository,
  });

  @override
  State<DriverHomeShell> createState() => _DriverHomeShellState();
}

class _DriverHomeShellState extends State<DriverHomeShell> {
  /// Default active tab: Home (center item).
  int _currentIndex = 1;

  /// Timestamp of the last back press on the Home tab for 2-second double-tap exit.
  DateTime? _lastBackPressTime;

  static const Color _selectedColor = AppColors.seseGold;

  @override
  void initState() {
    super.initState();
    // Base user-topic push (verification + announcements). The driver
    // topic is additionally subscribed on go-online (dashboard).
    // ignore: discarded_futures
    PushNotificationService.subscribe('user_${widget.user.uid}');
    // Device token for targeted broadcasts (admin inbox + urgent alerts).
    // ignore: discarded_futures
    PushNotificationService.registerToken(
      uid: widget.user.uid,
      isDriver: true,
      country: CountryDetectionService.instance.currentCountryCode,
    );
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        MandatoryLegalAcceptanceDialog.checkAndShow(
          context,
          userId: widget.user.uid,
          userRole: 'driver',
        );
      }
    });
  }

  @override
  void dispose() {
    // ignore: discarded_futures
    PushNotificationService.unsubscribe('user_${widget.user.uid}');
    super.dispose();
  }

  /// Home tab index — the only tab where system back exits the app.
  static const int _homeIndex = 1;

  void _onTabTapped(int index) {
    if (index == _currentIndex) return;
    setState(() => _currentIndex = index);
  }

  void _handlePopInvoked(bool didPop) {
    if (didPop) return;

    // 1. From Sub-tabs (Menu, Trips, Help): return to Home tab
    if (_currentIndex != _homeIndex) {
      setState(() => _currentIndex = _homeIndex);
      return;
    }

    // 2. From Home tab: Require double-tap within 2 seconds to exit
    final now = DateTime.now();
    if (_lastBackPressTime == null ||
        now.difference(_lastBackPressTime!) > const Duration(seconds: 2)) {
      _lastBackPressTime = now;
      ScaffoldMessenger.of(context).removeCurrentSnackBar();
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Press back again to exit'),
          duration: Duration(seconds: 2),
        ),
      );
      return;
    }

    // Second press within 2s window: exit app cleanly without popping root route
    if (Navigator.of(context).canPop()) {
      Navigator.of(context).pop();
    } else {
      SystemNavigator.pop();
    }
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) => _handlePopInvoked(didPop),
      child: Scaffold(
        body: SafeArea(
          top: true,
          bottom: false,
          child: Column(
            children: [
              Expanded(
                child: IndexedStack(
                  index: _currentIndex,
                  children: [
                    _MenuTab(
                      user: widget.user,
                      auth: widget.auth,
                      onGoTrips: () => _onTabTapped(2),
                      onGoHelp: () => _onTabTapped(3),
                    ),
                    DriverDashboardScreen(
                      fleetService: DriverFleetService(),
                      user: widget.user,
                      driverId: widget.user.uid,
                      onSignOut: () async => widget.auth.signOut(),
                    ),
                    _TripsTab(
                      user: widget.user,
                      tripRepository: widget.tripRepository,
                    ),
                    _HelpTab(user: widget.user),
                  ],
                ),
              ),
            ],
          ),
        ),
        // Full-screen menu hub: hide the bottom bar while the Menu view
        // (index 0) is active; every menu tile routes to another tab, which
        // restores the bar.
        bottomNavigationBar: _currentIndex == 0 ? null : Builder(
          builder: (context) {
            // Single source of truth is AppTheme.bottomNavigationBarTheme
            // (light/dark variants follow Theme brightness). The shell only
            // reads it — never hardcodes bar colors — so the bar can never
            // get stuck dark in light mode (or vice versa) again.
            final barTheme = Theme.of(context).bottomNavigationBarTheme;
            final isDark = Theme.of(context).brightness == Brightness.dark;
            final barBg =
                barTheme.backgroundColor ?? Theme.of(context).cardColor;
            return Container(
              decoration: BoxDecoration(
                color: barBg,
                boxShadow: [
                  BoxShadow(
                    color: isDark ? Colors.black54 : Colors.black.withValues(alpha: 0.08),
                    blurRadius: 8,
                    offset: const Offset(0, -2),
                  ),
                ],
              ),
              child: BottomNavigationBar(
                type: barTheme.type ?? BottomNavigationBarType.fixed,
                currentIndex: _currentIndex,
                onTap: _onTabTapped,
                selectedItemColor:
                    barTheme.selectedItemColor ?? _selectedColor,
                unselectedItemColor: barTheme.unselectedItemColor,
                backgroundColor: barBg,
                elevation: 0,
                selectedFontSize: 12,
                unselectedFontSize: 12,
                items: const [
                  BottomNavigationBarItem(
                    icon: Icon(Icons.menu),
                    activeIcon: Icon(Icons.menu),
                    label: 'Menu',
                    tooltip: 'Menu',
                  ),
                  BottomNavigationBarItem(
                    icon: Icon(Icons.home_outlined),
                    activeIcon: Icon(Icons.home_rounded),
                    label: 'Home',
                    tooltip: 'Home',
                  ),
                  BottomNavigationBarItem(
                    icon: Icon(Icons.history),
                    activeIcon: Icon(Icons.history),
                    label: 'Trips',
                    tooltip: 'Trips',
                  ),
                  BottomNavigationBarItem(
                    icon: Icon(Icons.help_outline),
                    activeIcon: Icon(Icons.support_agent),
                    label: 'Help',
                    tooltip: 'Help',
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



/// Menu / drawer tab: account actions and navigation shortcuts.
class _MenuTab extends StatelessWidget {
  final AppUser user;
  final AuthRepository auth;

  /// Switches the shell's BottomNavigationBar to the Trips tab (index 3).
  final VoidCallback onGoTrips;

  /// Switches the shell's BottomNavigationBar to the Help tab (index 4).
  final VoidCallback onGoHelp;

  const _MenuTab({
    required this.user,
    required this.auth,
    required this.onGoTrips,
    required this.onGoHelp,
  });

  @override
  Widget build(BuildContext context) {
    // Strict menu order (top → bottom): Profile header, Wallet, Earnings,
    // Trips History, Support, Settings (#6, very bottom).
    // Go Online lives on the Home tab; Fleet, Theme, App Mode switching,
    // Sign Out, and Delete Account live in Settings — the menu stays a
    // launcher, not a junk drawer.
    //
    // The Menu tab hides the shell bottom bar (index 0 → null), so the list
    // owns the full viewport: always-scrollable physics plus bottom padding
    // that includes the system gesture inset, keeping the last tile clear
    // of the edge on tall and short screens alike.
    return Scaffold(
      appBar: const SeseAppBar(title: 'Menu'),
      body: SafeArea(
        top: false,
        bottom: false,
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
          padding: EdgeInsets.fromLTRB(
            16,
            12,
            16,
            32 + MediaQuery.viewPaddingOf(context).bottom,
          ),
          children: [
          Builder(
            builder: (cardContext) => Card(
              child: InkWell(
                key: const Key('menu_profile_card'),
                borderRadius: BorderRadius.circular(12),
                onTap: () => Navigator.of(cardContext).push(
                  MaterialPageRoute(
                    builder: (_) => DriverProfileScreen(user: user),
                  ),
                ),
                child: ListTile(
                  leading: UserAvatar(
                    displayName: user.fullName,
                    photoUrl: user.photoUrl,
                  ),
                  title:
                      Text(user.fullName.isEmpty ? 'Driver' : user.fullName),
                  subtitle: Text(user.email),
                  trailing: const Icon(Icons.chevron_right,
                      color: AppColors.seseGold),
                ),
              ),
            ),
          ),
          const SizedBox(height: 8),
          SettingsTile(
            tileKey: const Key('menu_wallet_tile'),
            tooltipId: 'menu_wallet',
            userId: user.uid,
            leading: const Icon(Icons.account_balance_wallet_outlined,
                color: AppColors.seseGold),
            title: 'Wallet',
            infoDescription:
                'Manage funds, top up, request payouts, and view transaction history.',
            trailing: const Icon(Icons.chevron_right, color: AppColors.seseGold),
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => WalletScreen(user: user)),
            ),
          ),
          SettingsTile(
            tileKey: const Key('menu_earnings_tile'),
            tooltipId: 'menu_earnings',
            userId: user.uid,
            leading: const Icon(Icons.bar_chart_outlined,
                color: AppColors.seseGold),
            title: 'Earnings',
            infoDescription:
                'View daily, weekly, and monthly trip earnings and streak progress.',
            trailing: const Icon(Icons.chevron_right, color: AppColors.seseGold),
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => EarningsScreen(user: user)),
            ),
          ),
          SettingsTile(
            tileKey: const Key('menu_referral_tile'),
            tooltipId: 'menu_referral',
            userId: user.uid,
            leading: const Icon(Icons.card_giftcard_outlined,
                color: AppColors.seseGold),
            title: 'Refer & Earn',
            infoDescription:
                'Invite friends & drivers to earn lifetime bonus coins.',
            trailing: const Icon(Icons.chevron_right, color: AppColors.seseGold),
            onTap: () => Navigator.of(context).push(MaterialPageRoute(
              builder: (_) => ReferralHubScreen(user: user),
            )),
          ),
          SettingsTile(
            tileKey: const Key('menu_trips_history_tile'),
            tooltipId: 'menu_trips_history',
            userId: user.uid,
            leading: const Icon(Icons.history, color: AppColors.seseGold),
            title: 'Trips History',
            infoDescription: 'Active trips and ride history.',
            trailing: const Icon(Icons.chevron_right, color: AppColors.seseGold),
            onTap: onGoTrips,
          ),
          SettingsTile(
            tileKey: const Key('menu_support_tile'),
            tooltipId: 'menu_support',
            userId: user.uid,
            leading: const Icon(Icons.help_outline, color: AppColors.seseGold),
            title: 'Support',
            infoDescription: '24/7 driver support, safety assistance, and FAQs.',
            trailing: const Icon(Icons.chevron_right, color: AppColors.seseGold),
            onTap: onGoHelp,
          ),
          SettingsTile(
            tileKey: const Key('menu_settings_tile'),
            tooltipId: 'menu_settings',
            userId: user.uid,
            leading: const Icon(Icons.settings_outlined, color: AppColors.seseGold),
            title: 'Settings',
            infoDescription:
                'Manage vehicles & fleet, order sound, theme, phone privacy, and account.',
            trailing: const Icon(Icons.chevron_right, color: AppColors.seseGold),
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute(
                builder: (_) => SettingsScreen(user: user, auth: auth, isDriver: true),
              ),
            ),
          ),
          const SizedBox(height: 16),
        ],
        ),
      ),
    );
  }
}

/// Ride History & Active Trips view.
class _TripsTab extends StatelessWidget {
  final AppUser user;
  final TripRepository? tripRepository;

  const _TripsTab({
    required this.user,
    this.tripRepository,
  });

  @override
  Widget build(BuildContext context) {
    return CustomerTripsScreen(
      customerId: user.uid,
      isDriver: true,
      tripRepository: tripRepository,
    );
  }
}

/// Driver Support & FAQ view.
class _HelpTab extends StatelessWidget {
  final AppUser user;

  const _HelpTab({required this.user});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: const SeseAppBar(title: 'Help'),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Card(
            child: ListTile(
              key: const Key('contact_driver_support_tile'),
              leading: const Icon(Icons.support_agent_rounded,
                  color: AppColors.seseGold),
              title: const Text('Contact Driver Support',
                  style: TextStyle(fontWeight: FontWeight.w600)),
              subtitle: Text(
                '24/7 in-app AI support for drivers',
                style: Theme.of(context).textTheme.bodySmall,
              ),
              trailing: const Icon(Icons.chevron_right,
                  color: AppColors.seseGold),
              onTap: () => Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (_) => SupportChatScreen(
                    user: user,
                    userRole: 'driver',
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(height: 16),
          Card(
            child: Column(
              children: const [
                ExpansionTile(
                  leading: Icon(Icons.help_outline_rounded,
                      color: AppColors.seseGold),
                  title: Text('How do I go online?',
                      style: TextStyle(fontWeight: FontWeight.w600)),
                  children: [
                    Padding(
                      padding: EdgeInsets.fromLTRB(16, 0, 16, 16),
                      child: Text(
                        'Register a vehicle in Manage Fleet, wait for admin '
                        'verification, then tap Go Online on the Home tab.',
                      ),
                    ),
                  ],
                ),
                ExpansionTile(
                  leading: Icon(Icons.account_balance_wallet_outlined,
                      color: AppColors.seseGold),
                  title: Text('When do I get paid?',
                      style: TextStyle(fontWeight: FontWeight.w600)),
                  children: [
                    Padding(
                      padding: EdgeInsets.fromLTRB(16, 0, 16, 16),
                      child: Text(
                        'Payouts settle to your wallet after each completed trip. '
                        'See the Earnings tab for details.',
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
