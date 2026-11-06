import 'package:flutter/foundation.dart';

/// Pinned Firebase App Check **debug** tokens — single source of truth.
///
/// Register each exact value once in the Firebase console
/// (App Check > Apps > Manage debug tokens) for the matching app:
///
/// * sese_hub  -> [AppCheckConfig.seseHubDebugToken]
/// * sese_ride -> [AppCheckConfig.seseRideDebugToken]
///
/// Debug builds pin these values so every `flutter run` / `flutter build`
/// reuses the same token instead of generating a new random secret per
/// install. Release builds never use them (native seeding is debuggable-only
/// and Dart only references them under [debugTokenFor]).
///
/// WARNING: debug tokens bypass attestation. Never ship them in production
/// builds and never commit real tokens to a public repo. If one leaks,
/// delete it in the Firebase console and generate a new one.
abstract final class AppCheckConfig {
  /// Debug token for sese_hub (injected via --dart-define=SESE_HUB_APP_CHECK_DEBUG_TOKEN=...).
  static String get seseHubDebugToken {
    assert(!kReleaseMode, 'Debug tokens must not be present in release builds');
    return kReleaseMode
        ? ''
        : const String.fromEnvironment('SESE_HUB_APP_CHECK_DEBUG_TOKEN');
  }

  /// Debug token for sese_ride (injected via --dart-define=SESE_RIDE_APP_CHECK_DEBUG_TOKEN=...).
  static String get seseRideDebugToken {
    assert(!kReleaseMode, 'Debug tokens must not be present in release builds');
    return kReleaseMode
        ? ''
        : const String.fromEnvironment('SESE_RIDE_APP_CHECK_DEBUG_TOKEN');
  }

  /// Returns the pinned debug token for [appId] (`sese_hub` / `sese_ride`).
  static String debugTokenFor(String appId) {
    assert(!kReleaseMode, 'Debug tokens must not be present in release builds');
    if (kReleaseMode) return '';
    switch (appId) {
      case 'sese_hub':
        return seseHubDebugToken;
      case 'sese_ride':
        return seseRideDebugToken;
      default:
        throw ArgumentError.value(appId, 'appId', 'Expected sese_hub/sese_ride');
    }
  }
}
