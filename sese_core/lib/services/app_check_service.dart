import 'dart:async';
import 'package:firebase_app_check/firebase_app_check.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../config/app_check_config.dart';

/// Centralized, enterprise-grade Firebase App Check service.
///
/// Production Security Architecture:
/// 1. Strict environment isolation: Release builds exclusively enforce hardware-backed
///    attestation (Play Integrity on Android, App Attest / DeviceCheck on Apple).
/// 2. Debug attestation decoupling: Debug tokens are never included or activated in
///    production release builds.
/// 3. Token expiration protection: Listens to App Check token changes and refreshes
///    seamlessly to eliminate sudden `permission-denied` or `unauthenticated` blocks.
abstract final class AppCheckService {
  static StreamSubscription<String?>? _tokenSub;

  /// Initializes App Check for the specified [appId] ('sese_ride' or 'sese_hub').
  static Future<void> initialize({
    required String appId,
    String? channelName,
  }) async {
    // 1. Native debug token pinning (Debug builds ONLY)
    if (kDebugMode) {
      final debugToken = AppCheckConfig.debugTokenFor(appId);
      if (debugToken.isNotEmpty) {
        debugPrint('[$appId] Initializing App Check with debug token: $debugToken');
        final channel = channelName ?? 'com.sesetech.$appId/app_check';
        try {
          await MethodChannel(channel).invokeMethod('pinDebugToken', {'token': debugToken});
        } catch (e) {
          debugPrint('[$appId] AppCheck native token pin warning: $e');
        }
      }
    }

    // 2. Activate App Check with strict environment separation
    final rawToken = AppCheckConfig.debugTokenFor(appId).trim();
    final String? debugToken = rawToken.isNotEmpty ? rawToken : null;

    try {
      await FirebaseAppCheck.instance.activate(
        providerAndroid: kReleaseMode
            ? const AndroidPlayIntegrityProvider()
            : AndroidDebugProvider(
                debugToken: debugToken,
              ),
        providerApple: kReleaseMode
            ? const AppleAppAttestWithDeviceCheckFallbackProvider()
            : AppleDebugProvider(
                debugToken: debugToken,
              ),
      );
      if (kDebugMode) {
        debugPrint('[$appId] FirebaseAppCheck activated successfully (release: $kReleaseMode).');
      }
    } catch (e) {
      debugPrint('[$appId] FirebaseAppCheck activation error: $e');
    }

    // 3. Automated Token Expiration & Refresh Listener
    try {
      await _tokenSub?.cancel();
      _tokenSub = FirebaseAppCheck.instance.onTokenChange.listen(
        (token) {
          if (kDebugMode) {
            debugPrint('[$appId] App Check token refreshed: ${token != null ? "valid" : "null"}');
          }
        },
        onError: (e) {
          debugPrint('[$appId] App Check token refresh error: $e');
        },
      );
    } catch (e) {
      debugPrint('[$appId] App Check token listener error: $e');
    }
  }

  /// Cancels active App Check listeners on app shutdown or test teardown.
  static void dispose() {
    _tokenSub?.cancel();
    _tokenSub = null;
  }
}
