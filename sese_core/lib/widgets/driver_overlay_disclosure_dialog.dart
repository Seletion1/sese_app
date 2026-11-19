import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../theme/app_theme.dart';

/// Mandatory Google Play Prominent Disclosure Dialog for `SYSTEM_ALERT_WINDOW`.
///
/// Google Play policy requires displaying an explicit in-app prominent disclosure
/// explaining the feature and its exact purpose BEFORE navigating to the system
/// "Display over other apps" permission settings screen.
///
/// Policy Compliance Guarantees:
/// 1. Explains why permission is requested: To show a floating quick-return bubble
///    enabling drivers to quickly return to SeSe for incoming ride/delivery requests
///    while using third-party turn-by-turn navigation (e.g. Google Maps, Waze).
/// 2. Clear boundaries: Only active while ONLINE, never displays ads or promotional
///    content, never covers critical system elements.
/// 3. Non-coercive opt-in: Drivers who decline can still use the app completely
///    normally via standard notification channels.
class DriverOverlayDisclosureDialog extends StatelessWidget {
  static const String consentKey = 'has_consented_overlay_bubble';

  final VoidCallback onAgree;
  final VoidCallback? onDecline;

  const DriverOverlayDisclosureDialog({
    super.key,
    required this.onAgree,
    this.onDecline,
  });

  /// Check whether the driver has already been shown and consented to the disclosure.
  static Future<bool> shouldShowDisclosure() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      return !(prefs.getBool(consentKey) ?? false);
    } catch (_) {
      return true;
    }
  }

  /// Records consent in local preferences.
  static Future<void> recordConsent({bool consented = true}) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(consentKey, consented);
    } catch (_) {}
  }

  /// Convenience helper to display the disclosure dialog modally.
  static Future<bool> show(BuildContext context) async {
    final result = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => DriverOverlayDisclosureDialog(
        onAgree: () => Navigator.of(ctx).pop(true),
        onDecline: () => Navigator.of(ctx).pop(false),
      ),
    );
    return result ?? false;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final cardBg = isDark ? const Color(0xFF1E1E24) : Colors.white;
    final textColor = isDark ? Colors.white : Colors.black87;
    final subtextColor = isDark ? const Color(0xFFAAAAAA) : const Color(0xFF666666);

    return Dialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      backgroundColor: cardBg,
      insetPadding: const EdgeInsets.symmetric(horizontal: 24, vertical: 24),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 420),
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // Header Badge & Logo
              Center(
                child: Container(
                  width: 72,
                  height: 72,
                  decoration: BoxDecoration(
                    color: AppColors.seseGold.withValues(alpha: 0.15),
                    shape: BoxShape.circle,
                    border: Border.all(color: AppColors.seseGold, width: 2),
                  ),
                  child: const Center(
                    child: Icon(
                      Icons.picture_in_picture_alt_rounded,
                      color: AppColors.seseGold,
                      size: 36,
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 18),

              // Title
              Text(
                'Floating Quick-Return Bubble',
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.bold,
                  color: textColor,
                ),
              ),
              const SizedBox(height: 12),

              // Purpose & Scope
              Text(
                'SeSe Ride requests "Display over other apps" permission so you can keep a compact quick-return bubble visible while using navigation apps like Google Maps or Waze.',
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 14,
                  height: 1.45,
                  color: subtextColor,
                ),
              ),
              const SizedBox(height: 16),

              // Policy Compliance Transparency Box
              Container(
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  color: isDark ? const Color(0xFF252530) : const Color(0xFFF5F6F8),
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(
                    color: isDark ? const Color(0xFF333340) : const Color(0xFFE2E4E8),
                  ),
                ),
                child: Column(
                  children: [
                    _buildFeatureBullet(
                      icon: Icons.check_circle_rounded,
                      title: 'Active only while ONLINE',
                      desc: 'Automatically closes when you go offline, sign out, or close work mode.',
                      color: Colors.green,
                      textColor: textColor,
                      subtextColor: subtextColor,
                    ),
                    const SizedBox(height: 10),
                    _buildFeatureBullet(
                      icon: Icons.touch_app_rounded,
                      title: 'Instant 1-Tap Return',
                      desc: 'Tap the bubble anytime to jump straight back to incoming orders or trip routes.',
                      color: AppColors.seseGold,
                      textColor: textColor,
                      subtextColor: subtextColor,
                    ),
                    const SizedBox(height: 10),
                    _buildFeatureBullet(
                      icon: Icons.shield_outlined,
                      title: 'Privacy & Control',
                      desc: 'Zero ads or background tracking. You can toggle this on or off anytime in Settings.',
                      color: Colors.blueAccent,
                      textColor: textColor,
                      subtextColor: subtextColor,
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 20),

              // Actions
              FilledButton(
                key: const Key('driver_overlay_consent_agree_button'),
                style: FilledButton.styleFrom(
                  backgroundColor: AppColors.seseGold,
                  foregroundColor: Colors.black,
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(14),
                  ),
                ),
                onPressed: onAgree,
                child: const Text(
                  'Enable Quick-Return Bubble',
                  style: TextStyle(fontWeight: FontWeight.w700, fontSize: 15),
                ),
              ),
              const SizedBox(height: 8),
              TextButton(
                key: const Key('driver_overlay_consent_decline_button'),
                style: TextButton.styleFrom(
                  padding: const EdgeInsets.symmetric(vertical: 12),
                ),
                onPressed: onDecline,
                child: Text(
                  'Not Now (Continue without Bubble)',
                  style: TextStyle(
                    color: subtextColor,
                    fontWeight: FontWeight.w600,
                    fontSize: 14,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildFeatureBullet({
    required IconData icon,
    required String title,
    required String desc,
    required Color color,
    required Color textColor,
    required Color subtextColor,
  }) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, color: color, size: 20),
        const SizedBox(width: 10),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w700,
                  color: textColor,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                desc,
                style: TextStyle(
                  fontSize: 12,
                  height: 1.35,
                  color: subtextColor,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}
