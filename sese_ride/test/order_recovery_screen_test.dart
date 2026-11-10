import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sese_ride/features/trips/models/bid_models.dart';
import 'package:sese_ride/features/trips/models/trip_models.dart';
import 'package:sese_ride/features/trips/presentation/live_trip_screen.dart';
import 'package:sese_ride/features/trips/services/trip_service.dart';

class _FakeRecoveryTripRepo implements TripRepository {
  String? lastReassignedTripId;
  double? lastReassignedNewFare;
  String? lastCancelledTripId;
  ActiveTrip? activeTrip;

  _FakeRecoveryTripRepo({this.activeTrip});

  @override
  Future<void> reassignTrip(String tripId, {double? newFare}) async {
    lastReassignedTripId = tripId;
    lastReassignedNewFare = newFare;
  }

  @override
  Future<void> keepSearchingTrip(String tripId, {double? newFare}) async {
    lastReassignedTripId = tripId;
    lastReassignedNewFare = newFare;
  }

  @override
  Future<void> increaseTripFare(String tripId, double newFare) async {}

  @override
  Future<String> createTrip(TripDraft draft) async => 'trip_recovery_1';

  @override
  Stream<ActiveTrip?> tripStream(String tripId) => Stream.value(activeTrip);

  @override
  Stream<List<ActiveTrip>> activeTripsStream(String customerId) =>
      Stream.value(activeTrip != null ? [activeTrip!] : []);

  @override
  Stream<List<ActiveTrip>> userTripHistoryStream(String userId,
          {bool isDriver = false}) =>
      Stream.value([]);

  @override
  Future<void> cancelTrip(String tripId,
      {String? reason, bool useCashSettlement = false}) async {
    lastCancelledTripId = tripId;
  }

  @override
  Future<void> confirmCashCancellation(String tripId) async {}

  @override
  Future<void> submitBid(String tripId, double offeredFare,
      {int? etaMinutes}) async {}

  @override
  Future<void> rejectBid(String tripId, String driverId) async {}

  @override
  Future<void> acceptBid(String tripId, String driverId) async {}

  @override
  Stream<List<BidModel>> bidsStream(String tripId) => Stream.value([]);

  @override
  Stream<BidModel?> activeDriverBidStream(String driverId) => Stream.value(null);

  @override
  Stream<BidModel?> driverBidForTripStream(String tripId, String driverId) =>
      Stream.value(null);
}

void main() {
  group('Order Lifecycle Timeout & Customer Recovery Workflow', () {
    testWidgets(
        'renders timeout recovery screen with friendly suggestion and 3-option layout',
        (tester) async {
      final trip = ActiveTrip(
        tripId: 'trip_expired_1',
        customerId: 'customer_1',
        customerName: 'Micheal',
        status: TripStatus.returnedToCustomer,
        fareAmount: 4000.0,
        fareFormatted: '₦4,000',
        pickupAddress: 'Victoria Island, Lagos',
        dropoffAddress: 'Lekki Phase 1, Lagos',
        pickupLat: 6.4281,
        pickupLng: 3.4219,
        dropoffLat: 6.4474,
        dropoffLng: 3.4723,
      );

      final repo = _FakeRecoveryTripRepo(activeTrip: trip);

      await tester.pumpWidget(
        MaterialApp(
          home: LiveTripScreen(
            tripId: trip.tripId,
            repository: repo,
          ),
        ),
      );

      await tester.pumpAndSettle();

      // 1. Verify timeout notification header & helpful suggestion
      expect(find.text('Order Returned to You'), findsOneWidget);
      expect(
        find.text(
            'Please increase the fare to catch nearby drivers\' attention.'),
        findsOneWidget,
      );

      // 2. Verify current fare display
      expect(find.text('₦4,000'), findsOneWidget);

      // 3. Verify Primary Actions
      // - Reassign / Retry
      expect(find.byKey(const Key('recovery_reassign_retry_button')),
          findsOneWidget);
      expect(find.text('Reassign / Retry'), findsOneWidget);

      // - Make Changes / Edit
      expect(
          find.byKey(const Key('recovery_make_changes_button')), findsOneWidget);
      expect(find.text('Make Changes / Edit'), findsOneWidget);

      // 4. Verify Quick Fixed-Price Suggestion Chips side-by-side
      // For ₦4,000 baseline, increments are +₦500 (₦4,500) and +₦1,000 (₦5,000)
      final chip1 = find.byKey(const Key('recovery_chip_4500'));
      final chip2 = find.byKey(const Key('recovery_chip_5000'));
      await tester.ensureVisible(chip1);
      await tester.pumpAndSettle();
      expect(chip1, findsOneWidget);
      expect(chip2, findsOneWidget);
      expect(find.text('₦4,500'), findsOneWidget);
      expect(find.text('₦5,000'), findsOneWidget);
      expect(find.text('+₦500'), findsOneWidget);
      expect(find.text('+₦1,000'), findsOneWidget);
    });

    testWidgets('tapping Reassign/Retry triggers reassign with current fare',
        (tester) async {
      final trip = ActiveTrip(
        tripId: 'trip_expired_2',
        customerId: 'customer_1',
        customerName: 'Micheal',
        status: TripStatus.expired,
        fareAmount: 4000.0,
        fareFormatted: '₦4,000',
        pickupAddress: 'Victoria Island, Lagos',
        dropoffAddress: 'Lekki Phase 1, Lagos',
        pickupLat: 6.4281,
        pickupLng: 3.4219,
        dropoffLat: 6.4474,
        dropoffLng: 3.4723,
      );

      final repo = _FakeRecoveryTripRepo(activeTrip: trip);

      await tester.pumpWidget(
        MaterialApp(
          home: LiveTripScreen(
            tripId: trip.tripId,
            repository: repo,
          ),
        ),
      );

      await tester.pumpAndSettle();

      // Tap Reassign / Retry
      final reassignBtn = find.byKey(const Key('recovery_reassign_retry_button'));
      await tester.ensureVisible(reassignBtn);
      await tester.pumpAndSettle();
      await tester.tap(reassignBtn);
      await tester.pump();

      expect(repo.lastReassignedTripId, 'trip_expired_2');
      expect(repo.lastReassignedNewFare, isNull);
    });

    testWidgets(
        'tapping quick fixed-price chip triggers instant one-tap reassignment with higher fare',
        (tester) async {
      final trip = ActiveTrip(
        tripId: 'trip_expired_3',
        customerId: 'customer_1',
        customerName: 'Micheal',
        status: TripStatus.returnedToCustomer,
        fareAmount: 4000.0,
        fareFormatted: '₦4,000',
        pickupAddress: 'Victoria Island, Lagos',
        dropoffAddress: 'Lekki Phase 1, Lagos',
        pickupLat: 6.4281,
        pickupLng: 3.4219,
        dropoffLat: 6.4474,
        dropoffLng: 3.4723,
      );

      final repo = _FakeRecoveryTripRepo(activeTrip: trip);

      await tester.pumpWidget(
        MaterialApp(
          home: LiveTripScreen(
            tripId: trip.tripId,
            repository: repo,
          ),
        ),
      );

      await tester.pumpAndSettle();

      // Ensure chip is visible in scrollview before tapping
      final chipFinder = find.byKey(const Key('recovery_chip_5000'));
      await tester.ensureVisible(chipFinder);
      await tester.pumpAndSettle();

      // Tap second chip: ₦5,000
      await tester.tap(chipFinder);
      await tester.pump();

      // Instant one-tap reassignment dispatched to backend!
      expect(repo.lastReassignedTripId, 'trip_expired_3');
      expect(repo.lastReassignedNewFare, 5000.0);
    });

    testWidgets(
        'Make Changes / Edit button is present and clickable in recovery screen',
        (tester) async {
      final trip = ActiveTrip(
        tripId: 'trip_expired_4',
        customerId: 'customer_1',
        customerName: 'Micheal',
        status: TripStatus.returnedToCustomer,
        fareAmount: 3000.0,
        fareFormatted: '₦3,000',
        pickupAddress: 'Ikeja, Lagos',
        dropoffAddress: 'Yaba, Lagos',
        pickupLat: 6.6018,
        pickupLng: 3.3515,
        dropoffLat: 6.5095,
        dropoffLng: 3.3711,
      );

      final repo = _FakeRecoveryTripRepo(activeTrip: trip);

      await tester.pumpWidget(
        MaterialApp(
          home: LiveTripScreen(
            tripId: trip.tripId,
            repository: repo,
          ),
        ),
      );

      await tester.pumpAndSettle();

      final makeChangesBtn =
          find.byKey(const Key('recovery_make_changes_button'));
      expect(makeChangesBtn, findsOneWidget);
    });
  });
}
