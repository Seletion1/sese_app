import 'package:flutter/material.dart';
import 'package:latlong2/latlong.dart';
import 'package:sese_core/sese_core.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../trips/models/trip_models.dart';

/// Supported external and internal navigation providers.
enum NavigationAppOption {
  inAppOsm,
  googleMaps,
  waze,
  appleMaps,
  systemDefault,
}

/// Service to prompt drivers and launch turn-by-turn navigation
/// either in-app via OpenStreetMap or via external apps (Google Maps, Waze).
abstract final class NavigationLauncherService {
  /// Opens a bottom sheet prompting the driver to pick their navigation app.
  static Future<void> showNavigationChooser({
    required BuildContext context,
    required double destinationLat,
    required double destinationLng,
    required String destinationAddress,
    required bool isHeadingToPickup,
    LatLng? driverPosition,
    ActiveTrip? trip,
  }) async {
    final option = await showModalBottomSheet<NavigationAppOption>(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (ctx) => _NavigationChooserSheet(
        destinationAddress: destinationAddress,
        isHeadingToPickup: isHeadingToPickup,
      ),
    );

    if (option == null || !context.mounted) return;

    switch (option) {
      case NavigationAppOption.inAppOsm:
        // In-app turn-by-turn navigation runs directly on the main dashboard map canvas.
        break;

      case NavigationAppOption.googleMaps:
        await launchGoogleMaps(destinationLat, destinationLng);
        break;

      case NavigationAppOption.waze:
        await launchWaze(destinationLat, destinationLng);
        break;

      case NavigationAppOption.appleMaps:
        await launchAppleMaps(destinationLat, destinationLng);
        break;

      case NavigationAppOption.systemDefault:
        await launchSystemMap(destinationLat, destinationLng, destinationAddress);
        break;
    }
  }

  /// Launches Google Maps turn-by-turn navigation directly.
  static Future<bool> launchGoogleMaps(double lat, double lng) async {
    // 1. iOS Google Maps app scheme
    final iosGoogleUri = Uri.parse(
      'comgooglemaps://?daddr=$lat,$lng&directionsmode=driving',
    );
    if (await canLaunchUrl(iosGoogleUri)) {
      return launchUrl(iosGoogleUri, mode: LaunchMode.externalApplication);
    }

    // 2. Android turn-by-turn navigation intent
    final navUri = Uri.parse('google.navigation:q=$lat,$lng&mode=d');
    if (await canLaunchUrl(navUri)) {
      return launchUrl(navUri, mode: LaunchMode.externalApplication);
    }

    // 3. Fallback to standard Google Maps directions URL
    final webUri = Uri.parse(
      'https://www.google.com/maps/dir/?api=1&destination=$lat,$lng&travelmode=driving',
    );
    if (await canLaunchUrl(webUri)) {
      return launchUrl(webUri, mode: LaunchMode.externalApplication);
    }

    return false;
  }

  /// Launches Waze navigation directly.
  static Future<bool> launchWaze(double lat, double lng) async {
    final wazeAppUri = Uri.parse('waze://?ll=$lat,$lng&navigate=yes');
    if (await canLaunchUrl(wazeAppUri)) {
      return launchUrl(wazeAppUri, mode: LaunchMode.externalApplication);
    }

    final wazeWebUri = Uri.parse('https://waze.com/ul?ll=$lat,$lng&navigate=yes');
    if (await canLaunchUrl(wazeWebUri)) {
      return launchUrl(wazeWebUri, mode: LaunchMode.externalApplication);
    }

    return false;
  }

  /// Launches Apple Maps navigation directly. The `maps.apple.com` URL
  /// opens the native Maps app on iOS and degrades to the browser
  /// elsewhere, so this is safe to offer on every platform.
  static Future<bool> launchAppleMaps(double lat, double lng) async {
    final appleUri = Uri.parse('https://maps.apple.com/?daddr=$lat,$lng');
    if (await canLaunchUrl(appleUri)) {
      return launchUrl(appleUri, mode: LaunchMode.externalApplication);
    }
    return launchGoogleMaps(lat, lng);
  }

  /// Launches any installed system map via geo: intent.
  static Future<bool> launchSystemMap(
    double lat,
    double lng,
    String label,
  ) async {
    final geoUri = Uri.parse('geo:$lat,$lng?q=$lat,$lng(${Uri.encodeComponent(label)})');
    if (await canLaunchUrl(geoUri)) {
      return launchUrl(geoUri, mode: LaunchMode.externalApplication);
    }

    // Fallback to Google Maps web
    return launchGoogleMaps(lat, lng);
  }
}

class _NavigationChooserSheet extends StatelessWidget {
  final String destinationAddress;
  final bool isHeadingToPickup;

  const _NavigationChooserSheet({
    required this.destinationAddress,
    required this.isHeadingToPickup,
  });

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final cardBg = isDark ? const Color(0xFF1E1E24) : Colors.white;

    return Container(
      decoration: BoxDecoration(
        color: cardBg,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.15),
            blurRadius: 10,
            offset: const Offset(0, -2),
          ),
        ],
      ),
      // 16px gutters so app options span edge-to-edge on phones.
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Center(
            child: Container(
              width: 36,
              height: 4,
              decoration: BoxDecoration(
                color: Colors.grey.withValues(alpha: 0.4),
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ),
          const SizedBox(height: 16),
          Row(
            children: [
              const Icon(Icons.navigation_rounded, color: AppColors.seseGold, size: 24),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      isHeadingToPickup ? 'Navigate to Pickup' : 'Navigate to Dropoff',
                      style: Theme.of(context).textTheme.titleMedium?.copyWith(
                            fontWeight: FontWeight.bold,
                          ),
                    ),
                    if (destinationAddress.isNotEmpty)
                      Text(
                        destinationAddress,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 20),
          Text(
            'CHOOSE NAVIGATION APP',
            style: Theme.of(context).textTheme.labelSmall?.copyWith(
                  fontWeight: FontWeight.w700,
                  letterSpacing: 0.8,
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
          ),
          const SizedBox(height: 10),
          _NavOptionTile(
            title: 'In-App Navigation',
            subtitle: 'Turn-by-turn guidance on OpenStreetMap',
            icon: Icons.map_rounded,
            iconColor: AppColors.seseGold,
            onTap: () => Navigator.of(context).pop(NavigationAppOption.inAppOsm),
          ),
          const SizedBox(height: 8),
          _NavOptionTile(
            title: 'Google Maps',
            subtitle: 'External voice & traffic navigation',
            icon: Icons.alt_route_rounded,
            iconColor: Colors.blue.shade600,
            onTap: () => Navigator.of(context).pop(NavigationAppOption.googleMaps),
          ),
          const SizedBox(height: 8),
          _NavOptionTile(
            title: 'Waze',
            subtitle: 'External live community navigation',
            icon: Icons.directions_car_filled_rounded,
            iconColor: Colors.cyan.shade600,
            onTap: () => Navigator.of(context).pop(NavigationAppOption.waze),
          ),
          const SizedBox(height: 8),
          _NavOptionTile(
            title: 'Apple Maps',
            subtitle: 'External navigation on Apple Maps',
            icon: Icons.map_outlined,
            iconColor: Colors.grey.shade700,
            onTap: () => Navigator.of(context).pop(NavigationAppOption.appleMaps),
          ),
          const SizedBox(height: 8),
          _NavOptionTile(
            title: 'Other Navigation Apps',
            subtitle: 'Open default device GPS app',
            icon: Icons.explore_rounded,
            iconColor: Colors.green.shade600,
            onTap: () => Navigator.of(context).pop(NavigationAppOption.systemDefault),
          ),
        ],
      ),
    );
  }
}

class _NavOptionTile extends StatelessWidget {
  final String title;
  final String subtitle;
  final IconData icon;
  final Color iconColor;
  final VoidCallback onTap;

  const _NavOptionTile({
    required this.title,
    required this.subtitle,
    required this.icon,
    required this.iconColor,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final fill = isDark ? const Color(0xFF282832) : const Color(0xFFF3F4F6);

    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(14),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        decoration: BoxDecoration(
          color: fill,
          borderRadius: BorderRadius.circular(14),
        ),
        child: Row(
          children: [
            Container(
              width: 40,
              height: 40,
              decoration: BoxDecoration(
                color: iconColor.withValues(alpha: 0.15),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Icon(icon, color: iconColor, size: 22),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 14),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    subtitle,
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(fontSize: 12),
                  ),
                ],
              ),
            ),
            const Icon(Icons.arrow_forward_ios_rounded, size: 14, color: Colors.grey),
          ],
        ),
      ),
    );
  }
}
