import 'package:flutter/material.dart';
import 'package:sese_core/sese_core.dart';
import '../../config/presentation/global_config_screen.dart';
import '../../config/services/system_config_service.dart';
import '../../notifications/presentation/broadcast_screen.dart';
import '../../payouts/presentation/hub_payout_desk_screen.dart';
import '../../settings/hub_settings_screen.dart';
import '../../staff/presentation/staff_management_screen.dart';
import '../../staff/services/hub_access_service.dart';
import '../../support/hub_support_chat_screen.dart';
import '../../verification/presentation/vehicle_approvals_screen.dart';
import '../../trips/presentation/active_rides_console_screen.dart';
import '../../onboarding/presentation/admin_user_onboarding_screen.dart';
import '../services/hub_route_persistence.dart';
import 'hub_user_wallet_card.dart';

/// Unified permission-gated hub shell. Mounted ONLY after [HubAccessService]
/// qualifies the user (see AuthGate in main.dart). There are no separate
/// Agent views — one tab set, filtered by `assignedPermissions`.
///
/// Mobile layout: **3 module slots + 1 "More" slot** in the bottom bar.
/// `_recentTabs` is a 3-item LRU queue: the 3 most recently visited module
/// tabs occupy the visible slots; everything else lives behind the More menu.
/// Selecting a tab from More promotes it to the LRU front and drops the
/// least-recently used module tab back into the More list.
///
/// Wide screens keep a full NavigationRail with every permitted tab.
///
/// RBAC note: visibility is controlled by [visibleTabs]; the More menu
/// only shows tabs the user is actually permitted to see — no tab can
/// leak through More that the rail would have hidden.
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

  /// Jurisdiction scope (`global` or a country code). Passed to screens
  /// whose data model carries a country field (Active Rides); `global`
  /// leaves every filter free.
  final String countryScope;

  const HubDashboardScreen({
    super.key,
    required this.configService,
    this.user,
    this.staffRole = UserRole.agent,
    this.isOwner = false,
    this.permissions = const [],
    this.countryScope = countryScopeGlobal,
  });

  @override
  State<HubDashboardScreen> createState() => _HubDashboardScreenState();
}

class _HubDashboardScreenState extends State<HubDashboardScreen>
    with WidgetsBindingObserver {
  /// Currently selected [HubTab] (may be profile or any module tab).
  HubTab _activeTab = HubTab.profile;

  /// Last 3 visited module tabs (not profile). Drives the bottom bar.
  /// Ordered newest-first; the oldest entry is the LRU and is evicted
  /// when a new tab is promoted from More.
  late List<HubTab> _recentTabs;

  /// Cache of instantiated screen widgets keeping state warm across tab switches.
  final Map<HubTab, Widget> _screenCache = {};

  final _auth = FirebaseAuthRepository(isHubApp: true);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // Staff push topics (support escalations + announcements). Mounted
    // only after hub_staff qualification, so subscribers are staff.
    // ignore: discarded_futures
    PushNotificationService.subscribe('admin_support_alerts');
    if ((widget.user?.email ?? '').isNotEmpty) {
      // ignore: discarded_futures
      PushNotificationService.subscribe(
          'staff_${widget.user!.email.trim().toLowerCase()}');
    }
    _initRecentTabs();
    _restorePersistedState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && (widget.user?.uid ?? '').isNotEmpty) {
        MandatoryLegalAcceptanceDialog.checkAndShow(
          context,
          userId: widget.user!.uid,
          userRole: 'hub_staff',
        );
      }
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.inactive ||
        state == AppLifecycleState.hidden) {
      _persistCurrentNavigation();
    }
  }

  void _persistCurrentNavigation() {
    HubRoutePersistence.saveActiveTab(_activeTab.name);
    HubRoutePersistence.saveRecentTabs(_recentTabs.map((t) => t.name).toList());
  }

  Future<void> _restorePersistedState() async {
    try {
      final savedTabName = await HubRoutePersistence.getSavedActiveTab();
      final savedRecentNames = await HubRoutePersistence.getSavedRecentTabs();
      final savedSubRoute = await HubRoutePersistence.getSavedSubRoute();

      if (!mounted) return;

      final allTabs = _allTabs;
      setState(() {
        if (savedRecentNames != null && savedRecentNames.isNotEmpty) {
          final restored = <HubTab>[];
          for (final name in savedRecentNames) {
            try {
              final tab = HubTab.values.byName(name);
              if (allTabs.contains(tab) && tab != HubTab.profile) {
                restored.add(tab);
              }
            } catch (_) {}
          }
          if (restored.isNotEmpty) {
            _recentTabs = restored;
          }
        }

        if (savedTabName != null) {
          try {
            final tab = HubTab.values.byName(savedTabName);
            if (allTabs.contains(tab)) {
              _activeTab = tab;
            }
          } catch (_) {}
        }
      });

      if (savedSubRoute != null && mounted) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted) return;
          if (savedSubRoute == 'settings') {
            Navigator.of(context).push(
              MaterialPageRoute(
                builder: (_) => HubSettingsScreen(
                  configService: widget.configService,
                ),
              ),
            ).then((_) {
              HubRoutePersistence.saveSubRoute(null);
            });
          }
        });
      }
    } catch (e) {
      debugPrint('HubDashboardScreen: error restoring persisted state: $e');
    }
  }

  /// Seed [_recentTabs] from the first (up to 3) module tabs the user can see.
  /// Profile is excluded — it is always reachable via the More avatar slot.
  void _initRecentTabs() {
    final moduleTabs =
        _allTabs.where((t) => t != HubTab.profile).toList();
    _recentTabs = moduleTabs.take(3).toList();
    _activeTab = _recentTabs.isNotEmpty ? _recentTabs.first : HubTab.profile;
  }

  /// Every tab the user is entitled to see (RBAC-filtered).
  List<HubTab> get _allTabs => visibleTabs(
        role: widget.staffRole,
        isOwner: widget.isOwner,
        permissions: widget.permissions,
      );

  /// Module tabs NOT currently in [_recentTabs]. These appear in the More menu.
  List<HubTab> get _moreTabs {
    final recent = _recentTabs.toSet();
    return _allTabs
        .where((t) => t != HubTab.profile && !recent.contains(t))
        .toList();
  }

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

  /// Build the page for a given [HubTab].
  ///
  /// Converted modules receive the staffer's RBAC context (permissions +
  /// role + ownership) so their side-sheet sections gate per-section, plus
  /// the jurisdiction scope for country-filtered data. Null RBAC context
  /// inside those screens means "no gate" (tests/direct mounts).
  Widget _screenFor(HubTab t) {
    switch (t) {
      case HubTab.activeRides:
        return ActiveRidesConsoleScreen(
          permissions: widget.permissions,
          staffRole: widget.staffRole,
          isOwner: widget.isOwner,
          lockedCountry: widget.countryScope,
        );
      case HubTab.fleet:
        return VehicleApprovalsScreen(
          permissions: widget.permissions,
          staffRole: widget.staffRole,
          isOwner: widget.isOwner,
        );
      case HubTab.onboarding:
        return const AdminUserOnboardingScreen();
      case HubTab.support:
        return const HubSupportChatScreen();
      case HubTab.payouts:
        return const HubPayoutDeskScreen();
      case HubTab.broadcast:
        return const BroadcastScreen();
      case HubTab.config:
        return GlobalConfigScreen(
          configService: widget.configService,
          permissions: widget.permissions,
          staffRole: widget.staffRole,
          isOwner: widget.isOwner,
        );
      case HubTab.staff:
        return StaffManagementScreen(
          staffEmail: widget.user?.email ?? '',
        );
      case HubTab.profile:
        return _ProfilePage(user: widget.user, onSignOut: _confirmSignOut);
    }
  }

  /// Body using [IndexedStack] to keep states of visited tabs warm across switches.
  Widget _buildStackBody(List<HubTab> allTabs) {
    _screenCache.putIfAbsent(_activeTab, () => _screenFor(_activeTab));
    final activeIndex = allTabs.indexOf(_activeTab);
    return IndexedStack(
      index: activeIndex >= 0 ? activeIndex : 0,
      children: allTabs.map((t) {
        if (_screenCache.containsKey(t)) {
          return _screenCache[t]!;
        }
        return const SizedBox.shrink();
      }).toList(),
    );
  }

  /// Navigate to [tab] directly (bottom bar or rail tap).
  void _onTabSelected(HubTab tab) {
    setState(() {
      _activeTab = tab;
      if (tab == HubTab.profile) {
        _persistCurrentNavigation();
        return;
      }
      if (_recentTabs.contains(tab)) {
        // Already in recent: bubble it to the front.
        _recentTabs.remove(tab);
        _recentTabs.insert(0, tab);
      } else {
        // Not in recent: evict LRU (last) and promote new tab to front.
        if (_recentTabs.length >= 3) _recentTabs.removeLast();
        _recentTabs.insert(0, tab);
      }
      _persistCurrentNavigation();
    });
  }

  /// Open the More bottom sheet, navigate to the selected tab, and
  /// promote it to [_recentTabs] (evicting the LRU module tab).
  Future<void> _openMoreMenu() async {
    final selected = await showModalBottomSheet<HubTab>(
      context: context,
      showDragHandle: true,
      useSafeArea: true,
      builder: (ctx) => _MoreMenuSheet(
        user: widget.user,
        firstName: _firstName,
        consoleTitle: _consoleTitle,
        moreTabs: _moreTabs,
        recentTabs: _recentTabs,
        allTabs: _allTabs,
        configService: widget.configService,
        onTabSelected: (t) => Navigator.of(ctx).pop(t),
        onSignOut: () {
          Navigator.of(ctx).pop();
          _confirmSignOut();
        },
        onOpenSettings: () {
          Navigator.of(ctx).pop();
          HubRoutePersistence.saveSubRoute('settings');
          Navigator.of(context).push(
            MaterialPageRoute(
              builder: (_) => HubSettingsScreen(
                configService: widget.configService,
              ),
            ),
          ).then((_) {
            HubRoutePersistence.saveSubRoute(null);
          });
        },
      ),
    );
    if (selected == null || !mounted) return;
    setState(() {
      _activeTab = selected;
      if (selected != HubTab.profile) {
        // Evict LRU (last entry) and promote new tab to front.
        if (_recentTabs.length >= 3) _recentTabs.removeLast();
        _recentTabs.insert(0, selected);
      }
      _persistCurrentNavigation();
    });
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
      // Primary redirect: the hub's StreamBuilder auth gate observes the null
      // auth state and replaces the root with LoginPage automatically.
      // Belt-and-suspenders: pop to root in case the stream fires slowly on iOS.
      if (mounted && Navigator.of(context).canPop()) {
        Navigator.of(context).popUntil((route) => route.isFirst);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final allTabs = _allTabs;

    // Safe-guard: if activeTab was removed by a permission change, reset.
    if (!allTabs.contains(_activeTab)) {
      _activeTab = HubTab.profile;
    }

    final stackBody = _buildStackBody(allTabs);

    // Wide screens keep a full side rail.
    return LayoutBuilder(
      builder: (context, constraints) {
        final isWide = constraints.maxWidth >= 900;
        if (isWide) {
          return _buildWideLayout(allTabs, stackBody);
        }

        // Mobile: lone tab renders bar-less (NavigationBar asserts >= 2).
        if (allTabs.length < 2) {
          return Scaffold(body: stackBody);
        }
        return _buildMobileLayout(stackBody);
      },
    );
  }

  Widget _buildWideLayout(List<HubTab> allTabs, Widget stackBody) {
    final safeIndex = allTabs.contains(_activeTab)
        ? allTabs.indexOf(_activeTab)
        : 0;
    return Scaffold(
      body: Row(
        children: [
          NavigationRail(
            selectedIndex: safeIndex,
            onDestinationSelected: (i) => _onTabSelected(allTabs[i]),
            labelType: NavigationRailLabelType.all,
            leading: _RailProfileHeader(
              user: widget.user,
              firstName: _firstName,
              consoleTitle: _consoleTitle,
            ),
            destinations: [
              for (final t in allTabs)
                NavigationRailDestination(
                  icon: Icon(_iconFor(t, selected: false)),
                  selectedIcon: Icon(_iconFor(t, selected: true)),
                  label: Text(_labelFor(t)),
                ),
            ],
          ),
          Expanded(child: stackBody),
        ],
      ),
    );
  }

  Widget _buildMobileLayout(Widget stackBody) {
    // Bottom bar always has _recentTabs (up to 3) + "More" (always last).
    final bottomTabs = _recentTabs.toList();
    final moreSelected = !bottomTabs.contains(_activeTab) &&
        _activeTab != HubTab.profile;
    // Profile is accessed via the More sheet's avatar tap.
    final profileSelected = _activeTab == HubTab.profile;

    // Bottom bar index:
    //   0..(bottomTabs.length-1) → recent module tabs
    //   bottomTabs.length        → "More" / Profile avatar
    int selectedIndex;
    if (profileSelected || moreSelected) {
      selectedIndex = bottomTabs.length; // More selected
    } else {
      final i = bottomTabs.indexOf(_activeTab);
      selectedIndex = i >= 0 ? i : 0;
    }

    // Clamp: NavigationBar needs >= 2 destinations.
    final destinations = <NavigationDestination>[
      for (final t in bottomTabs)
        NavigationDestination(
          key: Key('hub_nav_${t.name}'),
          icon: Icon(_iconFor(t, selected: false)),
          selectedIcon: Icon(_iconFor(t, selected: true)),
          label: _labelFor(t),
        ),
      // The "More" destination carries the user's avatar and label.
      NavigationDestination(
        key: const Key('hub_nav_more'),
        icon: widget.user != null
            ? UserAvatar(
                displayName: widget.user!.fullName,
                photoUrl: widget.user!.photoUrl,
                radius: 12,
              )
            : const Icon(Icons.grid_view_outlined),
        selectedIcon: widget.user != null
            ? UserAvatar(
                displayName: widget.user!.fullName,
                photoUrl: widget.user!.photoUrl,
                radius: 12,
              )
            : const Icon(Icons.grid_view),
        label: 'More',
      ),
    ];

    return Scaffold(
      body: stackBody,
      bottomNavigationBar: NavigationBar(
        key: const Key('hub_navigation_bar'),
        selectedIndex: selectedIndex,
        labelBehavior: NavigationDestinationLabelBehavior.alwaysShow,
        onDestinationSelected: (i) {
          if (i == bottomTabs.length) {
            // More / avatar tapped.
            _openMoreMenu();
          } else {
            _onTabSelected(bottomTabs[i]);
          }
        },
        destinations: destinations,
      ),
    );
  }

  static String _labelFor(HubTab tab) {
    switch (tab) {
      case HubTab.activeRides:
        return 'Active Rides';
      case HubTab.fleet:
        return 'Fleet & Security';
      case HubTab.onboarding:
        return 'User Onboarding';
      case HubTab.support:
        return 'Support Inbox';
      case HubTab.payouts:
        return 'Payouts';
      case HubTab.broadcast:
        return 'Broadcasts';
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
      case HubTab.activeRides:
        return selected ? Icons.alt_route : Icons.alt_route_outlined;
      case HubTab.fleet:
        return selected ? Icons.verified_user : Icons.verified_user_outlined;
      case HubTab.onboarding:
        return selected ? Icons.person_add : Icons.person_add_outlined;
      case HubTab.support:
        return selected ? Icons.mark_chat_read : Icons.mark_chat_read_outlined;
      case HubTab.payouts:
        return selected ? Icons.payments : Icons.payments_outlined;
      case HubTab.broadcast:
        return selected ? Icons.campaign : Icons.campaign_outlined;
      case HubTab.config:
        return selected ? Icons.tune : Icons.tune_outlined;
      case HubTab.staff:
        return selected ? Icons.group : Icons.group_outlined;
      case HubTab.profile:
        return selected ? Icons.person : Icons.person_outline;
    }
  }
}

/// Full-screen "More" bottom sheet listing all overflow + profile options.
/// Mirrors the customer/driver app drawer aesthetic with sections.
class _MoreMenuSheet extends StatelessWidget {
  final AppUser? user;
  final String firstName;
  final String consoleTitle;

  /// Tabs that appear only in this More sheet (not already in the 3 bottom slots).
  final List<HubTab> moreTabs;

  /// Tabs currently in the 3 bottom slots. Shown in a secondary "Recent"
  /// section so the user can still reach them from this sheet.
  final List<HubTab> recentTabs;

  /// All tabs the user may see (for RBAC-consistent display).
  final List<HubTab> allTabs;

  final ValueChanged<HubTab> onTabSelected;
  final VoidCallback onSignOut;

  /// Opens [HubSettingsScreen] (Notifications, Appearance, Security, Config).
  final VoidCallback onOpenSettings;

  /// Required so [HubSettingsScreen] can construct [GlobalConfigScreen].
  final SystemConfigService configService;

  const _MoreMenuSheet({
    required this.user,
    required this.firstName,
    required this.consoleTitle,
    required this.moreTabs,
    required this.recentTabs,
    required this.allTabs,
    required this.onTabSelected,
    required this.onSignOut,
    required this.onOpenSettings,
    required this.configService,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final overflowTabs = moreTabs;

    return SafeArea(
      child: SingleChildScrollView(
        padding: EdgeInsets.zero,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // ── Profile header ──────────────────────────────────────────────
            InkWell(
              key: const Key('hub_more_profile_tile'),
              onTap: () => onTabSelected(HubTab.profile),
              child: Padding(
                padding:
                    const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
                child: Row(
                  children: [
                    if (user != null)
                      UserAvatar(
                        displayName: user!.fullName,
                        photoUrl: user!.photoUrl,
                        radius: 24,
                      )
                    else
                      CircleAvatar(
                        radius: 24,
                        backgroundColor: scheme.primary,
                        child: const Icon(Icons.hub, color: Colors.white),
                      ),
                    const SizedBox(width: 14),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            user?.fullName.isNotEmpty == true
                                ? user!.fullName
                                : firstName,
                            style: const TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                          Text(
                            consoleTitle,
                            style: TextStyle(
                              fontSize: 12,
                              color: scheme.onSurfaceVariant,
                            ),
                          ),
                        ],
                      ),
                    ),
                    Icon(Icons.chevron_right, color: scheme.onSurfaceVariant),
                  ],
                ),
              ),
            ),
            const Divider(height: 1),

            // ── Overflow module tabs ────────────────────────────────────────
            if (overflowTabs.isNotEmpty) ...[
              Padding(
                padding:
                    const EdgeInsets.fromLTRB(20, 14, 20, 4),
                child: Text(
                  'All Modules',
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                    color: scheme.onSurfaceVariant,
                    letterSpacing: 0.8,
                  ),
                ),
              ),
              for (final t in overflowTabs)
                _MoreTile(
                  key: Key('hub_more_tab_${t.name}'),
                  icon: _HubDashboardScreenState._iconFor(t, selected: false),
                  selectedIcon:
                      _HubDashboardScreenState._iconFor(t, selected: true),
                  label: _HubDashboardScreenState._labelFor(t),
                  onTap: () => onTabSelected(t),
                ),
              const Divider(height: 1),
            ],

            // ── Settings / Logout ───────────────────────────────────────────
            const SizedBox(height: 8),
            _MoreTile(
              key: const Key('hub_more_settings_tile'),
              icon: Icons.settings_outlined,
              selectedIcon: Icons.settings,
              label: 'Settings',
              onTap: onOpenSettings,
            ),
            _MoreTile(
              key: const Key('hub_more_theme_tile'),
              icon: Icons.brightness_6_outlined,
              selectedIcon: Icons.brightness_6,
              label: 'Theme / Appearance',
              onTap: () {
                Navigator.of(context).pop();
                showHubThemePickerSheet(context, ThemeController.instance);
              },
            ),
            _MoreTile(
              key: const Key('hub_more_signout_tile'),
              icon: Icons.logout,
              selectedIcon: Icons.logout,
              label: 'Sign Out',
              onTap: onSignOut,
              isDestructive: true,
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }
}

class _MoreTile extends StatelessWidget {
  final IconData icon;
  final IconData selectedIcon;
  final String label;
  final VoidCallback onTap;
  final bool isDestructive;

  const _MoreTile({
    super.key,
    required this.icon,
    required this.selectedIcon,
    required this.label,
    required this.onTap,
    this.isDestructive = false,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final color = isDestructive ? scheme.error : null;
    return ListTile(
      leading: Icon(icon, color: color),
      title: Text(label, style: color != null ? TextStyle(color: color) : null),
      trailing: Icon(Icons.chevron_right,
          size: 18, color: scheme.onSurfaceVariant),
      onTap: onTap,
    );
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
        // 16px outer gutters keep the card edge-to-edge on phones; the
        // 480 cap only centers it on wide screens.
        padding: const EdgeInsets.all(16),
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 480),
            child: Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                // Center keeps the avatar/name block centered; the card
                // itself already spans the gutter width via Center +
                // ConstrainedBox(maxWidth: 480), so no stretch is needed
                // here (stretch would left-align the fixed-size avatar).
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
                      const SizedBox(height: 16),
                      HubUserWalletCard(userId: u.uid),
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
                    ListTile(
                      key: const Key('hub_terms_tile'),
                      leading: const Icon(Icons.description_outlined),
                      title: const Text('Terms of Use'),
                      trailing: const Icon(Icons.chevron_right),
                      onTap: () => LegalDocumentViewer.showTerms(context),
                    ),
                    ListTile(
                      key: const Key('hub_privacy_policy_tile'),
                      leading: const Icon(Icons.privacy_tip_outlined),
                      title: const Text('Privacy Policy'),
                      trailing: const Icon(Icons.chevron_right),
                      onTap: () => LegalDocumentViewer.showPrivacy(context),
                    ),
                    const SizedBox(height: 16),
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
                  // 16px gutters match the option rows below.
                  padding: EdgeInsets.fromLTRB(16, 8, 16, 4),
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
