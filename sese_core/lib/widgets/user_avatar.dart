import 'package:flutter/material.dart';

/// Reusable profile-picture placeholder for every user in the SeSe apps.
///
/// - Shows [photoUrl] when available (NetworkImage).
/// - Otherwise shows an initials placeholder derived from [displayName]
///   with a deterministic background colour, or a person icon when the
///   name is empty.
///
/// Used by sese_ride (customer profile, driver menu, live-trip driver
/// sheet) and sese_hub (dashboard rail) so every user always has an avatar.
class UserAvatar extends StatelessWidget {
  final String displayName;
  final String? photoUrl;
  final double radius;
  final double? fontSize;
  final Color? backgroundColor;
  final Color? foregroundColor;

  const UserAvatar({
    super.key,
    required this.displayName,
    this.photoUrl,
    this.radius = 20,
    this.fontSize,
    this.backgroundColor,
    this.foregroundColor,
  });

  /// "Adaeze Okonkwo" -> "AO", "Adaeze" -> "A", "" -> "".
  static String initialsFor(String name) {
    final parts = name.trim().split(RegExp(r'\s+')).where((p) => p.isNotEmpty).toList();
    if (parts.isEmpty) return '';
    if (parts.length == 1) {
      final word = parts.first;
      return word.length >= 2
          ? word.substring(0, 2).toUpperCase()
          : word.toUpperCase();
    }
    return (parts[0][0] + parts[1][0]).toUpperCase();
  }

  /// Deterministic background colour from the display name so placeholders
  /// look distinct per user but stable across rebuilds.
  static Color colorFor(String name, BuildContext context) {
    const palette = <Color>[
      Colors.blue,
      Colors.green,
      Colors.orange,
      Colors.purple,
      Colors.teal,
      Colors.indigo,
      Colors.brown,
      Colors.cyan,
      Colors.deepOrange,
      Colors.pink,
    ];
    if (name.trim().isEmpty) return Colors.grey;
    var hash = 0;
    for (final code in name.trim().toLowerCase().codeUnits) {
      hash = (hash * 31 + code) & 0x7fffffff;
    }
    return palette[hash % palette.length];
  }

  bool get _hasPhoto => photoUrl != null && photoUrl!.trim().isNotEmpty;

  @override
  Widget build(BuildContext context) {
    final initials = initialsFor(displayName);
    final bg = backgroundColor ??
        (_hasPhoto ? Colors.grey.shade300 : colorFor(displayName, context));
    final fg = foregroundColor ?? Colors.white;
    final resolvedFontSize = fontSize ?? radius * 0.55;
    final diameter = radius * 2;

    Widget placeholderChild;
    if (initials.isEmpty) {
      placeholderChild = Icon(
        Icons.person,
        size: radius,
        color: fg,
      );
    } else {
      placeholderChild = Text(
        initials,
        style: TextStyle(
          color: fg,
          fontSize: resolvedFontSize,
          fontWeight: FontWeight.bold,
        ),
      );
    }

    if (!_hasPhoto) {
      return CircleAvatar(
        radius: radius,
        backgroundColor: colorFor(displayName, context),
        child: placeholderChild,
      );
    }

    // Photo available: Image.network with errorBuilder so a broken URL
    // falls back to the same initials placeholder instead of a grey box.
    return ClipOval(
      child: Image.network(
        photoUrl!.trim(),
        width: diameter,
        height: diameter,
        fit: BoxFit.cover,
        errorBuilder: (_, _, _) => Container(
          width: diameter,
          height: diameter,
          alignment: Alignment.center,
          color: colorFor(displayName, context),
          child: placeholderChild,
        ),
        loadingBuilder: (context, child, loadingProgress) {
          if (loadingProgress == null) return child;
          return Container(
            width: diameter,
            height: diameter,
            alignment: Alignment.center,
            color: bg,
            child: placeholderChild,
          );
        },
      ),
    );
  }
}
