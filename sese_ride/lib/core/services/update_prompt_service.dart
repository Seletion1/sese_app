import 'package:flutter/material.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:url_launcher/url_launcher.dart';

import '../screens/force_update_screen.dart';
import 'remote_config_service.dart';

/// Result of evaluating whether an update prompt should be shown based on
/// build-number lag.
class UpdatePromptDecision {
  final bool shouldPrompt;
  final int versionsBehind;
  final bool forceWhenThresholdReached;

  const UpdatePromptDecision({
    required this.shouldPrompt,
    required this.versionsBehind,
    required this.forceWhenThresholdReached,
  });
}

/// Checks whether the installed app build is behind [RemoteConfigService.latestBuildNumber]
/// by at least [RemoteConfigService.updatePromptLagThreshold] versions (default 3),
/// and prompts the user to update without interrupting them on every release.
class UpdatePromptService {
  UpdatePromptService._();

  /// Default number of versions behind before prompting (gives users 1–2 updates
  /// of breathing room).
  static const int maxBehindBeforePrompt = 3;

  static bool _hasPromptedThisSession = false;

  /// Pure evaluation of build-lag rules, extracted for unit testing.
  ///
  /// Returns `shouldPrompt: false` if either build number is `<= 0`, if
  /// [lagThreshold] is `<= 0`, or if `latestBuildNumber - currentBuildNumber < lagThreshold`.
  @visibleForTesting
  static UpdatePromptDecision evaluate({
    required int currentBuildNumber,
    required int latestBuildNumber,
    int lagThreshold = maxBehindBeforePrompt,
    int forceThreshold = 0,
  }) {
    if (latestBuildNumber <= 0 ||
        currentBuildNumber <= 0 ||
        lagThreshold <= 0) {
      return const UpdatePromptDecision(
        shouldPrompt: false,
        versionsBehind: 0,
        forceWhenThresholdReached: false,
      );
    }

    final versionsBehind = latestBuildNumber - currentBuildNumber;
    if (versionsBehind < lagThreshold) {
      return UpdatePromptDecision(
        shouldPrompt: false,
        versionsBehind: versionsBehind,
        forceWhenThresholdReached: false,
      );
    }

    final isForced = forceThreshold > 0 && versionsBehind >= forceThreshold;
    return UpdatePromptDecision(
      shouldPrompt: true,
      versionsBehind: versionsBehind,
      forceWhenThresholdReached: isForced,
    );
  }

  /// Convenience entry point that reads [RemoteConfigService] parameters and
  /// [ForceUpdateScreen.defaultUpdateUrl].
  static Future<void> checkUsingRemoteConfig({
    required BuildContext context,
    int? currentBuildNumberOverride,
    Future<bool> Function(Uri)? launchUrlOverride,
    bool bypassSessionGuard = false,
  }) {
    return checkAndPromptUpdate(
      context: context,
      latestBuildNumber: RemoteConfigService.latestBuildNumber,
      playStoreUrl: ForceUpdateScreen.defaultUpdateUrl,
      lagThreshold: RemoteConfigService.updatePromptLagThreshold,
      forceThreshold: RemoteConfigService.forceUpdateLagThreshold,
      currentBuildNumberOverride: currentBuildNumberOverride,
      launchUrlOverride: launchUrlOverride,
      bypassSessionGuard: bypassSessionGuard,
    );
  }

  /// Checks the installed build number against [latestBuildNumber] and shows an
  /// update dialog when the app is at least [lagThreshold] versions behind.
  ///
  /// Shows at most once per app session unless [bypassSessionGuard] is true.
  static Future<void> checkAndPromptUpdate({
    required BuildContext context,
    required int latestBuildNumber,
    required String playStoreUrl,
    int lagThreshold = maxBehindBeforePrompt,
    int forceThreshold = 0,
    bool? forceWhenThresholdReached,
    int? currentBuildNumberOverride,
    Future<bool> Function(Uri)? launchUrlOverride,
    bool bypassSessionGuard = false,
  }) async {
    if (_hasPromptedThisSession && !bypassSessionGuard) return;
    if (latestBuildNumber <= 0 || lagThreshold <= 0) return;

    int currentBuildNumber;
    if (currentBuildNumberOverride != null) {
      currentBuildNumber = currentBuildNumberOverride;
    } else {
      try {
        final packageInfo = await PackageInfo.fromPlatform();
        currentBuildNumber = int.tryParse(packageInfo.buildNumber) ?? 0;
      } catch (e) {
        debugPrint('UpdatePromptService: PackageInfo failed ($e)');
        return;
      }
    }

    final decision = evaluate(
      currentBuildNumber: currentBuildNumber,
      latestBuildNumber: latestBuildNumber,
      lagThreshold: lagThreshold,
      forceThreshold: forceThreshold,
    );

    if (!decision.shouldPrompt) return;
    if (!context.mounted) return;

    _hasPromptedThisSession = true;
    final isForced =
        forceWhenThresholdReached ?? decision.forceWhenThresholdReached;

    await showDialog<void>(
      context: context,
      barrierDismissible: !isForced,
      builder: (ctx) {
        return PopScope(
          canPop: !isForced,
          child: AlertDialog(
            title: const Text('Update Available'),
            content: Text(
              'Your app is ${decision.versionsBehind} versions behind. '
              'Update now to get the latest improvements, security fixes, '
              'and smoother performance.',
            ),
            actions: [
              if (!isForced)
                TextButton(
                  onPressed: () => Navigator.of(ctx).pop(),
                  child: const Text('Later'),
                ),
              FilledButton(
                onPressed: () async {
                  final uri = Uri.parse(playStoreUrl);
                  if (launchUrlOverride != null) {
                    await launchUrlOverride(uri);
                    return;
                  }
                  if (await canLaunchUrl(uri)) {
                    await launchUrl(uri, mode: LaunchMode.externalApplication);
                  }
                },
                child: const Text('Update Now'),
              ),
            ],
          ),
        );
      },
    );
  }

  /// Resets the per-session prompt guard (for unit/widget tests).
  @visibleForTesting
  static void resetSessionGuard() {
    _hasPromptedThisSession = false;
  }
}
