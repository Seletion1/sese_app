import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Mandatory Google Play Prominent Location Disclosure Dialog — two variants.
///
/// Google Play policy requires you to show these BEFORE the OS permission
/// prompt. Show [showForeground] before requesting
/// `ACCESS_FINE_LOCATION` (foreground), and [show] before requesting
/// `ACCESS_BACKGROUND_LOCATION` (background / always-on for drivers).
typedef BackgroundLocationNoticeDialog = ProminentLocationDisclosureDialog;

class ProminentLocationDisclosureDialog extends StatelessWidget {
  static const String consentKey = 'has_accepted_location_disclosure';

  final VoidCallback onAgree;
  final VoidCallback? onDecline;

  const ProminentLocationDisclosureDialog({
    super.key,
    required this.onAgree,
    this.onDecline,
  });

  /// Persists local & server consent tracking when user agrees.
  static Future<void> recordConsent({String? userId}) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(consentKey, true);
    } catch (_) {}

    if (userId != null && userId.isNotEmpty) {
      try {
        await FirebaseFirestore.instance.collection('users').doc(userId).set({
          'location_disclosure_accepted': true,
          'location_accepted_at': FieldValue.serverTimestamp(),
        }, SetOptions(merge: true));
      } catch (_) {}
    }
  }

  /// Pre-prompt verification gate: returns true if dialog should be displayed.
  static Future<bool> shouldShowDisclosure({String? userId}) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      var acceptedLocal = prefs.getBool(consentKey) ?? false;

      if (!acceptedLocal && userId != null && userId.isNotEmpty) {
        try {
          final userSnap = await FirebaseFirestore.instance
              .collection('users')
              .doc(userId)
              .get();
          if (userSnap.exists &&
              userSnap.data()?['location_disclosure_accepted'] == true) {
            acceptedLocal = true;
            await prefs.setBool(consentKey, true);
          }
        } catch (_) {}
      }

      final perm = await Geolocator.checkPermission();
      final osActive = perm == LocationPermission.always ||
          perm == LocationPermission.whileInUse;

      if (acceptedLocal && osActive) {
        return false; // SKIP dialog
      }
    } catch (_) {}
    return true;
  }

  // ---------------------------------------------------------------------------
  // Foreground location variant
  // ---------------------------------------------------------------------------

  /// Shows the **foreground** location disclosure dialog.
  /// Skips automatically if consent is already recorded and OS permissions active.
  static Future<bool> showForeground(BuildContext context, {String? userId}) async {
    final shouldShow = await shouldShowDisclosure(userId: userId);
    if (!shouldShow) return true;

    if (!context.mounted) return false;
    final result = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => _ForegroundLocationDialog(
        onAgree: () async {
          await recordConsent(userId: userId);
          if (ctx.mounted) Navigator.of(ctx).pop(true);
        },
        onDecline: () => Navigator.of(ctx).pop(false),
      ),
    );
    return result ?? false;
  }

  // ---------------------------------------------------------------------------
  // Background location variant (existing)
  // ---------------------------------------------------------------------------

  /// Shows the **background** location disclosure dialog.
  /// Skips automatically if consent is already recorded and OS permissions active.
  static Future<bool> show(BuildContext context, {String? userId}) async {
    final shouldShow = await shouldShowDisclosure(userId: userId);
    if (!shouldShow) return true;

    if (!context.mounted) return false;
    final result = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => ProminentLocationDisclosureDialog(
        onAgree: () async {
          await recordConsent(userId: userId);
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
          Icon(Icons.location_on, color: theme.primaryColor, size: 28),
          const SizedBox(width: 10),
          const Expanded(
            child: Text(
              'Background Location Notice',
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
              'SESE collects precise background location data to enable automated '
              'trip dispatching, real-time customer tracking, and route navigation '
              'even when the app is closed or not in use. You can change location '
              'access at any time in your phone settings.',
              style: TextStyle(fontSize: 14, height: 1.5),
            ),
            SizedBox(height: 12),
            Text(
              '• Used for driver proximity matching\n'
              '• Used for live trip navigation & safety\n'
              '• Active while online or during active trips',
              style: TextStyle(fontSize: 12, color: Colors.grey),
            ),
          ],
        ),
      ),
      actionsPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      actions: [
        TextButton(
          key: const Key('location_disclosure_decline_btn'),
          onPressed: () {
            if (onDecline != null) {
              onDecline!();
            } else {
              Navigator.of(context).pop(false);
            }
          },
          child: const Text(
            'Decline',
            style: TextStyle(color: Colors.grey, fontWeight: FontWeight.w600),
          ),
        ),
        ElevatedButton(
          key: const Key('location_disclosure_agree_btn'),
          style: ElevatedButton.styleFrom(
            backgroundColor: theme.primaryColor,
            foregroundColor: Colors.black,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(8),
            ),
          ),
          onPressed: onAgree,
          child: const Text(
            'Agree & Continue',
            style: TextStyle(fontWeight: FontWeight.bold),
          ),
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// Foreground location dialog (standalone widget)
// ---------------------------------------------------------------------------

/// Prominent foreground location disclosure dialog.
///
/// Shown before requesting `ACCESS_FINE_LOCATION` so the user understands
/// that SESE needs their position to match nearby drivers/riders and display
/// live pickup routes while the app is open. This is separate from the
/// background disclosure and must be shown first, before escalating to
/// the background permission request.
class _ForegroundLocationDialog extends StatelessWidget {
  final VoidCallback onAgree;
  final VoidCallback? onDecline;

  const _ForegroundLocationDialog({
    required this.onAgree,
    this.onDecline,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return AlertDialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      title: Row(
        children: [
          Icon(Icons.my_location_rounded, color: theme.primaryColor, size: 28),
          const SizedBox(width: 10),
          const Expanded(
            child: Text(
              'Location Access Required',
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
              'SESE needs your location to match you with nearby riders/drivers '
              'and display live pickup routes on the map.',
              style: TextStyle(fontSize: 14, height: 1.5),
            ),
            SizedBox(height: 12),
            Text(
              '• Used to find drivers near you\n'
              '• Used to display accurate pickup routes\n'
              '• Only collected while the app is open',
              style: TextStyle(fontSize: 12, color: Colors.grey),
            ),
          ],
        ),
      ),
      actionsPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      actions: [
        TextButton(
          key: const Key('fg_location_disclosure_decline_btn'),
          onPressed: () {
            if (onDecline != null) {
              onDecline!();
            } else {
              Navigator.of(context).pop(false);
            }
          },
          child: const Text(
            'Not Now',
            style: TextStyle(color: Colors.grey, fontWeight: FontWeight.w600),
          ),
        ),
        ElevatedButton(
          key: const Key('fg_location_disclosure_agree_btn'),
          style: ElevatedButton.styleFrom(
            backgroundColor: theme.primaryColor,
            foregroundColor: Colors.black,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(8),
            ),
          ),
          onPressed: onAgree,
          child: const Text(
            'Agree & Continue',
            style: TextStyle(fontWeight: FontWeight.bold),
          ),
        ),
      ],
    );
  }
}
