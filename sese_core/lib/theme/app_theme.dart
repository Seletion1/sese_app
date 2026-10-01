import 'package:flutter/material.dart';

/// Brand single source of truth — Official Warm Gold everywhere.
///
/// All primary accents (actions, selections, step progress, icons, list
/// tiles) resolve to [seseGold]; dark mode backgrounds remain clean black/dark grey.
abstract final class AppColors {
  // Official Sese Warm Gold Primary Color
  static const Color seseGold = Color(0xFFFFB800); // Warm Gold / Amber Accent
  static const Color seseGoldLight = Color(0xFFFFF8E7); // Light gold background tint

  /// Legacy alias kept for back-compat — prefer [seseGold] in new code.
  static const Color primary = seseGold;

  static const Color darkScaffold = Color(0xFF121212);
  static const Color darkCard = Color(0xFF1E1E1E);
  static const Color lightScaffold = Colors.white;
  static const Color lightCard = Colors.white;

  static const Color onPrimary = Colors.black;

  /// Soft grey fill for borderless form fields (light mode).
  static const Color lightFieldFill = Color(0xFFF4F5F7);

  /// Flat card surface (light mode) — colour only, no stroke.
  static const Color lightCardFill = Color(0xFFF8F9FA);

  /// Soft raised fill for borderless form fields (dark mode).
  static const Color darkFieldFill = Color(0xFF2A2A2E);
}

/// Shared [ThemeData] for sese_ride and sese_hub — the ONLY place app
/// themes are defined. Both apps mount `AppTheme.lightTheme` (or `AppTheme.light()`)
/// and `AppTheme.darkTheme` (or `AppTheme.dark()`) in their root `MaterialApp`.
abstract final class AppTheme {
  // Official Sese Warm Gold Primary Color
  static const Color seseGold = AppColors.seseGold;
  static const Color seseGoldLight = AppColors.seseGoldLight;

  /// Borderless, filled input decoration — the house style. The rounded
  /// outline keeps its 12px corner radius but draws no stroke
  /// ([BorderSide.none]), so fields read as soft grey pills.
  static InputDecorationTheme _inputDecorationTheme(Color fillColor) {
    final border = OutlineInputBorder(
      borderRadius: BorderRadius.circular(12),
      borderSide: BorderSide.none,
    );
    return InputDecorationTheme(
      filled: true,
      fillColor: fillColor,
      border: border,
      enabledBorder: border,
      focusedBorder: border,
      errorBorder: border,
      focusedErrorBorder: border,
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
    );
  }

  /// Flat, outline-free cards: solid fill, zero elevation, 12px corners.
  static CardThemeData _cardTheme(Color color) => CardThemeData(
        color: color,
        elevation: 0,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: BorderSide.none,
        ),
      );

  /// Dividers are invisible project-wide — separators should come from
  /// spacing and background contrast, never a stroked line.
  static const DividerThemeData _dividerTheme = DividerThemeData(
    color: Colors.transparent,
    thickness: 0,
    space: 0,
  );

  /// Borderless outlined buttons: no stroke, soft tonal fill, 12px corners.
  /// Keeps [OutlinedButton] call-sites visually stroke-free without forcing
  /// a widget-type migration.
  static OutlinedButtonThemeData _outlinedButtonTheme(Color fillColor) =>
      OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          side: BorderSide.none,
          backgroundColor: fillColor,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
        ),
      );

  /// Borderless chips: filled surface, no outline stroke.
  static ChipThemeData _chipTheme(Color fillColor) => ChipThemeData(
        backgroundColor: fillColor,
        side: BorderSide.none,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: BorderSide.none,
        ),
        elevation: 0,
        pressElevation: 0,
      );

  // Light Theme Configuration
  static final ThemeData lightTheme = ThemeData(
    useMaterial3: true,
    brightness: Brightness.light,
    primaryColor: seseGold,
    scaffoldBackgroundColor: Colors.white,
    cardColor: Colors.white,
    colorScheme: const ColorScheme.light(
      primary: seseGold,
      secondary: seseGold,
      surface: Colors.white,
      onSurface: Colors.black87,
    ),
    iconTheme: const IconThemeData(color: seseGold),
    primaryIconTheme: const IconThemeData(color: seseGold),
    listTileTheme: const ListTileThemeData(
      iconColor: seseGold,
      textColor: Colors.black87,
    ),
    bottomNavigationBarTheme: const BottomNavigationBarThemeData(
      selectedItemColor: seseGold,
      unselectedItemColor: Colors.grey,
    ),
    inputDecorationTheme:
        _inputDecorationTheme(AppColors.lightFieldFill),
    dividerTheme: _dividerTheme,
    cardTheme: _cardTheme(AppColors.lightCardFill),
    outlinedButtonTheme:
        _outlinedButtonTheme(AppColors.lightFieldFill),
    chipTheme: _chipTheme(AppColors.lightFieldFill),
  );

  // Dark Theme Configuration
  static final ThemeData darkTheme = ThemeData(
    useMaterial3: true,
    brightness: Brightness.dark,
    primaryColor: seseGold,
    scaffoldBackgroundColor: const Color(0xFF121212),
    cardColor: const Color(0xFF1E1E1E),
    colorScheme: const ColorScheme.dark(
      primary: seseGold,
      secondary: seseGold,
      surface: Color(0xFF1E1E1E),
      onSurface: Colors.white,
    ),
    iconTheme: const IconThemeData(color: seseGold),
    primaryIconTheme: const IconThemeData(color: seseGold),
    listTileTheme: const ListTileThemeData(
      iconColor: seseGold,
      textColor: Colors.white,
    ),
    bottomNavigationBarTheme: const BottomNavigationBarThemeData(
      selectedItemColor: seseGold,
      unselectedItemColor: Colors.grey,
    ),
    inputDecorationTheme:
        _inputDecorationTheme(AppColors.darkFieldFill),
    dividerTheme: _dividerTheme,
    cardTheme: _cardTheme(AppColors.darkCard),
    outlinedButtonTheme:
        _outlinedButtonTheme(AppColors.darkFieldFill),
    chipTheme: _chipTheme(AppColors.darkFieldFill),
  );

  /// Callable aliases
  static ThemeData light() => lightTheme;
  static ThemeData dark() => darkTheme;
}
