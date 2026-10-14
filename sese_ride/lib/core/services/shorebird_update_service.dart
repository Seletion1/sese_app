import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:shorebird_code_push/shorebird_code_push.dart';

/// Service managing Over-The-Air (OTA) Dart code patches via Shorebird.
///
/// Design contract:
/// - **Graceful degradation:** Degrades silently if Shorebird is unavailable,
///   offline, or running in debug mode (where patches are unsupported).
/// - **Non-blocking background check:** Patch downloads happen asynchronously
///   in the background without blocking the UI or startup sequence. Downloaded
///   patches are staged on-device and automatically applied on the next cold restart.
/// - **Zero network throw:** Errors during patch checking/downloading are caught
///   and logged via [debugPrint] without disrupting the user experience.
class ShorebirdUpdateService {
  final ShorebirdUpdater _updater;

  /// Creates a [ShorebirdUpdateService] instance with an optional [_updater]
  /// handle for dependency injection / testing.
  ShorebirdUpdateService({ShorebirdUpdater? updater})
      : _updater = updater ?? ShorebirdUpdater();

  /// Checks for available OTA patches on the Shorebird release channel.
  ///
  /// In debug mode ([kDebugMode]), patch checks are skipped because Shorebird
  /// engine hooks only operate on release/profile builds.
  Future<void> checkForUpdates() async {
    if (kDebugMode) {
      debugPrint('[ShorebirdUpdateService] Debug mode: skipping OTA patch check.');
      return;
    }

    try {
      if (!_updater.isAvailable) {
        debugPrint('[ShorebirdUpdateService] Shorebird updater is not available on this build.');
        return;
      }

      final status = await _updater.checkForUpdate();
      if (status == UpdateStatus.outdated) {
        debugPrint('[ShorebirdUpdateService] New OTA patch available. Downloading in background...');
        await _updater.update();
        debugPrint('[ShorebirdUpdateService] Patch downloaded successfully. Will apply on next restart.');
      } else {
        debugPrint('[ShorebirdUpdateService] App is up-to-date (status: ${status.name}).');
      }
    } catch (e, stackTrace) {
      debugPrint('[ShorebirdUpdateService] Error checking for OTA updates: $e\n$stackTrace');
    }
  }

  /// Returns the currently active patch number, or `null` if running the base release.
  Future<int?> getCurrentPatchNumber() async {
    try {
      if (!_updater.isAvailable) return null;
      final patch = await _updater.readCurrentPatch();
      return patch?.number;
    } catch (e) {
      debugPrint('[ShorebirdUpdateService] Error fetching patch number: $e');
      return null;
    }
  }
}
