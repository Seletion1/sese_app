import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sese_core/sese_core.dart';

void main() {
  group('NetworkStatusService & Banner Tests', () {
    test('NetworkStatusService starts online and tracks checking state', () async {
      final service = NetworkStatusService.instance;
      expect(service.isOnline.value, isTrue);
      expect(service.isChecking.value, isFalse);

      service.isOnline.value = false;
      expect(service.isOnline.value, isFalse);

      service.isOnline.value = true;
      expect(service.isOnline.value, isTrue);
    });

    testWidgets('NetworkStatusBanner renders when offline and triggers refresh',
        (tester) async {
      final service = NetworkStatusService.instance;
      service.reachabilityChecker = () async => true;
      addTearDown(() {
        service.reachabilityChecker = null;
      });
      service.isOnline.value = false;
      service.isChecking.value = false;

      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: NetworkStatusBannerWrapper(
              child: Center(child: Text('Home Content')),
            ),
          ),
        ),
      );
      await tester.pump();

      // Verify the warning banner content appears
      expect(find.text('Network unstable. Please check your connection'),
          findsOneWidget);
      expect(find.text('Refresh'), findsOneWidget);
      expect(find.text('Home Content'), findsOneWidget);

      // Tap Refresh button
      await tester.tap(find.byKey(const Key('network_banner_refresh_button')));
      await tester.pump();

      // Restore online status
      service.isOnline.value = true;
      await tester.pumpAndSettle();

      // Banner slides out
      expect(find.byType(NetworkStatusBanner), findsOneWidget);
    });

    test('OptimisticState executes successfully and can rollback', () async {
      int localState = 10;
      bool rolledBack = false;

      // 1. Successful optimistic action
      final res = await OptimisticState.execute<String, int>(
        currentValue: localState,
        optimisticValue: 20,
        onUpdate: (val) => localState = val,
        action: () async => 'success_result',
        onRollback: (prev, err) {},
      );

      expect(res, equals('success_result'));
      expect(localState, equals(20));

      // 2. Failing optimistic action triggers rollback
      final resFail = await OptimisticState.execute<String, int>(
        currentValue: localState,
        optimisticValue: 99,
        onUpdate: (val) => localState = val,
        action: () async => throw StateError('network_error'),
        onRollback: (prev, err) {
          rolledBack = true;
        },
        maxRetries: 0,
      );

      expect(resFail, isNull);
      expect(rolledBack, isTrue);
      expect(localState, equals(20)); // Rolled back to 20
    });

    test('NetworkStatusService forceResync triggers registered callbacks and emits onReconnected', () async {
      final service = NetworkStatusService.instance;
      bool callbackFired = false;
      final completer = Completer<void>();

      service.registerResyncCallback(() async {
        callbackFired = true;
      });

      final sub = service.onReconnected.listen((_) {
        if (!completer.isCompleted) completer.complete();
      });

      await service.forceResync();
      await completer.future.timeout(const Duration(seconds: 1));

      expect(callbackFired, isTrue);
      expect(completer.isCompleted, isTrue);
      await sub.cancel();
    });

    test('CancellationQueueService manages optimistic cancellation and retries on queue drain', () async {
      SharedPreferences.setMockInitialValues({});
      final queueService = CancellationQueueService.instance;
      queueService.clearForTest();

      const tripId = 'test_trip_abc_123';
      expect(queueService.isTripCancelled(tripId), isFalse);

      queueService.markCancelledLocally(tripId);
      expect(queueService.isTripCancelled(tripId), isTrue);

      bool executorCalled = false;
      queueService.cancellationExecutor = (req) async {
        if (req.tripId == tripId) {
          executorCalled = true;
        }
      };

      await queueService.enqueueCancellation(
        tripId: tripId,
        reason: 'customer_cancelled_test',
      );

      await queueService.processQueue();
      expect(executorCalled, isTrue);
      expect(queueService.queuedItems.isEmpty, isTrue);
    });
  });
}
