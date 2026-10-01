import 'dart:io' show Platform;
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart' as fb;
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:sese_core/sese_core.dart';

import 'auth_controller.dart';
import '../driver/presentation/driver_onboarding_screen.dart';
import '../home/customer_home_shell.dart';
import '../home/driver_home_shell.dart';
import '../referral/referral_input_widget.dart';
import 'package:sese_core/sese_core.dart'
    show ReferralService;

/// Unified Authentication Screen for sese_ride.
/// Supports Customer and Driver authentication with dual action modes:
/// - Sign In (`isSignUpMode == false`)
/// - Create Account (`isSignUpMode == true`)
///
/// Features:
/// 1. Warm Gold (`seseGold`) dynamic highlight for active action mode and role.
/// 2. Platform-aware social buttons: Google (Android/Web/iOS) and Apple (iOS).
/// 3. Sign In OAuth check: If document does NOT exist in `users`/`drivers`,
///    login is stopped and red SnackBar shown:
///    "Account does not exist. Please tap 'Create Account' to register."
/// 4. Create Account OAuth check: Extracts displayName, email, photoURL, and
///    pre-populates fields on the SAME screen for editing before final submission.
/// 5. OAuth buttons bypass Form key validation so empty field errors never block them.
class AuthScreen extends StatefulWidget {
  final AuthRepository? auth;
  final AuthController? controller;
  final UserRole initialRole;
  final bool initialSignUpMode;

  const AuthScreen({
    super.key,
    this.auth,
    this.controller,
    this.initialRole = UserRole.customer,
    this.initialSignUpMode = false,
  });

  @override
  State<AuthScreen> createState() => _AuthScreenState();
}

class _AuthScreenState extends State<AuthScreen> {
  final _formKey = GlobalKey<FormState>();

  late final AuthController _controller;
  late final AuthRepository _auth;

  final _firstNameController = TextEditingController();
  final _lastNameController = TextEditingController();
  final _emailController = TextEditingController();
  final _phoneController = TextEditingController();
  final _passwordController = TextEditingController();

  bool _obscurePassword = true;
  String? _referredBy;

  static const Color _seseGold = AppColors.seseGold;
  static const Color _roleAccentDark = Color(0xFFEAA200);
  static const Color _roleSelectedFill = Color(0xFFFFF6D6);

  static const String _accountMissingMessage =
      "Account does not exist. Please tap 'Create Account' to register.";

  @override
  void initState() {
    super.initState();
    _auth = widget.auth ?? FirebaseAuthRepository();
    _controller = widget.controller ??
        AuthController(
          auth: _auth,
          initialRole: widget.initialRole,
          initialSignUpMode: widget.initialSignUpMode,
        );
    _controller.addListener(_onControllerUpdate);
  }

  void _onControllerUpdate() {
    if (!mounted) return;
    if (_controller.firstName != _firstNameController.text) {
      _firstNameController.text = _controller.firstName;
    }
    if (_controller.lastName != _lastNameController.text) {
      _lastNameController.text = _controller.lastName;
    }
    if (_controller.email != _emailController.text) {
      _emailController.text = _controller.email;
    }
    if (_controller.phoneNumber != _phoneController.text) {
      _phoneController.text = _controller.phoneNumber;
    }
    setState(() {});
  }

  @override
  void dispose() {
    _controller.removeListener(_onControllerUpdate);
    if (widget.controller == null) {
      _controller.dispose();
    }
    _firstNameController.dispose();
    _lastNameController.dispose();
    _emailController.dispose();
    _phoneController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  void _showError(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: Colors.red.shade700,
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  // ─── OAuth Authentication Pipeline ──────────────────────────────────────────

  Future<void> _handleOAuth(String provider) async {
    _controller.setLoading(true);
    _controller.clearError();

    try {
      if (provider == 'google') {
        final appUser = await _controller.continueWithGoogle(
          role: _controller.selectedRole,
        );

        if (!mounted) return;

        if (appUser.role == UserRole.driver) {
          if (appUser.isPendingOnboarding) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: const Text(
                  'Driver account created! Proceed to Step 2: Personal Information.',
                ),
                backgroundColor: Colors.green.shade800,
                behavior: SnackBarBehavior.floating,
              ),
            );
            Navigator.of(context).pushAndRemoveUntil(
              MaterialPageRoute(
                builder: (_) => DriverOnboardingScreen(user: appUser, auth: _auth),
              ),
              (route) => false,
            );
          } else {
            Navigator.of(context).pushAndRemoveUntil(
              MaterialPageRoute(
                builder: (_) => DriverHomeShell(user: appUser, auth: _auth),
              ),
              (route) => false,
            );
          }
        } else {
          // Customer role -> CustomerHomeShell
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(
                'Welcome, ${appUser.fullName.isNotEmpty ? appUser.fullName : appUser.email}!',
              ),
              backgroundColor: Colors.green.shade800,
              behavior: SnackBarBehavior.floating,
            ),
          );
          Navigator.of(context).pushAndRemoveUntil(
            MaterialPageRoute(
              builder: (_) => CustomerHomeShell(user: appUser, auth: _auth),
            ),
            (route) => false,
          );
        }
        return;
      }

      if (provider != 'apple') {
        throw Exception('Unsupported provider: $provider');
      }

      final fbAuth = fb.FirebaseAuth.instance;
      final appleProvider = fb.AppleAuthProvider();
      final credential = await fbAuth.signInWithProvider(appleProvider);

      final firebaseUser = credential.user;
      if (firebaseUser == null) {
        throw Exception('User authentication failed.');
      }

      final uid = firebaseUser.uid;
      final isDriver = _controller.selectedRole == UserRole.driver;
      final targetCollection = isDriver ? 'drivers' : 'users';

      final firestore = FirebaseFirestore.instance;

      final docByUid = await firestore.collection(targetCollection).doc(uid).get();
      final docExists = docByUid.exists && docByUid.data() != null;

      if (!_controller.isSignUpMode) {
        // ─── Mode A: SIGN IN ──────────────────────────────────────────────────
        if (docExists) {
          final appUser = await _fetchExistingAppUser(firebaseUser, _controller.selectedRole);
          if (mounted) {
            _routeToHome(appUser);
          }
        } else {
          try {
            await _auth.signOut();
          } catch (_) {}
          _showError(_accountMissingMessage);
        }
      } else {
        // ─── Mode B: CREATE ACCOUNT ───────────────────────────────────────────
        String firstName = '';
        String lastName = '';
        final displayName = firebaseUser.displayName?.trim() ?? '';
        if (displayName.isNotEmpty) {
          final parts = displayName.split(RegExp(r'\s+'));
          firstName = parts.first;
          if (parts.length > 1) {
            lastName = parts.sublist(1).join(' ');
          }
        }

        if (isDriver) {
          final driverDocRef = firestore.collection('drivers').doc(uid);
          final existingDoc = await driverDocRef.get();
          final existingData = existingDoc.data();

          final driverData = <String, dynamic>{
            'uid': uid,
            'email': firebaseUser.email ?? '',
            'displayName': displayName,
            'fullName': displayName.isNotEmpty ? displayName : (firebaseUser.email ?? ''),
            'firstName': firstName,
            'lastName': lastName,
            'photoURL': firebaseUser.photoURL ?? '',
            'photoUrl': firebaseUser.photoURL ?? '',
            'role': 'driver',
            'verificationStatus': existingData?['verificationStatus'] ?? DriverVerification.pendingOnboarding,
            'isProfileVerified': existingData?['isProfileVerified'] ?? false,
            'isVehicleVerified': existingData?['isVehicleVerified'] ?? false,
            'canGoOnline': existingData?['canGoOnline'] ?? false,
            'isActive': existingData?['isActive'] ?? false,
            'createdAt': existingData?['createdAt'] ?? FieldValue.serverTimestamp(),
          };
          if (firebaseUser.phoneNumber != null && firebaseUser.phoneNumber!.trim().isNotEmpty) {
            driverData['phoneNumber'] = firebaseUser.phoneNumber!.trim();
          }
          await driverDocRef.set(driverData, SetOptions(merge: true));

          final appUser = AppUser(
            uid: uid,
            fullName: displayName.isNotEmpty ? displayName : (firebaseUser.email ?? ''),
            email: firebaseUser.email ?? '',
            phoneNumber: firebaseUser.phoneNumber ?? '',
            role: UserRole.driver,
            isActive: false,
            createdAt: firebaseUser.metadata.creationTime ?? DateTime.now(),
            photoUrl: firebaseUser.photoURL ?? '',
            verificationStatus: DriverVerification.pendingOnboarding,
          );

          if (mounted) {
            _routeToHome(appUser);
          }
        } else {
          final userDocRef = firestore.collection('users').doc(uid);
          final existingDoc = await userDocRef.get();
          final existingData = existingDoc.data();

          final userData = <String, dynamic>{
            'uid': uid,
            'email': firebaseUser.email ?? '',
            'displayName': displayName,
            'fullName': displayName.isNotEmpty ? displayName : (firebaseUser.email ?? ''),
            'firstName': firstName,
            'lastName': lastName,
            'photoURL': firebaseUser.photoURL ?? '',
            'photoUrl': firebaseUser.photoURL ?? '',
            'role': 'customer',
            'isActive': true,
            'createdAt': existingData?['createdAt'] ?? FieldValue.serverTimestamp(),
          };
          if (firebaseUser.phoneNumber != null && firebaseUser.phoneNumber!.trim().isNotEmpty) {
            userData['phoneNumber'] = firebaseUser.phoneNumber!.trim();
          }
          await userDocRef.set(userData, SetOptions(merge: true));

          final appUser = AppUser(
            uid: uid,
            fullName: displayName.isNotEmpty ? displayName : (firebaseUser.email ?? ''),
            email: firebaseUser.email ?? '',
            phoneNumber: firebaseUser.phoneNumber ?? '',
            role: UserRole.customer,
            isActive: true,
            createdAt: firebaseUser.metadata.creationTime ?? DateTime.now(),
            photoUrl: firebaseUser.photoURL ?? '',
          );

          if (mounted) {
            _routeToHome(appUser);
          }
        }
      }
    } on fb.FirebaseAuthException catch (e) {
      if (e.code == 'driver-account-missing') {
        try {
          await _auth.signOut();
        } catch (_) {}
        _showError(_accountMissingMessage);
      } else if (e.code != 'google-sign-in-cancelled' && e.code != 'canceled') {
        _showError(_mapAuthError(e.code));
      }
    } catch (e) {
      _showError('Authentication failed: $e');
    } finally {
      if (mounted) _controller.setLoading(false);
    }
  }

  Future<AppUser> _fetchExistingAppUser(fb.User firebaseUser, UserRole selectedRole) async {
    final firestore = FirebaseFirestore.instance;
    final isDriver = selectedRole == UserRole.driver;
    final collection = isDriver ? 'drivers' : 'users';

    final doc = await firestore.collection(collection).doc(firebaseUser.uid).get();
    if (doc.exists && doc.data() != null) {
      final data = Map<String, dynamic>.from(doc.data()!);
      data['uid'] = firebaseUser.uid;
      data['email'] = firebaseUser.email ?? data['email'] ?? '';
      data.putIfAbsent('role', () => isDriver ? 'driver' : 'customer');
      data.putIfAbsent(
        'photoUrl',
        () => data['photoURL'] ?? firebaseUser.photoURL ?? '',
      );
      return AppUser.fromMap(data);
    }

    return AppUser(
      uid: firebaseUser.uid,
      fullName: firebaseUser.displayName ?? firebaseUser.email ?? '',
      email: firebaseUser.email ?? '',
      phoneNumber: firebaseUser.phoneNumber ?? '',
      role: selectedRole,
      isActive: !isDriver,
      createdAt: firebaseUser.metadata.creationTime ?? DateTime.now(),
      photoUrl: firebaseUser.photoURL ?? '',
    );
  }

  // ─── Email / Password Submission ────────────────────────────────────────────

  Future<void> _submitEmailPassword() async {
    if (!_formKey.currentState!.validate()) return;
    _controller.setLoading(true);
    _controller.clearError();

    try {
      if (!_controller.isSignUpMode) {
        // Sign In Flow
        final user = await _auth.signInWithEmailPassword(
          email: _emailController.text.trim(),
          password: _passwordController.text,
          selectedRole: _controller.selectedRole,
        );

        if (_controller.selectedRole == UserRole.driver) {
          final exists = await _auth.driverAccountExists(user.uid);
          if (!exists) {
            try {
              await _auth.signOut();
            } catch (_) {}
            _showError(_accountMissingMessage);
            return;
          }
        }

        if (mounted) _routeToHome(user);
      } else {
        // Create Account Flow
        final fullName =
            '${_firstNameController.text.trim()} ${_lastNameController.text.trim()}'.trim();

        final repo = _auth is FirebaseAuthRepository
            ? _auth
            : null;
        final AppUser appUser;
        if (repo != null) {
          appUser = await repo.registerWithReferral(
            fullName: fullName,
            email: _emailController.text.trim(),
            phoneNumber: _phoneController.text.trim(),
            password: _passwordController.text.isNotEmpty
                ? _passwordController.text
                : 'OAuth-Registered-User-123!',
            role: _controller.selectedRole,
            referredBy: _referredBy,
          );
        } else {
          appUser = await _auth.register(
            fullName: fullName,
            email: _emailController.text.trim(),
            phoneNumber: _phoneController.text.trim(),
            password: _passwordController.text.isNotEmpty
                ? _passwordController.text
                : 'OAuth-Registered-User-123!',
            role: _controller.selectedRole,
          );
        }

        if (!mounted) return;

        if (_controller.selectedRole == UserRole.driver) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: const Text(
                'Driver account created! Proceed to Step 2: Personal Information.',
              ),
              backgroundColor: Colors.green.shade800,
              behavior: SnackBarBehavior.floating,
            ),
          );
          Navigator.of(context).pushReplacement(
            MaterialPageRoute(
              builder: (_) => DriverOnboardingScreen(user: appUser, auth: _auth),
            ),
          );
        } else {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('Welcome, $fullName! Your account is ready.'),
              backgroundColor: Colors.green.shade800,
              behavior: SnackBarBehavior.floating,
            ),
          );
          _routeToHome(appUser);
        }
      }
    } on fb.FirebaseAuthException catch (e) {
      if (e.code == 'driver-account-missing') {
        try {
          await _auth.signOut();
        } catch (_) {}
        _showError(_accountMissingMessage);
      } else {
        _showError(_mapAuthError(e.code));
      }
    } catch (e) {
      _showError('Authentication failed: $e');
    } finally {
      if (mounted) _controller.setLoading(false);
    }
  }

  void _routeToHome(AppUser user) {
    if (user.role == UserRole.driver) {
      if (user.isPendingOnboarding) {
        Navigator.of(context).pushAndRemoveUntil(
          MaterialPageRoute(
            builder: (_) => DriverOnboardingScreen(user: user, auth: _auth),
          ),
          (route) => false,
        );
        return;
      }
      Navigator.of(context).pushAndRemoveUntil(
        MaterialPageRoute(
          builder: (_) => DriverHomeShell(user: user, auth: _auth),
        ),
        (route) => false,
      );
    } else {
      Navigator.of(context).pushAndRemoveUntil(
        MaterialPageRoute(
          builder: (_) => CustomerHomeShell(user: user, auth: _auth),
        ),
        (route) => false,
      );
    }
  }

  String _mapAuthError(String code) {
    switch (code) {
      case 'driver-account-missing':
        return _accountMissingMessage;
      case 'user-not-found':
        return 'No account registered with this email.';
      case 'wrong-password':
        return 'Incorrect email or password.';
      case 'invalid-credential':
        return 'Invalid authentication credentials. Please try again.';
      case 'email-already-in-use':
        return 'An account already exists for this email address.';
      case 'weak-password':
        return 'Password must be at least 6 characters.';
      case 'user-disabled':
        return 'This account has been disabled.';
      case 'network-request-failed':
        return 'Network connection error. Check your connection.';
      default:
        return 'Authentication failed ($code).';
    }
  }

  // ─── UI Widgets ─────────────────────────────────────────────────────────────

  bool get _isAppleSupported {
    if (kIsWeb) return false;
    return Platform.isIOS || Platform.isMacOS;
  }

  @override
  Widget build(BuildContext context) {
    final isSignUp = _controller.isSignUpMode;
    final isDriver = _controller.selectedRole == UserRole.driver;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final inputFillColor =
        isDark ? const Color(0xFF2A2A2A) : const Color(0xFFF6F6F6);

    InputDecoration buildInputDecoration({
      required String labelText,
      String? hintText,
      required IconData prefixIcon,
      Widget? suffixIcon,
    }) {
      return InputDecoration(
        labelText: labelText,
        hintText: hintText,
        filled: true,
        fillColor: inputFillColor,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide.none,
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide.none,
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide.none,
        ),
        errorBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide.none,
        ),
        focusedErrorBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide.none,
        ),
        prefixIcon: Icon(prefixIcon),
        suffixIcon: suffixIcon,
      );
    }

    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 20),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 420),
              child: Form(
                key: _formKey,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    // Brand Logo & Title
                    Center(
                      child: Container(
                        width: 72,
                        height: 72,
                        decoration: const BoxDecoration(
                          color: _roleSelectedFill,
                          shape: BoxShape.circle,
                        ),
                        child: const Icon(
                          Icons.local_taxi_rounded,
                          size: 40,
                          color: _roleAccentDark,
                        ),
                      ),
                    ),
                    const SizedBox(height: 14),
                    Text(
                      'SeSe Ride',
                      style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                            fontWeight: FontWeight.bold,
                            color: Colors.black87,
                          ),
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 6),
                    Text(
                      isSignUp
                          ? 'Create your account to get started'
                          : 'Welcome back! Sign in to continue',
                      style: TextStyle(color: Colors.grey.shade600, fontSize: 14),
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 20),

                    // 1. Role Selection Switcher
                    Row(
                      children: [
                        Expanded(
                          child: _RoleCard(
                            key: const Key('role_customer_tile'),
                            title: 'Customer',
                            subtitle: 'Book rides & deliveries',
                            icon: Icons.person_outline,
                            selected: !isDriver,
                            onTap: _controller.isLoading
                                ? null
                                : () => _controller.setRole(UserRole.customer),
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: _RoleCard(
                            key: const Key('role_driver_tile'),
                            title: 'Driver',
                            subtitle: 'Earn on your schedule',
                            icon: Icons.two_wheeler,
                            selected: isDriver,
                            onTap: _controller.isLoading
                                ? null
                                : () => _controller.setRole(UserRole.driver),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 20),

                    // 2. Action Mode Selector (Sign In vs Create Account Toggle)
                    Container(
                      padding: const EdgeInsets.all(4),
                      decoration: BoxDecoration(
                        color: isDark ? const Color(0xFF2A2A2A) : Colors.grey.shade200,
                        borderRadius: BorderRadius.circular(16),
                      ),
                      child: Row(
                        children: [
                          Expanded(
                            child: _ModeToggleButton(
                              title: 'Sign In',
                              isSelected: !isSignUp,
                              onTap: _controller.isLoading
                                  ? null
                                  : () => _controller.setSignUpMode(false),
                            ),
                          ),
                          Expanded(
                            child: _ModeToggleButton(
                              title: 'Create Account',
                              isSelected: isSignUp,
                              onTap: _controller.isLoading
                                  ? null
                                  : () => _controller.setSignUpMode(true),
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 20),

                    // 3. Platform-aware Social Sign-In Buttons (Bypasses Form validation)
                    GoogleSignInButton(
                      text: isSignUp ? 'Sign up with Google' : 'Continue with Google',
                      onPressed: () {
                        if (!_controller.isLoading) _handleOAuth('google');
                      },
                    ),

                    if (_isAppleSupported) ...[
                      const SizedBox(height: 10),
                      AppleSignInButton(
                        text: isSignUp ? 'Sign up with Apple' : 'Continue with Apple',
                        onPressed: () {
                          if (!_controller.isLoading) _handleOAuth('apple');
                        },
                      ),
                    ],

                    const SizedBox(height: 18),
                    const Row(
                      children: [
                        Expanded(child: SizedBox(height: 12)),
                        Padding(
                          padding: EdgeInsets.symmetric(horizontal: 10),
                          child: Text('or continue with email',
                              style: TextStyle(color: Colors.grey, fontSize: 13)),
                        ),
                        Expanded(child: SizedBox(height: 12)),
                      ],
                    ),
                    const SizedBox(height: 18),

                    // 4. Form Fields
                    if (isSignUp) ...[
                      Row(
                        children: [
                          Expanded(
                            child: TextFormField(
                              controller: _firstNameController,
                              textCapitalization: TextCapitalization.words,
                              decoration: buildInputDecoration(
                                labelText: 'First Name',
                                prefixIcon: Icons.person_outline,
                              ),
                              validator: (v) {
                                if (v == null || v.trim().isEmpty) {
                                  return 'Required';
                                }
                                return null;
                              },
                            ),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: TextFormField(
                              controller: _lastNameController,
                              textCapitalization: TextCapitalization.words,
                              decoration: buildInputDecoration(
                                labelText: 'Last Name',
                                prefixIcon: Icons.person_outline,
                              ),
                              validator: (v) {
                                if (v == null || v.trim().isEmpty) {
                                  return 'Required';
                                }
                                return null;
                              },
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 12),
                      TextFormField(
                        controller: _phoneController,
                        keyboardType: TextInputType.phone,
                        decoration: buildInputDecoration(
                          labelText: 'Phone Number',
                          hintText: '08012345678',
                          prefixIcon: Icons.phone_outlined,
                        ),
                        validator: (v) {
                          if (v == null || v.trim().isEmpty) {
                            return 'Phone number is required';
                          }
                          return null;
                        },
                      ),
                      const SizedBox(height: 12),
                      ReferralInputWidget(
                        referralService:
                            const ReferralService(),
                        onResolved: (id) =>
                            _referredBy = id,
                      ),
                      const SizedBox(height: 12),
                    ],

                    TextFormField(
                      controller: _emailController,
                      keyboardType: TextInputType.emailAddress,
                      decoration: buildInputDecoration(
                        labelText: 'Email Address',
                        prefixIcon: Icons.email_outlined,
                      ),
                      validator: (v) {
                        if (v == null || v.trim().isEmpty) return 'Email is required';
                        if (!v.contains('@')) return 'Enter a valid email address';
                        return null;
                      },
                    ),
                    const SizedBox(height: 12),

                    TextFormField(
                      controller: _passwordController,
                      obscureText: _obscurePassword,
                      decoration: buildInputDecoration(
                        labelText: isSignUp && _controller.isOAuthPrePopulated
                            ? 'Set Password (Optional for OAuth)'
                            : 'Password',
                        prefixIcon: Icons.lock_outlined,
                        suffixIcon: IconButton(
                          icon: Icon(
                            _obscurePassword
                                ? Icons.visibility
                                : Icons.visibility_off,
                          ),
                          onPressed: () => setState(
                            () => _obscurePassword = !_obscurePassword,
                          ),
                        ),
                      ),
                      validator: (v) {
                        if (isSignUp && _controller.isOAuthPrePopulated) {
                          return null; // Optional if signing up with Google/Apple
                        }
                        if (v == null || v.isEmpty) return 'Password is required';
                        if (v.length < 6) {
                          return 'Password must be at least 6 characters';
                        }
                        return null;
                      },
                    ),
                    const SizedBox(height: 20),

                    // 5. Main Action Button (Single dynamic button directly underneath Password)
                    SizedBox(
                      width: double.infinity,
                      child: FilledButton(
                        key: Key(isSignUp
                            ? 'create_account_submit_button'
                            : 'sign_in_submit_button'),
                        onPressed: _controller.isLoading
                            ? null
                            : _submitEmailPassword,
                        style: FilledButton.styleFrom(
                          backgroundColor: _seseGold,
                          foregroundColor: Colors.black87,
                          disabledBackgroundColor:
                              _seseGold.withValues(alpha: 0.5),
                          minimumSize: const Size(double.infinity, 54),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(14),
                          ),
                          elevation: 0,
                        ),
                        child: _controller.isLoading
                            ? const SizedBox(
                                height: 22,
                                width: 22,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2.5,
                                  color: Colors.black87,
                                ),
                              )
                            : Text(
                                isSignUp ? 'Create Account' : 'Sign In',
                                style: const TextStyle(
                                  fontWeight: FontWeight.bold,
                                  fontSize: 16,
                                ),
                              ),
                      ),
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

/// Mode toggle button with Warm Gold active highlight and dimmed inactive state.
class _ModeToggleButton extends StatelessWidget {
  final String title;
  final bool isSelected;
  final VoidCallback? onTap;

  const _ModeToggleButton({
    required this.title,
    required this.isSelected,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        padding: const EdgeInsets.symmetric(vertical: 12),
        decoration: BoxDecoration(
          color: isSelected ? AppColors.seseGold : Colors.transparent,
          borderRadius: BorderRadius.circular(12),
          boxShadow: isSelected
              ? [
                  BoxShadow(
                    color: AppColors.seseGold.withValues(alpha: 0.3),
                    blurRadius: 6,
                    offset: const Offset(0, 2),
                  ),
                ]
              : null,
        ),
        child: Text(
          title,
          textAlign: TextAlign.center,
          style: TextStyle(
            fontWeight: FontWeight.bold,
            fontSize: 15,
            color: isSelected
                ? Colors.black87
                : (isDark ? Colors.grey.shade400 : Colors.grey.shade600),
          ),
        ),
      ),
    );
  }
}

/// Role selection card widget.
class _RoleCard extends StatelessWidget {
  final String title;
  final String subtitle;
  final IconData icon;
  final bool selected;
  final VoidCallback? onTap;

  const _RoleCard({
    super.key,
    required this.title,
    required this.subtitle,
    required this.icon,
    required this.selected,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final fillColor =
        selected
            ? (isDark ? const Color(0xFF3D3212) : const Color(0xFFFFF6D6))
            : (isDark ? const Color(0xFF242424) : Colors.white);

    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(14),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: fillColor,
          borderRadius: BorderRadius.circular(14),
        ),
        child: Row(
          children: [
            Icon(
              icon,
              size: 28,
              color: selected
                  ? const Color(0xFFEAA200)
                  : (isDark ? Colors.grey.shade400 : Colors.grey.shade700),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: TextStyle(
                      fontWeight: FontWeight.bold,
                      fontSize: 14,
                      color: selected
                          ? (isDark ? Colors.white : Colors.black87)
                          : (isDark ? Colors.grey.shade200 : Colors.grey.shade800),
                    ),
                  ),
                  Text(
                    subtitle,
                    style: TextStyle(
                      fontSize: 11,
                      color: isDark ? Colors.grey.shade400 : Colors.grey.shade600,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
