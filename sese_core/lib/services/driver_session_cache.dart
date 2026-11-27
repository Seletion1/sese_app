import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Lightweight synchronous-read, async-write local cache for essential driver
/// session state.
///
/// Written on every go-online / go-offline / active-trip update (< 1 ms) so
/// the next cold start can hydrate instantly from [SharedPreferences] without
/// waiting for a Firestore round-trip.
///
/// ## Keys stored (all under prefix `sese_dsc_`)
/// | Key                    | Type     | Meaning                                      |
/// |------------------------|----------|----------------------------------------------|
/// | `isOnline`             | bool     | Driver was online when app was last foregrounded |
/// | `sessionId`            | String   | Last active dispatch session ID              |
/// | `driverUid`            | String   | Authenticated UID                            |
/// | `activeTripId`         | String   | In-progress trip ID, empty when idle         |
/// | `activeTripJson`       | String   | Serialised last-known `ActiveTrip` map       |
/// | `lat`                  | double   | Last GPS latitude                            |
/// | `lng`                  | double   | Last GPS longitude                           |
/// | `mapProvider`          | String   | Last resolved map provider name              |
/// | `savedAtMs`            | int      | Epoch-ms when the snapshot was saved         |
///
/// ## Thread safety
/// [SharedPreferences.apply()] is fire-and-forget; reads are synchronous
/// after [init] completes.
class DriverSessionCache {
  DriverSessionCache._();
  static final DriverSessionCache instance = DriverSessionCache._();

  static const String _prefix = 'sese_dsc_';

  /// Maximum age for a cached session before it is treated as stale on
  /// cold start (8 hours — covers overnight breaks without driver going offline).
  static const Duration _maxAge = Duration(hours: 8);

  SharedPreferences? _prefs;

  // ── In-memory shadow (populated synchronously from prefs after [init]) ──
  bool _isOnline = false;
  String _sessionId = '';
  String _driverUid = '';
  String _activeTripId = '';
  Map<String, dynamic>? _activeTripJson;
  double? _lat;
  double? _lng;
  String _mapProvider = '';

  // ── Public getters (synchronous, 0-ms) ─────────────────────────────────

  /// Whether the driver was online at the last session snapshot.
  bool get isOnline => _isOnline;

  /// Last active session ID.
  String get sessionId => _sessionId;

  /// Authenticated driver UID.
  String get driverUid => _driverUid;

  /// In-progress trip ID; empty string when idle.
  String get activeTripId => _activeTripId;

  /// Serialised last-known trip data as a JSON map, or `null` if no active trip.
  Map<String, dynamic>? get activeTripJson => _activeTripJson;

  /// Last known GPS latitude, or `null` before first fix.
  double? get lastLatitude => _lat;

  /// Last known GPS longitude, or `null` before first fix.
  double? get lastLongitude => _lng;

  /// Name of the map provider that was active on last launch.
  String get mapProvider => _mapProvider;

  // ── Lifecycle ───────────────────────────────────────────────────────────

  /// Loads the persisted snapshot synchronously into the in-memory shadow.
  ///
  /// Call once during `main()` after [SharedPreferences.getInstance()] (which
  /// the [LocalCacheService] already awaits). Safe to call multiple times.
  Future<void> init() async {
    if (_prefs != null) return; // Already initialised.
    try {
      _prefs = await SharedPreferences.getInstance();
      _hydrate();
    } catch (e) {
      debugPrint('DriverSessionCache.init error: $e');
    }
  }

  /// Synchronous hydration from already-loaded [SharedPreferences] instance.
  /// Call this if [SharedPreferences.getInstance()] was already awaited
  /// elsewhere (avoids a second async await).
  void initFromPrefs(SharedPreferences prefs) {
    _prefs = prefs;
    _hydrate();
  }

  void _hydrate() {
    final p = _prefs;
    if (p == null) return;

    // Stale-check: ignore sessions older than [_maxAge].
    final savedAt = p.getInt(_k('savedAtMs')) ?? 0;
    if (savedAt > 0) {
      final age = DateTime.now().millisecondsSinceEpoch - savedAt;
      if (age > _maxAge.inMilliseconds) {
        debugPrint('DriverSessionCache: stale snapshot ($age ms old) — ignoring.');
        _isOnline = false;
        _sessionId = '';
        _driverUid = '';
        _activeTripId = '';
        _activeTripJson = null;
        _lat = null;
        _lng = null;
        _mapProvider = '';
        return;
      }
    }

    _isOnline = p.getBool(_k('isOnline')) ?? false;
    _sessionId = p.getString(_k('sessionId')) ?? '';
    _driverUid = p.getString(_k('driverUid')) ?? '';
    _activeTripId = p.getString(_k('activeTripId')) ?? '';
    _lat = p.getDouble(_k('lat'));
    _lng = p.getDouble(_k('lng'));
    _mapProvider = p.getString(_k('mapProvider')) ?? '';

    final tripRaw = p.getString(_k('activeTripJson'));
    if (tripRaw != null && tripRaw.isNotEmpty) {
      try {
        final decoded = jsonDecode(tripRaw);
        if (decoded is Map<String, dynamic>) {
          _activeTripJson = decoded;
        }
      } catch (_) {}
    }
  }

  // ── Write helpers ───────────────────────────────────────────────────────

  /// Atomically updates online status, session ID, driver UID, and optional
  /// active-trip ID. Persist is best-effort (fire-and-forget).
  void saveSessionState({
    required bool isOnline,
    required String driverUid,
    String sessionId = '',
    String activeTripId = '',
  }) {
    _isOnline = isOnline;
    _sessionId = sessionId;
    _driverUid = driverUid;
    _activeTripId = activeTripId;
    _flush();
  }

  /// Updates the active trip JSON snapshot for Firestore-free cold-start hydration.
  void saveActiveTripJson(Map<String, dynamic>? tripJson) {
    _activeTripJson = tripJson;
    _prefs?.setString(
      _k('activeTripJson'),
      tripJson != null ? jsonEncode(tripJson) : '',
    );
  }

  /// Persists the driver's last known GPS fix for instant map centering.
  void saveGpsFix(double lat, double lng) {
    _lat = lat;
    _lng = lng;
    _prefs
      ?..setDouble(_k('lat'), lat)
      ..setDouble(_k('lng'), lng);
  }

  /// Saves the last active map provider name.
  void saveMapProvider(String provider) {
    _mapProvider = provider;
    _prefs?.setString(_k('mapProvider'), provider);
  }

  /// Clears all cached state on sign-out.
  Future<void> clear() async {
    _isOnline = false;
    _sessionId = '';
    _driverUid = '';
    _activeTripId = '';
    _activeTripJson = null;
    _lat = null;
    _lng = null;
    _mapProvider = '';
    try {
      final p = _prefs;
      if (p != null) {
        for (final key in _allKeys) {
          await p.remove(key);
        }
      }
    } catch (e) {
      debugPrint('DriverSessionCache.clear error: $e');
    }
  }

  // ── Internal helpers ────────────────────────────────────────────────────

  String _k(String field) => '$_prefix$field';

  static const List<String> _allKeys = [
    '${_prefix}isOnline',
    '${_prefix}sessionId',
    '${_prefix}driverUid',
    '${_prefix}activeTripId',
    '${_prefix}activeTripJson',
    '${_prefix}lat',
    '${_prefix}lng',
    '${_prefix}mapProvider',
    '${_prefix}savedAtMs',
  ];

  void _flush() {
    final p = _prefs;
    if (p == null) return;
    p
      ..setBool(_k('isOnline'), _isOnline)
      ..setString(_k('sessionId'), _sessionId)
      ..setString(_k('driverUid'), _driverUid)
      ..setString(_k('activeTripId'), _activeTripId)
      ..setInt(_k('savedAtMs'), DateTime.now().millisecondsSinceEpoch);
  }
}
