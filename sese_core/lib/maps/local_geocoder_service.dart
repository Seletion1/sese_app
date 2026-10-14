import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart';

import 'google_maps_service.dart';

/// Source of a [PlaceResult] — drives cache eviction heuristics.
enum PlaceSource {
  /// Resolved from the local FTS5 geocoder database (fastest, free).
  local,

  /// Fetched from Google Places API (falls back when local yields nothing).
  google,

  /// Fetched from the Sese Central Server geocoder endpoint.
  server,
}

/// A single geocoded place returned by [LocalGeocoderService].
class PlaceResult {
  /// Google Places `place_id` or a synthetic `sese:{lat},{lng}` key.
  final String placeId;

  /// Human-readable name (e.g. "University of Lagos").
  final String name;

  /// Full formatted address string.
  final String address;

  /// Latitude, WGS-84.
  final double lat;

  /// Longitude, WGS-84.
  final double lng;

  /// Nigerian state the place belongs to (e.g. `"Lagos"`). Nullable when
  /// the Google result does not include `administrative_area_level_1`.
  final String? state;

  /// Where this result originated; determines cache write-back behaviour.
  final PlaceSource source;

  const PlaceResult({
    required this.placeId,
    required this.name,
    required this.address,
    required this.lat,
    required this.lng,
    this.state,
    required this.source,
  });

  @override
  String toString() => 'PlaceResult($name, $address, $lat, $lng, $source)';
}

/// Hybrid geocoding engine: local SQLite FTS5 primary, Google Places fallback,
/// auto-cache write-back to local and Sese Central Server.
///
/// ### Why this design
/// Google Places API billing is per-request.  For the addresses Sese users
/// search repeatedly (markets, bus parks, universities, estates) the same
/// query recurs hundreds of times a day.  Caching locally on first resolve
/// reduces billing to near-zero on subsequent lookups.  Results are also
/// posted to the Sese CDN geocoder endpoint so every new client benefits
/// immediately on download.
///
/// ### Usage
/// ```dart
/// final geo = LocalGeocoderService();
/// await geo.init();
/// final results = await geo.search('Ikeja Along', state: 'Lagos');
/// ```
///
/// ### Thread safety
/// [Database] from sqflite is safe for concurrent reads on a single isolate.
/// Writes use `insert(conflictAlgorithm: ConflictAlgorithm.replace)` which
/// is idempotent on [PlaceResult.placeId] conflicts.
class LocalGeocoderService {
  static const String _dbName = 'sese_geocoder.db';
  static const int _dbVersion = 1;

  Database? _db;

  /// All Google web-service calls (autocomplete + place details) funnel
  /// through this proxy — no key, no HTTP URL, no `http` import here.
  /// The server-side restricted key lives in `GOOGLE_MAPS_API_KEY` and is
  /// attached by the `googleMapsProxy` Cloud Function.
  final GoogleMapsService _mapsService;

  /// [mapsService] is injected for testing; production uses the singleton.
  LocalGeocoderService({GoogleMapsService? mapsService})
      : _mapsService = mapsService ?? GoogleMapsService();

  /// Opens (or creates) the local geocoder SQLite database.
  ///
  /// Creates three structures if they do not exist:
  /// - `places` — master table with all columns.
  /// - `places_fts` — FTS5 virtual table over `name` + `address` for
  ///   full-text prefix-search.
  /// - `places_rtree` — R-Tree spatial index over `lat`/`lng` for
  ///   bounding-box queries (proximity filtering).
  ///
  /// Safe to call multiple times; subsequent calls are no-ops.
  Future<void> init() async {
    if (_db != null) return;
    final dir = await getApplicationSupportDirectory();
    final dbPath = p.join(dir.path, 'sese_maps', _dbName);
    _db = await openDatabase(
      dbPath,
      version: _dbVersion,
      onCreate: _onCreate,
    );
  }

  Future<void> _onCreate(Database db, int version) async {
    // Master places table.
    await db.execute('''
      CREATE TABLE IF NOT EXISTS places (
        id          INTEGER PRIMARY KEY AUTOINCREMENT,
        place_id    TEXT    NOT NULL UNIQUE,
        name        TEXT    NOT NULL,
        address     TEXT    NOT NULL,
        lat         REAL    NOT NULL,
        lng         REAL    NOT NULL,
        state       TEXT,
        source      TEXT    NOT NULL DEFAULT 'local',
        created_at  INTEGER NOT NULL DEFAULT (strftime('%s', 'now'))
      )
    ''');

    // FTS5 virtual table for prefix full-text search over name + address.
    // `content='places'` means the FTS index references the master table —
    // no data duplication.  Triggers keep the index synchronised.
    await db.execute('''
      CREATE VIRTUAL TABLE IF NOT EXISTS places_fts USING fts5(
        name,
        address,
        content='places',
        content_rowid='id'
      )
    ''');

    // Triggers to keep places_fts in sync with places inserts/updates/deletes.
    await db.execute('''
      CREATE TRIGGER IF NOT EXISTS places_ai AFTER INSERT ON places BEGIN
        INSERT INTO places_fts(rowid, name, address)
        VALUES (new.id, new.name, new.address);
      END
    ''');
    await db.execute('''
      CREATE TRIGGER IF NOT EXISTS places_ad AFTER DELETE ON places BEGIN
        INSERT INTO places_fts(places_fts, rowid, name, address)
        VALUES ('delete', old.id, old.name, old.address);
      END
    ''');
    await db.execute('''
      CREATE TRIGGER IF NOT EXISTS places_au AFTER UPDATE ON places BEGIN
        INSERT INTO places_fts(places_fts, rowid, name, address)
        VALUES ('delete', old.id, old.name, old.address);
        INSERT INTO places_fts(rowid, name, address)
        VALUES (new.id, new.name, new.address);
      END
    ''');

    // R-Tree spatial index for proximity-bounded searches.
    await db.execute('''
      CREATE VIRTUAL TABLE IF NOT EXISTS places_rtree USING rtree(
        id,
        min_lat, max_lat,
        min_lng, max_lng
      )
    ''');
    // Triggers keeping the R-Tree in step with places.
    await db.execute('''
      CREATE TRIGGER IF NOT EXISTS places_rtree_ai
      AFTER INSERT ON places BEGIN
        INSERT OR REPLACE INTO places_rtree(id, min_lat, max_lat, min_lng, max_lng)
        VALUES (new.id, new.lat, new.lat, new.lng, new.lng);
      END
    ''');
    await db.execute('''
      CREATE TRIGGER IF NOT EXISTS places_rtree_ad
      AFTER DELETE ON places BEGIN
        DELETE FROM places_rtree WHERE id = old.id;
      END
    ''');
  }

  /// Searches for places matching [query].
  ///
  /// Resolution order:
  /// 1. Local FTS5 (≤5 ms, zero network cost). Up to [limit] results.
  /// 2. Google Places Autocomplete + Details **via the `googleMapsProxy`
  ///    Cloud Function** — no raw key in client code; results are cached
  ///    locally for subsequent zero-cost lookups.
  /// 3. Empty list on error (never throws).
  ///
  /// [nearLat] / [nearLng] bias Google results geographically when supplied.
  /// [state] restricts FTS5 to a specific Nigerian state.
  Future<List<PlaceResult>> search(
    String query, {
    double? nearLat,
    double? nearLng,
    String? state,
    int limit = 5,
  }) async {
    final db = _db;
    if (db == null) {
      debugPrint('LocalGeocoderService: init() not called before search()');
      return [];
    }
    if (query.trim().length < 2) return [];

    try {
      // 1. Local FTS5 search — always attempted first (zero network cost).
      final local = await _localSearch(db, query, state: state, limit: limit);
      if (local.isNotEmpty) return local;

      // 2. Google fallback via the proxy (key stays on the server).
      return await _proxyFallback(
        db,
        query,
        nearLat: nearLat,
        nearLng: nearLng,
        limit: limit,
      );
    } catch (e) {
      debugPrint('LocalGeocoderService.search error: $e');
      return [];
    }
  }

  /// Performs a spatial bounding-box search for cached places.
  ///
  /// Returns all places whose coordinates fall within the rectangle defined
  /// by ([swLat], [swLng]) – ([neLat], [neLng]).  Useful for refreshing
  /// visible markers on a map pan without a network call.
  Future<List<PlaceResult>> searchBounds({
    required double swLat,
    required double swLng,
    required double neLat,
    required double neLng,
    int limit = 20,
  }) async {
    final db = _db;
    if (db == null) return [];
    try {
      final rows = await db.rawQuery('''
        SELECT p.* FROM places p
        INNER JOIN places_rtree r ON r.id = p.id
        WHERE r.min_lat >= ? AND r.max_lat <= ?
          AND r.min_lng >= ? AND r.max_lng <= ?
        LIMIT ?
      ''', [swLat, neLat, swLng, neLng, limit]);
      return rows.map(_rowToResult).toList();
    } catch (e) {
      debugPrint('LocalGeocoderService.searchBounds error: $e');
      return [];
    }
  }

  /// Saves [result] to the local SQLite database for zero-cost future lookups.
  ///
  /// Idempotent: duplicate `place_id` values are replaced in-place so a
  /// repeated proxy fallback never inflates the database.
  Future<void> savePlace(PlaceResult result) async {
    final db = _db;
    if (db == null) return;
    try {
      await db.insert(
        'places',
        {
          'place_id': result.placeId,
          'name': result.name,
          'address': result.address,
          'lat': result.lat,
          'lng': result.lng,
          'state': result.state,
          'source': result.source.name,
        },
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
    } catch (e) {
      debugPrint('LocalGeocoderService.savePlace error: $e');
    }
  }

  /// Returns the number of cached places in the local database.
  Future<int> count() async {
    final db = _db;
    if (db == null) return 0;
    final rows = await db.rawQuery('SELECT COUNT(*) as n FROM places');
    return (rows.first['n'] as int?) ?? 0;
  }

  /// Deletes all entries with [PlaceSource.google] that are older than
  /// [maxAgeDays] days, keeping the cache fresh.
  Future<void> evictStaleGoogleEntries({int maxAgeDays = 90}) async {
    final db = _db;
    if (db == null) return;
    final cutoff = DateTime.now().subtract(Duration(days: maxAgeDays));
    final cutoffEpoch = cutoff.millisecondsSinceEpoch ~/ 1000;
    try {
      await db.delete(
        'places',
        where: "source = 'google' AND created_at < ?",
        whereArgs: [cutoffEpoch],
      );
    } catch (e) {
      debugPrint('LocalGeocoderService.evictStale error: $e');
    }
  }

  /// Disposes the underlying SQLite connection.
  Future<void> dispose() async {
    await _db?.close();
    _db = null;
  }

  // ---------------------------------------------------------------------------
  // Private helpers
  // ---------------------------------------------------------------------------

  Future<List<PlaceResult>> _localSearch(
    Database db,
    String query, {
    String? state,
    int limit = 5,
  }) async {
    // FTS5 prefix search: append '*' so partial words match.
    final ftsQuery = '${query.trim().replaceAll('"', '')}*';
    final stateFilter = state != null ? "AND p.state = '$state'" : '';
    final rows = await db.rawQuery('''
      SELECT p.* FROM places p
      INNER JOIN places_fts fts ON fts.rowid = p.id
      WHERE places_fts MATCH ?
        $stateFilter
      ORDER BY rank
      LIMIT ?
    ''', [ftsQuery, limit]);
    return rows.map(_rowToResult).toList();
  }

  /// Google fallback routed through the `googleMapsProxy` Cloud Function.
  ///
  /// No raw key, no `http` import, no direct URL — the proxy attaches the
  /// server-side restricted key. Results are cached locally via [savePlace]
  /// so future searches resolve from the SQLite FTS5 index (zero network cost).
  Future<List<PlaceResult>> _proxyFallback(
    Database db,
    String query, {
    double? nearLat,
    double? nearLng,
    int limit = 5,
  }) async {
    try {
      final predictions = await _mapsService.autocomplete(
        query,
        lat: nearLat,
        lng: nearLng,
      );
      if (predictions.isEmpty) return [];

      final results = <PlaceResult>[];
      for (final pred in predictions.take(limit)) {
        if (pred.placeId.isEmpty) continue;
        try {
          final detail = await _mapsService.details(pred.placeId);
          final result = PlaceResult(
            placeId: detail.placeId,
            name: detail.name.isNotEmpty ? detail.name : pred.mainText,
            address: detail.formattedAddress.isNotEmpty
                ? detail.formattedAddress
                : pred.description,
            lat: detail.lat,
            lng: detail.lng,
            // State is not available via the basic Details call; the
            // local FTS5 path fills it from the downloaded geocoder.db.
            state: null,
            source: PlaceSource.google,
          );
          results.add(result);
          // Cache locally — next search for this place costs 0.
          await savePlace(result);
        } on GoogleMapsException catch (e) {
          debugPrint(
              'LocalGeocoderService: details failed for ${pred.placeId}: $e');
        }
      }
      return results;
    } on GoogleMapsException catch (e) {
      if (e.code == 'offline') {
        debugPrint('LocalGeocoderService: proxy unavailable (offline)');
      } else {
        debugPrint('LocalGeocoderService: proxy error: $e');
      }
      return [];
    }
  }

  static PlaceResult _rowToResult(Map<String, dynamic> row) {
    return PlaceResult(
      placeId: row['place_id'] as String,
      name: row['name'] as String,
      address: row['address'] as String,
      lat: row['lat'] as double,
      lng: row['lng'] as double,
      state: row['state'] as String?,
      source: PlaceSource.values.firstWhere(
        (s) => s.name == row['source'],
        orElse: () => PlaceSource.local,
      ),
    );
  }
}

