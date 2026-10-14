import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:permission_handler/permission_handler.dart';

/// Outcome of a runtime permission handshake before opening a native
/// camera/gallery picker.
enum MediaPermissionOutcome {
  /// Picker may open.
  granted,

  /// Denied but requestable again — the caller should explain, then retry.
  denied,

  /// Permanently denied ("Don't ask again" / iOS once-denied). Only the
  /// OS settings screen can restore it — show [MediaPermissionService.prompt].
  permanentlyDenied,
}

/// Central runtime-permission handshake for every camera / photo-library
/// entry point (document upload, KYC selfies, live verification, chat
/// attachments).
///
/// WHY central: `image_picker` does not reliably prompt on every OS/API
/// level, so without an explicit handshake the native picker either opens
/// onto a dead/black preview or never fires its completion — with no error
/// surfaced. Every picker call must go through [ensureFor] first.
///
/// All methods are test-safe: a missing plugin (widget tests) resolves to
/// [MediaPermissionOutcome.granted] instead of throwing, so tests exercise
/// the picker seams without a platform channel.
abstract final class MediaPermissionService {
  /// Last [MediaPermissionOutcome.permanentlyDenied] source, for UIs that
  /// show the settings prompt after a gated pick returns null. Cleared
  /// whenever [promptIfPermanentlyDenied] actually shows.
  static Permission? lastPermanentDenial;

  /// Ensures the OS permission backing [source], requesting it when needed.
  /// Never throws.
  static Future<MediaPermissionOutcome> ensureFor(ImageSource source) async {
    try {
      if (source == ImageSource.camera) {
        return _toOutcome(await Permission.camera.request());
      }
      return _toOutcome(await _galleryRequest());
    } catch (e) {
      // No platform channel (widget tests) or plugin failure: the picker
      // seams are test-doubled anyway, so do not block the call.
      debugPrint('MediaPermissionService.ensureFor failed: $e');
      return MediaPermissionOutcome.granted;
    }
  }

  /// Best-effort background-location access for the online driver session
  /// (keeps the OS delivering GPS fixes while the app is minimized so the
  /// live-trip marker and dispatch heartbeats keep flowing).
  ///
  /// Returns true when background fixes may flow. Never blocks go-online:
  /// foreground fixes still work when this is false.
  static Future<bool> ensureBackgroundLocation() async {
    try {
      final current = await Permission.locationWhenInUse.status;
      if (!current.isGranted) return false;
      final always = await Permission.locationAlways.request();
      return always.isGranted;
    } catch (e) {
      debugPrint('MediaPermissionService.ensureBackgroundLocation: $e');
      return false;
    }
  }

  /// Shows the soft fallback prompt when the permission was permanently
  /// denied: explains the consequence and offers a one-tap jump to the OS
  /// settings screen. No-op unless [lastPermanentDenial] is set.
  static Future<void> promptIfPermanentlyDenied(BuildContext context) async {
    final denied = lastPermanentDenial;
    if (denied == null || !context.mounted) return;
    lastPermanentDenial = null;
    final label = denied == Permission.camera ? 'Camera' : 'Photo library';
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          '$label access is turned off. Document upload and verification '
          'photos need it to work.',
        ),
        action: SnackBarAction(
          label: 'Open Settings',
          onPressed: () {
            try {
              openAppSettings();
            } catch (e) {
              debugPrint('MediaPermissionService.openAppSettings: $e');
            }
          },
        ),
        duration: const Duration(seconds: 6),
      ),
    );
  }

  /// Gallery/photo-library request across API levels: Android 13+ uses the
  /// granular media permission, older Android falls back to storage, iOS
  /// uses photos (adding only — the picker never writes).
  static Future<PermissionStatus> _galleryRequest() async {
    if (defaultTargetPlatform == TargetPlatform.android) {
      var status = await Permission.photos.request();
      if (status.isGranted || status.isPermanentlyDenied) return status;
      return Permission.storage.request();
    }
    return Permission.photos.request();
  }

  static MediaPermissionOutcome _toOutcome(PermissionStatus status) {
    if (status.isGranted || status.isLimited) {
      return MediaPermissionOutcome.granted;
    }
    if (status.isPermanentlyDenied) {
      return MediaPermissionOutcome.permanentlyDenied;
    }
    return MediaPermissionOutcome.denied;
  }
}
