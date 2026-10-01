// Canonical implementation lives in sese_core so sese_ride and sese_hub
// share one persisted appearance state. This shim preserves the existing
// import path (`features/settings/theme_controller.dart`) — [ThemeController],
// [ThemeModeLabel], and the `sese_theme_mode` storage key all resolve to the
// shared core declarations.
export 'package:sese_core/theme/theme_controller.dart';
