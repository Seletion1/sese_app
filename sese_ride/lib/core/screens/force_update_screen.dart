import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

/// Blocking screen shown when the installed build is older than the
/// `min_supported_app_version` Remote Config parameter.
///
/// Unlike [MaintenanceScreen] this cannot auto-clear: the running binary is
/// the outdated one, so a Remote Config fetch cannot upgrade it. The user must
/// install a new build, which is why there is no skip/dismiss control.
class ForceUpdateScreen extends StatelessWidget {
  /// Play Store / App Store listing to send the user to.
  final String updateUrl;

  /// Version required by the server, shown so support can match reports.
  final String requiredVersion;

  const ForceUpdateScreen({
    super.key,
    required this.updateUrl,
    required this.requiredVersion,
  });

  /// Default listing URL, derived from the Android `applicationId`
  /// (`com.sesetech.sese_ride`).
  ///
  /// The iOS listing is not wired yet because the App Store ID is not known;
  /// add a platform switch here once the iOS build is published.
  static const String defaultUpdateUrl =
      'https://play.google.com/store/apps/details?id=com.sesetech.sese_ride';

  Future<void> _openStore(BuildContext context) async {
    final messenger = ScaffoldMessenger.maybeOf(context);
    var launched = false;
    try {
      final uri = Uri.parse(updateUrl);
      launched = await launchUrl(uri, mode: LaunchMode.externalApplication);
    } catch (e) {
      debugPrint('ForceUpdateScreen: could not open $updateUrl ($e)');
    }
    if (!launched) {
      messenger?.showSnackBar(
        const SnackBar(content: Text('Could not open the store listing.')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      child: Scaffold(
        body: SafeArea(
          child: Center(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(32),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.system_update,
                      size: 64, color: Color(0xFFFFB800)),
                  const SizedBox(height: 24),
                  const Text(
                    'Update Required',
                    textAlign: TextAlign.center,
                    style:
                        TextStyle(fontSize: 24, fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 12),
                  Text(
                    'Please update to version $requiredVersion or newer to '
                    'continue using SeSe Ride.',
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.bodyLarge,
                  ),
                  const SizedBox(height: 28),
                  FilledButton.icon(
                    icon: const Icon(Icons.download),
                    label: const Text('Update Now'),
                    onPressed: () => _openStore(context),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
