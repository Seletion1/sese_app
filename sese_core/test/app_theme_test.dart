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
      expect(dark.scaffoldBackgroundColor, const Color(0xFF121212));
      expect(dark.cardColor, const Color(0xFF1E1E1E));
      expect(dark.colorScheme.primary, const Color(0xFFFFB800));
      expect(dark.colorScheme.secondary, const Color(0xFFFFB800));
      expect(dark.colorScheme.surface, const Color(0xFF1E1E1E));
      expect(dark.colorScheme.onSurface, Colors.white);
      // ignore: deprecated_member_use (spec-mandated scheme field)
      expect(dark.colorScheme.onBackground, Colors.white);
      expect(dark.iconTheme.color, const Color(0xFFFFB800));
      expect(dark.listTileTheme.iconColor, const Color(0xFFFFB800));
      expect(dark.listTileTheme.textColor, Colors.white);
      expect(dark.bottomNavigationBarTheme.selectedItemColor,
          const Color(0xFFFFB800));
      expect(
          dark.bottomNavigationBarTheme.unselectedItemColor, Colors.grey);
    });

    test('light mode mirrors the brand with dark-on-light contrast', () {
      final light = AppTheme.light();
      expect(light.brightness, Brightness.light);
      expect(light.primaryColor, const Color(0xFFFFB800));
      expect(light.colorScheme.primary, const Color(0xFFFFB800));
      expect(light.colorScheme.secondary, const Color(0xFFFFB800));
      expect(light.colorScheme.onSurface, Colors.black87);
      expect(light.scaffoldBackgroundColor, Colors.white);
      expect(light.iconTheme.color, const Color(0xFFFFB800));
      expect(light.bottomNavigationBarTheme.selectedItemColor,
          const Color(0xFFFFB800));
      expect(
          light.bottomNavigationBarTheme.unselectedItemColor, Colors.grey);
    });
  });
}
