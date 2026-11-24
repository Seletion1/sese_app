import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sese_core/sese_core.dart';
import 'package:sese_ride/features/driver/presentation/widgets/driver_active_trip_card.dart';
import 'package:sese_ride/features/driver/services/driver_dispatch_service.dart';
import 'package:sese_ride/features/trips/models/trip_models.dart';

class _MockCancellingStreakService implements DriverStreakService {
  @override
  Future<void> advanceTripStatus(String tripId, String nextStatus) async {
    throw const DriverStreakException(
        'failed-precondition', 'Trip has been cancelled by customer.');
  }

  @override
  Future<void> advanceTripStatusWithLocation(String tripId, String nextStatus,
      {double? driverLat, double? driverLng}) async {
    throw const DriverStreakException(
        'failed-precondition', 'Trip has been cancelled by customer.');
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('Network State Restoration, Resync & Optimistic Cancellation Tests', () {
    setUp(() {
      SharedPreferences.setMockInitialValues({});
      CancellationQueueService.instance.clearForTest();
    });

    test('CancellationQueueService marks trip cancelled locally and queues for background retry', () async {
      final queue = CancellationQueueService.instance;
      const tripId = 'trip_optimistic_999';

      expect(queue.isTripCancelled(tripId), isFalse);

      queue.markCancelledLocally(tripId);
      expect(queue.isTripCancelled(tripId), isTrue);

      bool executed = false;
      queue.cancellationExecutor = (req) async {
        if (req.tripId == tripId) {
          executed = true;
        }
      };

      await queue.enqueueCancellation(
        tripId: tripId,
        reason: 'passenger_cancelled',
        useCashSettlement: false,
      );

      await queue.processQueue();
      expect(executed, isTrue);
      expect(queue.queuedItems.isEmpty, isTrue);
    });

    test('NetworkStatusService onReconnected fires and drains queue automatically', () async {
      final queue = CancellationQueueService.instance;
      await queue.init();

      const tripId = 'trip_reconnect_retry_101';
      bool executorCalled = false;
      final completer = Completer<void>();

      queue.cancellationExecutor = (req) async {
        if (req.tripId == tripId) {
          executorCalled = true;
          if (!completer.isCompleted) completer.complete();
        }
      };

      await queue.enqueueCancellation(
        tripId: tripId,
        reason: 'network_retry_test',
      );

      // Force network reconnection
      await NetworkStatusService.instance.forceResync();
      await completer.future.timeout(const Duration(seconds: 2));

      expect(executorCalled, isTrue);
    });

    testWidgets('DriverActiveTripCard triggers onOrphanedTripPurge when server reports trip cancelled',
        (tester) async {
      final mockStreak = _MockCancellingStreakService();
      bool purged = false;

      final testTrip = ActiveTrip(
        tripId: 'trip_dead_123',
        status: TripStatus.driverArrived,
        customerId: 'cust_abc',
        customerName: 'Test Customer',
        pickupAddress: 'Pickup Point',
        dropoffAddress: 'Dropoff Point',
        fareAmount: 3500,
        fareFormatted: '₦3,500',
        paymentMethod: 'wallet',
        serviceType: 'ride',
        vehicleCategory: 'car',
      );

      await tester.pumpWidget(
        MaterialApp(
          home: MediaQuery(
            data: const MediaQueryData(size: Size(800, 1200)),
            child: Scaffold(
              body: SizedBox(
                height: 1200,
                width: 800,
                child: DriverActiveTripCard(
                  trip: testTrip,
                  streakService: mockStreak,
                  onOrphanedTripPurge: () {
                    purged = true;
                  },
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Drag slide-to-action track to trigger advanceTripStatus
      await tester.drag(
        find.byKey(const Key('slide_to_action_track')),
        const Offset(700, 0),
      );
      await tester.pumpAndSettle();

      // Invariant: purged callback was triggered because trip is dead/cancelled
      expect(purged, isTrue);
      expect(find.text('Trip has been cancelled by customer.'), findsOneWidget);
    });
  });
}
