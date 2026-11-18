import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Supported layout view modes for `sese_hub`.
enum HubViewMode {
  /// Automatic responsive layout: phone screens use mobile layout, web/tablets use desktop layout.
  auto('auto', 'Auto (System Default)'),

  /// Forced mobile touch-optimized view.
  mobile('mobile', 'Mobile View'),

  /// Forced desktop view ("Request Desktop Site") with full 1280px viewport.
  desktop('desktop', 'Desktop View');

  final String code;
  final String label;

  const HubViewMode(this.code, this.label);

  static HubViewMode fromCode(String? raw) {
    if (raw == null) return HubViewMode.auto;
    final normalized = raw.trim().toLowerCase();
    for (final mode in HubViewMode.values) {
      if (mode.code == normalized) return mode;
    }
    return HubViewMode.auto;
  }
}

/// Global View Mode State Controller persisting user layout preference in [SharedPreferences].
class ViewModeController extends ValueNotifier<HubViewMode> {
  static final ViewModeController instance = ViewModeController._();

  static const String _kPrefKey = 'sese_hub_view_mode';

  ViewModeController._() : super(HubViewMode.auto);

  /// Loads the persisted view mode preference from [SharedPreferences].
  Future<void> load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final code = prefs.getString(_kPrefKey);
      value = HubViewMode.fromCode(code);
    } catch (e) {
      debugPrint('ViewModeController.load error: $e');
    }
  }

  /// Sets and persists the selected [HubViewMode].
  Future<void> setViewMode(HubViewMode mode) async {
    value = mode;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_kPrefKey, mode.code);
    } catch (e) {
      debugPrint('ViewModeController.setViewMode error: $e');
    }
  }
}
