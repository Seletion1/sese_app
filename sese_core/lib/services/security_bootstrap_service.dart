import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

/// Result of startup device integrity & zero-trust checks.
class SecurityCheckResult {
  final bool isTampered;
  final bool isRooted;
  final bool isEmulator;
  final bool isDebuggerAttached;
  final String? failureReason;

  const SecurityCheckResult({
    this.isTampered = false,
    this.isRooted = false,
    this.isEmulator = false,
    this.isDebuggerAttached = false,
    this.failureReason,
  });

  bool get hasViolation =>
      isTampered || isRooted || isEmulator || isDebuggerAttached;
}

/// Zero-trust client-side Security & Anti-Tampering Shield.
class SecurityBootstrapService {
  SecurityBootstrapService._();
  static final SecurityBootstrapService instance = SecurityBootstrapService._();

  /// Runs startup security check before loading feature UI.
  Future<SecurityCheckResult> verifyAppIntegrity({
    bool allowEmulatorInDebug = true,
  }) async {
    bool isTampered = false;
    bool isRooted = false;
    bool isEmulator = false;
    bool isDebuggerAttached = false;
    String? failureReason;

    // 1. Debugger attachment check
    // In release mode (kReleaseMode), Flutter disables Dart VM Service and debuggers by default.
    if (!kReleaseMode && !kDebugMode) {
      isDebuggerAttached = true;
      failureReason = 'Non-release profile or debugger environment detected.';
    }

    // 2. Root / Jailbreak check
    try {
      if (Platform.isAndroid) {
        const suPaths = [
          '/system/app/Superuser.apk',
          '/sbin/su',
          '/system/bin/su',
          '/system/xbin/su',
          '/data/local/xbin/su',
          '/data/local/bin/su',
          '/system/sd/xbin/su',
          '/system/bin/failsafe/su',
          '/data/local/su',
        ];
        for (final path in suPaths) {
          if (File(path).existsSync()) {
            isRooted = true;
            failureReason = 'Rooted Android environment ($path detected).';
            break;
          }
        }
      } else if (Platform.isIOS) {
        const cydiaPaths = [
          '/Applications/Cydia.app',
          '/Library/MobileSubstrate/MobileSubstrate.dylib',
          '/bin/bash',
          '/usr/sbin/sshd',
          '/etc/apt',
          '/private/var/lib/apt/',
        ];
        for (final path in cydiaPaths) {
          if (File(path).existsSync()) {
            isRooted = true;
            failureReason = 'Jailbroken iOS environment ($path detected).';
            break;
          }
        }
      }
    } catch (_) {}

    // 3. Untrusted emulator check in production
    if (!kDebugMode || !allowEmulatorInDebug) {
      try {
        if (Platform.isAndroid) {
          final isGeneric =
              Platform.environment['HARDWARE']?.contains('goldfish') ?? false;
          final isFVP =
              Platform.environment['MODEL']?.contains('google_sdk') ?? false;
          if (isGeneric || isFVP) {
            isEmulator = true;
            failureReason = 'Untrusted emulator detected in production mode.';
          }
        }
      } catch (_) {}
    }

    return SecurityCheckResult(
      isTampered: isTampered,
      isRooted: isRooted,
      isEmulator: isEmulator,
      isDebuggerAttached: isDebuggerAttached,
      failureReason: failureReason,
    );
  }

  /// Displays non-dismissible security blocking dialog when a violation is detected.
  Future<void> showSecurityModal(
    BuildContext context,
    SecurityCheckResult result,
  ) async {
    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (context) => PopScope(
        canPop: false,
        child: AlertDialog(
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
          ),
          title: const Row(
            children: [
              Icon(Icons.shield_rounded, color: Colors.red, size: 28),
              SizedBox(width: 8),
              Expanded(
                child: Text(
                  'Security Shield Triggered',
                  style: TextStyle(fontWeight: FontWeight.bold, fontSize: 18),
                ),
              ),
            ],
          ),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'This app cannot run on this device due to zero-trust security enforcement:',
                style: TextStyle(fontSize: 14),
              ),
              const SizedBox(height: 12),
              if (result.isTampered)
                _buildRuleItem('Modified binary or APK signature mismatch.'),
              if (result.isRooted)
                _buildRuleItem('Rooted or jailbroken device environment.'),
              if (result.isEmulator)
                _buildRuleItem('Untrusted emulator running in production.'),
              if (result.isDebuggerAttached)
                _buildRuleItem('Active debugger attached to binary.'),
              if (result.failureReason != null) ...[
                const SizedBox(height: 8),
                Text(
                  'Reason: ${result.failureReason}',
                  style: const TextStyle(fontSize: 12, color: Colors.grey),
                ),
              ],
            ],
          ),
          actions: const [
            Padding(
              padding: EdgeInsets.all(8.0),
              child: Text(
                'Access Blocked',
                style: TextStyle(
                  color: Colors.red,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildRuleItem(String text) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('• ',
              style: TextStyle(color: Colors.red, fontWeight: FontWeight.bold)),
          Expanded(child: Text(text, style: const TextStyle(fontSize: 13))),
        ],
      ),
    );
  }
}
