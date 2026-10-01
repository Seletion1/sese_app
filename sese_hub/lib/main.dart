import 'package:firebase_app_check/firebase_app_check.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:sese_core/sese_core.dart';

import 'firebase_options.dart';
import 'features/auth/login_page.dart';
import 'features/dashboard/presentation/hub_dashboard_screen.dart';
import 'features/config/services/system_config_service.dart';
import 'features/staff/services/hub_access_service.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);

  if (kDebugMode) {
    debugPrint(
      'sese_hub pinned App Check debug token: '
      '${AppCheckConfig.seseHubDebugToken}',
    );
  }
  // App Check is enforced on Firestore: without an activated provider
  // (e.g. the verification queue) every read fails PERMISSION_DENIED.
  await FirebaseAppCheck.instance.activate(
    providerAndroid: kDebugMode
        ? AndroidDebugProvider()
        : const AndroidPlayIntegrityProvider(),
    providerApple: kDebugMode
        ? AppleDebugProvider()
        : const AppleDeviceCheckProvider(),
  );

  // Prime cached country code for phone and regional config fields.
  await CountryDetectionService.instance.detectCountryCode();

  // Unified high-priority push (escalations, announcements) with chime.
  // Staff topics subscribe after qualification (dashboard shell).
  // ignore: discarded_futures
  PushNotificationService.init(onTap: _handlePushTap);

  runApp(const MyApp(showSplash: true));
}

/// Routes hub notification taps (logged; shells resolve live streams).
void _handlePushTap(Map<String, String> data) {
  debugPrint('sese_hub push tap: $data');
}

class MyApp extends StatefulWidget {
  final AuthRepository? authRepository;
  final HubAccessService? accessService;
  final bool showSplash;

  const MyApp({
    super.key,
    this.authRepository,
    this.accessService,
    this.showSplash = false,
  });

  @override
  State<MyApp> createState() => _MyAppState();
}

class _MyAppState extends State<MyApp> {
  @override
  void initState() {
    super.initState();
    // Best-effort restore of the persisted appearance (defaults to
    // ThemeMode.system, which adopts the OS Dark/Light preference).
    ThemeController.instance.load();
  }

  @override
  Widget build(BuildContext context) {
    final gate = _AuthGate(
      auth: widget.authRepository,
      accessService: widget.accessService,
    );

    return ValueListenableBuilder<ThemeMode>(
      valueListenable: ThemeController.instance,
      builder: (context, themeMode, _) {
        return MaterialApp(
          title: 'sese_hub',
          theme: AppTheme.light(),
          darkTheme: AppTheme.dark(),
          themeMode: themeMode,
          home: widget.showSplash
              ? SeSeSplashScreen(
                  nextScreen: gate,
                  subtitle: 'Staff Operations Hub',
                  logoVariant: SeSeLogoVariant.hub,
                )
              : gate,
        );
      },
    );
  }
}

/// Zero-trust gate for Sese Hub.
///
/// Flow:
/// - Not logged in -> [LoginPage] (shows no role hints or options).
/// - Logged in -> silent `hub_staff` qualification check:
///   qualified (doc exists OR primary owner) -> role-scoped dashboard;
///   not registered (verified by a successful registry read) -> sign out
///   once with a logged reason + generic rejection revealing nothing;
///   verification error (offline / PERMISSION_DENIED / App Check) -> the
///   session is PRESERVED and a retry screen is shown — a transient
///   failure never bounces the staffer straight back to sign-in.
class _AuthGate extends StatefulWidget {
  final AuthRepository? auth;
  final HubAccessService? accessService;

  const _AuthGate({this.auth, this.accessService});

  @override
  State<_AuthGate> createState() => _AuthGateState();
}

class _AuthGateState extends State<_AuthGate> {
  late final AuthRepository _authRepo;
  late final HubAccessService _access;
  final Map<String, Future<HubAccessResult>> _checks = {};
  final Set<String> _signedOutFor = {};
  late Stream<AppUser?> _authStream;

  @override
  void initState() {
    super.initState();
    _authRepo = widget.auth ?? FirebaseAuthRepository(isHubApp: true);
    _access = widget.accessService ?? const HubAccessService();
    _authStream = _authRepo.authStateChanges;
  }

  Future<HubAccessResult> _check(String email) {
    final key = email.trim().toLowerCase();
    return _checks.putIfAbsent(
      key,
      () => _access.checkAccess(email: email),
    );
  }

  /// Drops the cached hub_staff check for [email] so the next build re-runs
  /// the qualification read (used after a transient verification error).
  void _retryAccessCheck(String email) {
    setState(() => _checks.remove(email.trim().toLowerCase()));
  }

  /// Re-subscribes to the auth stream so a failed profile fetch (which the
  /// repository maps to `null`) is retried without forcing the staffer
  /// back through Google sign-in.
  void _retryProfileResolution() {
    setState(() => _authStream = _authRepo.authStateChanges);
  }

  void _signOutOnce(String email, String reason) {
    final key = email.trim().toLowerCase();
    if (_signedOutFor.add(key)) {
      debugPrint('sese_hub auth gate: signing out "$key" — $reason');
      // Fire-and-forget: the auth stream rebuilds to LoginPage on completion.
      _authRepo.signOut();
    }
  }

  /// True when Firebase Auth still holds a signed-in user even though the
  /// repository stream reported `null` (profile fetch failed / unresolved).
  /// Used to keep the staffer OFF the login screen until the profile check
  /// actually completes or fails conclusively.
  bool _hasRawFirebaseSession() {
    try {
      return FirebaseAuth.instance.currentUser != null;
    } catch (_) {
      // Firebase not initialized (unit tests) — no raw session to preserve.
      return false;
    }
  }

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<AppUser?>(
      stream: _authStream,
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return const _HubGateLoading();
        }

        if (snapshot.hasError) {
          debugPrint(
              'sese_hub auth gate: auth stream error: ${snapshot.error}');
          return _VerificationFailedNotice(
            message: 'Could not restore your session.',
            detail:
                'Your sign-in could not be verified (${snapshot.error}). '
                'Check your connection and try again.',
            onRetry: _retryProfileResolution,
          );
        }

        final user = snapshot.data;

        if (user == null) {
          // Race guard: the repository maps a failed profile fetch to `null`
          // even while a Firebase session is still active. Keep the staffer
          // on a retry screen instead of instantly routing back to Login.
          if (_hasRawFirebaseSession()) {
            debugPrint(
              'sese_hub auth gate: profile unresolved but a Firebase session '
              'is still active — staying on the verification screen.',
            );
            return _VerificationFailedNotice(
              message: 'Could not load your staff profile.',
              detail: 'Your account is signed in but its profile could not '
                  'be read yet. Check your connection and retry — you will '
                  'not need to sign in again.',
              onRetry: _retryProfileResolution,
              signOut: _authRepo.signOut,
            );
          }
          // Genuine sign-out: drop per-email caches so the next sign-in
          // re-runs the hub_staff check instead of replaying a stale
          // rejection (or a stale grant).
          if (_checks.isNotEmpty || _signedOutFor.isNotEmpty) {
            debugPrint(
                'sese_hub auth gate: session ended; clearing cached access checks.');
            _checks.clear();
            _signedOutFor.clear();
          }
          return LoginPage(auth: _authRepo);
        }

        final email = user.email;
        if (email.trim().isEmpty) {
          _signOutOnce(email, 'the account has no verified email address');
          return _NoRoleAssigned(auth: _authRepo);
        }

        return FutureBuilder<HubAccessResult>(
          future: _check(email),
          builder: (context, accessSnap) {
            if (accessSnap.connectionState == ConnectionState.waiting) {
              return const _HubGateLoading(label: 'Verifying staff access…');
            }
            final result = accessSnap.data;
            if (result == null) {
              return _VerificationFailedNotice(
                message: 'Could not verify your access.',
                detail: 'The staff registry check did not complete. Check '
                    'your connection and try again.',
                onRetry: () => _retryAccessCheck(email),
              );
            }
            if (result.status == HubAccessStatus.verificationError) {
              // The hub_staff read itself failed (offline,
              // PERMISSION_DENIED, App Check…). Never revoke the session
              // for a check we could not perform.
              debugPrint(
                'sese_hub auth gate: access check FAILED (not denied) for '
                '"$email": ${result.error}',
              );
              return _VerificationFailedNotice(
                message: 'Could not verify your access.',
                detail: 'Sese Hub could not reach the staff registry. Your '
                    'session is preserved — check your connection and '
                    'retry.',
                onRetry: () => _retryAccessCheck(email),
                signOut: () => _signOutOnce(
                    email, 'manual sign out from the verification screen'),
              );
            }
            if (result.qualified) {
              // Gmail pre-provisioning guard: Super authority always passes;
              // everyone else needs at least one assigned module permission.
              final hasAccess = result.isOwner ||
                  result.role == UserRole.superRole ||
                  result.assignedPermissions.isNotEmpty;
              if (hasAccess) {
                return HubDashboardScreen(
                  configService: SystemConfigService(),
                  user: user,
                  staffRole: result.role,
                  isOwner: result.isOwner,
                  permissions: result.assignedPermissions,
                );
              }
              _signOutOnce(email,
                  'the hub_staff record grants no module permissions');
              return _NoRoleAssigned(auth: _authRepo);
            }
            _signOutOnce(email, 'no active hub_staff record exists for this email');
            return _NoRoleAssigned(auth: _authRepo);
          },
        );
      },
    );
  }
}

/// Loading state shown while the auth stream or the hub_staff qualification
/// check is still in flight. The gate NEVER routes to [LoginPage] while one
/// of these is pending.
class _HubGateLoading extends StatelessWidget {
  final String label;

  const _HubGateLoading({this.label = 'Checking your session…'});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(
              width: 28,
              height: 28,
              child: CircularProgressIndicator(
                strokeWidth: 2.5,
                valueColor: AlwaysStoppedAnimation<Color>(Color(0xFFFFB800)),
              ),
            ),
            const SizedBox(height: 16),
            Text(label, textAlign: TextAlign.center),
          ],
        ),
      ),
    );
  }
}

/// Retry screen for transient verification failures (network offline,
/// PERMISSION_DENIED, profile fetch errors). The session is preserved —
/// only an explicit action signs the staffer out.
class _VerificationFailedNotice extends StatelessWidget {
  final String message;
  final String? detail;
  final VoidCallback onRetry;
  final VoidCallback? signOut;

  const _VerificationFailedNotice({
    required this.message,
    required this.onRetry,
    this.detail,
    this.signOut,
  });

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.cloud_off_outlined,
                  size: 64, color: Colors.orange),
              const SizedBox(height: 16),
              Text(
                message,
                style: const TextStyle(
                    fontSize: 20, fontWeight: FontWeight.bold),
                textAlign: TextAlign.center,
              ),
              if (detail != null) ...[
                const SizedBox(height: 8),
                Text(
                  detail!,
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: Colors.grey),
                ),
              ],
              const SizedBox(height: 24),
              FilledButton.icon(
                icon: const Icon(Icons.refresh),
                label: const Text('Retry'),
                onPressed: onRetry,
              ),
              if (signOut != null)
                TextButton(
                  onPressed: signOut,
                  child: const Text('Sign out instead'),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// No-role block screen for emails missing from `hub_staff` or holding
/// no active permissions. Shows only the standard message and a way out.
class _NoRoleAssigned extends StatelessWidget {
  final AuthRepository auth;

  const _NoRoleAssigned({required this.auth});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.lock_outlined, size: 64, color: Colors.red),
              const SizedBox(height: 16),
              const Text(
                hubAccessDeniedMessage,
                style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
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
