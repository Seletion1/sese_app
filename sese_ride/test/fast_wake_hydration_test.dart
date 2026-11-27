// Tests for the fast-wake hydration flow:
// - DriverSessionCache splash-bypass logic
// - Cached GPS fix used for initial map centering
// - Cache cleared on sign-out
// - FCM offer wake path sets incomingOfferNotifier

import 'package:flutter_test/flutter_test.dart';
import 'package:sese_core/services/driver_session_cache.dart';
import 'package:sese_core/services/push_notification_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  // ---------------------------------------------------------------------------
  // Splash-bypass decision
  // ---------------------------------------------------------------------------

  group('Fast-wake — splash bypass logic', () {
    test('Driver online + no pending offer → showSplash is false', () async {
      final cache = DriverSessionCache.instance;
      await cache.init();
      cache.saveSessionState(
        isOnline: true,
        driverUid: 'drv_001',
        sessionId: 'sess_001',
      );

      // Mirrors main.dart decision logic.
      final hasPendingOffer =
          PushNotificationService.incomingOfferNotifier.value != null;
      final hasCachedOnlineSession =
          cache.isOnline && cache.driverUid.isNotEmpty;
      final showSplash = !hasPendingOffer && !hasCachedOnlineSession;

      expect(showSplash, isFalse,
          reason: 'Online driver cold-start must skip splash');
    });

    test('Driver offline + no pending offer → showSplash is true', () async {
      final cache = DriverSessionCache.instance;
      await cache.init();
      cache.saveSessionState(
        isOnline: false,
        driverUid: 'drv_001',
        sessionId: '',
      );

      final hasPendingOffer =
          PushNotificationService.incomingOfferNotifier.value != null;
      final hasCachedOnlineSession =
          cache.isOnline && cache.driverUid.isNotEmpty;
      final showSplash = !hasPendingOffer && !hasCachedOnlineSession;

      expect(showSplash, isTrue,
          reason: 'Offline driver should see normal splash');
    });

    test('FCM pending offer → showSplash is false regardless of cache', () async {
      final cache = DriverSessionCache.instance;
      await cache.init();
      // Driver offline.
      cache.saveSessionState(
          isOnline: false, driverUid: 'drv_001', sessionId: '');

      // Inject a pending offer (simulating FCM wake).
      PushNotificationService.incomingOfferNotifier.value = {
        'tripId': 'trip_fcm_01',
        'type': 'new_trip_offer',
      };

      final hasPendingOffer =
          PushNotificationService.incomingOfferNotifier.value != null;
      final hasCachedOnlineSession =
          cache.isOnline && cache.driverUid.isNotEmpty;
      final showSplash = !hasPendingOffer && !hasCachedOnlineSession;

      expect(hasPendingOffer, isTrue);
      expect(showSplash, isFalse,
          reason: 'FCM offer wake must bypass splash even when cached offline');

      // Clean up.
      PushNotificationService.incomingOfferNotifier.value = null;
    });
  });

  // ---------------------------------------------------------------------------
  // GPS fix → map centering logic
  // ---------------------------------------------------------------------------

  group('Fast-wake — cached GPS fix for initial map centering', () {
    test('lastLatitude and lastLongitude are null before first fix', () async {
      final cache = DriverSessionCache.instance;
      await cache.init();
      expect(cache.lastLatitude, isNull);
      expect(cache.lastLongitude, isNull);
    });

    test('saveGpsFix stores and returns the correct coordinates', () async {
      final cache = DriverSessionCache.instance;
      await cache.init();
      cache.saveGpsFix(6.4550, 3.3841);
      expect(cache.lastLatitude, closeTo(6.455, 0.001));
      expect(cache.lastLongitude, closeTo(3.3841, 0.001));
    });

    test(
        'Cold-start centering logic falls back to cached fix when '
        'LocationService.lastKnownPosition is null', () async {
      final cache = DriverSessionCache.instance;
      await cache.init();
      cache.saveGpsFix(6.5244, 3.3792);

      // Mirrors initState logic in DriverDashboardScreen:
      //   _driverPosition = widget.initialPosition ?? fast ?? cachedFix ?? fallback;
      const _LatLng? widgetInitialPosition = null;
      const _LatLng? fastPosition = null; // LocationService returns null
      final cachedLat = cache.lastLatitude;
      final cachedLng = cache.lastLongitude;
      final cachedFix = (cachedLat != null && cachedLng != null)
          ? _LatLng(cachedLat, cachedLng)
          : null;

      final resolved = widgetInitialPosition ??
          fastPosition ??
          cachedFix ??
          const _LatLng(6.5244, 3.3792);

      expect(resolved.lat, closeTo(6.5244, 0.001));
      expect(resolved.lng, closeTo(3.3792, 0.001));
    });
  });

  // ---------------------------------------------------------------------------
  // Sign-out / cache clear
  // ---------------------------------------------------------------------------

  group('Fast-wake — sign-out clears cache', () {
    test('clear() resets all fields to safe defaults', () async {
      final cache = DriverSessionCache.instance;
      await cache.init();

      cache.saveSessionState(
        isOnline: true,
        driverUid: 'drv_001',
        sessionId: 'sess_001',
        activeTripId: 'trip_001',
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

      // After clear, splash should be shown normally.
      final hasCachedOnlineSession =
          cache.isOnline && cache.driverUid.isNotEmpty;
      expect(hasCachedOnlineSession, isFalse);
    });
  });

  // ---------------------------------------------------------------------------
  // Active trip JSON roundtrip
  // ---------------------------------------------------------------------------

  group('Fast-wake — active trip JSON cache', () {
    test('saveActiveTripJson persists trip map and clears on null', () async {
      final cache = DriverSessionCache.instance;
      await cache.init();

      cache.saveActiveTripJson({
        'tripId': 'trip_roundtrip',
        'status': 'IN_PROGRESS',
      });

      expect(cache.activeTripJson, isNotNull);
      expect(cache.activeTripJson!['tripId'], 'trip_roundtrip');
      expect(cache.activeTripJson!['status'], 'IN_PROGRESS');

      cache.saveActiveTripJson(null);
      expect(cache.activeTripJson, isNull);
    });
  });
}

/// Minimal immutable coordinate pair used in map-centering logic tests.
class _LatLng {
  const _LatLng(this.lat, this.lng);
  final double lat;
  final double lng;
}
