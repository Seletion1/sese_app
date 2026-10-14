import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Shared theme state for sese_ride and sese_hub — the ONLY place the
/// manual appearance selection lives.
///
/// - [ThemeMode.system] is the default application state: on first launch
///   the OS preference (Dark or Light) is adopted automatically.
/// - A manual pick ([ThemeMode.light] / [ThemeMode.dark] /
///   [ThemeMode.system]) persists in [SharedPreferences] across restarts.
///
/// Usage:
/// ```dart
/// await ThemeController.instance.load(); // once at startup
/// ValueListenableBuilder<ThemeMode>(
///   valueListenable: ThemeController.instance,
///   builder: (context, mode, _) => ...,
/// );
/// await ThemeController.instance.setTheme(ThemeMode.dark);
/// ```
class ThemeController extends ValueNotifier<ThemeMode> {
  static const String storageKey = 'sese_theme_mode';

  static final ThemeController instance = ThemeController._();

  ThemeController._() : super(ThemeMode.system);

  /// Test seam: inject a fake [SharedPreferences] instance.
  @visibleForTesting
  static SharedPreferences? testPreferences;

  /// Loads the persisted theme. Falls back to [ThemeMode.system].
  Future<void> load() async {
    try {
      final prefs = testPreferences ?? await SharedPreferences.getInstance();
      value = _decode(prefs.getString(storageKey));
    } catch (_) {
      value = ThemeMode.system;
    }
  }

  /// Persists [mode] and notifies listeners.
  Future<void> setTheme(ThemeMode mode) async {
    value = mode;
    try {
      final prefs = testPreferences ?? await SharedPreferences.getInstance();
      await prefs.setString(storageKey, _encode(mode));
    } catch (_) {
      // Persistence is best-effort (e.g. widget tests without plugins).
    }
  }

  static String _encode(ThemeMode mode) {
    switch (mode) {
      case ThemeMode.light:
        return 'light';
      case ThemeMode.dark:
        return 'dark';
      case ThemeMode.system:
        return 'system';
    }
  }

  static ThemeMode _decode(String? raw) {
    switch (raw) {
      case 'light':
        return ThemeMode.light;
      case 'dark':
        return ThemeMode.dark;
      case 'system':
      default:
        return ThemeMode.system;
    }
  }
}

/// Human-readable label for the active [ThemeMode].
extension ThemeModeLabel on ThemeMode {
  String get label {
    switch (this) {
      case ThemeMode.light:
        return 'Light';
      case ThemeMode.dark:
        return 'Dark';
      case ThemeMode.system:
        return 'System Default';
    }
  }
}

/// Theme picker bottom sheet (Light / Dark / System Default).
///
/// Lives here — not in any app screen — so the Menu tab, the Settings
/// screen, and profile screens can all open it without importing each other
/// (which would create import cycles).
Future<void> showThemePickerSheet(
  BuildContext context,
  ThemeController controller,
) {
  return showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    builder: (sheetContext) {
      return ValueListenableBuilder<ThemeMode>(
        valueListenable: controller,
        builder: (context, mode, _) {
          Widget option({
            required ThemeMode value,
            required IconData icon,
            required String title,
            required String subtitle,
          }) {
            final selected = mode == value;
            return ListTile(
              leading: Icon(icon),
              title: Text(title),
              subtitle: Text(subtitle),
              trailing: selected
                  ? Icon(Icons.check_circle,
                      color: Theme.of(context).colorScheme.primary)
                  : const Icon(Icons.circle_outlined),
              onTap: () async {
                await controller.setTheme(value);
                if (sheetContext.mounted) Navigator.of(sheetContext).pop();
              },
            );
          }

          return SafeArea(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Padding(
                  // 16px gutters match bottom-sheet rows below.
                  padding: EdgeInsets.fromLTRB(16, 8, 16, 4),
                  child: Text('App Theme',
                      style: TextStyle(
                          fontSize: 16, fontWeight: FontWeight.bold)),
                ),
                option(
                    value: ThemeMode.light,
                    icon: Icons.light_mode_outlined,
                    title: 'Light Mode',
                    subtitle: 'Always use the light theme'),
                option(
                    value: ThemeMode.dark,
                    icon: Icons.dark_mode_outlined,
                    title: 'Dark Mode',
                    subtitle: 'Always use the dark theme'),
                option(
                    value: ThemeMode.system,
                    icon: Icons.settings_suggest_outlined,
                    title: 'System Default',
                    subtitle: 'Follow device settings'),
                const SizedBox(height: 8),
              ],
            ),
          );
        },
      );
    },
  );
}
