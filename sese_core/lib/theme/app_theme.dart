import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Brand single source of truth — Official Warm Gold everywhere.
///
/// All primary accents (actions, selections, step progress, icons, list
/// tiles) resolve to [seseGold]; backgrounds adapt to system theme.
abstract final class AppColors {
  // Official Sese Warm Gold Primary Color
  static const Color seseGold = Color(0xFFFFB800); // Warm Gold / Amber Accent
  static const Color seseGoldLight = Color(0xFFFFF8E7); // Light gold background tint

  /// Legacy alias kept for back-compat — prefer [seseGold] in new code.
  static const Color primary = seseGold;

  static const Color darkScaffold = Color(0xFF121212);
  static const Color darkCard = Color(0xFF1E1E24);
  static const Color darkSurface = Color(0xFF1A1A20);
  static const Color lightScaffold = Color(0xFFF7F8FA);
  static const Color lightCard = Colors.white;

  static const Color onPrimary = Colors.black;

  /// Soft grey fill for borderless form fields (light mode).
  static const Color lightFieldFill = Color(0xFFF0F1F4);

  /// Flat card surface (light mode) — colour only, no stroke.
  static const Color lightCardFill = Colors.white;

  /// Soft raised fill for borderless form fields (dark mode).
  static const Color darkFieldFill = Color(0xFF252530);
}

/// Shared [ThemeData] for sese_ride and sese_hub — the ONLY place app
/// themes are defined. Both apps mount `AppTheme.lightTheme` (or `AppTheme.light()`)
/// and `AppTheme.darkTheme` (or `AppTheme.dark()`) in their root `MaterialApp`.
abstract final class AppTheme {
  // Official Sese Warm Gold Primary Color
  static const Color seseGold = AppColors.seseGold;
  static const Color seseGoldLight = AppColors.seseGoldLight;

  // ─── Reusable sub-theme builders ────────────────────────────────────────────

  /// Borderless, filled input decoration — the house style.
  static InputDecorationTheme _inputDecorationTheme(Color fillColor) {
    final border = OutlineInputBorder(
      borderRadius: BorderRadius.circular(14),
      borderSide: BorderSide.none,
    );
    return InputDecorationTheme(
      filled: true,
      fillColor: fillColor,
      border: border,
      enabledBorder: border,
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(14),
        borderSide: const BorderSide(color: seseGold, width: 1.5),
      ),
      errorBorder: border,
      focusedErrorBorder: border,
      contentPadding: const EdgeInsets.symmetric(horizontal: 18, vertical: 16),
      labelStyle: const TextStyle(fontWeight: FontWeight.w500),
      floatingLabelStyle: const TextStyle(color: seseGold, fontWeight: FontWeight.w600),
    );
  }

  /// Premium flat cards: zero elevation, 16px corners, subtle shadow via theme.
  static CardThemeData _cardTheme(Color color) => CardThemeData(
        color: color,
        elevation: 0,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: BorderSide.none,
        ),
        margin: EdgeInsets.zero,
      );

  /// Dividers are invisible project-wide.
  static const DividerThemeData _dividerTheme = DividerThemeData(
    color: Colors.transparent,
    thickness: 0,
    space: 0,
  );

  /// Borderless outlined buttons: no stroke, soft tonal fill, 14px corners.
  static OutlinedButtonThemeData _outlinedButtonTheme(Color fillColor) =>
      OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          side: BorderSide.none,
          backgroundColor: fillColor,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(14),
          ),
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
          textStyle: const TextStyle(fontWeight: FontWeight.w600, fontSize: 15),
        ),
      );

  /// Gold-filled primary button — premium, full-radius, bold label.
  static FilledButtonThemeData _filledButtonTheme() => FilledButtonThemeData(
        style: FilledButton.styleFrom(
          backgroundColor: seseGold,
          foregroundColor: Colors.black,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(14),
          ),
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
          textStyle: const TextStyle(
            fontWeight: FontWeight.w700,
            fontSize: 15,
            letterSpacing: 0.3,
          ),
          elevation: 0,
        ),
      );

  /// Elevated button (legacy usage) — gold background, rounded corners.
  static ElevatedButtonThemeData _elevatedButtonTheme() =>
      ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          backgroundColor: seseGold,
          foregroundColor: Colors.black,
          elevation: 0,
          shadowColor: Colors.transparent,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(14),
          ),
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
          textStyle: const TextStyle(
            fontWeight: FontWeight.w700,
            fontSize: 15,
            letterSpacing: 0.3,
          ),
        ),
      );

  /// Borderless chips.
  static ChipThemeData _chipTheme(Color fillColor, {required bool isDark}) => ChipThemeData(
        backgroundColor: fillColor,
        selectedColor: seseGold,
        secondarySelectedColor: seseGold,
        disabledColor: isDark ? const Color(0xFF2A2A36) : const Color(0xFFE0E0E0),
        side: BorderSide.none,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(20),
          side: BorderSide.none,
        ),
        elevation: 0,
        pressElevation: 0,
        labelStyle: TextStyle(
          fontWeight: FontWeight.w600,
          fontSize: 13,
          color: isDark ? Colors.white : const Color(0xFF1A1A1A),
        ),
        secondaryLabelStyle: const TextStyle(
          fontWeight: FontWeight.w700,
          fontSize: 13,
          color: Colors.black,
        ),
        checkmarkColor: Colors.black,
      );

  // ─── Light Theme ─────────────────────────────────────────────────────────────

  static final ThemeData lightTheme = ThemeData(
    useMaterial3: true,
    brightness: Brightness.light,
    primaryColor: seseGold,
    scaffoldBackgroundColor: AppColors.lightScaffold,
    cardColor: AppColors.lightCard,

    colorScheme: const ColorScheme.light(
      primary: seseGold,
      onPrimary: Colors.black,
      secondary: seseGold,
      onSecondary: Colors.black,
      surface: AppColors.lightCard,
      onSurface: Color(0xFF1A1A1A),
      surfaceContainerHighest: AppColors.lightFieldFill,
      outline: Color(0xFFE0E0E0),
    ),

    // ── AppBar ────────────────────────────────────────────────────────────────
    appBarTheme: AppBarTheme(
      backgroundColor: AppColors.lightCard,
      foregroundColor: const Color(0xFF1A1A1A),
      elevation: 0,
      scrolledUnderElevation: 1,
      shadowColor: Colors.black.withValues(alpha: 0.08),
      centerTitle: false,
      titleTextStyle: const TextStyle(
        fontSize: 18,
        fontWeight: FontWeight.w700,
        color: Color(0xFF1A1A1A),
        letterSpacing: -0.3,
      ),
      toolbarHeight: 60,
      systemOverlayStyle: SystemUiOverlayStyle.dark.copyWith(
        statusBarColor: Colors.transparent,
        systemNavigationBarColor: AppColors.lightScaffold,
      ),
      iconTheme: const IconThemeData(color: Color(0xFF1A1A1A), size: 22),
      actionsIconTheme: const IconThemeData(color: Color(0xFF1A1A1A), size: 22),
      surfaceTintColor: Colors.transparent,
    ),

    // ── Bottom Navigation ─────────────────────────────────────────────────────
    bottomNavigationBarTheme: const BottomNavigationBarThemeData(
      backgroundColor: AppColors.lightCard,
      selectedItemColor: seseGold,
      unselectedItemColor: Color(0xFF9E9E9E),
      selectedLabelStyle: TextStyle(fontWeight: FontWeight.w600, fontSize: 11),
      unselectedLabelStyle: TextStyle(fontWeight: FontWeight.w500, fontSize: 11),
      type: BottomNavigationBarType.fixed,
      elevation: 0,
    ),

    // ── Text ──────────────────────────────────────────────────────────────────
    textTheme: const TextTheme(
      displayLarge: TextStyle(fontWeight: FontWeight.w800, letterSpacing: -1.0, color: Color(0xFF1A1A1A)),
      displayMedium: TextStyle(fontWeight: FontWeight.w700, letterSpacing: -0.5, color: Color(0xFF1A1A1A)),
      displaySmall: TextStyle(fontWeight: FontWeight.w700, letterSpacing: -0.3, color: Color(0xFF1A1A1A)),
      headlineLarge: TextStyle(fontWeight: FontWeight.w700, letterSpacing: -0.3, color: Color(0xFF1A1A1A)),
      headlineMedium: TextStyle(fontWeight: FontWeight.w700, color: Color(0xFF1A1A1A)),
      headlineSmall: TextStyle(fontWeight: FontWeight.w600, color: Color(0xFF1A1A1A)),
      titleLarge: TextStyle(fontWeight: FontWeight.w700, color: Color(0xFF1A1A1A)),
      titleMedium: TextStyle(fontWeight: FontWeight.w600, color: Color(0xFF1A1A1A)),
      titleSmall: TextStyle(fontWeight: FontWeight.w600, color: Color(0xFF1A1A1A)),
      bodyLarge: TextStyle(fontWeight: FontWeight.w400, color: Color(0xFF1A1A1A)),
      bodyMedium: TextStyle(fontWeight: FontWeight.w400, color: Color(0xFF3A3A3A)),
      bodySmall: TextStyle(fontWeight: FontWeight.w400, color: Color(0xFF5A5A5A)),
      labelLarge: TextStyle(fontWeight: FontWeight.w600, letterSpacing: 0.2, color: Color(0xFF1A1A1A)),
      labelMedium: TextStyle(fontWeight: FontWeight.w500, color: Color(0xFF5A5A5A)),
      labelSmall: TextStyle(fontWeight: FontWeight.w500, letterSpacing: 0.4, color: Color(0xFF7A7A7A)),
    ),

    // ── Icons ─────────────────────────────────────────────────────────────────
    iconTheme: const IconThemeData(color: seseGold, size: 22),
    primaryIconTheme: const IconThemeData(color: seseGold),

    // ── ListTile ──────────────────────────────────────────────────────────────
    listTileTheme: const ListTileThemeData(
      iconColor: seseGold,
      textColor: Color(0xFF1A1A1A),
      subtitleTextStyle: TextStyle(
        fontSize: 13,
        color: Color(0xFF7A7A7A),
        fontWeight: FontWeight.w400,
      ),
      contentPadding: EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      minVerticalPadding: 12,
      visualDensity: VisualDensity.standard,
    ),

    // ── SnackBar ──────────────────────────────────────────────────────────────
    snackBarTheme: SnackBarThemeData(
      behavior: SnackBarBehavior.floating,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      backgroundColor: const Color(0xFF1A1A1A),
      contentTextStyle: const TextStyle(
        color: Colors.white,
        fontWeight: FontWeight.w500,
        fontSize: 14,
      ),
      actionTextColor: seseGold,
    ),

    // ── Dialog ────────────────────────────────────────────────────────────────
    dialogTheme: DialogThemeData(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      elevation: 0,
      backgroundColor: AppColors.lightCard,
      titleTextStyle: const TextStyle(
        fontSize: 18,
        fontWeight: FontWeight.w700,
        color: Color(0xFF1A1A1A),
      ),
    ),

    // ── Segmented Button ──────────────────────────────────────────────────────
    segmentedButtonTheme: SegmentedButtonThemeData(
      style: SegmentedButton.styleFrom(
        backgroundColor: AppColors.lightFieldFill,
        selectedBackgroundColor: seseGold,
        selectedForegroundColor: Colors.black,
        foregroundColor: const Color(0xFF5A5A5A),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        textStyle: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13),
        side: BorderSide.none,
      ),
    ),

    // ── Sub-themes ────────────────────────────────────────────────────────────
    inputDecorationTheme: _inputDecorationTheme(AppColors.lightFieldFill),
    dividerTheme: _dividerTheme,
    cardTheme: _cardTheme(AppColors.lightCardFill),
    outlinedButtonTheme: _outlinedButtonTheme(AppColors.lightFieldFill),
    filledButtonTheme: _filledButtonTheme(),
    elevatedButtonTheme: _elevatedButtonTheme(),
    chipTheme: _chipTheme(AppColors.lightFieldFill, isDark: false),
  );

  // ─── Dark Theme ──────────────────────────────────────────────────────────────

  static final ThemeData darkTheme = ThemeData(
    useMaterial3: true,
    brightness: Brightness.dark,
    primaryColor: seseGold,
    scaffoldBackgroundColor: AppColors.darkScaffold,
    cardColor: AppColors.darkCard,

    colorScheme: const ColorScheme.dark(
      primary: seseGold,
      onPrimary: Colors.black,
      secondary: seseGold,
      onSecondary: Colors.black,
      surface: AppColors.darkCard,
      onSurface: Colors.white,
      surfaceContainerHighest: AppColors.darkFieldFill,
      outline: Color(0xFF3A3A46),
    ),

    // ── AppBar ────────────────────────────────────────────────────────────────
    appBarTheme: AppBarTheme(
      backgroundColor: AppColors.darkScaffold,
      foregroundColor: Colors.white,
      elevation: 0,
      scrolledUnderElevation: 1,
      shadowColor: Colors.black.withValues(alpha: 0.4),
      centerTitle: false,
      titleTextStyle: const TextStyle(
        fontSize: 18,
        fontWeight: FontWeight.w700,
        color: Colors.white,
        letterSpacing: -0.3,
      ),
      toolbarHeight: 60,
      systemOverlayStyle: SystemUiOverlayStyle.light.copyWith(
        statusBarColor: Colors.transparent,
        systemNavigationBarColor: AppColors.darkScaffold,
      ),
      iconTheme: const IconThemeData(color: Colors.white, size: 22),
      actionsIconTheme: const IconThemeData(color: Colors.white, size: 22),
      surfaceTintColor: Colors.transparent,
    ),

    // ── Bottom Navigation ─────────────────────────────────────────────────────
    bottomNavigationBarTheme: const BottomNavigationBarThemeData(
      backgroundColor: Color(0xFF16161B),
      selectedItemColor: seseGold,
      unselectedItemColor: Color(0xFF6E6E7A),
      selectedLabelStyle: TextStyle(fontWeight: FontWeight.w600, fontSize: 11),
      unselectedLabelStyle: TextStyle(fontWeight: FontWeight.w500, fontSize: 11),
      type: BottomNavigationBarType.fixed,
      elevation: 0,
    ),

    // ── Text ──────────────────────────────────────────────────────────────────
    textTheme: const TextTheme(
      displayLarge: TextStyle(fontWeight: FontWeight.w800, letterSpacing: -1.0, color: Colors.white),
      displayMedium: TextStyle(fontWeight: FontWeight.w700, letterSpacing: -0.5, color: Colors.white),
      displaySmall: TextStyle(fontWeight: FontWeight.w700, letterSpacing: -0.3, color: Colors.white),
      headlineLarge: TextStyle(fontWeight: FontWeight.w700, letterSpacing: -0.3, color: Colors.white),
      headlineMedium: TextStyle(fontWeight: FontWeight.w700, color: Colors.white),
      headlineSmall: TextStyle(fontWeight: FontWeight.w600, color: Colors.white),
      titleLarge: TextStyle(fontWeight: FontWeight.w700, color: Colors.white),
      titleMedium: TextStyle(fontWeight: FontWeight.w600, color: Colors.white),
      titleSmall: TextStyle(fontWeight: FontWeight.w600, color: Colors.white),
      bodyLarge: TextStyle(fontWeight: FontWeight.w400, color: Colors.white),
      bodyMedium: TextStyle(fontWeight: FontWeight.w400, color: Color(0xFFCCCCCC)),
      bodySmall: TextStyle(fontWeight: FontWeight.w400, color: Color(0xFFAAAAAA)),
      labelLarge: TextStyle(fontWeight: FontWeight.w600, letterSpacing: 0.2, color: Colors.white),
      labelMedium: TextStyle(fontWeight: FontWeight.w500, color: Color(0xFFAAAAAA)),
      labelSmall: TextStyle(fontWeight: FontWeight.w500, letterSpacing: 0.4, color: Color(0xFF888888)),
    ),

    // ── Icons ─────────────────────────────────────────────────────────────────
    iconTheme: const IconThemeData(color: seseGold, size: 22),
    primaryIconTheme: const IconThemeData(color: seseGold),

    // ── ListTile ──────────────────────────────────────────────────────────────
    listTileTheme: const ListTileThemeData(
      iconColor: seseGold,
      textColor: Colors.white,
      subtitleTextStyle: TextStyle(
        fontSize: 13,
        color: Color(0xFF888888),
        fontWeight: FontWeight.w400,
      ),
      contentPadding: EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      minVerticalPadding: 12,
      visualDensity: VisualDensity.standard,
    ),

    // ── SnackBar ──────────────────────────────────────────────────────────────
    snackBarTheme: SnackBarThemeData(
      behavior: SnackBarBehavior.floating,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      backgroundColor: const Color(0xFF2A2A36),
      contentTextStyle: const TextStyle(
        color: Colors.white,
        fontWeight: FontWeight.w500,
        fontSize: 14,
      ),
      actionTextColor: seseGold,
    ),

    // ── Dialog ────────────────────────────────────────────────────────────────
    dialogTheme: DialogThemeData(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      elevation: 0,
      backgroundColor: AppColors.darkCard,
      titleTextStyle: const TextStyle(
        fontSize: 18,
        fontWeight: FontWeight.w700,
        color: Colors.white,
      ),
    ),

    // ── Segmented Button ──────────────────────────────────────────────────────
    segmentedButtonTheme: SegmentedButtonThemeData(
      style: SegmentedButton.styleFrom(
        backgroundColor: AppColors.darkFieldFill,
        selectedBackgroundColor: seseGold,
        selectedForegroundColor: Colors.black,
        foregroundColor: const Color(0xFFAAAAAA),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        textStyle: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13),
        side: BorderSide.none,
      ),
    ),

    // ── Sub-themes ────────────────────────────────────────────────────────────
    inputDecorationTheme: _inputDecorationTheme(AppColors.darkFieldFill),
    dividerTheme: _dividerTheme,
    cardTheme: _cardTheme(AppColors.darkCard),
    outlinedButtonTheme: _outlinedButtonTheme(AppColors.darkFieldFill),
    filledButtonTheme: _filledButtonTheme(),
    elevatedButtonTheme: _elevatedButtonTheme(),
    chipTheme: _chipTheme(AppColors.darkFieldFill, isDark: true),
  );

  /// Callable aliases
  static ThemeData light() => lightTheme;
  static ThemeData dark() => darkTheme;
}
