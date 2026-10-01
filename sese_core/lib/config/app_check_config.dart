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
  /// Debug token pinned to sese_hub.
  static const String seseHubDebugToken =
      'e1d8dc46-7c7d-48da-a9fd-e34592249fc5';

  /// Debug token pinned to sese_ride.
  static const String seseRideDebugToken =
      'cba5fa66-ef47-4b2f-83c1-4f05d2f035ad';

  /// Returns the pinned debug token for [appId] (`sese_hub` / `sese_ride`).
  static String debugTokenFor(String appId) {
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
