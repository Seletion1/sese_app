import 'dart:ui' as ui;
import 'package:flutter/foundation.dart';
import 'package:image_picker/image_picker.dart';

import 'form_draft_manager.dart';

/// Client-side Image Pre-Processing & Compression Service.
///
/// Reduces raw camera/gallery photos (often 5MB–15MB) down to ~150KB–300KB
/// before reaching Firebase Storage, saving client cellular bandwidth and
/// cloud storage costs while preserving crystal clarity for KYC/document review.
///
/// Also provides Android process-death tracking: records the pending target
/// before the OS camera/gallery intent is opened, and copies the resulting file
/// to permanent documents storage to prevent cache eviction.
abstract final class ImageCompressionService {
  /// Default target constraints matching mobile camera limits:
  /// 1600x1600 max dimension + 85% JPEG quality prevents Android memory spikes.
  static const int defaultMaxDimension = 1600;
  static const int defaultQuality = 85;

  /// Captures or selects an image using [ImagePicker] with native hardware/OS-level
  /// scaling and compression applied directly on Android & iOS.
  ///
  /// When [targetScreen], [targetField], and [userId] are provided:
  /// - Automatically records the pending picker target before launching the intent.
  /// - On completion, copies the resulting image into permanent app documents storage
  ///   (`getApplicationDocumentsDirectory()/kyc_drafts/`).
  /// - Clears the pending target on return or cancellation.
  static Future<XFile?> pickAndCompressImage({
    required ImageSource source,
    ImagePicker? picker,
    int maxDimension = defaultMaxDimension,
    int quality = defaultQuality,
    CameraDevice preferredCameraDevice = CameraDevice.rear,
    String? targetScreen,
    String? targetField,
    String? userId,
  }) async {
    final imagePicker = picker ?? ImagePicker();

    // 1. Record pending target before launching Android external camera/gallery intent
    if (targetScreen != null && targetField != null && userId != null) {
      await FormDraftManager.instance.recordPendingPickerTarget(
        screen: targetScreen,
        field: targetField,
        userId: userId,
      );
    }

    try {
      final file = await imagePicker.pickImage(
        source: source,
        maxWidth: maxDimension.toDouble(),
        maxHeight: maxDimension.toDouble(),
        imageQuality: quality,
        preferredCameraDevice: preferredCameraDevice,
      );

      if (file == null) {
        if (targetScreen != null) {
          await FormDraftManager.instance.clearPendingPickerTarget();
        }
        return null;
      }

      // 2. Immediately copy file to permanent storage if a target is specified
      XFile persistentFile = file;
      if (targetScreen != null && targetField != null) {
        persistentFile =
            await FormDraftManager.instance.copyToPermanentDraftStorage(
          file,
          prefix: '${targetScreen}_$targetField',
        );
        await FormDraftManager.instance.clearPendingPickerTarget();
      }

      if (kDebugMode) {
        final length = await persistentFile.length();
        debugPrint(
          'ImageCompressionService: compressed image picked: '
          '${persistentFile.name} (${formatBytes(length)})',
        );
      }

      return persistentFile;
    } catch (e) {
      if (targetScreen != null) {
        await FormDraftManager.instance.clearPendingPickerTarget();
      }
      debugPrint('ImageCompressionService: error picking image: $e');
      rethrow;
    }
  }

  /// Recovers lost image data after an Android process recreation.
  static Future<RecoveredPickerResult?> retrieveLostData({
    ImagePicker? picker,
  }) =>
      FormDraftManager.instance.checkAndRecoverLostData(picker: picker);

  /// Downsamples raw image bytes to [maxDimension] using Flutter's native Skia/Impeller
  /// engine decoder if the payload exceeds [targetByteThreshold].
  static Future<Uint8List> compressBytes(
    Uint8List inputBytes, {
    int maxDimension = defaultMaxDimension,
    int targetByteThreshold = 300 * 1024, // 300KB
  }) async {
    if (inputBytes.length <= targetByteThreshold) {
      return inputBytes;
    }

    try {
      final codec = await ui.instantiateImageCodec(
        inputBytes,
        targetWidth: maxDimension,
      );
      final frame = await codec.getNextFrame();
      final image = frame.image;
      final byteData = await image.toByteData(format: ui.ImageByteFormat.png);
      if (byteData == null) return inputBytes;

      final result = byteData.buffer.asUint8List();
      debugPrint(
        'ImageCompressionService: compressed bytes from '
        '${formatBytes(inputBytes.length)} to ${formatBytes(result.length)}',
      );
      return result;
    } catch (e) {
      debugPrint('ImageCompressionService: failed to downsample bytes: $e');
      return inputBytes;
    }
  }

  /// Formats byte counts into human-readable size strings (e.g. `245.5 KB`).
  static String formatBytes(int bytes) {
    if (bytes <= 0) return '0 B';
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) {
      return '${(bytes / 1024).toStringAsFixed(1)} KB';
    }
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }
}
