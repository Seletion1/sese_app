import 'package:flutter/material.dart';
import 'package:sese_core/sese_core.dart';
import 'auth_screen.dart';

/// Legacy shim bridging [RegistrationPage] to the refactored [AuthScreen] in Create Account mode.
/// Retains backward compatibility for external callers.
class RegistrationPage extends StatelessWidget {
  final AuthRepository? auth;
  final UserRole initialRole;

  const RegistrationPage({
    super.key,
    this.auth,
    this.initialRole = UserRole.customer,
  });

  @override
  Widget build(BuildContext context) {
    return AuthScreen(
      auth: auth,
      initialRole: initialRole,
      initialSignUpMode: true,
    );
  }
}
