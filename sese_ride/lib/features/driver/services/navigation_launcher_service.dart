import 'package:flutter/material.dart';
import 'package:latlong2/latlong.dart';
import 'package:sese_core/sese_core.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../trips/models/trip_models.dart';
import '../presentation/widgets/navigation_logos.dart';

/// Supported external navigation providers (strictly Google Maps & Waze).
enum NavigationAppOption {
  googleMaps,
  waze,
}

/// Service to prompt drivers and launch turn-by-turn navigation
/// via external apps (strictly Google Maps and Waze).
///
/// Features daily default preference: on the first tap of any calendar day,
/// prompts the driver with the 2-option picker and persists the choice.
/// Subsequent single taps on that same day launch the chosen app directly.
/// Once the local calendar date advances, the prompt re-appears on the first tap.
/// Long-pressing the Navigate button always re-opens the picker to switch mid-day.
abstract final class NavigationLauncherService {
  static const String prefNavAppKey = 'daily_default_nav_app';
  static const String prefNavDateKey = 'daily_default_nav_date';

  /// Returns today's local date string formatted as 'YYYY-MM-DD'.
  static String getTodayDateString([DateTime? now]) {
    final d = now ?? DateTime.now();
    final year = d.year.toString().padLeft(4, '0');
    final month = d.month.toString().padLeft(2, '0');
    final day = d.day.toString().padLeft(2, '0');
    return '$year-$month-$day';
  }

  /// Gets the saved navigation app preference if it matches today's date.
  /// If missing or from a previous calendar day, returns null (and clears stale date).
  static Future<NavigationAppOption?> getDailyDefaultNavApp({
    SharedPreferences? overridePrefs,
    DateTime? now,
  }) async {
    final prefs = overridePrefs ?? await SharedPreferences.getInstance();
    final savedDate = prefs.getString(prefNavDateKey);
    final savedApp = prefs.getString(prefNavAppKey);
    final today = getTodayDateString(now);

    if (savedDate == today && savedApp != null) {
      if (savedApp == NavigationAppOption.googleMaps.name) {
        return NavigationAppOption.googleMaps;
      } else if (savedApp == NavigationAppOption.waze.name) {
        return NavigationAppOption.waze;
      }
    } else if (savedDate != null && savedDate != today) {
      // Clear previous day's preference so new day prompts fresh
      await prefs.remove(prefNavAppKey);
      await prefs.remove(prefNavDateKey);
    }
    return null;
  }

  /// Saves today's navigation preference into persistent storage.
  static Future<void> setDailyDefaultNavApp(
    NavigationAppOption option, {
    SharedPreferences? overridePrefs,
    DateTime? now,
  }) async {
    final prefs = overridePrefs ?? await SharedPreferences.getInstance();
    final today = getTodayDateString(now);
    await prefs.setString(prefNavAppKey, option.name);
    await prefs.setString(prefNavDateKey, today);
  }

  /// Clears any saved daily navigation preference.
  static Future<void> clearDailyDefaultNavApp({
    SharedPreferences? overridePrefs,
  }) async {
    final prefs = overridePrefs ?? await SharedPreferences.getInstance();
    await prefs.remove(prefNavAppKey);
    await prefs.remove(prefNavDateKey);
  }

  /// Primary navigation dispatch:
  /// - If [forceChooser] is true (e.g. from long-press) or no valid preference
  ///   exists for today: prompts the driver with the 2-option sheet, saves the
  ///   choice, and launches it.
  /// - If a preference already exists for today: launches directly without showing
  ///   the picker.
  static Future<void> navigate({
    required BuildContext context,
    required double destinationLat,
    required double destinationLng,
    required String destinationAddress,
    required bool isHeadingToPickup,
    LatLng? driverPosition,
    ActiveTrip? trip,
    bool forceChooser = false,
  }) async {
    NavigationAppOption? targetOption;

    if (!forceChooser) {
      targetOption = await getDailyDefaultNavApp();
    }

    if (targetOption == null) {
      if (!context.mounted) return;
      targetOption = await showNavigationChooser(
        context: context,
        destinationAddress: destinationAddress,
        isHeadingToPickup: isHeadingToPickup,
      );
      if (targetOption != null) {
        await setDailyDefaultNavApp(targetOption);
      }
    }

    if (targetOption == null) return;

    switch (targetOption) {
      case NavigationAppOption.googleMaps:
        await launchGoogleMaps(destinationLat, destinationLng);
        break;
      case NavigationAppOption.waze:
        await launchWaze(destinationLat, destinationLng);
        break;
    }
  }

  /// Opens the 2-option chooser bottom sheet (Google Maps & Waze).
  static Future<NavigationAppOption?> showNavigationChooser({
    required BuildContext context,
    required String destinationAddress,
    required bool isHeadingToPickup,
    double? destinationLat,
    double? destinationLng,
    LatLng? driverPosition,
    ActiveTrip? trip,
  }) async {
    return showModalBottomSheet<NavigationAppOption>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) => _NavigationChooserSheet(
        destinationAddress: destinationAddress,
        isHeadingToPickup: isHeadingToPickup,
      ),
    );
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
      child: SafeArea(
        top: false,
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.of(context).size.height * 0.85,
          ),
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 20),
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
                    const Icon(
                      Icons.navigation_rounded,
                      color: AppColors.seseGold,
                      size: 24,
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            isHeadingToPickup
                                ? 'Navigate to Pickup'
                                : 'Navigate to Dropoff',
                            style: Theme.of(context)
                                .textTheme
                                .titleMedium
                                ?.copyWith(
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
                const SizedBox(height: 12),
                _NavOptionTile(
                  title: 'Google Maps',
                  subtitle: 'External voice & traffic navigation',
                  iconWidget: const GoogleMapsLogo(size: 26),
                  onTap: () =>
                      Navigator.of(context).pop(NavigationAppOption.googleMaps),
                ),
                const SizedBox(height: 10),
                _NavOptionTile(
                  title: 'Waze',
                  subtitle: 'External live community navigation',
                  iconWidget: const WazeLogo(size: 28),
                  onTap: () =>
                      Navigator.of(context).pop(NavigationAppOption.waze),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _NavOptionTile extends StatelessWidget {
  final String title;
  final String subtitle;
  final Widget iconWidget;
  final VoidCallback onTap;

  const _NavOptionTile({
    required this.title,
    required this.subtitle,
    required this.iconWidget,
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
              width: 42,
              height: 42,
              decoration: BoxDecoration(
                color: isDark ? const Color(0xFF1E1E24) : Colors.white,
                borderRadius: BorderRadius.circular(10),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.06),
                    blurRadius: 4,
                    offset: const Offset(0, 1),
                  ),
                ],
              ),
              alignment: Alignment.center,
              child: iconWidget,
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: const TextStyle(
                      fontWeight: FontWeight.w700,
                      fontSize: 14,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    subtitle,
                    style: Theme.of(context)
                        .textTheme
                        .bodySmall
                        ?.copyWith(fontSize: 12),
                  ),
                ],
              ),
            ),
            const Icon(
              Icons.arrow_forward_ios_rounded,
              size: 14,
              color: Colors.grey,
            ),
          ],
        ),
      ),
    );
  }
}
