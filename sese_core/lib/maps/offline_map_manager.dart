import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// Describes the downloadable asset bundle for one Nigerian state.
class StateBundleManifest {
  /// ISO 3166-2:NG sub-code without prefix, e.g. `"LA"` for Lagos.
  final String stateCode;

  /// Human-readable state name, e.g. `"Lagos"`.
  final String stateName;

  /// Bundle schema version.  Compared against the locally cached version
  /// to decide whether a refresh download is needed.
  final int version;

  /// Published timestamp (server-side).  Drives the 90–180 day refresh
  /// window: if `DateTime.now().difference(publishedAt).inDays >= 90` a
  /// background refresh is scheduled.
  final DateTime publishedAt;

  /// Direct CDN download URLs for the three bundle files.
  final String mbtileUrl;
  final String geocoderDbUrl;
  final String routingOsrmUrl;

  /// Approximate compressed size in bytes — shown in download progress UI.
  final int sizeBytes;

  const StateBundleManifest({
    required this.stateCode,
    required this.stateName,
    required this.version,
    required this.publishedAt,
    required this.mbtileUrl,
    required this.geocoderDbUrl,
    required this.routingOsrmUrl,
    required this.sizeBytes,
  });

  factory StateBundleManifest.fromJson(Map<String, dynamic> json) {
    return StateBundleManifest(
      stateCode: json['state_code'] as String,
      stateName: json['state_name'] as String,
      version: (json['version'] as num).toInt(),
      publishedAt: DateTime.parse(json['published_at'] as String),
      mbtileUrl: json['mbtile_url'] as String,
      geocoderDbUrl: json['geocoder_db_url'] as String,
      routingOsrmUrl: json['routing_osrm_url'] as String,
      sizeBytes: (json['size_bytes'] as num).toInt(),
    );
  }

  Map<String, dynamic> toJson() => {
        'state_code': stateCode,
        'state_name': stateName,
        'version': version,
        'published_at': publishedAt.toIso8601String(),
        'mbtile_url': mbtileUrl,
        'geocoder_db_url': geocoderDbUrl,
        'routing_osrm_url': routingOsrmUrl,
        'size_bytes': sizeBytes,
      };
}

/// Download progress reported by [OfflineMapManager.downloadStateBundles].
class BundleDownloadProgress {
  /// Which file is currently being downloaded.
  final String filename;

  /// Bytes received so far for the current file.
  final int received;

  /// Total bytes expected for the current file (`-1` when unknown).
  final int total;

  /// Ordinal of the current file (1-based).
  final int fileIndex;

  /// Total number of files being downloaded.
  final int fileCount;

  const BundleDownloadProgress({
    required this.filename,
    required this.received,
    required this.total,
    required this.fileIndex,
    required this.fileCount,
  });

  /// 0.0–1.0 progress for the current file; `null` when [total] is unknown.
  double? get fileFraction => total > 0 ? received / total : null;
}

/// Manages on-demand download, caching, and version-refresh of Nigerian state
/// map bundles from the Sese CDN.
///
/// ### Bundle layout on device
/// ```
/// <ApplicationSupportDirectory>/
///   sese_maps/
///     <stateCode>/
///       <stateCode>_manifest.json   ← locally cached manifest
///       tiles.mbtiles               ← vector tile database
///       geocoder.db                 ← SQLite FTS5 address database
///       routing.osrm                ← OSRM routing graph
/// ```
///
/// ### Download strategy
/// Only the *active* state is downloaded on first launch (~80–120 MB).
/// Other states are fetched on-demand when the user navigates to them.
/// Background refresh is triggered after 90 days; the full re-download
/// is deferred up to 180 days (uses local cache in the meantime).
///
/// ### Error handling
/// Every network call is wrapped in try/catch.  A failed download leaves the
/// partial file on disk and the cached manifest unchanged, so the next
/// [downloadStateBundles] call resumes cleanly.
class OfflineMapManager {
  /// Base URL for the Sese CDN manifest index.
  static const String _cdnManifestBase =
      'https://cdn.sesetech.com/maps/bundles';

  /// After how many days a local bundle is considered stale and a background
  /// refresh is triggered.
  static const int refreshAfterDays = 90;

  /// After how many days the local bundle MUST be refreshed (hard deadline).
  static const int mustRefreshAfterDays = 180;

  Directory? _baseDir;

  /// Initialises the base storage directory.  Safe to call multiple times.
  Future<void> init() async {
    if (_baseDir != null) return;
    final support = await getApplicationSupportDirectory();
    _baseDir = Directory(p.join(support.path, 'sese_maps'));
    await _baseDir!.create(recursive: true);
  }

  /// Returns the local file paths for the [stateCode] bundle if ALL three
  /// files exist on disk, or `null` if the bundle has never been downloaded.
  ///
  /// Does NOT validate file integrity or freshness — use [needsRefresh] for
  /// that check.
  Future<BundlePaths?> getLocalBundlePaths(String stateCode) async {
    final dir = _stateDir(stateCode);
    final paths = BundlePaths(
      mbtilePath: p.join(dir.path, 'tiles.mbtiles'),
      geocoderDbPath: p.join(dir.path, 'geocoder.db'),
      routingOsrmPath: p.join(dir.path, 'routing.osrm'),
    );
    final allExist = await Future.wait([
      File(paths.mbtilePath).exists(),
      File(paths.geocoderDbPath).exists(),
      File(paths.routingOsrmPath).exists(),
    ]);
    return allExist.every((e) => e) ? paths : null;
  }

  /// Returns `true` when the locally cached manifest for [stateCode] is at
  /// least [refreshAfterDays] days old, indicating a background refresh
  /// should be scheduled.
  Future<bool> needsRefresh(String stateCode) async {
    final manifest = await _localManifest(stateCode);
    if (manifest == null) return true;
    final age = DateTime.now().difference(manifest.publishedAt).inDays;
    return age >= refreshAfterDays;
  }

  /// Returns `true` when the bundle is past the [mustRefreshAfterDays] hard
  /// deadline and MUST be replaced before use.
  Future<bool> mustRefresh(String stateCode) async {
    final manifest = await _localManifest(stateCode);
    if (manifest == null) return true;
    final age = DateTime.now().difference(manifest.publishedAt).inDays;
    return age >= mustRefreshAfterDays;
  }

  /// Fetches the CDN manifest for [stateCode] and downloads all three bundle
  /// files, reporting progress via [onProgress].
  ///
  /// If the local bundle version matches the server version, no files are
  /// re-downloaded (only the manifest timestamp is updated).
  ///
  /// Returns `true` on success, `false` on any network / IO failure.
  Future<bool> downloadStateBundles(
    String stateCode, {
    void Function(BundleDownloadProgress)? onProgress,
  }) async {
    await init();
    try {
      // 1. Fetch server manifest.
      final manifest = await _fetchRemoteManifest(stateCode);
      if (manifest == null) {
        debugPrint('OfflineMapManager: could not fetch manifest for $stateCode');
        return false;
      }

      // 2. Skip full download if versions match.
      final local = await _localManifest(stateCode);
      if (local != null && local.version >= manifest.version) {
        debugPrint(
            'OfflineMapManager: $stateCode already at v${manifest.version}');
        // Refresh manifest timestamp so the 90-day clock resets.
        await _saveManifest(stateCode, manifest);
        return true;
      }

      // 3. Download the three files.
      final dir = _stateDir(stateCode);
      await dir.create(recursive: true);

      final files = [
        _FileSpec('tiles.mbtiles', manifest.mbtileUrl),
        _FileSpec('geocoder.db', manifest.geocoderDbUrl),
        _FileSpec('routing.osrm', manifest.routingOsrmUrl),
      ];

      for (var i = 0; i < files.length; i++) {
        final spec = files[i];
        final ok = await _downloadFile(
          url: spec.url,
          dest: p.join(dir.path, spec.name),
          onProgress: onProgress == null
              ? null
              : (received, total) => onProgress(
                    BundleDownloadProgress(
                      filename: spec.name,
                      received: received,
                      total: total,
                      fileIndex: i + 1,
                      fileCount: files.length,
                    ),
                  ),
        );
        if (!ok) return false;
      }

      // 4. Persist the manifest so version checks and refresh logic work.
      await _saveManifest(stateCode, manifest);
      debugPrint(
          'OfflineMapManager: downloaded $stateCode v${manifest.version}');
      return true;
    } catch (e) {
      debugPrint('OfflineMapManager.downloadStateBundles error: $e');
      return false;
    }
  }

  /// Checks every cached state bundle against the CDN version index and
  /// returns a list of [stateCode]s that have a newer version available.
  Future<List<String>> checkForUpdates() async {
    await init();
    final stale = <String>[];
    try {
      final uri = Uri.parse('$_cdnManifestBase/index.json');
      final response =
          await http.get(uri).timeout(const Duration(seconds: 15));
      if (response.statusCode != 200) return stale;

      final index = jsonDecode(response.body) as Map<String, dynamic>;
      for (final entry in index.entries) {
        final stateCode = entry.key;
        final serverVersion = (entry.value as num).toInt();
        final local = await _localManifest(stateCode);
        if (local == null || local.version < serverVersion) {
          stale.add(stateCode);
        }
      }
    } catch (e) {
      debugPrint('OfflineMapManager.checkForUpdates error: $e');
    }
    return stale;
  }

  /// Deletes the locally cached bundle for [stateCode], freeing disk space.
  Future<void> deleteBundle(String stateCode) async {
    final dir = _stateDir(stateCode);
    if (await dir.exists()) await dir.delete(recursive: true);
  }

  /// Returns a list of all [stateCode]s that have a fully-downloaded bundle
  /// on disk.
  Future<List<String>> cachedStateCodes() async {
    await init();
    final base = _baseDir;
    if (base == null) return [];
    final codes = <String>[];
    try {
      final entries = await base.list().toList();
      for (final entity in entries) {
        if (entity is Directory) {
          final code = p.basename(entity.path);
          final paths = await getLocalBundlePaths(code);
          if (paths != null) codes.add(code);
        }
      }
    } catch (e) {
      debugPrint('OfflineMapManager.cachedStateCodes error: $e');
    }
    return codes;
  }

  // ---------------------------------------------------------------------------
  // Private helpers
  // ---------------------------------------------------------------------------

  Directory _stateDir(String stateCode) =>
      Directory(p.join(_baseDir!.path, stateCode));

  File _manifestFile(String stateCode) =>
      File(p.join(_stateDir(stateCode).path, '${stateCode}_manifest.json'));

  Future<StateBundleManifest?> _localManifest(String stateCode) async {
    final f = _manifestFile(stateCode);
    if (!await f.exists()) return null;
    try {
      final content = await f.readAsString();
      return StateBundleManifest.fromJson(
          jsonDecode(content) as Map<String, dynamic>);
    } catch (_) {
      return null;
    }
  }

  Future<void> _saveManifest(
      String stateCode, StateBundleManifest manifest) async {
    final dir = _stateDir(stateCode);
    await dir.create(recursive: true);
    await _manifestFile(stateCode)
        .writeAsString(jsonEncode(manifest.toJson()));
  }

  Future<StateBundleManifest?> _fetchRemoteManifest(String stateCode) async {
    final uri = Uri.parse('$_cdnManifestBase/$stateCode/manifest.json');
    try {
      final response =
          await http.get(uri).timeout(const Duration(seconds: 15));
      if (response.statusCode != 200) return null;
      return StateBundleManifest.fromJson(
          jsonDecode(response.body) as Map<String, dynamic>);
    } catch (e) {
      debugPrint('OfflineMapManager._fetchRemoteManifest error: $e');
      return null;
    }
  }

  /// Downloads [url] to [dest], reporting [received]/[total] via [onProgress].
  /// Returns `true` on success.
  Future<bool> _downloadFile({
    required String url,
    required String dest,
    void Function(int received, int total)? onProgress,
  }) async {
    try {
      final request = http.Request('GET', Uri.parse(url));
      final streamed = await http.Client().send(request).timeout(
            const Duration(minutes: 10),
          );
      if (streamed.statusCode != 200) return false;

      final total = streamed.contentLength ?? -1;
      final file = File(dest);
      final sink = file.openWrite();
      var received = 0;

      await for (final chunk in streamed.stream) {
        sink.add(chunk);
        received += chunk.length;
        onProgress?.call(received, total);
      }
      await sink.close();
      return true;
    } catch (e) {
      debugPrint('OfflineMapManager._downloadFile error ($url): $e');
      return false;
    }
  }
}

/// Resolved local paths for a fully-downloaded state bundle.
class BundlePaths {
  /// Path to the `.mbtiles` vector tile database.
  final String mbtilePath;

  /// Path to the SQLite geocoder database.
  final String geocoderDbPath;

  /// Path to the OSRM routing graph.
  final String routingOsrmPath;

  const BundlePaths({
    required this.mbtilePath,
    required this.geocoderDbPath,
    required this.routingOsrmPath,
  });
}

class _FileSpec {
  final String name;
  final String url;
  const _FileSpec(this.name, this.url);
}
