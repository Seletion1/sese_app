import 'dart:ui' as ui;
import 'package:flutter/foundation.dart';
import 'package:image_picker/image_picker.dart';

/// Client-side Image Pre-Processing & Compression Service.
///
/// Reduces raw camera/gallery photos (often 5MB–15MB) down to ~150KB–300KB
/// before reaching Firebase Storage, saving client cellular bandwidth and
/// cloud storage costs while preserving crystal clarity for KYC/document review.
abstract final class ImageCompressionService {
  /// Default target constraints matching spec
  static const int defaultMaxDimension = 1280; // 1280x1280 max resolution
  static const int defaultQuality = 80; // 80% JPEG quality

  /// Captures or selects an image using [ImagePicker] with native hardware/OS-level
  /// scaling and compression applied directly on Android & iOS.
  static Future<XFile?> pickAndCompressImage({
    required ImageSource source,
    ImagePicker? picker,
    int maxDimension = defaultMaxDimension,
    int quality = defaultQuality,
    CameraDevice preferredCameraDevice = CameraDevice.rear,
  }) async {
    final imagePicker = picker ?? ImagePicker();
    try {
      final file = await imagePicker.pickImage(
        source: source,
        maxWidth: maxDimension.toDouble(),
        maxHeight: maxDimension.toDouble(),
        imageQuality: quality,
        preferredCameraDevice: preferredCameraDevice,
      );

      if (file == null) return null;

      if (kDebugMode) {
        final length = await file.length();
        debugPrint(
          'ImageCompressionService: compressed image picked: '
          '${file.name} (${formatBytes(length)})',
        );
      }

      return file;
    } catch (e) {
      debugPrint('ImageCompressionService: error picking image: $e');
      rethrow;
    }
  }

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
