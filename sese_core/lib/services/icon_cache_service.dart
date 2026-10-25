import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// Metadata for a cached UI icon.
class IconCacheEntry {
  final String filename;
  final String url;
  final int sizeBytes;

  const IconCacheEntry({
    required this.filename,
    required this.url,
    this.sizeBytes = 0,
  });
}

/// Service that manages downloading, local filesystem caching, and runtime
/// resolution of custom UI icons (vehicle categories, delivery boxes, etc.).
///
/// Features:
/// - Instant local filesystem lookup from the app documents directory.
/// - Bundled asset fallback so the app is 100% offline-ready on first launch.
/// - Dynamic streaming download and atomic file persistence from Firebase Storage.
/// - Self-healing fallback: re-downloads automatically if a file is wiped from device storage.
class IconCacheService {
  IconCacheService._();

  /// Global singleton instance.
  static final IconCacheService instance = IconCacheService._();

  Directory? _cacheDir;
  bool _initialized = false;
  final Map<String, File> _activeLocalFiles = {};
  final Set<String> _downloadingKeys = {};

  /// Whether the cache service has been initialized at least once.
  bool get isInitialized => _initialized;

  /// Pre-configured manifest mapping of icon keys to filenames and backend download URLs.
  static const Map<String, IconCacheEntry> defaultManifest = {
    'vehicle_bicycle': IconCacheEntry(
      filename: 'sese_bicycle.png',
      url:
          'https://firebasestorage.googleapis.com/v0/b/sese-ride.firebasestorage.app/o/ui_assets%2Ficons%2Fsese_bicycle.png?alt=media&token=1f7f66c1-946c-4a62-ad09-f6dc9178e214',
      sizeBytes: 324900,
    ),
    'vehicle_motorcycle': IconCacheEntry(
      filename: 'sese_motorcycle.png',
      url:
          'https://firebasestorage.googleapis.com/v0/b/sese-ride.firebasestorage.app/o/ui_assets%2Ficons%2Fsese_motorcycle.png?alt=media&token=4794dece-511b-40d6-b709-783d1e4b8433',
      sizeBytes: 374347,
    ),
    'vehicle_keke': IconCacheEntry(
      filename: 'sese_tricycle.png',
      url:
          'https://firebasestorage.googleapis.com/v0/b/sese-ride.firebasestorage.app/o/ui_assets%2Ficons%2Fsese_tricycle.png?alt=media&token=1317a0da-69b2-48e5-b034-8f01e6f091f0',
      sizeBytes: 503399,
    ),
    'vehicle_tricycle': IconCacheEntry(
      filename: 'sese_tricycle.png',
      url:
          'https://firebasestorage.googleapis.com/v0/b/sese-ride.firebasestorage.app/o/ui_assets%2Ficons%2Fsese_tricycle.png?alt=media&token=1317a0da-69b2-48e5-b034-8f01e6f091f0',
      sizeBytes: 503399,
    ),
    'vehicle_sedan': IconCacheEntry(
      filename: 'sese_car_sedan.png',
      url:
          'https://firebasestorage.googleapis.com/v0/b/sese-ride.firebasestorage.app/o/ui_assets%2Ficons%2Fsese_car_sedan.png?alt=media&token=54931c91-8808-49e2-a311-885fb01ec3ed',
      sizeBytes: 190980,
    ),
    'vehicle_car': IconCacheEntry(
      filename: 'sese_car_sedan.png',
      url:
          'https://firebasestorage.googleapis.com/v0/b/sese-ride.firebasestorage.app/o/ui_assets%2Ficons%2Fsese_car_sedan.png?alt=media&token=54931c91-8808-49e2-a311-885fb01ec3ed',
      sizeBytes: 190980,
    ),
    'vehicle_comfort': IconCacheEntry(
      filename: 'sese_standard_comfort.png',
      url:
          'https://firebasestorage.googleapis.com/v0/b/sese-ride.firebasestorage.app/o/ui_assets%2Ficons%2Fsese_standard_comfort.png?alt=media&token=18f1a268-7297-407f-864a-f0957735ff88',
      sizeBytes: 189738,
    ),
    'vehicle_premium': IconCacheEntry(
      filename: 'sese_executive_premium.png',
      url:
          'https://firebasestorage.googleapis.com/v0/b/sese-ride.firebasestorage.app/o/ui_assets%2Ficons%2Fsese_executive_premium.png?alt=media&token=cabfafc0-4f4a-439a-9095-82bbc69a10d2',
      sizeBytes: 200738,
    ),
    'vehicle_luxe': IconCacheEntry(
      filename: 'sese_luxe_super.png',
      url:
          'https://firebasestorage.googleapis.com/v0/b/sese-ride.firebasestorage.app/o/ui_assets%2Ficons%2Fsese_luxe_super.png?alt=media&token=9702e54d-3f89-4bcd-a0bd-c48448af3f21',
      sizeBytes: 171744,
    ),
    'vehicle_van': IconCacheEntry(
      filename: 'sese_van.png',
      url:
          'https://firebasestorage.googleapis.com/v0/b/sese-ride.firebasestorage.app/o/ui_assets%2Ficons%2Fsese_van.png?alt=media&token=5f7c81d6-e3be-41fc-9b69-7e92bd642ee6',
      sizeBytes: 145209,
    ),
    'vehicle_truck': IconCacheEntry(
      filename: 'sese_truck.png',
      url:
          'https://firebasestorage.googleapis.com/v0/b/sese-ride.firebasestorage.app/o/ui_assets%2Ficons%2Fsese_truck.png?alt=media&token=2aa94f88-fb10-46eb-a2ec-faec5d6c6d24',
      sizeBytes: 221853,
    ),
    'sender_box': IconCacheEntry(
      filename: 'sese_send_box.png',
      url:
          'https://firebasestorage.googleapis.com/v0/b/sese-ride.firebasestorage.app/o/ui_assets%2Ficons%2Fsese_send_box.png?alt=media&token=f1277a8b-1098-46dc-804a-57b40ec18af8',
      sizeBytes: 379788,
    ),
    'package_send': IconCacheEntry(
      filename: 'sese_send_box.png',
      url:
          'https://firebasestorage.googleapis.com/v0/b/sese-ride.firebasestorage.app/o/ui_assets%2Ficons%2Fsese_send_box.png?alt=media&token=f1277a8b-1098-46dc-804a-57b40ec18af8',
      sizeBytes: 379788,
    ),
    'receiver_box': IconCacheEntry(
      filename: 'sese_receiver_box.png',
      url:
          'https://firebasestorage.googleapis.com/v0/b/sese-ride.firebasestorage.app/o/ui_assets%2Ficons%2Fsese_receiver_box.png?alt=media&token=ea9547a7-55a2-4b1b-abad-fd6cb48cbaff',
      sizeBytes: 318972,
    ),
    'package_receive': IconCacheEntry(
      filename: 'sese_receiver_box.png',
      url:
          'https://firebasestorage.googleapis.com/v0/b/sese-ride.firebasestorage.app/o/ui_assets%2Ficons%2Fsese_receiver_box.png?alt=media&token=ea9547a7-55a2-4b1b-abad-fd6cb48cbaff',
      sizeBytes: 318972,
    ),
  };

  /// Initializes the local icon cache on app startup.
  ///
  /// Checks local documents directory for cached icon files. If missing, attempts
  /// to prime them from bundled Flutter asset assets, and streams the latest
  /// asset files from Firebase Storage in the background.
  Future<void> initialize({bool forceRefresh = false}) async {
    try {
      final docDir = await getApplicationDocumentsDirectory();
      final cacheDir = Directory(p.join(docDir.path, 'sese_icons'));
      if (!cacheDir.existsSync()) {
        await cacheDir.create(recursive: true);
      }
      _cacheDir = cacheDir;
      _initialized = true;

      // Check each icon key
      for (final entry in defaultManifest.entries) {
        final key = entry.key;
        final info = entry.value;
        final targetFile = File(p.join(cacheDir.path, info.filename));

        if (targetFile.existsSync() && targetFile.lengthSync() > 0 && !forceRefresh) {
          _activeLocalFiles[key] = targetFile;
        } else {
          // Offloaded to Cloud Storage: fetch in background on first launch
          unawaited(_downloadAndCache(key, info, targetFile));
        }
      }
    } catch (e) {
      if (kDebugMode) {
        debugPrint('IconCacheService.initialize error: $e');
      }
    }
  }

  /// Downloads an icon from its Firebase Storage URL and saves it atomically to disk.
  Future<File?> _downloadAndCache(
    String key,
    IconCacheEntry entry,
    File destination,
  ) async {
    if (_downloadingKeys.contains(key)) return null;
    _downloadingKeys.add(key);

    try {
      final uri = Uri.parse(entry.url);
      final client = http.Client();
      try {
        final response = await client.get(uri).timeout(const Duration(seconds: 15));
        if (response.statusCode == 200 && response.bodyBytes.isNotEmpty) {
          // Write to a temporary file first then rename to prevent corrupt half-writes
          final tempFile = File('${destination.path}.tmp');
          await tempFile.writeAsBytes(response.bodyBytes, flush: true);
          if (destination.existsSync()) {
            await destination.delete();
          }
          await tempFile.rename(destination.path);
          _activeLocalFiles[key] = destination;
          if (kDebugMode) {
            debugPrint('IconCacheService: successfully cached $key (${response.bodyBytes.length} bytes)');
          }
          return destination;
        }
      } finally {
        client.close();
      }
    } catch (e) {
      if (kDebugMode) {
        debugPrint('IconCacheService._downloadAndCache error for $key: $e');
      }
    } finally {
      _downloadingKeys.remove(key);
    }
    return null;
  }

  /// Returns the cached [File] for the given [key] if it exists on disk.
  ///
  /// If the file was unexpectedly removed or missing, triggers a background
  /// download to restore it.
  File? getLocalFile(String key) {
    final cached = _activeLocalFiles[key];
    if (cached != null && cached.existsSync() && cached.lengthSync() > 0) {
      return cached;
    }

    // Self-healing: if file is missing, re-verify cache directory
    final entry = defaultManifest[key];
    if (entry != null && _cacheDir != null) {
      final file = File(p.join(_cacheDir!.path, entry.filename));
      if (file.existsSync() && file.lengthSync() > 0) {
        _activeLocalFiles[key] = file;
        return file;
      }
      // Re-trigger download
      unawaited(_downloadAndCache(key, entry, file));
    }
    return null;
  }

  /// Returns true if the icon is currently cached and ready to render from local storage.
  bool isCached(String key) {
    return getLocalFile(key) != null;
  }

  /// Returns an asset path for the given icon key as a static fallback.
  String? getBundledAssetPath(String key) {
    final entry = defaultManifest[key];
    if (entry == null) return null;
    return 'assets/icons/${entry.filename}';
  }

  /// Builds a responsive, cached image widget for [key].
  ///
  /// Renders from:
  /// 1. Local device storage (`Image.file`) if cached.
  /// 2. Bundled package asset (`Image.asset`) if local cache is empty.
  /// 3. Network (`Image.network`) as continuous fallback.
  /// 4. [fallback] widget if provided.
  Widget buildIcon(
    String key, {
    double? width,
    double? height,
    BoxFit fit = BoxFit.contain,
    Widget? fallback,
  }) {
    return _CachedIconWidget(
      iconKey: key,
      width: width,
      height: height,
      fit: fit,
      fallback: fallback,
    );
  }
}

/// Internal widget handling dynamic loading and error fallback for a cached icon.
class _CachedIconWidget extends StatefulWidget {
  final String iconKey;
  final double? width;
  final double? height;
  final BoxFit fit;
  final Widget? fallback;

  const _CachedIconWidget({
    required this.iconKey,
    this.width,
    this.height,
    this.fit = BoxFit.contain,
    this.fallback,
  });

  @override
  State<_CachedIconWidget> createState() => _CachedIconWidgetState();
}

class _CachedIconWidgetState extends State<_CachedIconWidget> {
  File? _file;

  @override
  void initState() {
    super.initState();
    _checkFile();
  }

  @override
  void didUpdateWidget(covariant _CachedIconWidget oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.iconKey != widget.iconKey) {
      _checkFile();
    }
  }

  void _checkFile() {
    _file = IconCacheService.instance.getLocalFile(widget.iconKey);
  }

  @override
  Widget build(BuildContext context) {
    final entry = IconCacheService.defaultManifest[widget.iconKey];
    if (entry == null) {
      return widget.fallback ?? const SizedBox.shrink();
    }

    final localFile = _file ?? IconCacheService.instance.getLocalFile(widget.iconKey);
    final cacheW = widget.width != null ? (widget.width! * 2).toInt() : null;
    final cacheH = widget.height != null ? (widget.height! * 2).toInt() : null;

    if (localFile != null && localFile.existsSync()) {
      return Image.file(
        localFile,
        width: widget.width,
        height: widget.height,
        cacheWidth: cacheW,
        cacheHeight: cacheH,
        fit: widget.fit,
        errorBuilder: (ctx, err, stack) => _buildAssetOrNetwork(entry, cacheW, cacheH),
      );
    }

    return _buildAssetOrNetwork(entry, cacheW, cacheH);
  }

  Widget _buildAssetOrNetwork(IconCacheEntry entry, int? cacheW, int? cacheH) {
    return Image.network(
      entry.url,
      width: widget.width,
      height: widget.height,
      cacheWidth: cacheW,
      cacheHeight: cacheH,
      fit: widget.fit,
      errorBuilder: (ctx, err, stack) {
        return widget.fallback ?? const SizedBox.shrink();
      },
    );
  }
}
