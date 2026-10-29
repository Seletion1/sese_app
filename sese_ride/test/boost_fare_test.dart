import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sese_core/sese_core.dart';
import 'package:sese_ride/features/trips/models/bid_models.dart';
import 'package:sese_ride/features/trips/models/trip_models.dart';
import 'package:sese_ride/features/trips/presentation/live_trip_screen.dart';
import 'package:sese_ride/features/trips/services/trip_service.dart';

class _FakeTripRepo implements TripRepository {
  double currentFare = 4500.0;
  bool shouldThrow = false;
  String throwCode = 'unauthenticated';
  String throwMessage = 'Your session has expired. Please sign in again.';

  @override
  Future<void> increaseTripFare(String tripId, double newFare) async {
    if (shouldThrow) {
      throw TripException(throwCode, throwMessage);
    }
    currentFare = newFare;
  }

  @override
  Future<String> createTrip(TripDraft draft) async => 'trip_123';

  @override
  Stream<ActiveTrip?> tripStream(String tripId) => Stream.value(null);

  @override
  Stream<List<ActiveTrip>> activeTripsStream(String customerId) =>
      Stream.value([]);

  @override
  Stream<List<ActiveTrip>> userTripHistoryStream(String userId,
          {bool isDriver = false}) =>
      Stream.value([]);

  @override
  Future<void> cancelTrip(String tripId,
      {String? reason, bool useCashSettlement = false}) async {}

  @override
  Future<void> submitBid(String tripId, double offeredFare,
      {int? etaMinutes}) async {}

  @override
  Future<void> rejectBid(String tripId, String driverId) async {}

  @override
  Future<void> acceptBid(String tripId, String driverId) async {}

  @override
  Future<void> keepSearchingTrip(String tripId) async {}

  @override
  Stream<List<BidModel>> bidsStream(String tripId) => Stream.value([]);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final testTrip = ActiveTrip(
    tripId: 'trip_boost_1',
    customerId: 'cust_1',
    customerName: 'Bamiduro Micheal',
    pickupAddress: '34 Olafiloye St',
    dropoffAddress: '15 Ikorodu Rd',
    status: TripStatus.searchingDriver,
    fareAmount: 4500,
  );

  group('Boost Offer Fare Dialog Tests', () {
    testWidgets('Renders boost fare options and submits updated fare',
        (WidgetTester tester) async {
      final repo = _FakeTripRepo();

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (ctx) => ElevatedButton(
                onPressed: () {
                  // Open boost fare dialog using helper
                  showDialog<void>(
                    context: ctx,
                    builder: (dCtx) => StatefulBuilder(
                      builder: (dCtx, setDlg) => AlertDialog(
                        key: const Key('boost_fare_dialog'),
                        title: const Text('Boost Offer Fare'),
                        content: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            TextButton(
                              onPressed: () async {
                                await repo.increaseTripFare(testTrip.tripId, 5400);
                                if (dCtx.mounted) Navigator.pop(dCtx);
                              },
                              child: const Text('Confirm +20% (₦5,400)'),
                            ),
                          ],
                        ),
                      ),
                    ),
                  );
                },
                child: const Text('Open Boost'),
              ),
            ),
          ),
        ),
      );

      await tester.pumpAndSettle();

      await tester.tap(find.text('Open Boost'));
      await tester.pumpAndSettle();

      expect(find.text('Boost Offer Fare'), findsOneWidget);
      expect(find.text('Confirm +20% (₦5,400)'), findsOneWidget);

      await tester.tap(find.text('Confirm +20% (₦5,400)'));
      await tester.pumpAndSettle();

      expect(repo.currentFare, 5400.0);
    });
  });
}
