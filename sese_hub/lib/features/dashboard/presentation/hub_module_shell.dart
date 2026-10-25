import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

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

  const HubModuleSection({
    required this.id,
    required this.title,
    required this.icon,
    required this.child,
    this.permission,
  });
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
  String get _prefKey =>
      'hub_module_section_${widget.title.replaceAll(RegExp(r'\s+'), '_').toLowerCase()}';

  @override
  void initState() {
    super.initState();
    _index = widget.initialIndex;
    _restoreSavedSection();
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
        }
      }
    } catch (_) {}
  }

  void _selectSection(int i, String sectionId) {
    setState(() => _index = i);
    SharedPreferences.getInstance().then((prefs) {
      prefs.setString(_prefKey, sectionId);
    }).catchError((_) {});
  }

  @override
  void didUpdateWidget(covariant HubModuleShell oldWidget) {
    super.didUpdateWidget(oldWidget);
    final visible = _visible;
    if (visible.isNotEmpty && _index >= visible.length) {
      _index = visible.length - 1;
    }
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
        actions: [
          ...(widget.actions ?? const []),
          // Builder: opening the drawer needs a context under this Scaffold.
          Builder(
            builder: (ctx) => IconButton(
              key: const Key('hub_module_menu_button'),
              icon: const Icon(Icons.menu),
              tooltip: 'Module sections',
              onPressed: visible.isEmpty
                  ? null
                  : () => Scaffold.of(ctx).openDrawer(),
            ),
          ),
        ],
      ),
      drawer: visible.isEmpty
          ? null
          : Drawer(
              child: SafeArea(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Padding(
                      padding: const EdgeInsets.fromLTRB(20, 12, 20, 8),
                      child: Text(
                        widget.title,
                        style: Theme.of(context)
                            .textTheme
                            .titleSmall
                            ?.copyWith(fontWeight: FontWeight.bold),
                      ),
                    ),
                    const Divider(height: 1),
                    Expanded(
                      child: ListView.builder(
                        itemCount: visible.length,
                        itemBuilder: (_, i) {
                          final s = visible[i];
                          final selected = i == index;
                          return ListTile(
                            key: Key('hub_section_${s.id}'),
                            leading: Icon(
                              s.icon,
                              color: selected
                                  ? Theme.of(context).colorScheme.primary
                                  : null,
                            ),
                            title: Text(
                              s.title,
                              style: TextStyle(
                                fontWeight: selected
                                    ? FontWeight.bold
                                    : FontWeight.normal,
                              ),
                            ),
                            selected: selected,
                            selectedTileColor: Theme.of(context)
                                .colorScheme
                                .primary
                                .withValues(alpha: 0.08),
                            trailing: selected
                                ? Icon(
                                    Icons.check_circle,
                                    color: Theme.of(context)
                                        .colorScheme
                                        .primary,
                                    size: 20,
                                  )
                                : null,
                            onTap: () {
                              Navigator.of(context).pop();
                              _selectSection(i, s.id);
                            },
                          );
                        },
                      ),
                    ),
                  ],
                ),
              ),
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
