import 'package:flutter/material.dart';
import 'package:sese_core/sese_core.dart';

import 'permission_onboarding_screen.dart';
import 'permission_onboarding_service.dart';

/// Pre-flight Permission Gate (`PermissionOnboardingGate`).
///
/// Wraps home shell destinations (`CustomerHomeShell`, `DriverHomeShell`).
/// Checks if required baseline permissions for [role] are granted or
/// previously completed. If missing, presents [PermissionOnboardingScreen].
/// Once accepted, smoothly renders [child].
class PermissionOnboardingGate extends StatefulWidget {
  final AppUser user;
  final UserRole role;
  final AuthRepository? auth;
  final Widget child;

  const PermissionOnboardingGate({
    super.key,
    required this.user,
    required this.role,
    this.auth,
    required this.child,
  });

  /// Helper utility to wrap a target shell route in the permission gate.
  static Widget wrap({
    required AppUser user,
    required UserRole role,
    AuthRepository? auth,
    required Widget child,
  }) {
    return PermissionOnboardingGate(
      user: user,
      role: role,
      auth: auth,
      child: child,
    );
  }

  @override
  State<PermissionOnboardingGate> createState() =>
      _PermissionOnboardingGateState();
}

class _PermissionOnboardingGateState extends State<PermissionOnboardingGate>
    with WidgetsBindingObserver {
  late Future<bool> _isCompletedFuture;
  String? _cachedUserId;
  UserRole? _cachedRole;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _checkPermissions();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      PermissionOnboardingService.refreshLocationStatus();
    }
  }

  void _checkPermissions() {
    _cachedUserId = widget.user.uid;
    _cachedRole = widget.role;
    _isCompletedFuture = PermissionOnboardingService.isCompleted(
      userId: widget.user.uid,
      role: widget.role,
    );
  }

  @override
  void didUpdateWidget(covariant PermissionOnboardingGate oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.user.uid != widget.user.uid || oldWidget.role != widget.role) {
      _checkPermissions();
    }
  }

  void _handleCompleted() {
    setState(() {
      _isCompletedFuture = Future.value(true);
    });
  }

  @override
  Widget build(BuildContext context) {
    if (_cachedUserId != widget.user.uid || _cachedRole != widget.role) {
      _checkPermissions();
    }

    return FutureBuilder<bool>(
      future: _isCompletedFuture,
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done) {
          // Transparent scaffold during 0ms local SharedPreferences / status resolution
          return const Scaffold(body: SizedBox.shrink());
        }

        final isCompleted = snapshot.data ?? false;
        if (isCompleted) {
          return widget.child;
        }

        return PermissionOnboardingScreen(
          user: widget.user,
          role: widget.role,
          auth: widget.auth,
          onCompleted: _handleCompleted,
        );
      },
    );
  }
}
