import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart' as fb;
import 'package:flutter/foundation.dart';
import 'package:google_sign_in/google_sign_in.dart';

import 'auth_repository.dart';
import '../models/driver_verification.dart';
import '../models/user_model.dart';
import '../models/user_role.dart';
import '../referral/referral_code.dart';

/// Production [AuthRepository] backed by Firebase Auth + Cloud Firestore.
///
/// Role resolution order for an authenticated [fb.User]:
/// 1. Check `users/{uid}` — customer / driver accounts self-registered in sese_ride.
/// 2. Check `drivers/{uid}` — legacy driver documents.
/// 3. Check Firebase ID-token custom claims (`role` claim set by Cloud Functions).
/// 4. Check `admin_users/{email}` — hub staff provisioned via sese_hub.
/// 5. Owner email bootstrap (`bamiduromichael2@gmail.com` -> superRole).
/// 6. Default -> [UserRole.customer].
class FirebaseAuthRepository implements AuthRepository {
  /// Default Web OAuth Client ID associated with the `sese-ride` Firebase project.
  /// Required by Google Play Services on Android to return an OpenID Connect `idToken`.
  static const String defaultServerClientId =
      '618721373016-m544iaqof5f8rss97282imlno0bhgbl7.apps.googleusercontent.com';

  final fb.FirebaseAuth? _authExplicit;
  final FirebaseFirestore? _firestoreExplicit;
  final GoogleSignIn? _googleSignInExplicit;
  final String? _serverClientId;

  /// Whether this repository is running inside `sese_hub`.
  ///
  /// When `false` (the default — `sese_ride`), the `admin_users` Firestore
  /// lookup is skipped entirely so regular customers / drivers never trigger
  /// a PERMISSION_DENIED on that hub-only collection.
  final bool isHubApp;

  UserRole _pendingSelectedRole = UserRole.customer;

  @override
  void setPendingSelectedRole(UserRole role) {
    _pendingSelectedRole = role;
  }

  FirebaseAuthRepository({
    fb.FirebaseAuth? auth,
    FirebaseFirestore? firestore,
    GoogleSignIn? googleSignIn,
    String? serverClientId,
    this.isHubApp = false,
  })  : _authExplicit = auth,
        _firestoreExplicit = firestore,
        _googleSignInExplicit = googleSignIn,
        _serverClientId = serverClientId ?? defaultServerClientId;

  fb.FirebaseAuth? get _auth {
    try {
      return _authExplicit ?? fb.FirebaseAuth.instance;
    } catch (_) {
      return null;
    }
  }

  FirebaseFirestore? get _firestore {
    try {
      return _firestoreExplicit ?? FirebaseFirestore.instance;
    } catch (_) {
      return null;
    }
  }

  GoogleSignIn get _googleSignIn =>
      _googleSignInExplicit ??
      GoogleSignIn(
        serverClientId: _serverClientId,
        clientId: kIsWeb ? _serverClientId : null,
      );

  // ─── AuthRepository ───────────────────────────────────────────────────────

  @override
  Stream<AppUser?> get authStateChanges {
    final auth = _auth;
    if (auth == null) return const Stream.empty();

    return auth.authStateChanges().asyncMap((firebaseUser) async {
      if (firebaseUser == null) return null;
      try {
        return await _fetchAppUser(firebaseUser);
      } catch (e) {
        debugPrint('FirebaseAuthRepository.authStateChanges error: $e');
        return null;
      }
    });
  }

  @override
  Future<AppUser> signInWithEmailPassword({
    required String email,
    required String password,
    UserRole? selectedRole,
  }) async {
    final auth = _auth;
    if (auth == null) {
      throw fb.FirebaseAuthException(code: 'firebase-uninitialized');
    }
    final credential = await auth.signInWithEmailAndPassword(
      email: email.trim(),
      password: password,
    );
    return _fetchAppUser(credential.user!, selectedRole: selectedRole);
  }

  @override
  Future<AppUser> signInWithGoogle({UserRole? selectedRole}) async {
    final auth = _auth;
    if (auth == null) {
      throw fb.FirebaseAuthException(code: 'firebase-uninitialized');
    }
    final firebaseUser = await _authenticateWithGoogle(auth);
    return _fetchAppUser(firebaseUser, selectedRole: selectedRole);
  }

  @override
  Future<bool> driverAccountExists(String uid) async {
    final firestore = _firestore;
    if (uid.isEmpty) return false;
    if (firestore == null) return false;
    try {
      final doc = await firestore.collection('drivers').doc(uid).get();
      return doc.exists;
    } catch (e) {
      debugPrint('FirebaseAuthRepository.driverAccountExists error: $e');
      return false;
    }
  }

  @override
  Future<AppUser> registerDriverWithGoogle() async {
    final auth = _auth;
    final firestore = _firestore;
    if (auth == null || firestore == null) {
      throw fb.FirebaseAuthException(code: 'firebase-uninitialized');
    }
    final firebaseUser = await _authenticateWithGoogle(auth);

    // Existing driver account -> return it unchanged (never overwrite
    // submitted onboarding / hub approval flags).
    try {
      final existing =
          await firestore.collection('drivers').doc(firebaseUser.uid).get();
      if (existing.exists && existing.data() != null) {
        final data = Map<String, dynamic>.from(existing.data()!);
        data['uid'] = firebaseUser.uid;
        data['email'] = firebaseUser.email ?? data['email'] ?? '';
        data.putIfAbsent('role', () => 'driver');
        data.putIfAbsent(
          'photoUrl',
          () => data['photoURL'] ?? firebaseUser.photoURL ?? '',
        );
        return AppUser.fromMap(data);
      }
    } catch (e) {
      debugPrint(
          'FirebaseAuthRepository.registerDriverWithGoogle read error: $e');
    }

    final now = DateTime.now();
    final appUser = AppUser(
      uid: firebaseUser.uid,
      fullName: firebaseUser.displayName ?? firebaseUser.email ?? '',
      email: firebaseUser.email ?? '',
      phoneNumber: firebaseUser.phoneNumber ?? '',
      role: UserRole.driver,
      isActive: false,
      createdAt: firebaseUser.metadata.creationTime ?? now,
      photoUrl: firebaseUser.photoURL ?? '',
      verificationStatus: DriverVerification.pendingOnboarding,
    );
    await firestore.collection('drivers').doc(firebaseUser.uid).set({
      ...appUser.toMap(),
      DriverVerification.fieldStatus: DriverVerification.pendingOnboarding,
      DriverVerification.fieldProfileVerified: false,
      DriverVerification.fieldVehicleVerified: false,
      DriverVerification.fieldCanGoOnline: false,
    });
    return appUser;
  }

  @override
  Future<AppUser> continueWithGoogle({
    UserRole? selectedRole,
    bool isSignUp = false,
  }) async {
    final auth = _auth;
    final firestore = _firestore;
    if (auth == null) {
      throw fb.FirebaseAuthException(code: 'firebase-uninitialized');
    }

    final effectiveRole = selectedRole ?? _pendingSelectedRole;
    _pendingSelectedRole = effectiveRole;

    final firebaseUser = await _authenticateWithGoogle(auth);
    final isDriver = effectiveRole == UserRole.driver;

    if (!isSignUp) {
      // ─── Sign-In Mode ───────────────────────────────────────────────────────
      if (isDriver && firestore != null) {
        final driverDoc =
            await firestore.collection('drivers').doc(firebaseUser.uid).get();
        if (!driverDoc.exists || driverDoc.data() == null) {
          try {
            await auth.signOut();
          } catch (_) {}
          throw fb.FirebaseAuthException(
            code: 'driver-account-missing',
            message:
                "Account does not exist. Please tap 'Create Account' to register as a driver.",
          );
        }
      }
      return _fetchAppUser(firebaseUser, selectedRole: effectiveRole);
    }

    // ─── Create Account Mode ─────────────────────────────────────────────────
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
      if (firestore != null) {
        final driverDocRef =
            firestore.collection('drivers').doc(firebaseUser.uid);
        final existingDoc = await driverDocRef.get();
        final existingData = existingDoc.data();

        final driverData = <String, dynamic>{
          'uid': firebaseUser.uid,
          'email': firebaseUser.email ?? '',
          'displayName': displayName,
          'fullName': displayName.isNotEmpty ? displayName : (firebaseUser.email ?? ''),
          'firstName': firstName,
          'lastName': lastName,
          'photoURL': firebaseUser.photoURL ?? '',
          'photoUrl': firebaseUser.photoURL ?? '',
          'role': 'driver',
          'verificationStatus': existingData?['verificationStatus'] ??
              DriverVerification.pendingOnboarding,
          'isProfileVerified': existingData?['isProfileVerified'] ?? false,
          'isVehicleVerified': existingData?['isVehicleVerified'] ?? false,
          'canGoOnline': existingData?['canGoOnline'] ?? false,
          'isActive': existingData?['isActive'] ?? false,
          'createdAt':
              existingData?['createdAt'] ?? FieldValue.serverTimestamp(),
        };
        if (firebaseUser.phoneNumber != null &&
            firebaseUser.phoneNumber!.trim().isNotEmpty) {
          driverData['phoneNumber'] = firebaseUser.phoneNumber!.trim();
        }
        await driverDocRef.set(driverData, SetOptions(merge: true));
        // Backfill deterministic referral code for Google driver sign-ups.
        await ensureReferralCode(
          collection: 'drivers',
          uid: firebaseUser.uid,
          fullName: displayName.isNotEmpty
              ? displayName
              : (firebaseUser.email ?? ''),
          phoneNumber: firebaseUser.phoneNumber ?? '',
        );
      }

      return AppUser(
        uid: firebaseUser.uid,
        fullName: displayName.isNotEmpty ? displayName : (firebaseUser.email ?? ''),
        email: firebaseUser.email ?? '',
        phoneNumber: firebaseUser.phoneNumber ?? '',
        role: UserRole.driver,
        isActive: false,
        createdAt: firebaseUser.metadata.creationTime ?? DateTime.now(),
        photoUrl: firebaseUser.photoURL ?? '',
        verificationStatus: DriverVerification.pendingOnboarding,
      );
    } else {
      if (firestore != null) {
        final userDocRef =
            firestore.collection('users').doc(firebaseUser.uid);
        final existingDoc = await userDocRef.get();
        final existingData = existingDoc.data();

        final userData = <String, dynamic>{
          'uid': firebaseUser.uid,
          'email': firebaseUser.email ?? '',
          'displayName': displayName,
          'fullName': displayName.isNotEmpty ? displayName : (firebaseUser.email ?? ''),
          'firstName': firstName,
          'lastName': lastName,
          'photoURL': firebaseUser.photoURL ?? '',
          'photoUrl': firebaseUser.photoURL ?? '',
          'role': 'customer',
          'isActive': true,
          'createdAt':
              existingData?['createdAt'] ?? FieldValue.serverTimestamp(),
        };
        if (firebaseUser.phoneNumber != null &&
            firebaseUser.phoneNumber!.trim().isNotEmpty) {
          userData['phoneNumber'] = firebaseUser.phoneNumber!.trim();
        }
        await userDocRef.set(userData, SetOptions(merge: true));
        // Backfill deterministic referral code for Google customer sign-ups.
        await ensureReferralCode(
          collection: 'users',
          uid: firebaseUser.uid,
          fullName: displayName.isNotEmpty
              ? displayName
              : (firebaseUser.email ?? ''),
          phoneNumber: firebaseUser.phoneNumber ?? '',
        );
      }

      return AppUser(
        uid: firebaseUser.uid,
        fullName: displayName.isNotEmpty ? displayName : (firebaseUser.email ?? ''),
        email: firebaseUser.email ?? '',
        phoneNumber: firebaseUser.phoneNumber ?? '',
        role: UserRole.customer,
        isActive: true,
        createdAt: firebaseUser.metadata.creationTime ?? DateTime.now(),
        photoUrl: firebaseUser.photoURL ?? '',
      );
    }
  }

  /// Shared Google authentication flow (web popup / mobile GMS), returning
  /// the signed-in Firebase user. Used by [signInWithGoogle] (sign-in mode)
  /// and [registerDriverWithGoogle] (create-account mode).
  Future<fb.User> _authenticateWithGoogle(fb.FirebaseAuth auth) async {
    fb.UserCredential userCredential;
    if (kIsWeb) {
      debugPrint('FirebaseAuthRepository.signInWithGoogle: Using web signInWithPopup');
      final provider = fb.GoogleAuthProvider();
      userCredential = await auth.signInWithPopup(provider);
    } else {
      debugPrint('FirebaseAuthRepository.signInWithGoogle: Launching mobile GoogleSignIn');
      final googleUser = await _googleSignIn.signIn();
      if (googleUser == null) {
        throw fb.FirebaseAuthException(code: 'google-sign-in-cancelled');
      }
      final googleAuth = await googleUser.authentication;
      debugPrint(
        'FirebaseAuthRepository.signInWithGoogle: tokens received -> '
        'idToken: ${googleAuth.idToken != null ? "[present]" : "[null]"}, '
        'accessToken: ${googleAuth.accessToken != null ? "[present]" : "[null]"}',
      );
      if (googleAuth.idToken == null) {
        throw fb.FirebaseAuthException(
          code: 'google-id-token-missing',
          message:
              'Google returned no idToken. Check SHA-1/SHA-256 in Firebase console, '
              'google-services.json freshness, and Google Play Services on this device '
              '(Huawei devices without GMS cannot use Google Sign-In).',
        );
      }

      final credential = fb.GoogleAuthProvider.credential(
        accessToken: googleAuth.accessToken,
        idToken: googleAuth.idToken,
      );
      userCredential = await auth.signInWithCredential(credential);
    }
    return userCredential.user!;
  }

  @override
  Future<AppUser> register({
    required String fullName,
    required String email,
    required String phoneNumber,
    required String password,
    required UserRole role,
    String? vehicleType,
    String? licenseNo,
  }) async {
    return registerWithReferral(
      fullName: fullName,
      email: email,
      phoneNumber: phoneNumber,
      password: password,
      role: role,
      vehicleType: vehicleType,
      licenseNo: licenseNo,
    );
  }

  /// Registration with optional referral attribution.
  ///
  /// Generates the deterministic referral code
  /// (`FirstInitial + LastInitial + last4(phone)`) and stores it at
  /// `referralCode`. When [referredBy] is a valid referrer uid, also stores
  /// `referredBy`, `referralSignupAt`, and mirrors the code into the public
  /// `referral_codes/{CODE}` lookup (first-writer-wins).
  Future<AppUser> registerWithReferral({
    required String fullName,
    required String email,
    required String phoneNumber,
    required String password,
    required UserRole role,
    String? vehicleType,
    String? licenseNo,
    String? referredBy,
  }) async {
    final auth = _auth;
    final firestore = _firestore;
    if (auth == null || firestore == null) {
      throw fb.FirebaseAuthException(code: 'firebase-uninitialized');
    }

    final credential = await auth.createUserWithEmailAndPassword(
      email: email.trim(),
      password: password,
    );
    final firebaseUser = credential.user!;
    await firebaseUser.updateDisplayName(fullName);

    final now = DateTime.now();
    final isDriver = role == UserRole.driver;

    final appUser = AppUser(
      uid: firebaseUser.uid,
      fullName: fullName,
      email: email.trim(),
      phoneNumber: phoneNumber.trim(),
      role: role,
      // Drivers start inactive (Step 2 onboarding -> pending hub approval).
      isActive: !isDriver,
      createdAt: now,
      verificationStatus:
          isDriver ? DriverVerification.pendingOnboarding : '',
    );

    // Deterministic referral code + optional attribution.
    final referralCode = generateReferralCode(
      fullName: fullName,
      phoneNumber: phoneNumber,
    );

    // Write profile document to the appropriate Firestore collection.
    if (isDriver) {
      final data = {
        ...appUser.toMap(),
        'referralCode': referralCode,
        if (referredBy != null && referredBy.isNotEmpty)
          'referredBy': referredBy,
        if (referredBy != null && referredBy.isNotEmpty)
          'referralSignupAt': now.toIso8601String(),
        DriverVerification.fieldStatus:
            DriverVerification.pendingOnboarding,
        DriverVerification.fieldProfileVerified: false,
        DriverVerification.fieldVehicleVerified: false,
        DriverVerification.fieldCanGoOnline: false,
        'initialVehicleType': vehicleType,
        'licenseNo': licenseNo,
      };
      await firestore.collection('drivers').doc(firebaseUser.uid).set(data);
    } else {
      await firestore
          .collection('users')
          .doc(firebaseUser.uid)
          .set({
        ...appUser.toMap(),
        'referralCode': referralCode,
        if (referredBy != null && referredBy.isNotEmpty)
          'referredBy': referredBy,
        if (referredBy != null && referredBy.isNotEmpty)
          'referralSignupAt': now.toIso8601String(),
      });
    }
    await _mirrorReferralCode(
        firestore, referralCode, firebaseUser.uid, isDriver);

    return appUser;
  }

  /// Ensures a deterministic referral code exists on a profile document.
  ///
  /// Used by Google/Apple OAuth flows where no phone number may be present
  /// at signup. Generates from [fullName]+[phoneNumber], writes it when
  /// missing, and mirrors it into `referral_codes/{CODE}`.
  Future<String?> ensureReferralCode({
    required String collection,
    required String uid,
    required String fullName,
    required String phoneNumber,
  }) async {
    final firestore = _firestore;
    if (firestore == null || uid.isEmpty) return null;
    try {
      final ref = firestore.collection(collection).doc(uid);
      final snap = await ref.get();
      final existing =
          (snap.data()?['referralCode'] ?? '').toString();
      if (existing.isNotEmpty) return existing;
      final name = fullName.isEmpty ? 'SeSe User' : fullName;
      final code = generateReferralCode(
          fullName: name, phoneNumber: phoneNumber);
      await ref.set({'referralCode': code}, SetOptions(merge: true));
      await _mirrorReferralCode(firestore, code, uid, collection == 'drivers');
      return code;
    } catch (e) {
      debugPrint('ensureReferralCode skipped: $e');
      return null;
    }
  }

  /// Mirrors the deterministic code into the public lookup collection
  /// (first-writer-wins; collisions keep the earliest owner).
  Future<void> _mirrorReferralCode(
    FirebaseFirestore firestore,
    String code,
    String uid,
    bool isDriver,
  ) async {
    try {
      final ref = firestore.collection('referral_codes').doc(code);
      final existing = await ref.get();
      if (!existing.exists) {
        await ref.set({
          'referrerId': uid,
          'collection': isDriver ? 'drivers' : 'users',
          'createdAt': FieldValue.serverTimestamp(),
        });
      }
    } catch (e) {
      debugPrint('referral code mirror skipped: $e');
    }
  }

  @override
  Future<void> deleteAccount({String? password}) async {
    final auth = _auth;
    final currentUser = auth?.currentUser;
    if (auth == null || currentUser == null) {
      throw fb.FirebaseAuthException(
        code: 'user-not-found',
        message: 'No active user session found.',
      );
    }

    // 1. Explicit re-authentication
    if (password != null && password.isNotEmpty) {
      final email = currentUser.email;
      if (email != null && email.isNotEmpty) {
        final credential = fb.EmailAuthProvider.credential(
          email: email,
          password: password,
        );
        await currentUser.reauthenticateWithCredential(credential);
      }
    } else {
      // Google account re-authentication
      await _authenticateWithGoogle(auth);
    }

    // 2. Soft-delete and 30-day regulatory archival in Firestore
    final firestore = _firestore;
    if (firestore != null) {
      final now = DateTime.now();
      final purgeDate = now.add(const Duration(days: 30));
      final archiveData = {
        'status': 'deleted',
        'isDeleted': true,
        'deletedAt': now.toIso8601String(),
        'scheduledPurgeAt': purgeDate.toIso8601String(),
        'isActive': false,
        'canGoOnline': false,
      };

      try {
        await firestore.collection('users').doc(currentUser.uid).set(
              archiveData,
              SetOptions(merge: true),
            );
      } catch (e) {
        debugPrint('FirebaseAuthRepository.deleteAccount users soft-delete error: $e');
      }

      try {
        await firestore.collection('drivers').doc(currentUser.uid).set(
              archiveData,
              SetOptions(merge: true),
            );
      } catch (e) {
        debugPrint('FirebaseAuthRepository.deleteAccount drivers soft-delete error: $e');
      }
    }

    // 3. Purge Firebase Auth account and revoke session
    await currentUser.delete();
    await signOut();
  }

  @override
  Future<void> signOut() async {
    if (!kIsWeb) {
      try {
        await _googleSignIn.signOut();
      } catch (e) {
        debugPrint('FirebaseAuthRepository.signOut: googleSignIn signOut error: $e');
      }
    }
    try {
      await _auth?.signOut();
    } catch (e) {
      debugPrint('FirebaseAuthRepository.signOut: firebase signOut error: $e');
    }
  }

  // ─── Internal ─────────────────────────────────────────────────────────────

  /// Resolves a Firebase Auth [fb.User] to an [AppUser] by reading Firestore
  /// and/or inspecting ID-token custom claims.
  ///
  /// [selectedRole] is the role picked on the login screen:
  /// - Customer toggle (or default): new users are created in `users/{uid}`
  ///   with `role: 'customer'` and land directly on the Customer View.
  /// - Driver toggle on SIGN-IN: existing `drivers/{uid}` accounts route to
  ///   Driver Home (or Step 2 onboarding when
  ///   `verificationStatus == 'pending_onboarding'`). Missing accounts throw
  ///   `driver-account-missing` and no document is auto-created.
  /// - Existing users keep their designated stored role, which governs the
  ///   default landing page via the AuthGate.
  Future<AppUser> _fetchAppUser(
    fb.User firebaseUser, {
    UserRole? selectedRole,
  }) async {
    // 1. Owner email bootstrap — always treated as Super Admin immediately.
    if (firebaseUser.email?.toLowerCase() == 'bamiduromichael2@gmail.com') {
      return AppUser(
        uid: firebaseUser.uid,
        fullName: firebaseUser.displayName ?? 'Super Admin',
        email: firebaseUser.email!,
        phoneNumber: firebaseUser.phoneNumber ?? '',
        role: UserRole.superRole,
        isActive: true,
        createdAt: firebaseUser.metadata.creationTime ?? DateTime.now(),
        photoUrl: firebaseUser.photoURL ?? '',
      );
    }

    // 2. Check Firebase ID-token custom claims (set by Cloud Functions for hub staff).
    try {
      final idToken = await firebaseUser.getIdTokenResult();
      final claimRole = idToken.claims?['role'] as String?;
      if (claimRole != null) {
        final userRole = _claimToUserRole(claimRole);
        return AppUser(
          uid: firebaseUser.uid,
          fullName: firebaseUser.displayName ?? firebaseUser.email ?? '',
          email: firebaseUser.email ?? '',
          phoneNumber: firebaseUser.phoneNumber ?? '',
          role: userRole,
          isActive: true,
          createdAt: firebaseUser.metadata.creationTime ?? DateTime.now(),
          photoUrl: firebaseUser.photoURL ?? '',
        );
      }
    } catch (e) {
      debugPrint('FirebaseAuthRepository._fetchAppUser: claims error $e');
    }

    final firestore = _firestore;
    if (firestore != null) {
      // 3. Check admin_users/{email} — hub staff provisioned via sese_hub.
      //    Skipped entirely in sese_ride to avoid PERMISSION_DENIED for
      //    regular customers and drivers who have no admin_users record.
      if (isHubApp && firebaseUser.email != null) {
        try {
          final adminDoc = await firestore
              .collection('admin_users')
              .doc(firebaseUser.email)
              .get();
          if (adminDoc.exists && adminDoc.data() != null) {
            final data = adminDoc.data()!;
            final roleStr = (data['role'] as String? ?? 'agent').toLowerCase();
            return AppUser(
              uid: firebaseUser.uid,
              fullName: firebaseUser.displayName ??
                  data['fullName'] ??
                  firebaseUser.email!,
              email: firebaseUser.email!,
              phoneNumber: firebaseUser.phoneNumber ?? data['phone'] ?? '',
              role: UserRoleExtension.fromString(roleStr),
              isActive: true,
              createdAt: firebaseUser.metadata.creationTime ?? DateTime.now(),
              photoUrl: (data['photoUrl'] ?? data['photoURL'] ?? firebaseUser.photoURL ?? '').toString(),
            );
          }
        } catch (e) {
          debugPrint('FirebaseAuthRepository._fetchAppUser admin_users error: $e');
        }
      }

      // 4. Check drivers/{uid} FIRST — driver accounts are authoritative
      // for the Driver toggle. (Checked before users/ so a Firebase user
      // holding both docs resolves to their driver onboarding state.)
      try {
        final driverDoc =
            await firestore.collection('drivers').doc(firebaseUser.uid).get();
        if (driverDoc.exists && driverDoc.data() != null) {
          final data = Map<String, dynamic>.from(driverDoc.data()!);
          data['uid'] = firebaseUser.uid;
          data['email'] = firebaseUser.email ?? data['email'] ?? '';
          data.putIfAbsent('role', () => 'driver');
          data.putIfAbsent(
            'photoUrl',
            () => data['photoURL'] ?? firebaseUser.photoURL ?? '',
          );
          final existing = AppUser.fromMap(data);
          _logRoleSelection(existing.role, selectedRole);
          return existing;
        }
      } catch (e) {
        debugPrint('FirebaseAuthRepository._fetchAppUser drivers error: $e');
      }

      // 5. Check users/{uid} — customer accounts self-registered in sese_ride.
      try {
        final userDoc =
            await firestore.collection('users').doc(firebaseUser.uid).get();
        if (userDoc.exists && userDoc.data() != null) {
          final data = Map<String, dynamic>.from(userDoc.data()!);
          data['uid'] = firebaseUser.uid;
          data['email'] = firebaseUser.email ?? data['email'] ?? '';
          data.putIfAbsent(
            'photoUrl',
            () => data['photoURL'] ?? firebaseUser.photoURL ?? '',
          );
          final existing = AppUser.fromMap(data);
          _logRoleSelection(existing.role, selectedRole);
          return existing;
        }
      } catch (e) {
        debugPrint('FirebaseAuthRepository._fetchAppUser users error: $e');
      }
    }

    // 6. New user (no Firestore doc):
    // - Customer toggle (or default): create `users/{uid}` with
    //   `role: 'customer'` -> lands directly on the Customer View.
    // - Driver toggle on SIGN-IN: refuse — there is no driver account to
    //   sign into. The UI catches `driver-account-missing`, signs out, and
    //   shows "Account does not exist. Please tap 'Create Account' to
    //   register as a driver." Driver creation lives in [register] and
    //   [registerDriverWithGoogle] only.
    // - sese_hub: NO doc is auto-created. A missing record is expected for
    //   unprovisioned staff — writing a `users/{uid}` customer doc from a
    //   doomed hub login pollutes the collection and masks the
    //   "no hub_staff record" rejection the hub gate relies on.
    final requestedRole = selectedRole ?? _pendingSelectedRole;
    if (requestedRole == UserRole.driver) {
      throw fb.FirebaseAuthException(
        code: 'driver-account-missing',
        message:
            "Account does not exist. Please tap 'Create Account' to register as a driver.",
      );
    }
    final appUser = AppUser(
      uid: firebaseUser.uid,
      fullName: firebaseUser.displayName ?? firebaseUser.email ?? '',
      email: firebaseUser.email ?? '',
      phoneNumber: firebaseUser.phoneNumber ?? '',
      role: UserRole.customer,
      isActive: true,
      createdAt: firebaseUser.metadata.creationTime ?? DateTime.now(),
      photoUrl: firebaseUser.photoURL ?? '',
    );

    if (firestore != null && !isHubApp) {
      try {
        await firestore
            .collection('users')
            .doc(firebaseUser.uid)
            .set(appUser.toMap(), SetOptions(merge: true));
      } catch (_) {}
    }

    return appUser;
  }

  /// Logs when the login-screen role pick differs from the stored account
  /// role. Existing users always land on their designated role's dashboard.
  void _logRoleSelection(UserRole storedRole, UserRole? selectedRole) {
    if (selectedRole != null && selectedRole != storedRole) {
      debugPrint(
        'FirebaseAuthRepository: login selectedRole=${selectedRole.name} '
        'differs from stored role=${storedRole.name}; '
        'routing to designated ${storedRole.name} landing page.',
      );
    }
  }

  /// Maps a Firebase custom claim role string to [UserRole].
  UserRole _claimToUserRole(String claim) {
    switch (claim.toUpperCase()) {
      case 'SUPER_ADMIN':
      case 'ROLE_SUPER_ADMIN':
        return UserRole.superRole;
      case 'OPERATIONS_ADMIN':
      case 'FINANCE_ADMIN':
      case 'SECURITY_AUDITOR':
        return UserRole.admin;
      case 'AGENT':
      case 'ROLE_CUSTOMER_SUPPORT':
      case 'ROLE_DRIVER_SUPPORT':
      case 'DISPATCH_OPERATIONS':
        return UserRole.agent;
      case 'DRIVER':
        return UserRole.driver;
      default:
        return UserRole.customer;
    }
  }
}
