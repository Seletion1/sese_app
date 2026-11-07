import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
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
  });
}
