import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sese_core/sese_core.dart';

void main() {
  group('AppTheme brand contract', () {
    test('official Warm Gold token', () {
      expect(AppColors.seseGold, const Color(0xFFFFB800));
      expect(AppColors.seseGoldLight, const Color(0xFFFFF8E7));
      expect(AppColors.primary, AppColors.seseGold);
    });

    test('dark mode matches the spec configuration', () {
      final dark = AppTheme.dark();
      expect(dark.brightness, Brightness.dark);
      expect(dark.primaryColor, const Color(0xFFFFB800));
      expect(dark.scaffoldBackgroundColor, AppColors.darkScaffold);
      expect(dark.cardColor, AppColors.darkCard);
      expect(dark.colorScheme.primary, const Color(0xFFFFB800));
      expect(dark.colorScheme.secondary, const Color(0xFFFFB800));
      expect(dark.colorScheme.surface, AppColors.darkCard);
      expect(dark.colorScheme.onSurface, Colors.white);
      // ignore: deprecated_member_use (spec-mandated scheme field)
      expect(dark.colorScheme.onBackground, Colors.white);
      expect(dark.iconTheme.color, const Color(0xFFFFB800));
      expect(dark.listTileTheme.iconColor, const Color(0xFFFFB800));
      expect(dark.listTileTheme.textColor, Colors.white);
      expect(dark.bottomNavigationBarTheme.selectedItemColor,
          const Color(0xFFFFB800));
      expect(
          dark.bottomNavigationBarTheme.unselectedItemColor, const Color(0xFF6E6E7A));
    });

    test('light mode mirrors the brand with dark-on-light contrast', () {
      final light = AppTheme.light();
      expect(light.brightness, Brightness.light);
      expect(light.primaryColor, const Color(0xFFFFB800));
      expect(light.colorScheme.primary, const Color(0xFFFFB800));
      expect(light.colorScheme.secondary, const Color(0xFFFFB800));
      expect(light.colorScheme.onSurface, const Color(0xFF1A1A1A));
      expect(light.scaffoldBackgroundColor, AppColors.lightScaffold);
      expect(light.iconTheme.color, const Color(0xFFFFB800));
      expect(light.bottomNavigationBarTheme.selectedItemColor,
          const Color(0xFFFFB800));
      expect(
          light.bottomNavigationBarTheme.unselectedItemColor, const Color(0xFF9E9E9E));
    });
  });
}
