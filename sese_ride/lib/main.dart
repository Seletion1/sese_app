import 'dart:async';

import 'package:firebase_app_check/firebase_app_check.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:sese_core/sese_core.dart';

import 'package:google_maps_flutter_android/google_maps_flutter_android.dart'
    show GoogleMapsFlutterAndroid;
import 'package:google_maps_flutter_platform_interface/google_maps_flutter_platform_interface.dart'
    show GoogleMapsFlutterPlatform;

import 'core/screens/force_update_screen.dart';
import 'core/screens/maintenance_screen.dart';
import 'core/services/remote_config_service.dart';
import 'core/services/shorebird_update_service.dart';
import 'driver_overlay_entry.dart';
export 'driver_overlay_entry.dart' show overlayMain;
import 'firebase_options.dart';
import 'features/auth/login_page.dart';
import 'features/driver/presentation/driver_onboarding_screen.dart';
import 'features/home/customer_home_shell.dart';
import 'features/home/driver_home_shell.dart';
import 'features/settings/role_controller.dart';
import 'features/customer/services/location_service.dart';
import 'widgets/map_provider.dart' show GmsAvailability;

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Use Texture Layer Hybrid Composition (TLHC) so native Google Maps renders
  // directly through Flutter's lightweight texture pipeline without creating
  // separate heavy Android window surfaces or triggering ANR onLayout stalls.
  final GoogleMapsFlutterPlatform mapsImplementation =
      GoogleMapsFlutterPlatform.instance;
  if (mapsImplementation is GoogleMapsFlutterAndroid) {
    mapsImplementation.useAndroidViewSurface = false;
  }

  // Prime GMS availability check so map surfaces have synchronous 0ms resolution.
  // ignore: discarded_futures
  unawaited(GmsAvailability.isAvailable());

  await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);

  // App Check attestation is ENFORCED on Firestore: without an activated
  // provider every read fails with PERMISSION_DENIED. Debug builds use the
  // pinned debug token (see AppCheckConfig + MainActivity seeding);
  // release builds use Play Integrity / App Attest.
  if (kDebugMode) {
    debugPrint(
      'sese_ride pinned App Check debug token: '
      '${AppCheckConfig.seseRideDebugToken}',
    );
    try {
      await const MethodChannel('com.sesetech.sese_ride/app_check').invokeMethod(
        'pinDebugToken',
        {'token': AppCheckConfig.seseRideDebugToken},
      );
    } catch (e) {
      debugPrint('AppCheck pin error: $e');
    }
  }
  try {
    await FirebaseAppCheck.instance.activate(
      providerAndroid: kDebugMode
          ? AndroidDebugProvider()
          : const AndroidPlayIntegrityProvider(),
      providerApple: kDebugMode
          ? AppleDebugProvider()
          : const AppleDeviceCheckProvider(),
    );
  } catch (e) {
    debugPrint('AppCheck activate error: $e');
  }

  // Detect user's country/dial code at startup (primary: locale, fallback: timezone, default: NG).
  // Result is cached synchronously for SesePhoneInputField's initialValue.
  await CountryDetectionService.instance.detectCountryCode();

  // Proactive fast location priming on boot (uses last known position for instant load)
  // ignore: discarded_futures
  unawaited(LocationService.primeFastLocation());

  // Restore the persisted theme (defaults to system theme) before first frame builds.
  await ThemeController.instance.load();

  // App-wide dynamic flags (maintenance mode, minimum version, driver
  // verification rules). Must run after App Check is activated so the fetch
  // is not rejected, and before runApp so the first frame is already gated.
  // Never throws: RemoteConfigService falls back to compiled defaults.
  await RemoteConfigService.init();

  // Prime custom UI icons cache (vehicles, package boxes) from local storage
  // and sync from backend Firebase Storage.
  // ignore: discarded_futures
  unawaited(IconCacheService.instance.initialize());

  // Prime dynamic awareness & info tooltips from server and local view tracking.
  // ignore: discarded_futures
  unawaited(AwarenessTooltipService.instance.initialize());

  // Non-blocking Over-The-Air (OTA) Dart patch check via Shorebird.
  // Downloads updates in background; applied on next cold app restart.
  // ignore: discarded_futures
  unawaited(ShorebirdUpdateService().checkForUpdates());

  // Resolved here, behind the splash, so _AppGuard can decide synchronously.
  // An empty string means "unknown" and is treated as supported.
  final installedVersion = await _resolveInstalledVersion();

  // Unified high-priority push (order/chat/system) with custom chime.
  // Tap routing is handled per-screen; the overlay entry above stays
  // referenced so tree-shaking keeps `overlayMain`.
  // ignore: discarded_futures
  PushNotificationService.init(onTap: _handlePushTap);
  // Keep a static reference so the overlay entry-point is retained.
  // ignore: unnecessary_statements
  overlayMain;

  // Widget-build safety net (2026-10-01): if any screen's build fails on
  // device, show a readable error card instead of a blank/grey void — and
  // log the full details. A blank home strands an earning driver with zero
  // information; this converts "white screen, unknown cause" into a named
  // error the user can report and we can fix exactly. Only renders when a
  // build has ALREADY failed; it changes nothing on healthy frames.
  ErrorWidget.builder = (FlutterErrorDetails details) {
    debugPrint('sese_ride build failure: ${details.exceptionAsString()}');
    debugPrint(details.stack.toString());
    return Material(
      child: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.error_outline,
                    size: 48, color: Colors.red.shade700),
                const SizedBox(height: 12),
                const Text(
                  'Something went wrong',
                  style:
                      TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 8),
                const Text(
                  'Please restart the app. If this keeps happening, contact '
                  'support with the code below.',
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 12),
                SelectableText(
                  details.exceptionAsString().split('\n').first,
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                      fontSize: 12, fontFamily: 'monospace'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  };

  // showSplash: true — the Flutter SeSeSplashScreen is the ONLY branded
  // experience. The native Android window is now a plain solid-colour fill
  // (matching system theme) so there is no double-splash; it fades seamlessly
  // into the Flutter splash logo on the first engine frame.
  runApp(MyApp(showSplash: true, installedVersion: installedVersion));
}

/// Reads the running build's version, or `''` when the platform channel is
/// unavailable (unit tests, unsupported platforms).
Future<String> _resolveInstalledVersion() async {
  try {
    return (await PackageInfo.fromPlatform()).version;
  } catch (e) {
    debugPrint('sese_ride: could not resolve package version ($e)');
    return '';
  }
}

/// Routes notification taps to in-app destinations.
///
/// The unified "SeSe Driver Active" ongoing notification carries
/// `type=foreground_request`: tapping it already restores `MainActivity` to
/// the foreground (content intent with
/// `FLAG_UPDATE_CURRENT | FLAG_IMMUTABLE`), so the handler only logs it —
/// no extra navigation that could fight the restore.
void _handlePushTap(Map<String, String> data) {
  debugPrint('sese_ride push tap: $data');
  if (data['type'] == 'foreground_request') {
    debugPrint('sese_ride: online-alert tap — app restored to foreground.');
    return;
  }
  // Deep-link routing (trip chat sheets, order feed) is resolved by the
  // foreground shells via their live streams; the tap payload is logged
  // here for diagnostics and future route wiring.
}

class MyApp extends StatefulWidget {
  final AuthRepository? authRepository;
  final bool showSplash;

  /// Running build version, resolved in `main()`. Empty or null means unknown,
  /// which `_AppGuard` treats as "supported" so a platform-channel failure can
  /// never lock users out of the app.
  final String? installedVersion;

  const MyApp({
    super.key,
    this.authRepository,
    this.showSplash = false,
    this.installedVersion,
  });

  @override
  State<MyApp> createState() => _MyAppState();
}

class _MyAppState extends State<MyApp> {
  @override
  void initState() {
    super.initState();
    // Best-effort restore of the persisted theme (defaults to system).
    ThemeController.instance.load();
  }

  @override
  Widget build(BuildContext context) {
    // Rebuilds the gate when a live Remote Config push changes a gated flag.
    final gate = ValueListenableBuilder<int>(
      valueListenable: RemoteConfigService.revision,
      builder: (context, _, _) => _AppGuard(
        installedVersion: widget.installedVersion ?? '',
        child: _AuthGate(authRepository: widget.authRepository),
      ),
    );

    return ValueListenableBuilder<ThemeMode>(
      valueListenable: ThemeController.instance,
      builder: (context, themeMode, _) {
        return MaterialApp(
          navigatorKey: IncomingCallOverlay.navigatorKey,
          title: 'sese_ride',
          theme: AppTheme.light(),
          darkTheme: AppTheme.dark(),
          themeMode: themeMode,
          builder: (context, child) => IncomingCallOverlay(
            child: child ?? const SizedBox.shrink(),
          ),
          home: widget.showSplash
              ? SeSeSplashScreen(
                  nextScreen: gate,
                  subtitle: 'Ride & Delivery in Motion',
                )
              : gate,
        );
      },
    );
  }
}

/// Enforces the app-health Remote Config flags before any feature UI renders.
///
/// Precedence: maintenance mode wins over the version check, because a locked
/// app cannot offer an update path either. Both gates are re-evaluated on every
/// Remote Config live update because the parent rebuilds from
/// [RemoteConfigService.revision].
///
/// Deliberately synchronous: [installedVersion] is resolved in `main()` while
/// the splash screen is up, so no spinner (and no perpetually-scheduled frame)
/// is introduced on the way to the first feature paint.
class _AppGuard extends StatelessWidget {
  final Widget child;
  final String installedVersion;

  const _AppGuard({required this.child, required this.installedVersion});

  @override
  Widget build(BuildContext context) {
    if (RemoteConfigService.inMaintenanceMode) {
      return MaintenanceScreen(
          message: RemoteConfigService.maintenanceMessage);
    }

    if (!RemoteConfigService.isAppVersionSupported(installedVersion)) {
      return ForceUpdateScreen(
        updateUrl: ForceUpdateScreen.defaultUpdateUrl,
        requiredVersion: RemoteConfigService.minSupportedAppVersion,
      );
    }

    return child;
  }
}

/// Role-based routing gate. Listens to the Firebase auth state stream and
/// renders the correct shell based on the authenticated user's role.
///
/// **Must be a [StatefulWidget].** The [AuthRepository] instance (and
/// therefore its [authStateChanges] async-mapped stream) must survive
/// rebuilds. If it were created inside [build], every parent rebuild would
/// produce a fresh [asyncMap] that re-delivers the still-cached Firebase
/// user before the null event, re-routing a signing-out user back to the
/// dashboard — the "sign-out loop" bug.
class _AuthGate extends StatefulWidget {
  final AuthRepository? authRepository;

  const _AuthGate({this.authRepository});

  @override
  State<_AuthGate> createState() => _AuthGateState();
}

class _AuthGateState extends State<_AuthGate> {
  /// Created once in [initState] and held for the widget's lifetime.
  /// Using [widget.authRepository] when injected (tests), or a fresh
  /// [FirebaseAuthRepository] otherwise — both are created exactly once.
  late final AuthRepository _auth;
  String? _modeRestoreUid;
  Future<UserRole>? _modeRestoreFuture;

  @override
  void initState() {
    super.initState();
    _auth = widget.authRepository ?? FirebaseAuthRepository();
  }

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<AppUser?>(
      stream: _auth.authStateChanges,
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          // Transparent scaffold — blends into the SeSeSplashScreen that
          // is still fading in above us. The spinner is intentionally absent
          // here; any loading cue will appear after the splash finishes.
          return const Scaffold(body: SizedBox.shrink());
        }

        final user = snapshot.data;

        if (user == null) {
          _modeRestoreUid = null;
          _modeRestoreFuture = null;
          return LoginPage(auth: _auth);
        }

        // Initialize in-app VoIP calling subsystem with the authenticated user credentials
        // ignore: discarded_futures
        CallServiceManager.instance.initialize(
          currentUserId: user.uid,
          displayName: user.fullName,
          avatarUrl: user.photoUrl,
        );

        // Driver onboarding gate:
        // - `pending_onboarding` (fresh Create Account, Step 2 not yet
        //   submitted) -> Step 2 Personal Information Form.
        // - Any other driver state (pending hub review, approved) lands on
        //   Driver Home: a persistent banner covers the pending state and
        //   Fleet & Vehicles stays reachable while verification is pending.
        if (user.role == UserRole.driver && user.isPendingOnboarding) {
          return DriverOnboardingScreen(user: user, auth: _auth);
        }

        if (user.role == UserRole.customer || user.role == UserRole.driver) {
          if (_modeRestoreUid != user.uid || _modeRestoreFuture == null) {
            _modeRestoreUid = user.uid;
            _modeRestoreFuture = RoleController.instance.restoreSession(
              userId: user.uid,
              fallbackRole: user.role,
              onProtectionExpired: () {
                final navigator = IncomingCallOverlay.navigatorKey.currentState;
                if (navigator == null) return;
                navigator.pushAndRemoveUntil(
                  MaterialPageRoute(
                    builder: (_) => DriverHomeShell(user: user, auth: _auth),
                  ),
                  (route) => false,
                );
              },
            );
          }
          return FutureBuilder<UserRole>(
            future: _modeRestoreFuture,
            builder: (context, modeSnapshot) {
              if (modeSnapshot.connectionState != ConnectionState.done) {
                return const Scaffold(body: SizedBox.shrink());
              }
              switch (modeSnapshot.data ?? user.role) {
                case UserRole.customer:
                  return CustomerHomeShell(user: user, auth: _auth);
                case UserRole.driver:
                  return DriverHomeShell(user: user, auth: _auth);
                case UserRole.admin:
                case UserRole.superRole:
                case UserRole.agent:
                  return CustomerHomeShell(user: user, auth: _auth);
              }
            },
          );
        }

        switch (user.role) {
          case UserRole.customer:
            return CustomerHomeShell(user: user, auth: _auth);
          case UserRole.driver:
            return DriverHomeShell(user: user, auth: _auth);
          case UserRole.admin:
          case UserRole.superRole:
          case UserRole.agent:
            // Admin/super/agent accounts are permitted to use customer
            // features in sese_ride (unified wallet & account access).
            // Route to CustomerHomeShell so the owner can book rides and
            // monitor the platform while staying logged in.
            return CustomerHomeShell(user: user, auth: _auth);
        }
      },
    );
  }
}
