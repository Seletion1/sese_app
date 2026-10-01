import 'package:flutter/foundation.dart';
import 'package:sese_core/sese_core.dart';

/// State and logic controller for the unified authentication screen in sese_ride.
class AuthController extends ChangeNotifier {
  final AuthRepository auth;

  UserRole _selectedRole;
  bool _isSignUpMode;
  bool _isLoading = false;
  String? _errorMessage;

  // Form field state for sign in & create account
  String firstName = '';
  String lastName = '';
  String email = '';
  String phoneNumber = '';
  String password = '';

  // Google / OAuth extracted metadata flag
  bool isOAuthPrePopulated = false;
  String? oauthPhotoUrl;
  String? oauthUid;

  AuthController({
    AuthRepository? auth,
    UserRole initialRole = UserRole.customer,
    bool initialSignUpMode = false,
  })  : auth = auth ?? FirebaseAuthRepository(),
        _selectedRole = initialRole,
        _isSignUpMode = initialSignUpMode {
    this.auth.setPendingSelectedRole(_selectedRole);
  }

  UserRole get selectedRole => _selectedRole;
  bool get isSignUpMode => _isSignUpMode;
  bool get isLoading => _isLoading;
  String? get errorMessage => _errorMessage;

  void setRole(UserRole role) {
    if (_selectedRole == role) return;
    _selectedRole = role;
    auth.setPendingSelectedRole(role);
    _errorMessage = null;
    notifyListeners();
  }

  /// Unified Google Sign-In / Sign-Up.
  /// Accepts the currently selected role from the UI state ([role], defaults to [_selectedRole]).
  Future<AppUser> continueWithGoogle({UserRole? role}) async {
    final effectiveRole = role ?? _selectedRole;
    auth.setPendingSelectedRole(effectiveRole);
    setLoading(true);
    clearError();
    try {
      final user = await auth.continueWithGoogle(
        selectedRole: effectiveRole,
        isSignUp: _isSignUpMode,
      );
      return user;
    } catch (e) {
      setError(e.toString());
      rethrow;
    } finally {
      setLoading(false);
    }
  }

  void setSignUpMode(bool isSignUp) {
    if (_isSignUpMode == isSignUp) return;
    _isSignUpMode = isSignUp;
    _errorMessage = null;
    notifyListeners();
  }

  void setLoading(bool loading) {
    _isLoading = loading;
    notifyListeners();
  }

  void setError(String? error) {
    _errorMessage = error;
    notifyListeners();
  }

  void clearError() {
    _errorMessage = null;
    notifyListeners();
  }

  /// Called when OAuth metadata is extracted from Google / Apple sign-in in Create Account mode.
  void applyOAuthProfile({
    required String? extractedDisplayName,
    required String? extractedEmail,
    required String? extractedPhoneNumber,
    required String? extractedPhotoUrl,
    required String? extractedUid,
  }) {
    isOAuthPrePopulated = true;
    oauthUid = extractedUid;
    oauthPhotoUrl = extractedPhotoUrl;

    if (extractedEmail != null && extractedEmail.isNotEmpty) {
      email = extractedEmail;
    }

    if (extractedPhoneNumber != null && extractedPhoneNumber.isNotEmpty) {
      phoneNumber = extractedPhoneNumber;
    }

    if (extractedDisplayName != null && extractedDisplayName.trim().isNotEmpty) {
      final parts = extractedDisplayName.trim().split(RegExp(r'\s+'));
      firstName = parts.first;
      if (parts.length > 1) {
        lastName = parts.sublist(1).join(' ');
      }
    }

    notifyListeners();
  }
}
