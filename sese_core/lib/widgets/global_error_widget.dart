import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../theme/app_theme.dart';

/// Clean, reassuring user-facing error view (`GlobalErrorWidget`).
///
/// Replaces default Flutter error screens / raw stack trace text with an
/// enterprise-standard, user-reassuring card. Guarantees that raw exception
/// messages, line numbers, and internal package paths are NEVER exposed to end users.
class GlobalErrorWidget extends StatelessWidget {
  final VoidCallback? onRestart;
  final VoidCallback? onContactSupport;
  final String? customMessage;

  const GlobalErrorWidget({
    super.key,
    this.onRestart,
    this.onContactSupport,
    this.customMessage,
  });

  static const Color _seseGold = AppColors.seseGold;

  void _defaultRestart(BuildContext context) {
    if (onRestart != null) {
      onRestart!();
    } else {
      // Best-effort restart / route pop
      final nav = Navigator.maybeOf(context);
      if (nav != null && nav.canPop()) {
        nav.pop();
      } else {
        // Triggers app exit or system navigator pop so app can relaunch cleanly
        SystemNavigator.pop();
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;

    final cardBg = isDark ? const Color(0xFF1E1E1E) : Colors.white;

    return Material(
      color: theme.scaffoldBackgroundColor,
      child: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.symmetric(horizontal: 24.0, vertical: 32.0),
            child: Container(
              constraints: const BoxConstraints(maxWidth: 440),
              padding: const EdgeInsets.all(28.0),
              decoration: BoxDecoration(
                color: cardBg,
                borderRadius: BorderRadius.circular(24),
                border: Border.all(
                  color: _seseGold.withValues(alpha: 0.35),
                  width: 1.5,
                ),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: isDark ? 0.3 : 0.08),
                    blurRadius: 16,
                    offset: const Offset(0, 6),
                  ),
                ],
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  // Reassuring Shield Badge Icon
                  Container(
                    width: 76,
                    height: 76,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: _seseGold.withValues(alpha: 0.15),
                      border: Border.all(
                        color: _seseGold.withValues(alpha: 0.4),
                        width: 2,
                      ),
                      boxShadow: [
                        BoxShadow(
                          color: _seseGold.withValues(alpha: 0.25),
                          blurRadius: 16,
                          spreadRadius: 2,
                        ),
                      ],
                    ),
                    child: const Icon(
                      Icons.shield_outlined,
                      size: 40,
                      color: _seseGold,
                    ),
                  ),

                  const SizedBox(height: 24),

                  // Headline
                  Text(
                    'Something went wrong',
                    style: theme.textTheme.headlineSmall?.copyWith(
                      fontWeight: FontWeight.w800,
                      fontSize: 20,
                      letterSpacing: -0.3,
                    ),
                    textAlign: TextAlign.center,
                  ),

                  const SizedBox(height: 12),

                  // Reassuring user copy (no raw stack trace details)
                  Text(
                    customMessage ??
                        "Don't worry, your data is secure. Please tap below to restart or report this to support.",
                    style: theme.textTheme.bodyMedium?.copyWith(
                      fontSize: 14,
                      color: theme.textTheme.bodyMedium?.color
                          ?.withValues(alpha: 0.8),
                      height: 1.45,
                    ),
                    textAlign: TextAlign.center,
                  ),

                  const SizedBox(height: 28),

                  // Primary Action Button: Restart App
                  SizedBox(
                    width: double.infinity,
                    height: 50,
                    child: ElevatedButton.icon(
                      key: const Key('global_error_restart_button'),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: _seseGold,
                        foregroundColor: Colors.black,
                        elevation: 1,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(14),
                        ),
                      ),
                      onPressed: () => _defaultRestart(context),
                      icon: const Icon(Icons.refresh_rounded, size: 20),
                      label: const Text(
                        'Restart App',
                        style: TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                  ),

                  if (onContactSupport != null) ...[
                    const SizedBox(height: 12),

                    // Secondary Action Button: Contact Support
                    SizedBox(
                      width: double.infinity,
                      height: 48,
                      child: TextButton.icon(
                        key: const Key('global_error_support_button'),
                        style: TextButton.styleFrom(
                          foregroundColor: theme.textTheme.bodyMedium?.color,
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(14),
                          ),
                        ),
                        onPressed: onContactSupport,
                        icon: const Icon(Icons.support_agent_rounded, size: 20),
                        label: const Text(
                          'Contact Support',
                          style: TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
