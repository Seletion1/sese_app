import 'package:firebase_app_check/firebase_app_check.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:sese_core/sese_core.dart';

import 'core/screens/force_update_screen.dart';
import 'core/screens/maintenance_screen.dart';
import 'core/services/remote_config_service.dart';
import 'driver_overlay_entry.dart';
import 'firebase_options.dart';
import 'features/auth/login_page.dart';
import 'features/driver/presentation/driver_onboarding_screen.dart';
import 'features/home/customer_home_shell.dart';
import 'features/home/driver_home_shell.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
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
  }
  await FirebaseAppCheck.instance.activate(
    providerAndroid: kDebugMode
        ? AndroidDebugProvider()
        : const AndroidPlayIntegrityProvider(),
    providerApple: kDebugMode
        ? AppleDebugProvider()
        : const AppleDeviceCheckProvider(),
  );

  // Detect user's country/dial code at startup (primary: locale, fallback: timezone, default: NG).
  // Result is cached synchronously for SesePhoneInputField's initialValue.
  await CountryDetectionService.instance.detectCountryCode();

  // App-wide dynamic flags (maintenance mode, minimum version, driver
  // verification rules). Must run after App Check is activated so the fetch
  // is not rejected, and before runApp so the first frame is already gated.
  // Never throws: RemoteConfigService falls back to compiled defaults.
  await RemoteConfigService.init();

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
void _handlePushTap(Map<String, String> data) {
  debugPrint('sese_ride push tap: $data');
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
          title: 'sese_ride',
          theme: AppTheme.light(),
          darkTheme: AppTheme.dark(),
          themeMode: themeMode,
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
class _AuthGate extends StatelessWidget {
  final AuthRepository? authRepository;

  const _AuthGate({this.authRepository});

  @override
  Widget build(BuildContext context) {
    final auth = authRepository ?? FirebaseAuthRepository();
    return StreamBuilder<AppUser?>(
      stream: auth.authStateChanges,
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return const Scaffold(
            body: Center(
              child: SizedBox(
                width: 28,
                height: 28,
                child: CircularProgressIndicator(
                  strokeWidth: 2.5,
                  valueColor: AlwaysStoppedAnimation<Color>(Color(0xFFFFB800)),
                ),
              ),
            ),
          );
        }

        final user = snapshot.data;

        if (user == null) {
          return LoginPage(auth: auth);
        }

        // Driver onboarding gate:
        // - `pending_onboarding` (fresh Create Account, Step 2 not yet
        //   submitted) -> Step 2 Personal Information Form.
        // - Any other driver state (pending hub review, approved) lands on
        //   Driver Home: a persistent banner covers the pending state and
        //   Fleet & Vehicles stays reachable while verification is pending.
        if (user.role == UserRole.driver && user.isPendingOnboarding) {
          return DriverOnboardingScreen(user: user, auth: auth);
        }

        switch (user.role) {
          case UserRole.customer:
            return CustomerHomeShell(user: user, auth: auth);
          case UserRole.driver:
            return DriverHomeShell(user: user, auth: auth);
          default:
            // Hub staff opened the wrong app.
            return _WrongAppScreen(user: user, auth: auth);
        }
      },
    );
  }
}

class _WrongAppScreen extends StatelessWidget {
  final AppUser user;
  final AuthRepository auth;
  const _WrongAppScreen({required this.user, required this.auth});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.error_outline, size: 64, color: Colors.red),
              const SizedBox(height: 16),
              const Text('Wrong App',
                  style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold)),
              const SizedBox(height: 8),
              Text(
                'Account ${user.email} is a hub staff account. '
                'Please use the sese_hub app instead.',
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 24),
              FilledButton.icon(
                icon: const Icon(Icons.logout),
                label: const Text('Sign Out'),
                onPressed: () => auth.signOut(),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
