import 'package:flutter/material.dart';

/// Standard branded AppBar component for SeSe applications.
///
/// Thin wrapper over [AppBar] that enforces the house style defined in
/// [AppTheme.appBarTheme]: zero elevation, 60 px height, bold title, and a
/// 1 px divider on scroll. Back-button styling is inherited from the theme so
/// it adapts to light/dark automatically.
///
/// Implements [PreferredSizeWidget] so it can be passed directly to
/// [Scaffold.appBar]. Supports custom title, leading icon, action buttons,
/// and bottom widgets (e.g. [TabBar]).
class SeseAppBar extends StatelessWidget implements PreferredSizeWidget {
  final String title;
  final Widget? leading;
  final List<Widget>? actions;
  final PreferredSizeWidget? bottom;

  /// Whether to horizontally centre the title. Defaults to `false` (start-
  /// aligned), consistent with Material 3 and the house AppBarTheme.
  final bool centerTitle;

  /// Override the title widget entirely (e.g. a [SeSeLogo]).
  /// When provided, [title] is ignored.
  final Widget? titleWidget;

  const SeseAppBar({
    super.key,
    this.title = '',
    this.leading,
    this.actions,
    this.bottom,
    this.centerTitle = false,
    this.titleWidget,
  });

  @override
  Widget build(BuildContext context) {
    return AppBar(
      title: titleWidget ?? Text(title),
      leading: leading,
      actions: actions,
      bottom: bottom,
      centerTitle: centerTitle,
    );
  }

  @override
  Size get preferredSize =>
      Size.fromHeight(kToolbarHeight + (bottom?.preferredSize.height ?? 0.0));
}
