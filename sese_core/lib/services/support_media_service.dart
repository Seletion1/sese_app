import 'package:firebase_storage/firebase_storage.dart';
import 'package:flutter/foundation.dart';
import 'package:image_picker/image_picker.dart';
import 'package:permission_handler/permission_handler.dart';

import 'image_compression_service.dart';
import 'media_permission_service.dart';

/// Shared support-media uploader for `sese_ride` and `sese_hub`.
///
/// Both apps upload chat photos to `support_media/{userId}/...` (the chat
/// owner's folder — the storage rules grant staff reads off auth claims, so
/// agents can open photos in chats they have not yet claimed). Centralising
/// here keeps the path, size cap, and MIME policy identical on both sides;
/// a drift between two copies once caused every upload to 403.
///
/// Images only — `storage.rules` `isImage()` rejects non-image MIME and the
/// Firestore rules reject any audio message type, so there is deliberately
/// no audio path here.
class SupportMediaService {
  final FirebaseStorage? _storage;

  const SupportMediaService([this._storage]);

  FirebaseStorage? get _bucket {
    try {
      return _storage ?? FirebaseStorage.instance;
    } catch (_) {
      return null;
    }
  }

  /// Storage path for a chat photo. Must stay `support_media/{userId}/...`
  /// to match the storage rules.
  static String pathFor(String userId, String suffix) {
    return 'support_media/$userId/'
        '${DateTime.now().millisecondsSinceEpoch}_$suffix';
  }

  /// Picks a photo, handshaking the OS runtime permission FIRST
  /// ([MediaPermissionService.ensureFor]) so the native picker never opens
  /// onto a dead preview. Returns null on cancel, denial, or failure.
  /// Separated from [upload] so widget tests can skip the plugin.
  ///
  /// [source] defaults to the gallery; pass [ImageSource.camera] for
  /// capture flows. On permanent denial the outcome is recorded on
  /// [MediaPermissionService.lastPermanentDenial] — the caller should show
  /// [MediaPermissionService.promptIfPermanentlyDenied] next.
  Future<XFile?> pickPhoto({ImageSource source = ImageSource.gallery}) async {
    try {
      final outcome = await MediaPermissionService.ensureFor(source);
      if (outcome != MediaPermissionOutcome.granted) {
        if (outcome == MediaPermissionOutcome.permanentlyDenied) {
          MediaPermissionService.lastPermanentDenial =
              source == ImageSource.camera
                  ? Permission.camera
                  : Permission.photos;
        }
        return null;
      }
      return await ImageCompressionService.pickAndCompressImage(
        source: source,
        maxDimension: ImageCompressionService.defaultMaxDimension,
        quality: ImageCompressionService.defaultQuality,
      );
    } catch (e) {
      debugPrint('SupportMediaService.pickPhoto failed: $e');
      return null;
    }
  }

  /// Camera capture shorthand for [pickPhoto] with [ImageSource.camera].
  Future<XFile?> takePhoto() => pickPhoto(source: ImageSource.camera);

  /// Uploads [file] to [storagePath] and returns the download URL.
  /// Throws [SupportMediaException] (user-safe message) on failure.
  Future<String> upload({
    required XFile file,
    required String storagePath,
  }) async {
    final bucket = _bucket;
    if (bucket == null || file.path.isEmpty) {
      throw const SupportMediaException(
        'Attachments are unavailable right now.',
      );
    }
    final ext = file.path.contains('.')
        ? file.path.split('.').last.toLowerCase()
        : 'jpg';
    try {
      final ref = bucket.ref().child(storagePath);
      await ref.putData(
        await file.readAsBytes(),
        SettableMetadata(contentType: 'image/$ext'),
      );
      return await ref.getDownloadURL();
    } catch (e) {
      debugPrint('SupportMediaService.upload failed: $e');
      throw const SupportMediaException(
        'Could not upload that photo. Try again.',
      );
    }
  }

  /// Best-effort delete of an orphaned upload (e.g. the Firestore write
  /// failed after the bytes landed). Never throws.
  Future<void> deleteQuietly(String storagePath) async {
    try {
      await _bucket?.ref().child(storagePath).delete();
    } catch (_) {}
  }
}

/// User-safe upload failure. [message] may be shown in a SnackBar verbatim.
class SupportMediaException implements Exception {
  final String message;

  const SupportMediaException(this.message);

  @override
  String toString() => 'SupportMediaException: $message';
}
