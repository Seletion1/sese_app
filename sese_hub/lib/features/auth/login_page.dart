import 'package:firebase_auth/firebase_auth.dart' show FirebaseAuthException;
import 'package:flutter/material.dart';
import 'package:sese_core/sese_core.dart';
import '../staff/services/hub_access_service.dart';

/// sese_hub staff sign-in — email/password or Google OAuth.
///
/// Zero role leakage: no role steps, hints, or options. After every
/// successful sign-in a silent `hub_staff` qualification check runs;
/// unqualified accounts are signed straight back out with a generic
/// modal. Navigation is handled by the StreamBuilder _AuthGate in main.dart.
class LoginPage extends StatefulWidget {
  final AuthRepository? auth;

  const LoginPage({super.key, this.auth});

  @override
  State<LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends State<LoginPage> {
  final _formKey = GlobalKey<FormState>();
  final _email = TextEditingController();
  final _password = TextEditingController();
  late final AuthRepository _auth;
  final HubAccessService _access = const HubAccessService();

  bool _obscurePassword = true;
  bool _submitting = false;

  @override
  void initState() {
    super.initState();
    _auth = widget.auth ?? FirebaseAuthRepository(isHubApp: true);
  }

  @override
  void dispose() {
    _email.dispose();
    _password.dispose();
    super.dispose();
  }

  void _showError(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message), backgroundColor: Colors.red.shade700),
    );
  }

  /// Silent post-login qualification gate. Returns true when the account
  /// may proceed; signs the user back out and shows the generic modal
  /// otherwise — without revealing any role information.
  ///
  /// Two distinct failure modes:
  /// - NOT REGISTERED (proven by a successful registry read): the session
  ///   is revoked and the generic Access Denied modal is shown.
  /// - VERIFICATION ERROR (offline / PERMISSION_DENIED / App Check): the
  ///   session is KEPT — `_AuthGate` takes over with its retry screen so a
  ///   transient failure never bounces the staffer straight back to
  ///   sign-in (the historic ejection loop).
  Future<bool> _verifyHubAccess(AppUser user) async {
    final result = await _access.checkAccess(email: user.email);
    if (result.qualified) return true;
    if (result.status == HubAccessStatus.verificationError) {
      debugPrint(
        'LoginPage: hub access could not be verified for ${user.email} '
        '(${result.error}); keeping the session for retry via the auth gate.',
      );
      return true; // The gate's verification screen offers Retry.
    }
    debugPrint(
      'LoginPage: no active hub_staff record for ${user.email}; '
      'revoking the session.',
    );
    try {
      await _auth.signOut();
    } catch (_) {}
    if (!mounted) return false;
    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        title: const Row(
          children: [
            Icon(Icons.lock_outlined, color: Colors.red),
            SizedBox(width: 8),
            Text('Access Denied'),
          ],
        ),
        content: const Text(
          'Your account is not qualified or registered to access '
          'Sese Hub. Please contact the system owner.',
        ),
        actions: [
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('Understood'),
          ),
        ],
      ),
    );
    return false;
  }

  Future<void> _signInWithPassword() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() => _submitting = true);
    try {
      // Success: silent hub_staff check, then _AuthGate handles navigation.
      final user = await _auth.signInWithEmailPassword(
        email: _email.text.trim(),
        password: _password.text,
      );
      await _verifyHubAccess(user);
    } on FirebaseAuthException catch (e) {
      _showError(_authErrorMessage(e.code));
    } catch (e) {
      _showError('Sign-in failed. Please try again.');
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  Future<void> _signInWithGoogle() async {
    setState(() => _submitting = true);
    try {
      final user = await _auth.signInWithGoogle();
      await _verifyHubAccess(user);
      // Navigation handled by _AuthGate.
    } on FirebaseAuthException catch (e) {
      debugPrint('LoginPage: FirebaseAuthException during Google sign-in: ${e.code} - ${e.message}');
      if (e.code != 'google-sign-in-cancelled') {
        _showError(_authErrorMessage(e.code));
      }
    } catch (e, stack) {
      debugPrint('LoginPage: Unexpected error during Google sign-in: $e\n$stack');
      _showError(_mapGoogleSignInError(e));
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  /// Maps raw Google Sign-In failures (thrown as generic exceptions carrying
  /// `ApiException: <code>`) to actionable user messages.
  ///
  /// - 10 (DEVELOPER_ERROR): signing cert / package / OAuth client mismatch.
  /// - 7 (NETWORK_ERROR): Play Services couldn't reach Google — retry.
  /// - 12500: OAuth consent / account state problem.
  /// - 12501: user cancelled the account picker.
  String _mapGoogleSignInError(Object e) {
    final text = e.toString();
    if (text.contains('ApiException: 10')) {
      return 'Google sign-in blocked (Error 10): this app build is not '
          'registered with Google. Reinstall the app from a fresh build and '
          'ensure its signing certificate is added in Firebase console.';
    }
    if (text.contains('ApiException: 7') ||
        text.contains('network_error')) {
      return 'Google sign-in needs a connection to Google Play services. '
          'Check your internet, update Play services, then try again — '
          'or use email sign-in below.';
    }
    if (text.contains('ApiException: 12500')) {
      return 'Google sign-in is not set up for this account. Try another '
          'account or use email sign-in.';
    }
    if (text.contains('ApiException: 12501') ||
        text.contains('sign_in_canceled')) {
      return 'Google sign-in was cancelled.';
    }
    return 'Google sign-in failed. Please try again.';
  }

  String _authErrorMessage(String code) {
    switch (code) {
      case 'user-not-found':
        return 'No account found with this email.';
      case 'wrong-password':
        return 'Incorrect email or password.';
      case 'invalid-credential':
        return 'Invalid authentication credentials. Please try again.';
      case 'too-many-requests':
        return 'Too many failed attempts. Please wait a moment.';
      case 'user-disabled':
        return 'This account has been disabled. Contact an administrator.';
      case 'account-exists-with-different-credential':
        return 'This email is already registered with a different sign-in method. '
            'Sign in with email & password instead.';
      case 'credential-already-in-use':
      case 'provider-already-linked':
        return 'This sign-in method is already linked. Please sign in normally.';
      case 'requires-recent-login':
        return 'For security, please sign out and sign back in, then try again.';
      case 'operation-not-allowed':
        return 'This sign-in method is currently disabled. Contact an administrator.';
      case 'user-token-expired':
        return 'Your session expired. Please sign in again.';
      case 'invalid-email':
        return 'Please enter a valid email address.';
      case 'channel-error':
        return 'Unable to connect to authentication service. Please check your credentials and internet connection.';
      default:
        return 'Sign-in failed. Please verify your credentials and try again.';
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            // 16px gutters keep the form edge-to-edge on phones; the 400
            // cap only centers the column on tablets/desktop.
            padding: const EdgeInsets.all(16),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 400),
              child: Form(
                key: _formKey,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    const Center(
                        child: SeSeLogo(
                            size: 140, variant: SeSeLogoVariant.hub)),
                    const SizedBox(height: 16),
                    Text(
                      'Welcome',
                      style: Theme.of(context).textTheme.headlineSmall,
                      textAlign: TextAlign.center,
                    ),
                    const Text(
                      'Staff access only',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: Colors.grey),
                    ),
                    const SizedBox(height: 32),
                    GoogleSignInButton(
                      onPressed: () {
                        if (!_submitting) _signInWithGoogle();
                      },
                    ),
                    const SizedBox(height: 24),
                    TextFormField(
                      controller: _email,
                      keyboardType: TextInputType.emailAddress,
                      decoration: const InputDecoration(
                        labelText: 'Gmail / Email',
                      ),
                      validator: (v) {
                        if (v == null || v.trim().isEmpty) return 'Required';
                        if (!v.contains('@')) return 'Enter a valid email';
                        return null;
                      },
                    ),
                    const SizedBox(height: 12),
                    TextFormField(
                      controller: _password,
                      obscureText: _obscurePassword,
                      decoration: InputDecoration(
                        labelText: 'Password',
                        suffixIcon: IconButton(
                          icon: Icon(_obscurePassword
                              ? Icons.visibility
                              : Icons.visibility_off),
                          onPressed: () => setState(
                              () => _obscurePassword = !_obscurePassword),
                        ),
                      ),
                      validator: (v) {
                        if (v == null || v.isEmpty) return 'Required';
                        if (v.length < 6) return 'Min 6 characters';
                        return null;
                      },
                    ),
                    const SizedBox(height: 20),
                    FilledButton(
                      onPressed: _submitting ? null : _signInWithPassword,
                      child: _submitting
                          ? const SizedBox(
                              height: 20,
                              width: 20,
                              child:
                                  CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Text('Sign in'),
                    ),
                    const SizedBox(height: 12),
                    const LegalAuthDisclaimer(),
                    const SizedBox(height: 12),
                    const Text(
                      'No self-registration. Contact the system owner for access.',
                      textAlign: TextAlign.center,
                      style: TextStyle(fontSize: 12, color: Colors.grey),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
