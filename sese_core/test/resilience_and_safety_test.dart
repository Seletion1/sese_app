import 'dart:async';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sese_core/sese_core.dart';

void main() {
  group('Safe Collection & Defensive JSON Parsing Tests', () {
    test('SafeListAccess handles empty and populated lists without throwing', () {
      final empty = <String>[];
      expect(empty.firstOrNull, isNull);
      expect(empty.lastOrNull, isNull);
      expect(empty.singleOrNull, isNull);
      expect(empty.getOrNull(0), isNull);
      expect(empty.getOrNull(5), isNull);
      expect(empty.getOrNull(-1), isNull);
      expect(empty.firstWhereOrNull((s) => s == 'item'), isNull);

      final populated = ['a', 'b', 'c'];
      expect(populated.firstOrNull, equals('a'));
      expect(populated.lastOrNull, equals('c'));
      expect(populated.singleOrNull, isNull);
      expect(populated.getOrNull(1), equals('b'));
      expect(populated.getOrNull(10), isNull);
      expect(populated.firstWhereOrNull((s) => s == 'b'), equals('b'));

      final single = ['only'];
      expect(single.singleOrNull, equals('only'));
      expect(single.firstOrNull, equals('only'));
    });

    test('SafeIterableAccess handles iterables safely', () {
      final Set<int> emptySet = {};
      expect(emptySet.safeFirst, isNull);
      expect(emptySet.safeLast, isNull);
      expect(emptySet.safeSingle, isNull);

      final Set<int> set = {10, 20, 30};
      expect(set.safeFirst, equals(10));
      expect(set.safeLast, equals(30));
      expect(set.safeSingle, isNull);
      expect(set.safeFirstWhere((i) => i == 20), equals(20));
      expect(set.safeFirstWhere((i) => i == 99), isNull);
    });

    test('safe_json defensive parsing coerces safely', () {
      expect(safeString(' hello '), equals('hello'));
      expect(safeString(null, fallback: 'default'), equals('default'));
      expect(safeString('', fallback: 'default'), equals('default'));

      expect(safeBool(true), isTrue);
      expect(safeBool('true'), isTrue);
      expect(safeBool('1'), isTrue);
      expect(safeBool(1), isTrue);
      expect(safeBool('false'), isFalse);
      expect(safeBool(0), isFalse);
      expect(safeBool(null, fallback: true), isTrue);

      expect(safeList<String>(['a', 'b']), equals(['a', 'b']));
      expect(safeList<int>([1, 'invalid', 3]), equals([1, 3]));
      expect(safeList<int>(null), isEmpty);

      expect(safeMap({'key': 'val'}), equals({'key': 'val'}));
      expect(safeMap(null), isEmpty);

      final now = DateTime.now();
      expect(safeDateTime(now), equals(now));
      expect(safeDateTime(now.millisecondsSinceEpoch)?.millisecondsSinceEpoch,
          equals(now.millisecondsSinceEpoch));
      expect(safeDateTime(null), isNull);
    });
  });

  group('SafeStreamBuilder & Error Boundary Tests', () {
    testWidgets('renders loading widget when data is waiting', (tester) async {
      final controller = StreamController<String>();

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SafeStreamBuilder<String>(
              stream: controller.stream,
              loadingWidget: const Text('Custom Loading...'),
              builder: (context, data) => Text('Data: $data'),
            ),
          ),
        ),
      );

      expect(find.text('Custom Loading...'), findsOneWidget);
      await controller.close();
    });

    testWidgets('renders data when stream yields successfully', (tester) async {
      final controller = StreamController<String>();

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SafeStreamBuilder<String>(
              stream: controller.stream,
              builder: (context, data) => Text('Data: $data'),
            ),
          ),
        ),
      );

      controller.add('System Ready');
      await tester.pump();

      expect(find.text('Data: System Ready'), findsOneWidget);
      await controller.close();
    });

    testWidgets('catches permission-denied FirebaseException gracefully',
        (tester) async {
      final controller = StreamController<String>();

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SafeStreamBuilder<String>(
              stream: controller.stream,
              builder: (context, data) => Text('Data: $data'),
            ),
          ),
        ),
      );

      controller.addError(
        FirebaseException(
          plugin: 'cloud_firestore',
          code: 'permission-denied',
          message: 'The caller does not have permission',
        ),
      );
      await tester.pump();

      expect(find.text('Syncing system configurations...'), findsOneWidget);
      await controller.close();
    });
  });

  group('NetworkTimeoutHelper Tests', () {
    test('withTimeout returns action value when within deadline', () async {
      final result = await NetworkTimeoutHelper.withTimeout(
        () async => 'success_result',
        timeout: const Duration(seconds: 2),
      );
      expect(result, equals('success_result'));
    });

    test('withTimeout returns fallback on TimeoutException', () async {
      final result = await NetworkTimeoutHelper.withTimeout<String>(
        () async {
          await Future.delayed(const Duration(milliseconds: 300));
          return 'slow_data';
        },
        timeout: const Duration(milliseconds: 10),
        fallback: 'cached_fallback_data',
        operationName: 'Fast test check',
      );
      expect(result, equals('cached_fallback_data'));
    });
  });
}
