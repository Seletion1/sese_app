import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:sese_core/sese_core.dart';

/// Central guard against the Firestore `WatchStream: UNAUTHENTICATED` retry
/// loop seen on sese_hub (stale Firebase ID token => every `snapshots()`
/// listener closes with `Status{code=UNAUTHENTICATED, ...}` and retries
/// forever).
///
/// Usage:
/// 1. Call [ensureFreshHubIdToken] before opening long-lived collection
///    streams (each verification/support screen does this in `initState` and
///    [HubAccessService.checkAccess] does it before the `hub_staff` read).
/// 2. In every `StreamBuilder` error branch, check
///    [isHubSessionExpiredError(snapshot.error)] first and return
///    [HubSessionExpiredView] — it signs the staffer out once, shows the
///    "Session expired. Please log in again." notice, and the `_AuthGate`
///    in `main.dart` routes back to [LoginPage] automatically via
///    `authStateChanges` (there are no named routes — do NOT
///    `pushReplacementNamed('/login')`).
Future<bool> ensureFreshHubIdToken() async {
  try {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return false;
    // Force a server round-trip: clears stale/expiring credentials so the
    // Firestore WatchStream re-opens with a valid OAuth token instead of
    // looping on UNAUTHENTICATED.
    await user.getIdToken(true);
    return true;
  } on FirebaseAuthException catch (e) {
    debugPrint('HubSessionGuard: token refresh failed (${e.code}); signing out.');
    await _signOutHub();
    return false;
  } catch (e) {
    debugPrint('HubSessionGuard: token refresh error: $e');
    return false;
  }
}

/// True when [error] is a Firestore/Auth failure that means the session can
/// no longer authorize streams: `UNAUTHENTICATED` (stale/invalid credential).
///
/// `PERMISSION_DENIED` is deliberately NOT a session error: it means the
/// credential is valid but rules/App Check rejected the read (wrong
/// collection, missing staff record, unregistered debug token, ...).
/// Signing out on it is what caused the 1-second open-then-"Session expired"
/// loop on the verification desk — the session must be preserved so the
/// screen can show its retry/error UI instead.
bool isHubSessionExpiredError(Object? error) {
  if (error is FirebaseException) {
    final code = error.code.toLowerCase().replaceAll('-', '_');
    if (code == 'unauthenticated') {
      return true;
    }
    final msg = (error.message ?? '').toUpperCase();
    if (msg.contains('UNAUTHENTICATED') ||
        msg.contains('INVALID AUTHENTICATION CREDENTIALS')) {
      return true;
    }
    return false;
  }
  final text = error.toString().toUpperCase();
  return text.contains('UNAUTHENTICATED') ||
      text.contains('INVALID AUTHENTICATION CREDENTIALS');
}

/// Signs the staffer out (Firebase + Google, clearing cached credentials),
/// shows the "Session expired" notice, and returns true when [error] was a
/// session error (caller should then render [HubSessionExpiredView]).
/// Returns false when the error is unrelated (caller keeps its own UI).
Future<bool> handleHubStreamAuthError(
  BuildContext context,
  Object error,
) async {
  if (!isHubSessionExpiredError(error)) return false;
  await _signOutHub();
  if (context.mounted) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        const SnackBar(
          content: Text('Session expired. Please log in again.'),
          backgroundColor: Colors.orange,
        ),
      );
  }
  return true;
}

Future<void> _signOutHub() async {
  try {
    // Repository sign-out also clears the cached Google account so the next
    // sign-in re-prompts instead of silently reusing stale credentials.
    await FirebaseAuthRepository(isHubApp: true).signOut();
  } catch (_) {
    try {
      await FirebaseAuth.instance.signOut();
    } catch (_) {}
  }
}

/// Full-area notice rendered by stream error branches when the session is
/// gone. Signs out exactly once (post-frame, so no build side-effects) and
/// shows "Session expired. Please log in again." — the `_AuthGate` then
/// routes to the sign-in view automatically.
class HubSessionExpiredView extends StatefulWidget {
  final Object? error;
  final String contextLabel;

  const HubSessionExpiredView({
    super.key,
    this.error,
    this.contextLabel = 'live updates',
  });

  @override
  State<HubSessionExpiredView> createState() => _HubSessionExpiredViewState();
}

class _HubSessionExpiredViewState extends State<HubSessionExpiredView> {
  bool _handled = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _expireOnce());
  }

  Future<void> _expireOnce() async {
    if (_handled || !mounted) return;
    _handled = true;
    await _signOutHub();
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        const SnackBar(
          content: Text('Session expired. Please log in again.'),
          backgroundColor: Colors.orange,
        ),
      );
  }

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.lock_clock_outlined,
                size: 48, color: Colors.orange),
            const SizedBox(height: 12),
            const Text(
              'Session expired. Please log in again.',
              textAlign: TextAlign.center,
              style: TextStyle(fontWeight: FontWeight.bold, fontSize: 15),
            ),
            const SizedBox(height: 6),
            Text(
              'Could not load ${widget.contextLabel} with the current '
              'credentials. Returning to sign-in…',
              textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.grey, fontSize: 12),
            ),
            const SizedBox(height: 16),
            FilledButton.icon(
              icon: const Icon(Icons.login),
              label: const Text('Back to Sign In'),
              onPressed: _expireOnce,
            ),
          ],
        ),
      ),
    );
  }
}
