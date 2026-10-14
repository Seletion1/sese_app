import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Prominent System Overlay (`SYSTEM_ALERT_WINDOW`) Disclosure Dialog required by Google Play policy.
///
/// Rendered in the Driver app BEFORE redirecting the driver to the OS Overlay Settings screen.
class DriverOverlayDisclosureDialog extends StatelessWidget {
  static const String consentKey = 'has_accepted_overlay_disclosure';

  final VoidCallback onAgree;
  final VoidCallback? onDecline;

  const DriverOverlayDisclosureDialog({
    super.key,
    required this.onAgree,
    this.onDecline,
  });

  /// Presents the non-dismissible prominent overlay disclosure dialog.
  /// Returns `true` if the user taps "Open Settings", `false` otherwise.
  static Future<bool> show(BuildContext context) async {
    final prefs = await SharedPreferences.getInstance();
    if (!context.mounted) return false;
    final result = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => DriverOverlayDisclosureDialog(
        onAgree: () async {
          await prefs.setBool(consentKey, true);
          if (ctx.mounted) Navigator.of(ctx).pop(true);
        },
        onDecline: () => Navigator.of(ctx).pop(false),
      ),
    );
    return result ?? false;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return AlertDialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      title: Row(
        children: [
          Icon(Icons.layers_outlined, color: theme.primaryColor, size: 28),
          const SizedBox(width: 10),
          const Expanded(
            child: Text(
              'Display Over Other Apps',
              style: TextStyle(fontWeight: FontWeight.bold, fontSize: 18),
            ),
          ),
        ],
      ),
      content: const SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'SeSe Driver requires overlay permissions to notify you of high-priority trip requests while you are using navigation apps or your screen is in the background.',
              style: TextStyle(fontSize: 14, height: 1.5),
            ),
            SizedBox(height: 12),
            Text(
              '• Shows floating ride dispatch popups over map apps\n'
              '• Ensures you never miss an incoming passenger order\n'
              '• Only active while you are signed Online',
              style: TextStyle(fontSize: 12, color: Colors.grey),
            ),
          ],
        ),
      ),
      actionsPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      actions: [
        TextButton(
          key: const Key('overlay_disclosure_cancel_btn'),
          onPressed: () {
            if (onDecline != null) {
              onDecline!();
            } else {
              Navigator.of(context).pop(false);
            }
          },
          child: const Text(
            'Cancel',
            style: TextStyle(color: Colors.grey, fontWeight: FontWeight.w600),
          ),
        ),
        ElevatedButton(
          key: const Key('overlay_disclosure_open_settings_btn'),
          style: ElevatedButton.styleFrom(
            backgroundColor: theme.primaryColor,
            foregroundColor: Colors.black,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(8),
            ),
          ),
          onPressed: onAgree,
          child: const Text(
            'Open Settings',
            style: TextStyle(fontWeight: FontWeight.bold),
          ),
        ),
      ],
    );
  }
}
