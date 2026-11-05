import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';

/// Real-time Anti-Fake GPS & Mock Location Guard.
class FakeGpsGuard {
  FakeGpsGuard._();
  static final FakeGpsGuard instance = FakeGpsGuard._();

  /// Inspects a [Position] for mock location provider flags.
  bool isMockLocation(Position position) {
    return position.isMocked;
  }

  /// Displays non-dismissible warning popup when Mock Location is active.
  Future<void> showMockLocationWarning(BuildContext context) async {
    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (context) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Row(
          children: [
            Icon(Icons.wrong_location_rounded, color: Colors.red, size: 28),
            SizedBox(width: 8),
            Expanded(
              child: Text(
                'Fake GPS / Mock Location Detected',
                style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
              ),
            ),
          ],
        ),
        content: const Text(
          'Mock location apps or location spoofing detected on your device.\n\n'
          'To ensure safety, turn off Mock Locations or Fake GPS spoofing apps in your device developer settings to continue using SeSe.',
          style: TextStyle(fontSize: 14),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('I Have Disabled It'),
          ),
        ],
      ),
    );
  }
}
