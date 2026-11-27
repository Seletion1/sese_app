// ignore_for_file: prefer_const_constructors

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:sese_core/services/driver_session_cache.dart';

void main() {
  /// Reset the singleton's internal [SharedPreferences] state before each test
  /// by using [SharedPreferences.setMockInitialValues].
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  group('DriverSessionCache — init & hydration', () {
    test('defaults to offline / empty before init', () {
      // A freshly created singleton (before init) has safe default values.
      final cache = DriverSessionCache.instance;
      expect(cache.isOnline, isFalse);
      expect(cache.driverUid, isEmpty);
      expect(cache.sessionId, isEmpty);
      expect(cache.activeTripId, isEmpty);
      expect(cache.activeTripJson, isNull);
      expect(cache.lastLatitude, isNull);
      expect(cache.lastLongitude, isNull);
      expect(cache.mapProvider, isEmpty);
    });

    test('saveSessionState persists and in-memory shadow updates immediately',
        () async {
      final cache = DriverSessionCache.instance;
      await cache.init();

      cache.saveSessionState(
        isOnline: true,
        driverUid: 'uid_abc',
        sessionId: 'sess_123',
        activeTripId: 'trip_xyz',
      );

      expect(cache.isOnline, isTrue);
      expect(cache.driverUid, 'uid_abc');
      expect(cache.sessionId, 'sess_123');
      expect(cache.activeTripId, 'trip_xyz');
    });

    test('saveSessionState with isOnline:false clears online flag', () async {
      final cache = DriverSessionCache.instance;
      await cache.init();

      cache.saveSessionState(
        isOnline: true,
        driverUid: 'uid_abc',
        sessionId: 'sess_123',
      );
      expect(cache.isOnline, isTrue);

      cache.saveSessionState(
        isOnline: false,
        driverUid: 'uid_abc',
        sessionId: '',
        activeTripId: '',
      );
      expect(cache.isOnline, isFalse);
      expect(cache.sessionId, isEmpty);
    });

    test('saveGpsFix persists lat/lng into in-memory shadow', () async {
      final cache = DriverSessionCache.instance;
      await cache.init();

      cache.saveGpsFix(6.5244, 3.3792);

      expect(cache.lastLatitude, closeTo(6.5244, 0.0001));
      expect(cache.lastLongitude, closeTo(3.3792, 0.0001));
    });

    test('saveMapProvider stores provider name', () async {
      final cache = DriverSessionCache.instance;
      await cache.init();

      cache.saveMapProvider('mapbox');
      expect(cache.mapProvider, 'mapbox');
    });

    test('saveActiveTripJson stores and retrieves trip map', () async {
      final cache = DriverSessionCache.instance;
      await cache.init();

      final tripData = {
        'tripId': 'trip_001',
        'status': 'IN_PROGRESS',
        'fareKobo': 500000,
      };
      cache.saveActiveTripJson(tripData);

      expect(cache.activeTripJson, isNotNull);
      expect(cache.activeTripJson!['tripId'], 'trip_001');
      expect(cache.activeTripJson!['fareKobo'], 500000);
    });

    test('saveActiveTripJson with null clears the snapshot', () async {
      final cache = DriverSessionCache.instance;
      await cache.init();

      cache.saveActiveTripJson({'tripId': 'trip_001'});
      expect(cache.activeTripJson, isNotNull);

      cache.saveActiveTripJson(null);
      expect(cache.activeTripJson, isNull);
    });

    test('clear() resets all fields to defaults', () async {
      final cache = DriverSessionCache.instance;
      await cache.init();

      cache.saveSessionState(
        isOnline: true,
        driverUid: 'uid_abc',
        sessionId: 'sess_123',
        activeTripId: 'trip_xyz',
      );
      cache.saveGpsFix(6.5244, 3.3792);
      cache.saveMapProvider('mapbox');
      cache.saveActiveTripJson({'tripId': 'trip_001'});

      await cache.clear();

      expect(cache.isOnline, isFalse);
      expect(cache.driverUid, isEmpty);
      expect(cache.sessionId, isEmpty);
      expect(cache.activeTripId, isEmpty);
      expect(cache.lastLatitude, isNull);
      expect(cache.lastLongitude, isNull);
      expect(cache.mapProvider, isEmpty);
      expect(cache.activeTripJson, isNull);
    });
  });

  group('DriverSessionCache — hydration roundtrip via initFromPrefs', () {
    test('hydrates from pre-seeded SharedPreferences on subsequent launch',
        () async {
      // Simulate a previous app run that saved session state.
      final nowMs = DateTime.now().millisecondsSinceEpoch;
      SharedPreferences.setMockInitialValues({
        'sese_dsc_isOnline': true,
        'sese_dsc_sessionId': 'sess_prev',
        'sese_dsc_driverUid': 'uid_prev',
        'sese_dsc_activeTripId': 'trip_prev',
        'sese_dsc_lat': 6.5244,
        'sese_dsc_lng': 3.3792,
        'sese_dsc_mapProvider': 'google',
        'sese_dsc_savedAtMs': nowMs, // fresh — not stale
      });

      final prefs = await SharedPreferences.getInstance();
      final cache = DriverSessionCache.instance;
      // Force re-hydration by calling initFromPrefs directly (bypasses the
      // singleton already-inited guard so we can test hydration in isolation).
      cache.initFromPrefs(prefs);

      expect(cache.isOnline, isTrue);
      expect(cache.sessionId, 'sess_prev');
      expect(cache.driverUid, 'uid_prev');
      expect(cache.activeTripId, 'trip_prev');
      expect(cache.lastLatitude, closeTo(6.5244, 0.0001));
      expect(cache.lastLongitude, closeTo(3.3792, 0.0001));
      expect(cache.mapProvider, 'google');
    });

    test('stale snapshot older than 8 hours is ignored on hydration', () async {
      // Timestamp > 8 hours ago.
      final staleMs =
          DateTime.now().millisecondsSinceEpoch - const Duration(hours: 9).inMilliseconds;
      SharedPreferences.setMockInitialValues({
        'sese_dsc_isOnline': true,
        'sese_dsc_driverUid': 'uid_stale',
        'sese_dsc_savedAtMs': staleMs,
      });

      final prefs = await SharedPreferences.getInstance();
      final cache = DriverSessionCache.instance;
      cache.initFromPrefs(prefs);

      // Stale snapshot — cache must stay at safe defaults (not hydrate online).
      expect(cache.isOnline, isFalse);
      expect(cache.driverUid, isEmpty);
    });
  });

  group('DriverSessionCache — splash-bypass logic', () {
    // Mirrors the logic in main.dart:
    //   final showSplash = !hasPendingOffer && !hasCachedOnlineSession;
    bool computeShowSplash({
      required bool hasPendingOffer,
      required bool hasCachedOnlineSession,
    }) =>
        !hasPendingOffer && !hasCachedOnlineSession;

    test('showSplash is false when driver UID is set and isOnline is true',
        () async {
      final cache = DriverSessionCache.instance;
      await cache.init();

      cache.saveSessionState(
        isOnline: true,
        driverUid: 'uid_driver',
        sessionId: 'sess',
      );

      final hasCachedOnlineSession =
          cache.isOnline && cache.driverUid.isNotEmpty;
      final showSplash = computeShowSplash(
        hasPendingOffer: false,
        hasCachedOnlineSession: hasCachedOnlineSession,
      );

      expect(hasCachedOnlineSession, isTrue);
      expect(showSplash, isFalse,
          reason: 'Splash must be bypassed for online driver cold-start');
    });

    test('showSplash is true when driver is offline', () async {
      final cache = DriverSessionCache.instance;
      await cache.init();

      cache.saveSessionState(
        isOnline: false,
        driverUid: 'uid_driver',
        sessionId: '',
      );

      final hasCachedOnlineSession =
          cache.isOnline && cache.driverUid.isNotEmpty;
      final showSplash = computeShowSplash(
        hasPendingOffer: false,
        hasCachedOnlineSession: hasCachedOnlineSession,
      );

      expect(showSplash, isTrue,
          reason: 'Offline driver must still see splash on fresh launch');
    });

    test('showSplash is false when there is a pending FCM offer (regardless of online state)',
        () async {
      final cache = DriverSessionCache.instance;
      await cache.init();
      // Driver offline in cache.
      cache.saveSessionState(
          isOnline: false, driverUid: 'uid_driver', sessionId: '');

      final hasCachedOnlineSession =
          cache.isOnline && cache.driverUid.isNotEmpty;
      final showSplash = computeShowSplash(
        hasPendingOffer: true,
        hasCachedOnlineSession: hasCachedOnlineSession,
      );

      expect(showSplash, isFalse,
          reason: 'Pending FCM offer always bypasses splash');
    });
  });
}
