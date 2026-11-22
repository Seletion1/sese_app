import 'dart:async';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../../staff/services/hub_access_service.dart' show HubTab;

/// One sub-section inside a Hub module: title + icon + content + the
/// permission code required to see it (null = no extra gate beyond the
/// module tab itself).
class HubModuleSection {
  final String id;
  final String title;
  final IconData icon;
  final Widget child;

  /// Fine-grained permission code (e.g. `config_pricing`). When non-null,
  /// [HubModuleShell] shows the section only if [isSectionVisible]
  /// returns true for it.
  final String? permission;

  /// Optional live count stream for dynamic badge display in navigation tiles.
  final Stream<int>? badgeStream;

  const HubModuleSection({
    required this.id,
    required this.title,
    required this.icon,
    required this.child,
    this.permission,
    this.badgeStream,
  });
}

/// Context snapshot of a mounted [HubModuleShell] communicating its sub-sections,
/// active index, and switch action up to [HubDashboardScreen] without coupling.
class HubModuleContext {
  final String title;
  final List<HubModuleSection> sections;
  final int selectedIndex;
  final void Function(int index, String sectionId) onSelectSection;
  final Map<int, int> sectionCounts;

  const HubModuleContext({
    required this.title,
    required this.sections,
    required this.selectedIndex,
    required this.onSelectSection,
    this.sectionCounts = const {},
  });
}

/// InheritedWidget providing a [ValueNotifier] where child [HubModuleShell]s
/// register their sub-sections for the parent [HubDashboardScreen] Profile drawer.
class HubTabScope extends InheritedWidget {
  final HubTab tab;
  final ValueNotifier<HubModuleContext?> notifier;

  const HubTabScope({
    super.key,
    required this.tab,
    required this.notifier,
    required super.child,
  });

  static HubTabScope? maybeOf(BuildContext context) {
    return context.dependOnInheritedWidgetOfExactType<HubTabScope>();
  }

  @override
  bool updateShouldNotify(HubTabScope oldWidget) =>
      tab != oldWidget.tab || notifier != oldWidget.notifier;
}

/// Single-section module shell for sese_hub: only ONE sub-section renders
/// in the body at a time (no deep vertical scrolling). A persistent Menu
/// icon at the top-right of the AppBar slides open a LEFT-hand side sheet
/// ([Drawer]) listing every visible sub-section; tapping an item navigates
/// instantly and closes the sheet, and tapping the scrim dismisses it.
///
/// Section visibility is permission-filtered BEFORE the list is built, so
/// staff never see (or can navigate to) sections outside their grants. The
/// first visible section is selected automatically; if none is visible, a
/// permission notice renders instead of an empty shell. Section widgets
/// stay mounted in an [IndexedStack] so scroll positions and loaded streams
/// survive section switches.
class HubModuleShell extends StatefulWidget {
  final String title;
  final List<HubModuleSection> sections;
  final int initialIndex;

  /// Extra AppBar actions rendered BEFORE the Menu icon (Menu stays at the
  /// top-right edge).
  final List<Widget>? actions;

  /// Returns true when the staffer may see [section]. Sections failing the
  /// check are excluded from the sheet AND the body (no hidden routes).
  final bool Function(HubModuleSection section)? isSectionVisible;

  const HubModuleShell({
    super.key,
    required this.title,
    required this.sections,
    this.initialIndex = 0,
    this.actions,
    this.isSectionVisible,
  });

  @override
  State<HubModuleShell> createState() => _HubModuleShellState();
}

class _HubModuleShellState extends State<HubModuleShell> {
  late int _index;
  bool _userHasSelectedSection = false;
  final Map<int, int> _sectionCounts = {};
  final List<StreamSubscription<int>> _badgeSubscriptions = [];

  String get _prefKey =>
      'hub_module_section_${widget.title.replaceAll(RegExp(r'\s+'), '_').toLowerCase()}';

  @override
  void initState() {
    super.initState();
    _index = widget.initialIndex;
    _restoreSavedSection();
    _listenToSectionBadges();
  }

  @override
  void dispose() {
    _cancelBadgeSubscriptions();
    super.dispose();
  }

  void _listenToSectionBadges() {
    _cancelBadgeSubscriptions();
    final visible = _visible;
    for (int i = 0; i < visible.length; i++) {
      final sectionIndex = i;
      final stream = visible[i].badgeStream;
      if (stream != null) {
        final sub = stream.listen((count) {
          if (!mounted) return;
          _sectionCounts[sectionIndex] = count;
          _updateParentScope();
          if (!_userHasSelectedSection) {
            final currentIndex = _index.clamp(0, visible.length - 1);
            final currentCount = _sectionCounts[currentIndex] ?? 0;
            if (currentCount <= 0) {
              final pendingIndex = _firstSectionWithPendingWork(visible);
              if (pendingIndex != -1 && pendingIndex != _index) {
                setState(() => _index = pendingIndex);
              }
            }
          }
        }, onError: (_) {});
        _badgeSubscriptions.add(sub);
      }
    }
  }

  int _firstSectionWithPendingWork(List<HubModuleSection> visible) {
    for (int i = 0; i < visible.length; i++) {
      if ((_sectionCounts[i] ?? 0) > 0) {
        return i;
      }
    }
    return -1;
  }

  void _cancelBadgeSubscriptions() {
    for (final sub in _badgeSubscriptions) {
      sub.cancel();
    }
    _badgeSubscriptions.clear();
  }

  Future<void> _restoreSavedSection() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final savedId = prefs.getString(_prefKey);
      if (savedId != null && mounted) {
        final visible = _visible;
        final found = visible.indexWhere((s) => s.id == savedId);
        if (found != -1 && found != _index) {
          setState(() => _index = found);
          _updateParentScope();
        }
      }
    } catch (_) {}
  }

  void _selectSection(int i, String sectionId) {
    _userHasSelectedSection = true;
    setState(() => _index = i);
    _updateParentScope();
    SharedPreferences.getInstance().then((prefs) {
      prefs.setString(_prefKey, sectionId);
    }).catchError((_) {});
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _updateParentScope();
  }

  @override
  void didUpdateWidget(covariant HubModuleShell oldWidget) {
    super.didUpdateWidget(oldWidget);
    final visible = _visible;
    if (visible.isNotEmpty && _index >= visible.length) {
      _index = visible.length - 1;
    }
    if (oldWidget.sections != widget.sections) {
      _listenToSectionBadges();
    }
    _updateParentScope();
  }

  void _updateParentScope() {
    final scope = HubTabScope.maybeOf(context);
    if (scope == null) return;
    final visible = _visible;
    final index = visible.isEmpty ? 0 : _index.clamp(0, visible.length - 1);
    scope.notifier.value = HubModuleContext(
      title: widget.title,
      sections: visible,
      selectedIndex: index,
      onSelectSection: _selectSection,
      sectionCounts: Map<int, int>.unmodifiable(_sectionCounts),
    );
  }

  List<HubModuleSection> get _visible {
    final check = widget.isSectionVisible;
    if (check == null) return widget.sections;
    return widget.sections.where(check).toList();
  }

  @override
  Widget build(BuildContext context) {
    final visible = _visible;
    final index = visible.isEmpty ? 0 : _index.clamp(0, visible.length - 1);
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.title),
        actions: widget.actions,
        automaticallyImplyLeading: false,
      ),
      body: visible.isEmpty
          ? const Center(
              child: Padding(
                padding: EdgeInsets.all(24),
                child: Text(
                  'No sections assigned. Please contact administration for access.',
                  textAlign: TextAlign.center,
                ),
              ),
            )
          : IndexedStack(
              index: index,
              children: [for (final s in visible) s.child],
            ),
    );
  }
}
