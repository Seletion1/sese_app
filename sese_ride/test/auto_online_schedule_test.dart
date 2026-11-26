import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:sese_ride/features/driver/services/auto_schedule_service.dart';
import 'package:sese_ride/features/settings/auto_online_schedule_card.dart';

// ─── Fake service ─────────────────────────────────────────────────────────────

class _FakeAutoScheduleService extends AutoScheduleService {
  AutoSchedulePrefs _stored;
  final List<AutoSchedulePrefs> saveLog = [];
  String? errorToThrow;

  _FakeAutoScheduleService({AutoSchedulePrefs initial = const AutoSchedulePrefs()})
      : _stored = initial;

  @override
  Stream<AutoSchedulePrefs> prefsStream(String uid) => Stream.value(_stored);

  @override
  Future<AutoSchedulePrefs> fetchPrefs(String uid) async => _stored;

  @override
  Future<void> savePrefs(String uid, AutoSchedulePrefs prefs) async {
    if (errorToThrow != null) throw AutoScheduleException(errorToThrow!);
    _stored = prefs;
    saveLog.add(prefs);
  }
}

// ─── Widget helper ───────────────────────────────────────────────────────────

Widget _wrap(Widget child) {
  return MaterialApp(
    home: Scaffold(body: SingleChildScrollView(child: child)),
  );
}

// ─── Tests ───────────────────────────────────────────────────────────────────

void main() {
  group('AutoSchedulePrefs', () {
    test('defaults when map is null', () {
      final p = AutoSchedulePrefs.fromMap(null);
      expect(p.enabled, isTrue);
      expect(p.autoOnlineTime, '06:00');
      expect(p.autoOfflineTime, '22:00');
    });

    test('defaults when autoScheduleEnabled is absent (null)', () {
      final p = AutoSchedulePrefs.fromMap({'autoOnlineTime': '07:00'});
      expect(p.enabled, isTrue); // null → true (platform default)
      expect(p.autoOnlineTime, '07:00');
    });

    test('disabled when autoScheduleEnabled is false', () {
      final p = AutoSchedulePrefs.fromMap({'autoScheduleEnabled': false});
      expect(p.enabled, isFalse);
    });

    test('toMap round-trips', () {
      const original = AutoSchedulePrefs(
        enabled: false,
        autoOnlineTime: '08:30',
        autoOfflineTime: '21:00',
      );
      final restored = AutoSchedulePrefs.fromMap(original.toMap());
      expect(restored, equals(original));
    });

    test('copyWith preserves unchanged fields', () {
      const p = AutoSchedulePrefs(
        enabled: true,
        autoOnlineTime: '06:00',
        autoOfflineTime: '22:00',
      );
      final updated = p.copyWith(enabled: false);
      expect(updated.enabled, isFalse);
      expect(updated.autoOnlineTime, '06:00');
      expect(updated.autoOfflineTime, '22:00');
    });

    test('equality holds', () {
      expect(const AutoSchedulePrefs(), const AutoSchedulePrefs());
    });

    test('inequality on differing fields', () {
      expect(
        const AutoSchedulePrefs(autoOnlineTime: '06:00'),
        isNot(const AutoSchedulePrefs(autoOnlineTime: '07:00')),
      );
    });
  });

  group('AutoScheduleService', () {
    test('savePrefs logs the correct prefs', () async {
      final svc = _FakeAutoScheduleService();
      const prefs = AutoSchedulePrefs(
        enabled: true,
        autoOnlineTime: '07:00',
        autoOfflineTime: '21:00',
      );
      await svc.savePrefs('driver_1', prefs);
      expect(svc.saveLog, hasLength(1));
      expect(svc.saveLog.first, equals(prefs));
    });

    test('savePrefs throws AutoScheduleException on error', () async {
      final svc = _FakeAutoScheduleService()
        ..errorToThrow = 'Network failed.';
      expect(
        () => svc.savePrefs('driver_1', const AutoSchedulePrefs()),
        throwsA(isA<AutoScheduleException>()),
      );
    });

    test('fetchPrefs returns stored prefs', () async {
      final stored = const AutoSchedulePrefs(
        autoOnlineTime: '08:00',
        autoOfflineTime: '20:00',
      );
      final svc = _FakeAutoScheduleService(initial: stored);
      final fetched = await svc.fetchPrefs('driver_1');
      expect(fetched, equals(stored));
    });
  });

  group('AutoOnlineScheduleCard widget', () {
    testWidgets('renders with default prefs (enabled, 6 AM / 10 PM)', (tester) async {
      final svc = _FakeAutoScheduleService();
      await tester.pumpWidget(_wrap(
        AutoOnlineScheduleCard(driverId: 'uid_1', service: svc),
      ));
      await tester.pump(); // StreamBuilder tick

      expect(find.text('Auto Online Schedule'), findsOneWidget);
      expect(find.byKey(const Key('auto_schedule_toggle')), findsOneWidget);
      expect(find.byKey(const Key('auto_online_time_tile')), findsOneWidget);
      expect(find.byKey(const Key('auto_offline_time_tile')), findsOneWidget);
      // Default 6:00 AM label
      expect(find.text('6:00 AM'), findsOneWidget);
      // Default 10:00 PM label
      expect(find.text('10:00 PM'), findsOneWidget);
    });

    testWidgets('toggle OFF saves disabled prefs', (tester) async {
      final svc = _FakeAutoScheduleService();
      await tester.pumpWidget(_wrap(
        AutoOnlineScheduleCard(driverId: 'uid_1', service: svc),
      ));
      await tester.pump();

      final toggle = find.byKey(const Key('auto_schedule_toggle'));
      expect(tester.widget<Switch>(toggle).value, isTrue);

      await tester.tap(toggle);
      await tester.pumpAndSettle();

      expect(svc.saveLog, hasLength(1));
      expect(svc.saveLog.first.enabled, isFalse);
    });

    testWidgets('time tiles are disabled when schedule is OFF', (tester) async {
      final svc = _FakeAutoScheduleService(
        initial: const AutoSchedulePrefs(enabled: false),
      );
      await tester.pumpWidget(_wrap(
        AutoOnlineScheduleCard(driverId: 'uid_1', service: svc),
      ));
      await tester.pump();

      // The IgnorePointer wrapper should prevent taps on time tiles
      final onlineTile = find.byKey(const Key('auto_online_time_tile'));
      await tester.tap(onlineTile, warnIfMissed: false);
      await tester.pumpAndSettle();

      // No save should have been triggered from the tile tap
      expect(svc.saveLog, isEmpty);
    });

    testWidgets('shows error snackbar on save failure', (tester) async {
      final svc = _FakeAutoScheduleService()
        ..errorToThrow = 'Server unavailable.';
      await tester.pumpWidget(_wrap(
        AutoOnlineScheduleCard(driverId: 'uid_1', service: svc),
      ));
      await tester.pump();

      final toggle = find.byKey(const Key('auto_schedule_toggle'));
      await tester.tap(toggle);
      await tester.pumpAndSettle();

      expect(find.text('Server unavailable.'), findsOneWidget);
    });

    testWidgets('renders custom online/offline times from stored prefs',
        (tester) async {
      final svc = _FakeAutoScheduleService(
        initial: const AutoSchedulePrefs(
          enabled: true,
          autoOnlineTime: '08:00',
          autoOfflineTime: '20:30',
        ),
      );
      await tester.pumpWidget(_wrap(
        AutoOnlineScheduleCard(driverId: 'uid_1', service: svc),
      ));
      await tester.pump();

      expect(find.text('8:00 AM'), findsOneWidget);
      expect(find.text('8:30 PM'), findsOneWidget);
    });

    testWidgets('info footer visible when schedule is ON', (tester) async {
      final svc = _FakeAutoScheduleService();
      await tester.pumpWidget(_wrap(
        AutoOnlineScheduleCard(driverId: 'uid_1', service: svc),
      ));
      await tester.pump();

      expect(
        find.textContaining('manually go Offline'),
        findsOneWidget,
      );
    });

    testWidgets('info footer hidden when schedule is OFF', (tester) async {
      final svc = _FakeAutoScheduleService(
        initial: const AutoSchedulePrefs(enabled: false),
      );
      await tester.pumpWidget(_wrap(
        AutoOnlineScheduleCard(driverId: 'uid_1', service: svc),
      ));
      await tester.pump();

      expect(find.textContaining('manually go Offline'), findsNothing);
    });
  });
}
