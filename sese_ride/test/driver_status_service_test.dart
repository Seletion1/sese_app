import 'package:flutter_test/flutter_test.dart';
import 'package:sese_ride/features/driver/services/driver_status_service.dart';

/// In-memory backend: no Firebase, deterministic grants.
class _FakeBackend implements DriverStatusBackend {
  int goOnlineCalls = 0;
  int goOfflineCalls = 0;
  bool grantOnline = true;
  bool confirmOffline = true;

  @override
  Future<Map<String, dynamic>> callGoOnline(
    String idToken, {
    required String driverId,
    required Map<String, dynamic> fix,
  }) async {
    goOnlineCalls++;
    return {
      'granted': grantOnline,
      'status': grantOnline ? 'active' : 'denied',
      'message': grantOnline ? 'Online verified by server.' : 'Suspended.',
    };
  }

  @override
  Future<Map<String, dynamic>> callGoOffline({
    required String driverId,
  }) async {
    goOfflineCalls++;
    return {
      'granted': confirmOffline,
      'confirmed': confirmOffline,
      'status': confirmOffline ? 'offline' : 'on_trip',
      'message': confirmOffline ? '' : 'Trip in progress.',
    };
  }
}

DriverGpsFix _fix({double accuracy = 10, bool mocked = false}) => DriverGpsFix(
      latitude: 6.5244,
      longitude: 3.3792,
      accuracyMeters: accuracy,
      timestamp: DateTime.now(),
      isMocked: mocked,
    );

DriverStatusService _service(_FakeBackend backend) => DriverStatusService(
      backend: backend,
      idTokenProvider: () async => 'test-token',
    );

void main() {
  group('DriverStatusService zero-trust handshake', () {
    test('grants online on server approval and forwards signed fix', () async {
      final backend = _FakeBackend();
      final decision = await _service(backend).requestGoOnline(
        driverId: 'd1',
        fix: _fix(),
      );

      expect(decision.granted, isTrue);
      expect(decision.status, 'active');
      expect(backend.goOnlineCalls, 1);
    });

    test('rejects spoofed fix before any backend call', () async {
      final backend = _FakeBackend();

      expect(
        () => _service(backend).requestGoOnline(
          driverId: 'd1',
          fix: _fix(mocked: true),
        ),
        throwsA(isA<DriverStatusException>().having(
          (e) => e.code,
          'code',
          'gps-spoofed',
        )),
      );
      expect(backend.goOnlineCalls, 0);
    });

    test('rejects low-accuracy fix before any backend call', () async {
      final backend = _FakeBackend();

      expect(
        () => _service(backend).requestGoOnline(
          driverId: 'd1',
          fix: _fix(accuracy: 500),
        ),
        throwsA(isA<DriverStatusException>().having(
          (e) => e.code,
          'code',
          'gps-inaccurate',
        )),
      );
      expect(backend.goOnlineCalls, 0);
    });

    test('surfaces server denial without granting', () async {
      final backend = _FakeBackend()..grantOnline = false;
      final decision = await _service(backend).requestGoOnline(
        driverId: 'd1',
        fix: _fix(),
      );

      expect(decision.granted, isFalse);
    });

    test('requires auth token before calling backend', () async {
      final backend = _FakeBackend();
      final service = DriverStatusService(
        backend: backend,
        idTokenProvider: () async => null,
      );

      expect(
        () => service.requestGoOnline(driverId: 'd1', fix: _fix()),
        throwsA(isA<DriverStatusException>().having(
          (e) => e.code,
          'code',
          'unauthenticated',
        )),
      );
      expect(backend.goOnlineCalls, 0);
    });

    test('confirms offline on server acknowledgement', () async {
      final backend = _FakeBackend();
      final decision =
          await _service(backend).requestGoOffline(driverId: 'd1');

      expect(decision.granted, isTrue);
      expect(backend.goOfflineCalls, 1);
    });

    test('keeps online state when server refuses offline (mid-ride)', () async {
      final backend = _FakeBackend()..confirmOffline = false;
      final decision =
          await _service(backend).requestGoOffline(driverId: 'd1');

      expect(decision.granted, isFalse);
      expect(decision.message, 'Trip in progress.');
    });
  });
}
