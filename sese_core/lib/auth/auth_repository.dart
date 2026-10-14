import '../models/user_model.dart';
import '../models/user_role.dart';

/// Contract for authentication used by sese_ride and sese_hub.
abstract class AuthRepository {
  /// Live stream of the current authenticated user.
  /// Emits [AppUser] when signed in, `null` when signed out.
  /// Persists across app restarts — the primary mechanism for auth-gated routing.
  Stream<AppUser?> get authStateChanges;

  /// Email / password sign-in. Returns the signed-in [AppUser].
  /// [selectedRole] is the role chosen on the login screen. New users are
  /// created with this role; existing users keep their designated stored role
  /// which governs landing-page routing.
  Future<AppUser> signInWithEmailPassword({
    required String email,
    required String password,
    UserRole? selectedRole,
  });

  /// Google OAuth sign-in. Returns the signed-in [AppUser].
  /// Behaves like [signInWithEmailPassword] with respect to [selectedRole].
  Future<AppUser> signInWithGoogle({UserRole? selectedRole});

  /// Self-registration for sese_ride (customer direct, driver pending
  /// onboarding -> Step 2 form, then pending approval in sese_hub).
  /// Returns the created [AppUser].
  ///
  /// Driver records are created with
  /// `verificationStatus: 'pending_onboarding'` plus
  /// `isProfileVerified/isVehicleVerified/canGoOnline: false`, and the
  /// caller routes the driver to the Step 2 onboarding form.
  Future<AppUser> register({
    required String fullName,
    required String email,
    required String phoneNumber,
    required String password,
    required UserRole role,
    String? vehicleType,
    String? licenseNo,
  });

  /// True when a driver document already exists at `drivers/{uid}`.
  /// Used by the Driver Sign-In enforcement: sign-in proceeds only for
  /// existing driver accounts, otherwise the UI shows
  /// "Account does not exist. Please tap 'Create Account' to register
  /// as a driver." and stops login.
  Future<bool> driverAccountExists(String uid);

  /// Google "Create Account" for drivers: authenticates via Google, creates
  /// the initial `drivers/{uid}` record with
  /// `verificationStatus: 'pending_onboarding'` (when absent), and returns
  /// the driver [AppUser] so the caller can route to Step 2 onboarding.
  /// Existing driver accounts are returned unchanged (no overwrite).
  Future<AppUser> registerDriverWithGoogle();

  /// Deletes the currently authenticated user's account after verifying
  /// re-authentication credentials (with optional [password] for email accounts).
  /// Performs soft-deletion and regulatory archival before purging credentials.
  Future<void> deleteAccount({String? password});

  /// Unified Google Sign-In / Sign-Up. Accepts the currently selected role
  /// from the UI state ([selectedRole]) and whether the user is in Sign-Up mode ([isSignUp]).
  ///
  /// - When [selectedRole] is [UserRole.driver] in Sign-Up mode: creates the driver
  ///   document in `drivers/{uid}` with `role: 'driver'` and `verificationStatus: 'pending_onboarding'`.
  /// - When [selectedRole] is [UserRole.customer] in Sign-Up mode: creates or updates the
  ///   customer document in `users/{uid}` with `role: 'customer'`.
  /// - In Sign-In mode for drivers: verifies the driver document exists, otherwise rejects.
  Future<AppUser> continueWithGoogle({
    UserRole? selectedRole,
    bool isSignUp = false,
  });

  /// Updates the pending selected role so background auth state listeners
  /// never default an in-flight driver registration to customer.
  void setPendingSelectedRole(UserRole role);

  /// Provider ids (e.g. `password`, `google.com`) linked to the current
  /// Firebase user. Best-effort — returns empty when signed out or the
  /// reload fails. Drives the settings password sheet (update vs link mode).
  Future<List<String>> authProviders();

  /// Creates or updates the account password, synchronizing credentials so
  /// email/password and OAuth sign-in keep working side by side:
  /// - Password-linked accounts: re-authenticates with [currentPassword]
  ///   (required) then updates to [newPassword].
  /// - OAuth-only accounts (Google/phone): links the email/password
  ///   credential (with a `provider-already-linked` fallback to update).
  /// Records `password` in the profile's `authProviders` ([role] picks the
  /// `users` vs `drivers` collection). Never touches the transaction PIN.
  ///
  /// Passwords are used VERBATIM (never trimmed) on every path — settings,
  /// registration, and sign-in — so surrounding whitespace can never cause
  /// a set-then-mismatch failure.
  Future<void> setAccountPassword({
    String? currentPassword,
    required String newPassword,
    UserRole? role,
  });

  /// Signs out the currently authenticated user.
  Future<void> signOut();
}

