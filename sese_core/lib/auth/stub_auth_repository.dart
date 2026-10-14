import 'dart:async';

import 'auth_repository.dart';
import '../models/user_model.dart';
import '../models/user_role.dart';

/// Test / dev placeholder [AuthRepository] — never used at runtime.
/// Satisfies the interface so widget tests compile without Firebase.
class StubAuthRepository implements AuthRepository {
  const StubAuthRepository();

  @override
  Stream<AppUser?> get authStateChanges => const Stream.empty();

  @override
  Future<AppUser> signInWithEmailPassword({
    required String email,
    required String password,
    UserRole? selectedRole,
  }) {
    throw UnimplementedError('StubAuthRepository: signInWithEmailPassword');
  }

  @override
  Future<AppUser> signInWithGoogle({UserRole? selectedRole}) {
    throw UnimplementedError('StubAuthRepository: signInWithGoogle');
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
  }) {
    throw UnimplementedError('StubAuthRepository: register');
  }

  @override
  Future<bool> driverAccountExists(String uid) async => false;

  @override
  Future<AppUser> registerDriverWithGoogle() {
    throw UnimplementedError('StubAuthRepository: registerDriverWithGoogle');
  }

  @override
  Future<AppUser> continueWithGoogle({
    UserRole? selectedRole,
    bool isSignUp = false,
  }) {
    throw UnimplementedError('StubAuthRepository: continueWithGoogle');
  }

  @override
  void setPendingSelectedRole(UserRole role) {}

  @override
  Future<void> deleteAccount({String? password}) async {}

  @override
  Future<List<String>> authProviders() async => const [];

  @override
  Future<void> setAccountPassword({
    String? currentPassword,
    required String newPassword,
    UserRole? role,
  }) {
    throw UnimplementedError('StubAuthRepository: setAccountPassword');
  }

  @override
  Future<void> signOut() async {}
}

