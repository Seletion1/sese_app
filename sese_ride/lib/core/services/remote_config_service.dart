import 'dart:async';

import 'package:firebase_remote_config/firebase_remote_config.dart';
import 'package:flutter/foundation.dart';

/// Remote Config parameter keys.
///
/// These must stay in lockstep with the `parameters` map of the published
/// Remote Config template (`firebase remoteconfig:get` / `--only
/// remoteconfig`). Keys are `snake_case` on the wire; the typed getters on
/// [RemoteConfigService] expose them in Dart `camelCase`.
abstract final class RemoteConfigKeys {
  // Driver & ride rules
  static const String requireMultiVehicleSnapshot =
      'require_multi_vehicle_snapshot';
  static const String driverCommissionRate = 'driver_commission_rate';
  static const String maxCancellationLimit = 'max_cancellation_limit';

  // KYC & onboarding flags
  static const String autoSyncDriverKycToCustomer =
      'auto_sync_driver_kyc_to_customer';
  static const String requireCustomerNinVerification =
      'require_customer_nin_verification';

  // App maintenance & versions
  static const String minSupportedAppVersion = 'min_supported_app_version';
  static const String inMaintenanceMode = 'in_maintenance_mode';
  static const String maintenanceMessage = 'maintenance_message';
}

/// App-wide dynamic configuration, served from Firebase Remote Config.
///
/// Design contract:
/// - **Never throws.** Every getter degrades to the compiled default in
///   [_defaults] when Firebase is unavailable, the network is down, or the
///   service was never initialised. This is required because the package is
///   read from widget code and unit tests, which run without an initialised
///   `FirebaseApp` (accessing `FirebaseRemoteConfig.instance` would throw).
/// - **Not a source of truth for money.** Commission and settlement figures
///   are computed server-side in `functions/src/driverStreak.ts` from
///   `system_configs`; see [driverCommissionRate] for why this value is
///   intentionally left unwired.
class RemoteConfigService {
  RemoteConfigService._();

  /// Compiled in-app defaults. Also used as the fetch-time `setDefaults`
  /// baseline so a cold, offline, first-launch client still behaves.
  static const Map<String, Object> _defaults = <String, Object>{
    // Driver & ride rules
    RemoteConfigKeys.requireMultiVehicleSnapshot: true,
    RemoteConfigKeys.driverCommissionRate: 0.15,
    RemoteConfigKeys.maxCancellationLimit: 3,
    // KYC & onboarding flags
    RemoteConfigKeys.autoSyncDriverKycToCustomer: true,
    RemoteConfigKeys.requireCustomerNinVerification: false,
    // App maintenance & versions
    RemoteConfigKeys.minSupportedAppVersion: '1.0.0',
    RemoteConfigKeys.inMaintenanceMode: false,
    RemoteConfigKeys.maintenanceMessage:
        'Sese Ride is under quick maintenance. Back shortly!',
  };

  static FirebaseRemoteConfig? _instance;
  static StreamSubscription<RemoteConfigUpdate>? _updateSubscription;
  static bool _initialized = false;

  /// Bumped after a successful [init] and on every live server push.
  ///
  /// Widgets that gate on a flag (for example the startup maintenance /
  /// force-update guard in `main.dart`) rebuild from this so publishing a new
  /// value takes effect without an app restart.
  static final ValueNotifier<int> revision = ValueNotifier<int>(0);

  /// Test-only overrides, keyed by [RemoteConfigKeys]. When non-null they
  /// short-circuit every getter so flows can be exercised without Firebase.
  static Map<String, Object>? _overrides;

  /// Lazily resolves the plugin singleton, swallowing the "no Firebase app"
  /// failure so getters stay usable in tests and offline startups.
  static FirebaseRemoteConfig? get _remoteConfig {
    if (_instance != null) return _instance;
    try {
      return _instance = FirebaseRemoteConfig.instance;
    } catch (e) {
      debugPrint('RemoteConfigService: instance unavailable ($e). '
          'Serving compiled defaults.');
      return null;
    }
  }

  /// Applies the config settings, loads in-app defaults, fetches, activates,
  /// and subscribes to real-time updates. Safe to call more than once.
  static Future<void> init() async {
    if (_initialized) return;
    final rc = _remoteConfig;
    if (rc == null) return;

    try {
      await rc.setConfigSettings(
        RemoteConfigSettings(
          fetchTimeout: const Duration(seconds: 10),
          // Throttled in release builds; unthrottled in debug so a parameter
          // change in the console is visible on the next fetch.
          minimumFetchInterval:
              kDebugMode ? Duration.zero : const Duration(hours: 1),
        ),
      );

      await rc.setDefaults(_defaults);
      await rc.fetchAndActivate();

      // Real-time updates: the server pushes new values to a live session
      // without waiting for the next cold start. The 6.x SDK exposes this as
      // `onConfigUpdated`.
      _updateSubscription ??= rc.onConfigUpdated.listen((event) async {
        try {
          await rc.activate();
          debugPrint('RemoteConfigService: live update ${event.updatedKeys}');
          revision.value++;
        } catch (e) {
          debugPrint('RemoteConfigService: activate after update failed: $e');
        }
      });

      _initialized = true;
      revision.value++;
    } catch (e) {
      // Keep serving compiled defaults rather than blocking app startup.
      debugPrint('RemoteConfigService.init failed, using defaults: $e');
    }
  }

  /// True once [init] has completed a fetch without throwing.
  static bool get isInitialized => _initialized;

  /// Releases the real-time listener. Called from app teardown / tests.
  static Future<void> dispose() async {
    await _updateSubscription?.cancel();
    _updateSubscription = null;
    _instance = null;
    _initialized = false;
    _overrides = null;
  }

  // --- Getters ---------------------------------------------------------
  // Each getter prefers a test override, then the activated remote value,
  // then the compiled default.

  static bool _bool(String key) {
    final override = _overrides?[key];
    if (override is bool) return override;
    try {
      return _remoteConfig?.getBool(key) ?? _defaults[key]! as bool;
    } catch (e) {
      debugPrint('RemoteConfigService: bool $key failed ($e)');
      return _defaults[key]! as bool;
    }
  }

  static double _double(String key) {
    final override = _overrides?[key];
    if (override is num) return override.toDouble();
    try {
      // `getDouble` is used for numeric keys so a server value authored as
      // `3.0` is not rejected by `getInt`'s stricter parse.
      return _remoteConfig?.getDouble(key) ?? _defaultNum(key);
    } catch (e) {
      debugPrint('RemoteConfigService: double $key failed ($e)');
      return _defaultNum(key);
    }
  }

  static int _int(String key) {
    final override = _overrides?[key];
    if (override is num) return override.toInt();
    try {
      return (_remoteConfig?.getDouble(key) ?? _defaultNum(key)).round();
    } catch (e) {
      debugPrint('RemoteConfigService: int $key failed ($e)');
      return _defaultNum(key).round();
    }
  }

  /// Compiled default for a numeric key, normalised to [double] because
  /// `setDefaults` accepts int and double literals interchangeably.
  static double _defaultNum(String key) => (_defaults[key]! as num).toDouble();

  static String _string(String key) {
    final override = _overrides?[key];
    if (override is String) return override;
    try {
      return _remoteConfig?.getString(key) ?? _defaults[key]! as String;
    } catch (e) {
      debugPrint('RemoteConfigService: string $key failed ($e)');
      return _defaults[key]! as String;
    }
  }

  // Verification & driver rules

  /// When true, a driver going ONLINE with exactly one approved vehicle skips
  /// the live camera snapshot and is taken straight online. Drivers with two
  /// or more approved vehicles always pick a session vehicle first.
  static bool get requireMultiVehicleSnapshot =>
      _bool(RemoteConfigKeys.requireMultiVehicleSnapshot);

  /// Mirrors an approved driver's KYC into their customer profile. See
  /// `DriverToCustomerSync` for the fields actually written.
  static bool get autoSyncDriverKycToCustomer =>
      _bool(RemoteConfigKeys.autoSyncDriverKycToCustomer);

  /// When true, customer KYC submission requires a verified NIN.
  static bool get requireCustomerNinVerification =>
      _bool(RemoteConfigKeys.requireCustomerNinVerification);

  /// Platform commission rate as a fraction of fare (0.15 == 15%).
  ///
  /// Intentionally **not wired into any fare or earnings calculation**.
  /// Commission is server-authoritative: `functions/src/driverStreak.ts`
  /// derives it from the admin-managed `DailyStreakConfig.baseCommissionRate`
  /// plus the `L1_RATES` step-down ladder, persists the result to
  /// `trips/{id}.settlement.commissionRate`, and the client only renders that
  /// settled value. A client-side Remote Config rate would be a second,
  /// user-overridable source of truth that can silently disagree with what a
  /// driver was actually charged, so earnings screens must keep reading the
  /// settlement snapshot.
  static double get driverCommissionRate =>
      _double(RemoteConfigKeys.driverCommissionRate);

  /// Maximum cancellations a customer may accumulate before the app blocks
  /// further ride requests.
  static int get maxCancellationLimit =>
      _int(RemoteConfigKeys.maxCancellationLimit);

  // App health & maintenance

  /// Lowest app version allowed to run, as a dotted `major.minor.patch`
  /// string. Compared against the installed build via [isAppVersionSupported].
  static String get minSupportedAppVersion =>
      _string(RemoteConfigKeys.minSupportedAppVersion);

  /// When true the app is locked behind [maintenanceMessage].
  static bool get inMaintenanceMode =>
      _bool(RemoteConfigKeys.inMaintenanceMode);

  /// Copy shown on the maintenance lock screen.
  static String get maintenanceMessage =>
      _string(RemoteConfigKeys.maintenanceMessage);

  /// True when [installedVersion] satisfies [minSupportedAppVersion].
  ///
  /// Compares the numeric `major.minor.patch` core only; a build suffix such
  /// as `1.0.0+1` is ignored so `1.0.0+9` still satisfies `1.0.0`. A blank
  /// or unparseable [installedVersion] is treated as supported so a
  /// platform-channel failure can never lock users out of the app.
  static bool isAppVersionSupported(String installedVersion) {
    final required = _parseVersion(minSupportedAppVersion);
    final installed = _parseVersion(installedVersion);
    if (required == null || installed == null) return true;

    for (var i = 0; i < 3; i++) {
      if (installed[i] != required[i]) return installed[i] > required[i];
    }
    return true;
  }

  /// Extracts `major.minor.patch` ints, tolerating `+build` and `-prerelease`
  /// suffixes. Returns null when the core is not numeric.
  static List<int>? _parseVersion(String raw) {
    final core = raw.trim().split(RegExp('[+-]')).first.trim();
    final parts = core.split('.');
    if (parts.isEmpty || parts.length > 3) return null;
    final out = <int>[0, 0, 0];
    for (var i = 0; i < 3; i++) {
      if (i >= parts.length) continue;
      final n = int.tryParse(parts[i].trim());
      if (n == null) return null;
      out[i] = n;
    }
    return out;
  }

  /// Installs [overrides] as the active test seam, bypassing Remote Config.
  @visibleForTesting
  static void debugSetOverrides(Map<String, Object>? overrides) {
    _overrides = overrides;
    revision.value++;
  }
}
