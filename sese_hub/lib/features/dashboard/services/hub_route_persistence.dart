import 'package:shared_preferences/shared_preferences.dart';

/// Helper for persisting and restoring the admin Hub active tab, recent tabs,
/// sub-routes, and module sections across app backgrounding, minimization,
/// and fresh restarts.
abstract final class HubRoutePersistence {
  static const String keyActiveTab = 'hub_persisted_active_tab';
  static const String keyRecentTabs = 'hub_persisted_recent_tabs';
  static const String keySubRoute = 'hub_persisted_sub_route';

  /// Persists the active [HubTab] name (e.g. `'config'`, `'activeRides'`).
  static Future<void> saveActiveTab(String tabName) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(keyActiveTab, tabName);
    } catch (_) {}
  }

  /// Persists the list of recent module tabs for the bottom navigation bar.
  static Future<void> saveRecentTabs(List<String> tabNames) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setStringList(keyRecentTabs, tabNames);
    } catch (_) {}
  }

  /// Persists an open sub-screen route (e.g. `'settings'`, `'calling_config'`).
  static Future<void> saveSubRoute(String? routeName) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      if (routeName == null) {
        await prefs.remove(keySubRoute);
      } else {
        await prefs.setString(keySubRoute, routeName);
      }
    } catch (_) {}
  }

  /// Returns the last active tab name or null if none saved.
  static Future<String?> getSavedActiveTab() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      return prefs.getString(keyActiveTab);
    } catch (_) {
      return null;
    }
  }

  /// Returns the saved list of recent tabs or null if none saved.
  static Future<List<String>?> getSavedRecentTabs() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      return prefs.getStringList(keyRecentTabs);
    } catch (_) {
      return null;
    }
  }

  /// Returns the saved sub-route name or null if none was open.
  static Future<String?> getSavedSubRoute() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      return prefs.getString(keySubRoute);
    } catch (_) {
      return null;
    }
  }
}
