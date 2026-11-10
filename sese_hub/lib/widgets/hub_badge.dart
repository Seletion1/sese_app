import 'package:flutter/material.dart';

/// Reusable dynamic count badge pill for SeSe Hub navigation, tabs, and headers.
///
/// Renders a sleek colored pill with bold count text when [count] > 0.
/// Renders [SizedBox.shrink] when [count] <= 0 or during empty stream states.
class HubCountBadge extends StatelessWidget {
  final int count;
  final Color? color;
  final Color textColor;
  final double fontSize;
  final EdgeInsetsGeometry padding;
  final EdgeInsetsGeometry margin;

  const HubCountBadge({
    super.key,
    required this.count,
    this.color,
    this.textColor = Colors.white,
    this.fontSize = 11,
    this.padding = const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
    this.margin = const EdgeInsets.only(left: 6),
  });

  /// Stream-backed factory for reactive Firestore badge count updates.
  static Widget stream({
    Key? key,
    required Stream<int> stream,
    Color? color,
    Color textColor = Colors.white,
    double fontSize = 11,
    EdgeInsetsGeometry padding = const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
    EdgeInsetsGeometry margin = const EdgeInsets.only(left: 6),
  }) {
    return StreamBuilder<int>(
      key: key,
      stream: stream,
      builder: (context, snapshot) {
        final count = snapshot.data ?? 0;
        if (count <= 0) return const SizedBox.shrink();
        return HubCountBadge(
          count: count,
          color: color,
          textColor: textColor,
          fontSize: fontSize,
          padding: padding,
          margin: margin,
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    if (count <= 0) return const SizedBox.shrink();

    final badgeColor = color ?? Colors.red.shade700;
    final displayCount = count > 99 ? '99+' : '$count';

    return Container(
      margin: margin,
      padding: padding,
      decoration: BoxDecoration(
        color: badgeColor,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Text(
        displayCount,
        style: TextStyle(
          color: textColor,
          fontSize: fontSize,
          fontWeight: FontWeight.bold,
          height: 1.1,
        ),
      ),
    );
  }
}
