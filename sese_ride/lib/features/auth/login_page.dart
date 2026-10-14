import 'package:flutter/material.dart';
import 'package:sese_core/sese_core.dart';
import 'welcome_role_selection_screen.dart';

/// Legacy shim bridging [LoginPage] to [WelcomeRoleSelectionScreen].
/// Keeps backward compatibility with existing tests and imports.
class LoginPage extends StatelessWidget {
  final AuthRepository? auth;

  const LoginPage({super.key, this.auth});

  @override
  Widget build(BuildContext context) {
    return WelcomeRoleSelectionScreen(auth: auth);
  }
}

