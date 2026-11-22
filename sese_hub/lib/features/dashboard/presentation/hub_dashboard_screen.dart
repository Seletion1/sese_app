import 'dart:async';
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
import '../services/hub_pending_counts_service.dart';
import '../services/hub_route_persistence.dart';
import '../services/view_mode_controller.dart';
import '../../../widgets/hub_badge.dart';
import 'hub_module_shell.dart' show HubModuleContext, HubTabScope;
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

  /// Per-tab sub-section context notifiers registered by child [HubModuleShell]s.
  final Map<HubTab, ValueNotifier<HubModuleContext?>> _moduleNotifiers = {};

  ValueNotifier<HubModuleContext?> _notifierFor(HubTab tab) {
    return _moduleNotifiers.putIfAbsent(
      tab,
      () => ValueNotifier<HubModuleContext?>(null),
    );
  }

  final _auth = FirebaseAuthRepository(isHubApp: true);
  StreamSubscription? _networkReconnectSub;

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
    _networkReconnectSub =
        NetworkStatusService.instance.onReconnected.listen((_) {
      if (mounted) {
        debugPrint(
            'HubDashboardScreen: Connection restored, forcing state re-sync.');
        setState(() {});
      }
    });
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
    for (final notifier in _moduleNotifiers.values) {
      notifier.dispose();
    }
    _networkReconnectSub?.cancel();
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
        return _ProfilePage(
          user: widget.user,
          staffRole: widget.staffRole,
          permissions: widget.permissions,
          onSignOut: _confirmSignOut,
        );
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
          return HubTabScope(
            tab: t,
            notifier: _notifierFor(t),
            child: _screenCache[t]!,
          );
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

  final _scaffoldKey = GlobalKey<ScaffoldState>();

  /// Opens [HubSettingsScreen] (Profile, Notifications, Appearance, Security, Config).
  void _openSettings() {
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
  }

  /// Open the right-side profile and section sub-list drawer.
  void _openProfileOrSubListMenu() {
    _scaffoldKey.currentState?.openEndDrawer();
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
      await HubRoutePersistence.clearSavedNavigation();
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

  Stream<int>? _streamForTab(HubTab tab) {
    final service = HubPendingCountsService();
    switch (tab) {
      case HubTab.fleet:
        return service.fleetTotalPendingCountStream;
      case HubTab.onboarding:
        return service.onboardingTotalPendingCountStream;
      case HubTab.support:
        return service.pendingSupportChatsCountStream;
      case HubTab.payouts:
        return service.pendingPayoutsCountStream;
      default:
        return null;
    }
  }

  Widget _buildTabIcon(HubTab tab, {required bool selected}) {
    final icon = Icon(_iconFor(tab, selected: selected));
    final stream = _streamForTab(tab);
    if (stream == null) return icon;

    return StreamBuilder<int>(
      stream: stream,
      builder: (context, snapshot) {
        final count = snapshot.data ?? 0;
        if (count <= 0) return icon;
        return Badge(
          label: Text(count > 99 ? '99+' : '$count'),
          backgroundColor: Colors.red.shade700,
          child: icon,
        );
      },
    );
  }

  Widget _buildWideLayout(List<HubTab> allTabs, Widget stackBody) {
    final safeIndex = allTabs.contains(_activeTab)
        ? allTabs.indexOf(_activeTab)
        : 0;
    return Scaffold(
      body: SafeArea(
        child: Row(
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
                    icon: _buildTabIcon(t, selected: false),
                    selectedIcon: _buildTabIcon(t, selected: true),
                    label: Text(_labelFor(t)),
                  ),
              ],
            ),
            const VerticalDivider(thickness: 1, width: 1),
            Expanded(child: stackBody),
          ],
        ),
      ),
    );
  }

  Widget _buildMobileLayout(Widget stackBody) {
    final moduleTabs = _allTabs.where((t) => t != HubTab.profile).toList();
    final isProfileSelected = _activeTab == HubTab.profile;

    final overflowStreams = moduleTabs
        .map((t) => _streamForTab(t))
        .whereType<Stream<int>>()
        .toList();
    final Stream<int>? profileBadgeStream = overflowStreams.isNotEmpty
        ? HubPendingCountsService.combineStreams(overflowStreams)
        : null;

    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    return Scaffold(
      key: _scaffoldKey,
      endDrawer: _HubProfileAndSectionDrawer(
        user: widget.user,
        firstName: _firstName,
        consoleTitle: _consoleTitle,
        allTabs: _allTabs,
        activeTab: _activeTab,
        activeModuleNotifier: _notifierFor(_activeTab),
        configService: widget.configService,
        onTabSelected: _onTabSelected,
        onSignOut: _confirmSignOut,
        onOpenSettings: _openSettings,
      ),
      body: stackBody,
      bottomNavigationBar: SafeArea(
        top: false,
        child: Container(
          key: const Key('hub_navigation_bar'),
          height: 74,
          decoration: BoxDecoration(
            color: scheme.surface,
            border: Border(
              top: BorderSide(
                color: scheme.outlineVariant.withValues(alpha: 0.35),
                width: 1,
              ),
            ),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.04),
                blurRadius: 4,
                offset: const Offset(0, -1),
              ),
            ],
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              // 1. Horizontally Scrollable Section Buttons
              Expanded(
                child: SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  physics: const BouncingScrollPhysics(),
                  padding:
                      const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      for (final t in moduleTabs)
                        _HubSectionButton(
                          key: Key('hub_nav_${t.name}'),
                          tab: t,
                          isSelected: _activeTab == t,
                          icon: _buildTabIcon(t, selected: _activeTab == t),
                          label: _labelFor(t),
                          onTap: () => _onTabSelected(t),
                        ),
                    ],
                  ),
                ),
              ),

              // Vertical subtle divider between scrollable sections and pinned Profile
              Container(
                height: 38,
                width: 1,
                color: scheme.outlineVariant.withValues(alpha: 0.3),
              ),

              // 2. Stationary / Pinned Profile Button (does NOT scroll)
              SizedBox(
                width: 76,
                child: _HubPinnedProfileButton(
                  key: const Key('hub_nav_more'),
                  user: widget.user,
                  isSelected: isProfileSelected,
                  badgeStream: profileBadgeStream,
                  onTap: _openProfileOrSubListMenu,
                ),
              ),
            ],
          ),
        ),
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

/// Horizontally scrollable section button widget for the mobile bottom bar.
class _HubSectionButton extends StatelessWidget {
  final HubTab tab;
  final bool isSelected;
  final Widget icon;
  final String label;
  final VoidCallback onTap;

  const _HubSectionButton({
    super.key,
    required this.tab,
    required this.isSelected,
    required this.icon,
    required this.label,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final primaryColor = scheme.primary;

    return Semantics(
      button: true,
      selected: isSelected,
      label: label,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(16),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
          margin: const EdgeInsets.symmetric(horizontal: 2, vertical: 1),
          decoration: BoxDecoration(
            color: isSelected
                ? primaryColor.withValues(alpha: 0.14)
                : Colors.transparent,
            borderRadius: BorderRadius.circular(16),
            border: isSelected
                ? Border.all(
                    color: primaryColor.withValues(alpha: 0.35),
                    width: 1.2,
                  )
                : null,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              AnimatedContainer(
                duration: const Duration(milliseconds: 200),
                padding: const EdgeInsets.all(2),
                decoration: BoxDecoration(
                  color: isSelected
                      ? primaryColor.withValues(alpha: 0.18)
                      : Colors.transparent,
                  shape: BoxShape.circle,
                ),
                child: icon,
              ),
              const SizedBox(height: 2),
              Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 10.5,
                  fontWeight: isSelected ? FontWeight.w700 : FontWeight.w500,
                  color: isSelected ? primaryColor : scheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Stationary / pinned Profile button on the right side of the bottom bar.
class _HubPinnedProfileButton extends StatelessWidget {
  final AppUser? user;
  final bool isSelected;
  final VoidCallback onTap;
  final Stream<int>? badgeStream;

  const _HubPinnedProfileButton({
    super.key,
    required this.user,
    required this.isSelected,
    required this.onTap,
    this.badgeStream,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final primaryColor = scheme.primary;

    Widget buildBaseAvatar() => user != null
        ? UserAvatar(
            displayName: user!.fullName,
            photoUrl: user!.photoUrl,
            radius: 12,
          )
        : Icon(
            isSelected ? Icons.person : Icons.person_outline,
            size: 20,
            color: isSelected ? primaryColor : scheme.onSurfaceVariant,
          );

    final Widget avatarWidget = badgeStream != null
        ? StreamBuilder<int>(
            stream: badgeStream,
            builder: (context, snapshot) {
              final count = snapshot.data ?? 0;
              final base = buildBaseAvatar();
              if (count <= 0) return base;
              return Badge(
                label: Text(count > 99 ? '99+' : '$count'),
                backgroundColor: Colors.red.shade700,
                child: base,
              );
            },
          )
        : buildBaseAvatar();

    return Semantics(
      button: true,
      selected: isSelected,
      label: 'Profile',
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(16),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
          margin: const EdgeInsets.symmetric(horizontal: 2, vertical: 1),
          decoration: BoxDecoration(
            color: isSelected
                ? primaryColor.withValues(alpha: 0.14)
                : Colors.transparent,
            borderRadius: BorderRadius.circular(16),
            border: isSelected
                ? Border.all(
                    color: primaryColor.withValues(alpha: 0.35),
                    width: 1.2,
                  )
                : null,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Container(
                padding: const EdgeInsets.all(1.5),
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  border: Border.all(
                    color: isSelected
                        ? primaryColor
                        : scheme.outlineVariant.withValues(alpha: 0.6),
                    width: 1.4,
                  ),
                ),
                child: avatarWidget,
              ),
              const SizedBox(height: 2),
              Text(
                'Profile',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 10.5,
                  fontWeight: isSelected ? FontWeight.w700 : FontWeight.w500,
                  color: isSelected ? primaryColor : scheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Unified Profile & Section Sub-List drawer.
///
/// Combines the staff profile header (where tapping the avatar opens Profile Settings),
/// any active section's sub-list items (e.g. KYC approvals, vehicle registrations),
/// navigation shortcuts for all modules, and system actions (Settings, Theme, Sign Out).
class _HubProfileAndSectionDrawer extends StatelessWidget {
  final AppUser? user;
  final String firstName;
  final String consoleTitle;
  final List<HubTab> allTabs;
  final HubTab activeTab;
  final ValueNotifier<HubModuleContext?> activeModuleNotifier;
  final ValueChanged<HubTab> onTabSelected;
  final VoidCallback onSignOut;
  final VoidCallback onOpenSettings;
  final SystemConfigService configService;

  const _HubProfileAndSectionDrawer({
    required this.user,
    required this.firstName,
    required this.consoleTitle,
    required this.allTabs,
    required this.activeTab,
    required this.activeModuleNotifier,
    required this.onTabSelected,
    required this.onSignOut,
    required this.onOpenSettings,
    required this.configService,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    return Drawer(
      child: SafeArea(
        child: ValueListenableBuilder<HubModuleContext?>(
          valueListenable: activeModuleNotifier,
          builder: (context, moduleContext, _) {
            final hasSubSections =
                moduleContext != null && moduleContext.sections.isNotEmpty;

            return SingleChildScrollView(
              padding: EdgeInsets.zero,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  // ── Admin Profile Header ─────────────────────────────────────
                  // Tapping the profile picture OR the tile directly opens Profile Settings
                  InkWell(
                    key: const Key('hub_more_profile_tile'),
                    onTap: () {
                      Navigator.of(context).pop();
                      onOpenSettings();
                    },
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 18, vertical: 16),
                      child: Row(
                        children: [
                          GestureDetector(
                            key: const Key('hub_profile_avatar_tap'),
                            onTap: () {
                              Navigator.of(context).pop();
                              onOpenSettings();
                            },
                            child: Stack(
                              clipBehavior: Clip.none,
                              children: [
                                if (user != null)
                                  UserAvatar(
                                    displayName: user!.fullName,
                                    photoUrl: user!.photoUrl,
                                    radius: 26,
                                  )
                                else
                                  CircleAvatar(
                                    radius: 26,
                                    backgroundColor: scheme.primary,
                                    child: const Icon(Icons.hub,
                                        color: Colors.white, size: 28),
                                  ),
                                Positioned(
                                  right: -2,
                                  bottom: -2,
                                  child: Container(
                                    padding: const EdgeInsets.all(3),
                                    decoration: BoxDecoration(
                                      color: scheme.primary,
                                      shape: BoxShape.circle,
                                      border: Border.all(
                                          color: scheme.surface, width: 2),
                                    ),
                                    child: const Icon(
                                      Icons.settings,
                                      size: 11,
                                      color: Colors.black87,
                                    ),
                                  ),
                                ),
                              ],
                            ),
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
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                    fontSize: 16,
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                                const SizedBox(height: 2),
                                Text(
                                  consoleTitle,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    fontSize: 12,
                                    color: scheme.onSurfaceVariant,
                                  ),
                                ),
                                const SizedBox(height: 2),
                                Text(
                                  'Tap avatar for Settings',
                                  style: TextStyle(
                                    fontSize: 10.5,
                                    color: scheme.primary,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                              ],
                            ),
                          ),
                          Icon(Icons.chevron_right,
                              color: scheme.onSurfaceVariant),
                        ],
                      ),
                    ),
                  ),
                  const Divider(height: 1),

                  // ── Active Section Sub-List (when active module has multiple items) ────
                  if (hasSubSections) ...[
                    Padding(
                      padding: const EdgeInsets.fromLTRB(18, 14, 18, 6),
                      child: Row(
                        children: [
                          Icon(Icons.subdirectory_arrow_right,
                              size: 16, color: scheme.primary),
                          const SizedBox(width: 6),
                          Expanded(
                            child: Text(
                              moduleContext.title,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontSize: 11,
                                fontWeight: FontWeight.w700,
                                color: scheme.primary,
                                letterSpacing: 0.6,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                    for (int i = 0; i < moduleContext.sections.length; i++) ...[
                      Builder(builder: (context) {
                        final s = moduleContext.sections[i];
                        final isSelected = i == moduleContext.selectedIndex;
                        final count = moduleContext.sectionCounts[i] ?? 0;
                        return ListTile(
                          key: Key('hub_section_${s.id}'),
                          dense: true,
                          leading: Icon(
                            s.icon,
                            color: isSelected
                                ? scheme.primary
                                : scheme.onSurfaceVariant,
                            size: 22,
                          ),
                          title: Text(
                            s.title,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 13.5,
                              fontWeight: isSelected
                                  ? FontWeight.bold
                                  : FontWeight.w500,
                              color: isSelected ? scheme.primary : null,
                            ),
                          ),
                          selected: isSelected,
                          selectedTileColor:
                              scheme.primary.withValues(alpha: 0.08),
                          trailing: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              if (count > 0) HubCountBadge(count: count),
                              if (isSelected) ...[
                                const SizedBox(width: 8),
                                Icon(
                                  Icons.check_circle,
                                  color: scheme.primary,
                                  size: 18,
                                ),
                              ],
                            ],
                          ),
                          onTap: () {
                            Navigator.of(context).pop();
                            moduleContext.onSelectSection(i, s.id);
                          },
                        );
                      }),
                    ],
                    const Divider(height: 1),
                  ],

                  // ── All Modules / Quick Navigation Shortcuts ─────────────────
                  Padding(
                    padding: const EdgeInsets.fromLTRB(18, 14, 18, 4),
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
                  for (final t in allTabs.where((t) => t != HubTab.profile))
                    _MoreTile(
                      key: Key('hub_more_tab_${t.name}'),
                      icon: _HubDashboardScreenState._iconFor(t,
                          selected: t == activeTab),
                      selectedIcon:
                          _HubDashboardScreenState._iconFor(t, selected: true),
                      label: _HubDashboardScreenState._labelFor(t),
                      badgeStream: _streamForTab(t),
                      onTap: () {
                        Navigator.of(context).pop();
                        onTabSelected(t);
                      },
                    ),
                  const Divider(height: 1),

                  // ── Settings, Theme, and Sign Out ─────────────────────────────
                  const SizedBox(height: 6),
                  _MoreTile(
                    key: const Key('hub_more_settings_tile'),
                    icon: Icons.settings_outlined,
                    selectedIcon: Icons.settings,
                    label: 'Profile Settings',
                    onTap: () {
                      Navigator.of(context).pop();
                      onOpenSettings();
                    },
                  ),
                  _MoreTile(
                    key: const Key('hub_more_theme_tile'),
                    icon: Icons.brightness_6_outlined,
                    selectedIcon: Icons.brightness_6,
                    label: 'Theme / Appearance',
                    onTap: () {
                      Navigator.of(context).pop();
                      showHubThemePickerSheet(
                          context, ThemeController.instance);
                    },
                  ),
                  _MoreTile(
                    key: const Key('hub_more_signout_tile'),
                    icon: Icons.logout,
                    selectedIcon: Icons.logout,
                    label: 'Sign Out',
                    onTap: () {
                      Navigator.of(context).pop();
                      onSignOut();
                    },
                    isDestructive: true,
                  ),
                  const SizedBox(height: 12),
                ],
              ),
            );
          },
        ),
      ),
    );
  }

  static Stream<int>? _streamForTab(HubTab tab) {
    final service = HubPendingCountsService();
    switch (tab) {
      case HubTab.fleet:
        return service.fleetTotalPendingCountStream;
      case HubTab.onboarding:
        return service.onboardingTotalPendingCountStream;
      case HubTab.support:
        return service.pendingSupportChatsCountStream;
      case HubTab.payouts:
        return service.pendingPayoutsCountStream;
      default:
        return null;
    }
  }
}

class _MoreTile extends StatelessWidget {
  final IconData icon;
  final IconData selectedIcon;
  final String label;
  final VoidCallback onTap;
  final bool isDestructive;
  final Stream<int>? badgeStream;

  const _MoreTile({
    super.key,
    required this.icon,
    required this.selectedIcon,
    required this.label,
    required this.onTap,
    this.isDestructive = false,
    this.badgeStream,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final color = isDestructive ? scheme.error : null;
    return ListTile(
      leading: Icon(icon, color: color),
      title: Text(label, style: color != null ? TextStyle(color: color) : null),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (badgeStream != null)
            HubCountBadge.stream(stream: badgeStream!),
          Icon(Icons.chevron_right, size: 18, color: scheme.onSurfaceVariant),
        ],
      ),
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
          const SizedBox(height: 6),
          ValueListenableBuilder<HubViewMode>(
            valueListenable: ViewModeController.instance,
            builder: (context, mode, _) {
              if (mode == HubViewMode.desktop) {
                return IconButton(
                  key: const Key('rail_switch_to_mobile_btn'),
                  icon: const Icon(Icons.phone_android, size: 16, color: Color(0xFFE2B714)),
                  tooltip: 'Switch to Mobile View',
                  onPressed: () => ViewModeController.instance.setViewMode(HubViewMode.auto),
                );
              }
              return const SizedBox.shrink();
            },
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
  final UserRole staffRole;
  final List<String> permissions;
  final VoidCallback onSignOut;

  const _ProfilePage({
    required this.user,
    this.staffRole = UserRole.agent,
    this.permissions = const [],
    required this.onSignOut,
  });

  @override
  Widget build(BuildContext context) {
    final u = user;
    final seq = u?.sequentialId ?? '';
    final staffSeqId = seq.startsWith('SH') ? seq : 'SH0001';

    return Scaffold(
      appBar: AppBar(
        title: const Text('Profile'),
        actions: [
          ValueListenableBuilder<HubViewMode>(
            valueListenable: ViewModeController.instance,
            builder: (context, mode, _) {
              if (mode == HubViewMode.desktop) {
                return TextButton.icon(
                  key: const Key('profile_switch_to_mobile_btn'),
                  style: TextButton.styleFrom(
                    foregroundColor: const Color(0xFFE2B714),
                  ),
                  icon: const Icon(Icons.phone_android, size: 18),
                  label: const Text(
                    'Mobile View',
                    style: TextStyle(fontWeight: FontWeight.bold),
                  ),
                  onPressed: () => ViewModeController.instance.setViewMode(HubViewMode.auto),
                );
              }
              return const SizedBox.shrink();
            },
          ),
        ],
      ),
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
                      const SizedBox(height: 10),
                      Wrap(
                        spacing: 8,
                        runSpacing: 6,
                        alignment: WrapAlignment.center,
                        children: [
                          Chip(
                            avatar: const Icon(Icons.badge_outlined,
                                size: 16, color: Color(0xFFE2B714)),
                            label: Text(
                              'Staff ID: $staffSeqId',
                              style: const TextStyle(
                                  fontWeight: FontWeight.bold, fontSize: 12),
                            ),
                            backgroundColor: Theme.of(context)
                                .colorScheme
                                .surfaceContainerHighest,
                          ),
                          Chip(
                            avatar: const Icon(Icons.shield_outlined,
                                size: 16, color: Colors.blue),
                            label: Text(
                              'Role: ${staffRole.name.toUpperCase()}',
                              style: const TextStyle(
                                  fontWeight: FontWeight.w600, fontSize: 12),
                            ),
                            backgroundColor: Theme.of(context)
                                .colorScheme
                                .surfaceContainerHighest,
                          ),
                        ],
                      ),
                      const SizedBox(height: 16),
                      HubUserWalletCard(
                        userId: u.uid,
                        role: 'hub',
                        sequentialId: staffSeqId,
                        targetLabel: 'Staff Ledger • $staffSeqId',
                      ),
                    ],
                    const SizedBox(height: 24),
                    ValueListenableBuilder<HubViewMode>(
                      valueListenable: ViewModeController.instance,
                      builder: (context, currentMode, _) {
                        return ListTile(
                          key: const Key('hub_view_mode_tile'),
                          leading: const Icon(Icons.desktop_windows_outlined),
                          title: const Text('Layout View Mode'),
                          subtitle: Text(currentMode.label),
                          trailing: DropdownButton<HubViewMode>(
                            value: currentMode,
                            underline: const SizedBox.shrink(),
                            items: HubViewMode.values
                                .map(
                                  (m) => DropdownMenuItem(
                                    value: m,
                                    child: Text(
                                      m.label,
                                      style: const TextStyle(fontSize: 13),
                                    ),
                                  ),
                                )
                                .toList(),
                            onChanged: (val) {
                              if (val != null) {
                                ViewModeController.instance.setViewMode(val);
                              }
                            },
                          ),
                        );
                      },
                    ),
                    const SizedBox(height: 8),
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
