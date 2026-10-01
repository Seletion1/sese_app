import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sese_core/sese_core.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    ThemeController.testPreferences =
        await SharedPreferences.getInstance();
    ThemeController.instance.value = ThemeMode.system;
  });

  tearDown(() {
    ThemeController.testPreferences = null;
    ThemeController.instance.value = ThemeMode.system;
  });

  group('ThemeController (shared sese_ride + sese_hub state)', () {
    test('defaults to ThemeMode.system (adopts OS preference)', () {
      expect(ThemeController.instance.value, ThemeMode.system);
    });

    test('setTheme persists light/dark/system across load', () async {
      await ThemeController.instance.setTheme(ThemeMode.dark);
      expect(ThemeController.instance.value, ThemeMode.dark);

      // Simulate a restart: reset in-memory, reload from storage.
      ThemeController.instance.value = ThemeMode.system;
      await ThemeController.instance.load();
      expect(ThemeController.instance.value, ThemeMode.dark);

      await ThemeController.instance.setTheme(ThemeMode.light);
      ThemeController.instance.value = ThemeMode.system;
      await ThemeController.instance.load();
      expect(ThemeController.instance.value, ThemeMode.light);

      await ThemeController.instance.setTheme(ThemeMode.system);
      ThemeController.instance.value = ThemeMode.dark;
      await ThemeController.instance.load();
      expect(ThemeController.instance.value, ThemeMode.system);
    });

    test('unknown stored value falls back to system', () async {
      final prefs = ThemeController.testPreferences!;
      await prefs.setString(ThemeController.storageKey, 'neon');
      await ThemeController.instance.load();
      expect(ThemeController.instance.value, ThemeMode.system);
    });

    test('labels cover System Default | Light | Dark', () {
      expect(ThemeMode.system.label, 'System Default');
      expect(ThemeMode.light.label, 'Light');
      expect(ThemeMode.dark.label, 'Dark');
    });
  });
}
