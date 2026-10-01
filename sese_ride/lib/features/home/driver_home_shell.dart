import 'package:flutter/material.dart';
import 'package:sese_core/sese_core.dart';
import '../driver/presentation/driver_dashboard_screen.dart';
import '../driver/presentation/driver_profile_screen.dart';
import '../driver/services/driver_fleet_service.dart';
import '../home/customer_home_shell.dart';
import '../settings/role_controller.dart';
import '../settings/screens/settings_screen.dart';
import '../support/support_chat_screen.dart';
import '../wallet/earnings_screen.dart';
import '../wallet/wallet_screen.dart';

/// Role-gated container strictly for Driver users, scoped to the driver's
/// real authenticated UID.
///
/// Hosts a 5-item [BottomNavigationBar] (Menu | Earnings | Home | Trips | Help)
/// with an [IndexedStack] so each tab keeps its state (notably the Driver Map
/// / Go Online view) when switching tabs.
class DriverHomeShell extends StatefulWidget {
  final AppUser user;
  final AuthRepository auth;

  const DriverHomeShell({
    super.key,
    required this.user,
    required this.auth,
  });

  @override
  State<DriverHomeShell> createState() => _DriverHomeShellState();
}

class _DriverHomeShellState extends State<DriverHomeShell> {
  /// Default active tab: Home (center item).
  int _currentIndex = 2;

  /// Timestamp of the last back press on the Home tab for 2-second double-tap exit.
  DateTime? _lastBackPressTime;

  static const Color _selectedColor = AppColors.seseGold;
  static const Color _unselectedColor = Color(0xFF757575);

  @override
  void initState() {
    super.initState();
    // Base user-topic push (verification + announcements). The driver
    // topic is additionally subscribed on go-online (dashboard).
    // ignore: discarded_futures
    PushNotificationService.subscribe('user_${widget.user.uid}');
  }

  @override
  void dispose() {
    // ignore: discarded_futures
    PushNotificationService.unsubscribe('user_${widget.user.uid}');
    super.dispose();
  }

  /// Home tab index — the only tab where system back exits the app.
  static const int _homeIndex = 2;

  void _onTabTapped(int index) {
    if (index == _currentIndex) return;
    setState(() => _currentIndex = index);
  }

  void _handlePopInvoked(bool didPop) {
    if (didPop) return;

    // 1. From Sub-tabs (Menu, Earnings, Trips, Help): return to Home tab
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

    // Second press within 2s window: pop and exit app
    Navigator.of(context).pop();
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
                      onGoTrips: () => _onTabTapped(3),
                      onGoHelp: () => _onTabTapped(4),
                    ),
                    EarningsScreen(user: widget.user),
                    DriverDashboardScreen(
                      fleetService: DriverFleetService(),
                      user: widget.user,
                      driverId: widget.user.uid,
                      onSignOut: () => widget.auth.signOut(),
                    ),
                    const _TripsTab(),
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
      bottomNavigationBar: _currentIndex == 0 ? null : Container(
        decoration: BoxDecoration(
          color: Theme.of(context).cardColor,
          boxShadow: [
            BoxShadow(
              color: Theme.of(context).brightness == Brightness.dark
                  ? Colors.black54
                  : Colors.black.withValues(alpha: 0.08),
              blurRadius: 8,
              offset: const Offset(0, -2),
            ),
          ],
        ),
        child: BottomNavigationBar(
          type: BottomNavigationBarType.fixed,
          currentIndex: _currentIndex,
          onTap: _onTabTapped,
          selectedItemColor: _selectedColor,
          unselectedItemColor: _unselectedColor,
          backgroundColor: Theme.of(context).cardColor,
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
              icon: Icon(Icons.account_balance_wallet_outlined),
              activeIcon: Icon(Icons.account_balance_wallet),
              label: 'Earnings',
              tooltip: 'Earnings',
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

  Future<void> _handleSwitchToCustomer(BuildContext context) async {
    final hasActiveTrip =
        await RoleController.instance.checkDriverHasActiveTrip(user.uid);
    if (!context.mounted) return;

    RoleController.instance.setCurrentRole(UserRole.customer);

    if (hasActiveTrip) {
      RoleController.instance.startActiveTripCountdown(
        onExpired: () {
          debugPrint('Active trip protection timer expired: auto-switching to Driver Mode');
          RoleController.instance.setCurrentRole(UserRole.driver);
          Navigator.of(context).pushAndRemoveUntil(
            MaterialPageRoute(
              builder: (_) => DriverHomeShell(user: user, auth: auth),
            ),
            (route) => false,
          );
        },
      );
    } else {
      RoleController.instance.cancelActiveTripCountdown();
    }

    Navigator.of(context).pushAndRemoveUntil(
      MaterialPageRoute(
        builder: (_) => CustomerHomeShell(user: user, auth: auth),
      ),
      (route) => false,
    );
  }

  @override
  Widget build(BuildContext context) {
    // Strict menu order (top → bottom): Profile header, Wallet, Earnings,
    // Trips History, Support, Settings (#6), Switch mode (#7, very bottom).
    // Go Online lives on the Home tab; Fleet, Theme, Sign Out, and Delete
    // Account live in Settings — the menu stays a launcher, not a junk drawer.
    return Scaffold(
      appBar: AppBar(title: const Text('Menu')),
      body: ListView(
        padding: const EdgeInsets.all(16),
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
          Builder(
            builder: (tileContext) => ListTile(
              key: const Key('menu_wallet_tile'),
              leading: const Icon(Icons.account_balance_wallet_outlined,
                  color: AppColors.seseGold),
              title: const Text('Wallet'),
              subtitle: const Text(
                  'Manage funds, top up, request payouts, and view '
                  'transaction history'),
              trailing: const Icon(Icons.chevron_right,
                  color: AppColors.seseGold),
              onTap: () => Navigator.of(tileContext).push(
                MaterialPageRoute(
                  builder: (_) => WalletScreen(user: user),
                ),
              ),
            ),
          ),
          Builder(
            builder: (tileContext) => ListTile(
              key: const Key('menu_earnings_tile'),
              leading: const Icon(Icons.bar_chart_outlined,
                  color: AppColors.seseGold),
              title: const Text('Earnings'),
              subtitle: const Text(
                  'View daily, weekly, and monthly trip earnings and '
                  'streak progress'),
              trailing: const Icon(Icons.chevron_right,
                  color: AppColors.seseGold),
              onTap: () => Navigator.of(tileContext).push(
                MaterialPageRoute(
                  builder: (_) => EarningsScreen(user: user),
                ),
              ),
            ),
          ),
          ListTile(
            key: const Key('menu_trips_history_tile'),
            leading:
                const Icon(Icons.history, color: AppColors.seseGold),
            title: const Text('Trips History'),
            subtitle: const Text('Active trips and ride history'),
            trailing: const Icon(Icons.chevron_right,
                color: AppColors.seseGold),
            onTap: onGoTrips,
          ),
          ListTile(
            key: const Key('menu_support_tile'),
            leading:
                const Icon(Icons.help_outline, color: AppColors.seseGold),
            title: const Text('Support'),
            subtitle: const Text('24/7 driver support and FAQs'),
            trailing: const Icon(Icons.chevron_right,
                color: AppColors.seseGold),
            onTap: onGoHelp,
          ),
          ListTile(
            key: const Key('menu_settings_tile'),
            leading:
                const Icon(Icons.settings_outlined, color: AppColors.seseGold),
            title: const Text('Settings'),
            subtitle: const Text('Fleet, sound, theme, privacy, account'),
            trailing: const Icon(Icons.chevron_right,
                color: AppColors.seseGold),
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute(
                builder: (_) => SettingsScreen(
                  user: user,
                  auth: auth,
                  isDriver: true,
                ),
              ),
            ),
          ),
          const SizedBox(height: 8),
          ListTile(
            key: const Key('menu_switch_mode_tile'),
            leading: const Icon(Icons.swap_horiz, color: AppColors.seseGold),
            title: const Text('Switch to Customer Mode'),
            subtitle: const Text('Book rides & deliveries as a customer'),
            trailing: const Icon(Icons.chevron_right, color: AppColors.seseGold),
            onTap: () => _handleSwitchToCustomer(context),
          ),
        ],
      ),
    );
  }
}

/// Ride History & Active Trips view.
class _TripsTab extends StatelessWidget {
  const _TripsTab();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Trips')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: const [
          Card(
            child: ListTile(
              leading: Icon(Icons.directions_car_outlined),
              title: Text('Active trips'),
              subtitle: Text('No active trips. Go online to receive offers.'),
            ),
          ),
          SizedBox(height: 8),
          Card(
            child: ListTile(
              leading: Icon(Icons.history),
              title: Text('Ride history'),
              subtitle: Text('Completed trips will appear here.'),
            ),
          ),
        ],
      ),
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
      appBar: AppBar(title: const Text('Help')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Card(
            child: ListTile(
              key: const Key('contact_driver_support_tile'),
              leading: const Icon(Icons.support_agent,
                  color: AppColors.seseGold),
              title: const Text('Contact Driver Support'),
              subtitle:
                  const Text('24/7 in-app AI support for drivers'),
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
          const SizedBox(height: 8),
          ExpansionTile(
            leading: Icon(Icons.help_outline),
            title: Text('How do I go online?'),
            children: [
              Padding(
                padding: EdgeInsets.all(16),
                child: Text(
                  'Register a vehicle in Manage Fleet, wait for admin '
                  'verification, then tap Go Online on the Home tab.',
                ),
              ),
            ],
          ),
          ExpansionTile(
            leading: Icon(Icons.help_outline),
            title: Text('When do I get paid?'),
            children: [
              Padding(
                padding: EdgeInsets.all(16),
                child: Text(
                  'Payouts settle to your wallet after each completed trip. '
                  'See the Earnings tab for details.',
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
