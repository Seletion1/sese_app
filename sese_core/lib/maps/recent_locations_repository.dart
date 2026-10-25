import 'dart:convert';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'place_models.dart';

/// Zero-cost address-reuse store: every booked location persists locally
/// (SharedPreferences JSON, MRU-capped) and backs up to
/// `users/{uid}/recent_locations/{placeId}` in Firestore.
///
/// THE COST STRATEGY, in one place:
/// - Search screen opens → [topRecent] serves 5 rows, 0 API calls.
/// - Tap a recent → coordinates come from storage, 0 API calls.
/// - Type → debounced (400ms) proxy autocomplete, 1 call per pause.
/// - Pick a prediction → 1 Details call, then [saveRecent] (local +
///   Firestore merge). The NEXT tap on it costs 0.
///
/// All I/O is best-effort and never throws: a missing Firebase app, a
/// denied Firestore write, or a corrupt cache degrades to in-memory
/// recents for the session. Test seams (`prefsOverride`, `firestoreOverride`)
/// keep widget tests offline.
class RecentLocationsRepository {
  static const String _prefsKey = 'sese_recent_locations_v1';

  final SharedPreferences? _prefsOverride;
  final FirebaseFirestore? _firestoreOverride;

  /// Last cloud sync per uid (in-memory; a fresh launch re-syncs once the
  /// search UI opens — that IS the new-device path).
  final Map<String, int> _lastSyncMs = {};

  RecentLocationsRepository({
    this._prefsOverride,
    this._firestoreOverride,
  });

  Future<SharedPreferences?> get _prefs async {
    if (_prefsOverride != null) return _prefsOverride;
    try {
      return await SharedPreferences.getInstance();
    } catch (e) {
      debugPrint('RecentLocations prefs unavailable: $e');
      return null;
    }
  }

  FirebaseFirestore? get _db {
    if (_firestoreOverride != null) return _firestoreOverride;
    try {
      return FirebaseFirestore.instance;
    } catch (_) {
      return null;
    }
  }

  /// All cached recents, newest first. Never throws (empty on any failure).
  Future<List<RecentLocation>> loadAll() async {
    try {
      final prefs = await _prefs;
      final raw = prefs?.getString(_prefsKey);
      if (raw == null || raw.isEmpty) return [];
      final list = (jsonDecode(raw) as List<dynamic>);
      final out = <RecentLocation>[];
      for (final item in list) {
        if (item is! Map) continue;
        final loc =
            RecentLocation.fromMap(Map<String, dynamic>.from(item));
        if (loc.isValid) out.add(loc);
      }
      out.sort((a, b) => b.lastUsedMs.compareTo(a.lastUsedMs));
      return out.take(RecentLocation.maxCached).toList();
    } catch (e) {
      debugPrint('RecentLocations load failed: $e');
      return [];
    }
  }

  /// Immediate search-screen rows: top 5, 0 API calls.
  Future<List<RecentLocation>> topRecent({int limit = 5}) async {
    final all = await loadAll();
    return all.take(limit).toList();
  }

  /// Returns the top frequent and recent locations.
  /// Locations used multiple times or recently float to the top.
  Future<List<RecentLocation>> getFrequentAndRecent({int limit = 8}) async {
    final all = await loadAll();
    all.sort((a, b) {
      final aScore = a.useCount * 1000000000000 + a.lastUsedMs;
      final bScore = b.useCount * 1000000000000 + b.lastUsedMs;
      return bScore.compareTo(aScore);
    });
    return all.take(limit).toList();
  }

  /// Searches cached locations locally without any network or API calls.
  /// Matches against mainText, formattedAddress, and secondaryText.
  /// Ranks by match relevance and frequency/recency.
  Future<List<RecentLocation>> searchLocal(String query, {int limit = 6}) async {
    final clean = query.trim().toLowerCase();
    if (clean.isEmpty) return getFrequentAndRecent(limit: limit);

    final all = await loadAll();
    final matches = <RecentLocation>[];

    for (final loc in all) {
      final main = loc.mainText.toLowerCase();
      final addr = loc.formattedAddress.toLowerCase();
      final sec = loc.secondaryText.toLowerCase();

      if (main.contains(clean) || addr.contains(clean) || sec.contains(clean)) {
        matches.add(loc);
      }
    }

    // Sort: exact/prefix match on main text first, then by frequency & recency
    matches.sort((a, b) {
      final aMain = a.mainText.toLowerCase();
      final bMain = b.mainText.toLowerCase();
      final aStarts = aMain.startsWith(clean);
      final bStarts = bMain.startsWith(clean);
      if (aStarts && !bStarts) return -1;
      if (!aStarts && bStarts) return 1;

      // Score based on frequency and recency
      final aScore = a.useCount * 1000000000000 + a.lastUsedMs;
      final bScore = b.useCount * 1000000000000 + b.lastUsedMs;
      return bScore.compareTo(aScore);
    });

    return matches.take(limit).toList();
  }

  Future<void> _writeLocal(List<RecentLocation> all) async {
    try {
      final prefs = await _prefs;
      await prefs?.setString(
        _prefsKey,
        jsonEncode(all.map((e) => e.toMap()).toList()),
      );
    } catch (e) {
      debugPrint('RecentLocations local write failed: $e');
    }
  }

  /// Saves or touches an address in the local cache and Firestore backup.
  /// Automatically generates a deterministic placeId if none provided.
  Future<void> saveLocation({
    required String address,
    required double lat,
    required double lng,
    String? placeId,
    String? mainText,
    String? secondaryText,
    String? tag,
    String? uid,
  }) async {
    if (address.trim().isEmpty || (lat == 0 && lng == 0)) return;
    final cleanAddress = address.trim();
    final pId = (placeId != null && placeId.isNotEmpty)
        ? placeId
        : 'loc_${lat.toStringAsFixed(5)}_${lng.toStringAsFixed(5)}';

    final loc = RecentLocation(
      placeId: pId,
      formattedAddress: cleanAddress,
      mainText: mainText ?? cleanAddress,
      secondaryText: secondaryText ?? '',
      lat: lat,
      lng: lng,
      lastUsedMs: DateTime.now().millisecondsSinceEpoch,
      useCount: 1,
      tag: tag,
    );
    await saveRecent(loc, uid: uid);
  }

  /// Persists a booked location: MRU-touch locally (capped) + Firestore
  /// merge backup (best-effort; a denied write never fails the booking).
  Future<void> saveRecent(RecentLocation location, {String? uid}) async {
    if (!location.isValid) return;
    final all = await loadAll();
    final existingIdx = all.indexWhere((e) =>
        e.placeId == location.placeId ||
        (e.formattedAddress.isNotEmpty &&
            e.formattedAddress.toLowerCase() ==
                location.formattedAddress.toLowerCase()));

    RecentLocation touched;
    if (existingIdx >= 0) {
      final existing = all.removeAt(existingIdx);
      touched = existing.touched(newTag: location.tag);
    } else {
      touched = location;
    }

    all.insert(0, touched);
    await _writeLocal(all.take(RecentLocation.maxCached).toList());
    if (uid == null || uid.isEmpty) return;
    try {
      await _db
          ?.collection('users')
          .doc(uid)
          .collection('recent_locations')
          .doc(touched.placeId)
          .set(touched.toMap(), SetOptions(merge: true));
    } catch (e) {
      debugPrint('RecentLocations cloud backup failed: $e');
    }
  }

  /// Merges the Firestore backup into the local cache (newest wins per
  /// placeId). Called when the search UI first opens per launch (throttled
  /// to one sync per uid per hour) — this is what heals a new device.
  /// Never throws.
  Future<void> syncFromCloud(String uid) async {
    if (uid.isEmpty) return;
    final now = DateTime.now().millisecondsSinceEpoch;
    if (now - (_lastSyncMs[uid] ?? 0) < const Duration(hours: 1).inMilliseconds) {
      return;
    }
    _lastSyncMs[uid] = now;
    try {
      final snap = await _db
          ?.collection('users')
          .doc(uid)
          .collection('recent_locations')
          .orderBy('lastUsedMs', descending: true)
          .limit(RecentLocation.maxCached)
          .get();
      if (snap == null) return;
      final byId = <String, RecentLocation>{};
      for (final loc in await loadAll()) {
        byId[loc.placeId] = loc;
      }
      for (final doc in snap.docs) {
        final loc = RecentLocation.fromMap(doc.data());
        if (!loc.isValid) continue;
        final existing = byId[loc.placeId];
        if (existing == null || loc.lastUsedMs > existing.lastUsedMs) {
          byId[loc.placeId] = loc;
        }
      }
      final merged = byId.values.toList()
        ..sort((a, b) => b.lastUsedMs.compareTo(a.lastUsedMs));
      await _writeLocal(merged.take(RecentLocation.maxCached).toList());
    } catch (e) {
      debugPrint('RecentLocations cloud sync failed: $e');
    }
  }

  /// Clears the device cache (account sign-out hygiene). Cloud backup stays.
  Future<void> clearLocal() async {
    try {
      await (await _prefs)?.remove(_prefsKey);
    } catch (e) {
      debugPrint('RecentLocations clear failed: $e');
    }
  }
}
