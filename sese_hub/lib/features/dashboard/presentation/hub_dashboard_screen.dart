import 'package:flutter/material.dart';
import 'package:sese_core/sese_core.dart';
import '../../config/presentation/global_config_screen.dart';
import '../../config/services/system_config_service.dart';
import '../../payouts/presentation/hub_payout_desk_screen.dart';
import '../../staff/presentation/staff_management_screen.dart';
import '../../staff/services/hub_access_service.dart';
import '../../support/hub_support_chat_screen.dart';
import '../../verification/presentation/vehicle_approvals_screen.dart';

/// Unified permission-gated hub shell. Mounted ONLY after [HubAccessService]
/// qualifies the user (see AuthGate in main.dart). There are no separate
/// Agent views — one tab set, filtered by `assignedPermissions`.
///
/// Visibility (see [visibleTabs] — drives BOTH the wide side rail and the
/// mobile bottom bar, so a tab can never leak through one layout):
/// - Owner: every tab (permanent master control).
/// - Super role: every module tab.
/// - Anyone else: ONLY tabs in their `assignedPermissions`; Profile always.
/// Logout lives solely inside the Profile screen — never in the nav bar.
class HubDashboardScreen extends StatefulWidget {
  final SystemConfigService configService;
  final AppUser? user;

  /// Authoritative staff role from the silent `hub_staff` check.
  final UserRole staffRole;

  /// Owner-exclusive provisioning (Add Staff) renders only when true.
  final bool isOwner;

  /// Assigned module permissions from the staffer's `hub_staff` record.
  /// Tabs without an explicit grant are hidden automatically.
  final List<String> permissions;

  const HubDashboardScreen({
    super.key,
    required this.configService,
    this.user,
    this.staffRole = UserRole.agent,
    this.isOwner = false,
    this.permissions = const [],
  });

  @override
  State<HubDashboardScreen> createState() => _HubDashboardScreenState();
}

class _HubDashboardScreenState extends State<HubDashboardScreen> {
  int _selectedIndex = 0;
  final _auth = FirebaseAuthRepository(isHubApp: true);

  @override
  void initState() {
    super.initState();
    // Staff push topics (support escalations + announcements). Mounted
    // only after hub_staff qualification, so subscribers are staff.
    // ignore: discarded_futures
    PushNotificationService.subscribe('admin_support_alerts');
    if ((widget.user?.email ?? '').isNotEmpty) {
      // ignore: discarded_futures
      PushNotificationService.subscribe(
          'staff_${widget.user!.email.trim().toLowerCase()}');
    }
  }

  List<HubTab> get _tabs => visibleTabs(
        role: widget.staffRole,
        isOwner: widget.isOwner,
        permissions: widget.permissions,
      );

  String get _consoleTitle {
    switch (widget.staffRole) {
      case UserRole.superRole:
        return 'Super Admin Console';
      case UserRole.admin:
        return 'Admin Console';
      case UserRole.agent:
        return 'Operations Console';
      case UserRole.customer:
      case UserRole.driver:
        return 'Sese Hub';
    }
  }

  String get _firstName {
    final full = widget.user?.fullName.trim() ?? '';
    if (full.isEmpty) return 'Bamiduro';
    return full.split(RegExp(r'\s+')).first;
  }

  List<Widget> get _screens => _tabs.map((t) {
        switch (t) {
          case HubTab.fleet:
            return const VehicleApprovalsScreen();
          case HubTab.support:
            return const HubSupportChatScreen();
          case HubTab.payouts:
            return const HubPayoutDeskScreen();
          case HubTab.config:
            return GlobalConfigScreen(configService: widget.configService);
          case HubTab.staff:
            return StaffManagementScreen(
              staffEmail: widget.user?.email ?? '',
            );
          case HubTab.profile:
            return _ProfilePage(user: widget.user, onSignOut: _confirmSignOut);
        }
      }).toList();

  void _onDestinationSelected(int index) {
    setState(() => _selectedIndex = index);
  }

  Future<void> _confirmSignOut() async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Sign out?'),
        content: const Text('You will be signed out of Sese Hub.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Sign Out'),
          ),
        ],
      ),
    );
    if (confirm == true) {
      await _auth.signOut();
    }
  }

  @override
  Widget build(BuildContext context) {
    final tabs = _tabs;
    final safeIndex =
        _selectedIndex < tabs.length ? _selectedIndex : 0;
    final screens = _screens;

    // Wide screens keep a side rail; mobile widths use a bottom bar.
    // Logout appears nowhere here — Profile screen only.
    return LayoutBuilder(
      builder: (context, constraints) {
        final isWide = constraints.maxWidth >= 900;
        if (isWide) {
          return Scaffold(
            body: Row(
              children: [
                NavigationRail(
                  selectedIndex: safeIndex,
                  onDestinationSelected: _onDestinationSelected,
                  labelType: NavigationRailLabelType.all,
                  leading: _RailProfileHeader(
                    user: widget.user,
                    firstName: _firstName,
                    consoleTitle: _consoleTitle,
                  ),
                  destinations: [
                    for (final t in tabs)
                      NavigationRailDestination(
                        icon: Icon(_iconFor(t, selected: false)),
                        selectedIcon: Icon(_iconFor(t, selected: true)),
                        label: Text(_labelFor(t)),
                      ),
                  ],
                ),
                Expanded(
                  child: IndexedStack(
                    index: safeIndex,
                    children: screens,
                  ),
                ),
              ],
            ),
          );
        }

        // Mobile / narrow: bottom navigation bar. A lone tab renders
        // bar-less (NavigationBar asserts >= 2 destinations) — reachable
        // only in tests, since the auth gate blocks permission-less
        // staffers before they ever get here.
        if (tabs.length < 2) {
          return Scaffold(
            body: IndexedStack(
              index: safeIndex,
              children: screens,
            ),
          );
        }
        return Scaffold(
          body: IndexedStack(
            index: safeIndex,
            children: screens,
          ),
          bottomNavigationBar: NavigationBar(
            selectedIndex: safeIndex,
            onDestinationSelected: _onDestinationSelected,
            labelBehavior:
                NavigationDestinationLabelBehavior.alwaysShow,
            destinations: [
              for (final t in tabs)
                if (t == HubTab.profile)
                  NavigationDestination(
                    icon: widget.user != null
                        ? UserAvatar(
                            displayName: widget.user!.fullName,
                            photoUrl: widget.user!.photoUrl,
                            radius: 12,
                          )
                        : const Icon(Icons.person_outline),
                    selectedIcon: widget.user != null
                        ? UserAvatar(
                            displayName: widget.user!.fullName,
                            photoUrl: widget.user!.photoUrl,
                            radius: 12,
                          )
                        : const Icon(Icons.person),
                    label: _firstName,
                  )
                else
                  NavigationDestination(
                    icon: Icon(_iconFor(t, selected: false)),
                    selectedIcon: Icon(_iconFor(t, selected: true)),
                    label: _labelFor(t),
                  ),
            ],
          ),
        );
      },
    );
  }

  static String _labelFor(HubTab tab) {
    switch (tab) {
      case HubTab.fleet:
        return 'Fleet & Security';
      case HubTab.support:
        return 'Support Inbox';
      case HubTab.payouts:
        return 'Payouts';
      case HubTab.config:
        return 'Dynamic Config';
      case HubTab.staff:
        return 'Staff';
      case HubTab.profile:
        return 'Profile';
    }
  }

  static IconData _iconFor(HubTab tab, {required bool selected}) {
    switch (tab) {
      case HubTab.fleet:
        return selected ? Icons.verified_user : Icons.verified_user_outlined;
      case HubTab.support:
        return selected ? Icons.mark_chat_read : Icons.mark_chat_read_outlined;
      case HubTab.payouts:
        return selected ? Icons.payments : Icons.payments_outlined;
      case HubTab.config:
        return selected ? Icons.tune : Icons.tune_outlined;
      case HubTab.staff:
        return selected ? Icons.group : Icons.group_outlined;
      case HubTab.profile:
        return selected ? Icons.person : Icons.person_outline;
    }
  }
}

class _RailProfileHeader extends StatelessWidget {
  final AppUser? user;
  final String firstName;
  final String consoleTitle;

  const _RailProfileHeader({
    required this.user,
    required this.firstName,
    required this.consoleTitle,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 8),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (user != null)
            UserAvatar(
              displayName: user!.fullName,
              photoUrl: user!.photoUrl,
              radius: 20,
            )
          else
            CircleAvatar(
              backgroundColor: Theme.of(context).colorScheme.primary,
              child: const Icon(Icons.hub, color: Colors.white),
            ),
          const SizedBox(height: 8),
          Text(
            user != null && user!.fullName.isNotEmpty
                ? firstName
                : 'STAFF',
            style: const TextStyle(fontSize: 11, fontWeight: FontWeight.bold),
            overflow: TextOverflow.ellipsis,
          ),
          Text(
            consoleTitle,
            style: TextStyle(fontSize: 9, color: Colors.grey.shade600),
            overflow: TextOverflow.ellipsis,
            textAlign: TextAlign.center,
          ),
        ],
      ),
    );
  }
}

/// Simple profile page so the Profile avatar/name lives in the
/// navigation bar, not a side panel.
class _ProfilePage extends StatelessWidget {
  final AppUser? user;
  final VoidCallback onSignOut;

  const _ProfilePage({required this.user, required this.onSignOut});

  @override
  Widget build(BuildContext context) {
    final u = user;
    return Scaffold(
      appBar: AppBar(title: const Text('Profile')),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 480),
            child: Card(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (u != null)
                      UserAvatar(
                        displayName: u.fullName,
                        photoUrl: u.photoUrl,
                        radius: 36,
                      )
                    else
                      CircleAvatar(
                        radius: 36,
                        backgroundColor:
                            Theme.of(context).colorScheme.primary,
                        child: const Icon(Icons.person,
                            color: Colors.white, size: 36),
                      ),
                    const SizedBox(height: 16),
                    Text(
                      u?.fullName.isNotEmpty == true
                          ? u!.fullName
                          : 'Bamiduro',
                      style: const TextStyle(
                          fontSize: 20, fontWeight: FontWeight.bold),
                      textAlign: TextAlign.center,
                    ),
                    if (u != null) ...[
                      const SizedBox(height: 4),
                      Text(u.email,
                          style: TextStyle(
                              color: Colors.grey.shade600, fontSize: 13)),
                    ],
                    const SizedBox(height: 24),
                    ValueListenableBuilder<ThemeMode>(
                      valueListenable: ThemeController.instance,
                      builder: (context, mode, _) {
                        return ListTile(
                          key: const Key('hub_theme_tile'),
                          leading: const Icon(Icons.brightness_6_outlined),
                          title: const Text('Theme / Appearance'),
                          subtitle: Text(mode.label),
                          trailing: const Icon(Icons.chevron_right),
                          onTap: () => showHubThemePickerSheet(
                              context, ThemeController.instance),
                        );
                      },
                    ),
                    const SizedBox(height: 8),
                    SizedBox(
                      width: double.infinity,
                      child: OutlinedButton.icon(
                        icon: const Icon(Icons.logout),
                        label: const Text('Sign Out'),
                        onPressed: onSignOut,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Modal bottom sheet to pick [ThemeMode.system] (default, follows the OS)
/// / [ThemeMode.light] / [ThemeMode.dark]. Persists via [ThemeController]
/// (SharedPreferences) across restarts.
Future<void> showHubThemePickerSheet(
  BuildContext context,
  ThemeController controller,
) {
  return showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    builder: (sheetContext) {
      return ValueListenableBuilder<ThemeMode>(
        valueListenable: controller,
        builder: (context, mode, _) {
          Widget option({
            required ThemeMode value,
            required IconData icon,
            required String title,
            required String subtitle,
          }) {
            final selected = mode == value;
            return ListTile(
              leading: Icon(icon),
              title: Text(title),
              subtitle: Text(subtitle),
              trailing: selected
                  ? Icon(
                      Icons.check_circle,
                      color: Theme.of(context).colorScheme.primary,
                    )
                  : const Icon(Icons.circle_outlined),
              onTap: () async {
                await controller.setTheme(value);
                if (sheetContext.mounted) {
                  Navigator.of(sheetContext).pop();
                }
              },
            );
          }

          return SafeArea(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Padding(
                  padding: EdgeInsets.fromLTRB(20, 8, 20, 4),
                  child: Text(
                    'Theme / Appearance',
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
                option(
                  value: ThemeMode.system,
                  icon: Icons.settings_suggest_outlined,
                  title: 'System Default',
                  subtitle: 'Follow device settings',
                ),
                option(
                  value: ThemeMode.light,
                  icon: Icons.light_mode_outlined,
                  title: 'Light Mode',
                  subtitle: 'Always use the light theme',
                ),
                option(
                  value: ThemeMode.dark,
                  icon: Icons.dark_mode_outlined,
                  title: 'Dark Mode',
                  subtitle: 'Always use the dark theme',
                ),
                const SizedBox(height: 8),
              ],
            ),
          );
        },
      );
    },
  );
}
