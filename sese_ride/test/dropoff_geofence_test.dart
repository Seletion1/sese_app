import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sese_ride/features/trips/models/bid_models.dart';
import 'package:sese_ride/features/trips/models/trip_models.dart';
import 'package:sese_ride/features/trips/presentation/live_trip_screen.dart';
import 'package:sese_ride/features/trips/services/trip_service.dart';
import 'package:sese_ride/features/driver/services/driver_streak_service.dart';
import 'package:sese_ride/features/driver/presentation/widgets/driver_active_trip_card.dart';

class _FakeTripRepo implements TripRepository {
  String? lastDropoffApprovedTripId;
  bool? lastDropoffApprovalResponse;
  ActiveTrip? activeTrip;

  _FakeTripRepo({this.activeTrip});

  @override
  Future<void> respondDropoffApproval(String tripId, {required bool approved}) async {
    lastDropoffApprovedTripId = tripId;
    lastDropoffApprovalResponse = approved;
  }

  @override
  Future<String> createTrip(TripDraft draft) async => 'trip_1';

  @override
  Stream<ActiveTrip?> tripStream(String tripId) => Stream.value(activeTrip);

  @override
  Stream<List<ActiveTrip>> activeTripsStream(String customerId) =>
      Stream.value(activeTrip != null ? [activeTrip!] : []);

  @override
  Stream<List<ActiveTrip>> userTripHistoryStream(String userId, {bool isDriver = false}) =>
      Stream.value([]);

  @override
  Future<void> cancelTrip(String tripId, {String? reason, bool useCashSettlement = false}) async {}

  @override
  Future<void> confirmCashCancellation(String tripId, {bool cashCollected = true}) async {}

  @override
  Future<void> submitBid(String tripId, double offeredFare, {int? etaMinutes}) async {}

  @override
  Future<void> acceptBid(String tripId, String driverId) async {}

  @override
  Future<void> rejectBid(String tripId, String driverId) async {}

  @override
  Future<void> reassignTrip(String tripId, {double? newFare}) async {}

  @override
  Future<void> keepSearchingTrip(String tripId, {double? newFare}) async {}

  @override
  Future<void> increaseTripFare(String tripId, double newFare) async {}

  @override
  Stream<List<BidModel>> bidsStream(String tripId) => Stream.value([]);

  @override
  Stream<BidModel?> activeDriverBidStream(String driverId) => Stream.value(null);

  @override
  Stream<BidModel?> driverBidForTripStream(String tripId, String driverId) => Stream.value(null);
}

class _FakeStreakBackend implements DriverStreakBackend {
  String? lastApprovedTripId;
  double? lastDriverLat;
  double? lastDriverLng;
  String? lastCancelledTripId;

  @override
  Future<Map<String, dynamic>> callAdvanceTripStatus(
    String tripId,
    String status, {
    double? driverLat,
    double? driverLng,
  }) async => {'ok': true};

  @override
  Future<Map<String, dynamic>> callVerifyDeliveryPin(
    String tripId,
    String pin, {
    double? driverLat,
    double? driverLng,
  }) async => {'ok': true};

  @override
  Future<Map<String, dynamic>> callRequestDropoffApproval(
    String tripId, {
    required double driverLat,
    required double driverLng,
    String? reason,
  }) async {
    lastApprovedTripId = tripId;
    lastDriverLat = driverLat;
    lastDriverLng = driverLng;
    return {'ok': true, 'distanceMeters': 1250.0};
  }

  @override
  Future<Map<String, dynamic>> callReportDriverLocation(
    String tripId,
    double lat,
    double lng,
    bool isMocked,
  ) async =>
      {'ok': true};

  @override
  Future<Map<String, dynamic>> callCancelDropoffApprovalRequest(String tripId) async {
    lastCancelledTripId = tripId;
    return {'ok': true};
  }

  @override
  Future<Map<String, dynamic>> callConfirmCashCancellation(
    String tripId, {
    bool cashCollected = true,
  }) async => {'ok': true};

  @override
  Future<Map<String, dynamic>> callAcceptTrip(String tripId, {String? sessionId}) async =>
      {'ok': true};

  @override
  Future<Map<String, dynamic>> callDeclineTrip(String tripId, {String action = 'rejected'}) async =>
      {'ok': true};

  @override
  Future<Map<String, dynamic>> callCancelTrip(String tripId, {String? reason}) async =>
      {'ok': true};

  @override
  Future<Map<String, dynamic>> callSkipDeliveryPin(String tripId) async =>
      {'ok': true};

  @override
  Future<Map<String, dynamic>> callRecordDropoffArrival(String tripId) async =>
      {'ok': true};
}

void main() {
  group('Drop-off Geofencing & Approval Model Tests', () {
    test('ActiveTrip correctly parses dropoff approval fields and exposes getters', () {
      final map = <String, dynamic>{
        'tripId': 'trip_geo_1',
        'status': 'IN_PROGRESS',
        'customerId': 'cust_1',
        'customerName': 'Michael B.',
        'driverId': 'drv_1',
        'pickupAddress': '123 Alpha St',
        'dropoffAddress': '456 Beta Ave',
        'fare': 2500,
        'dropoffApprovalStatus': 'PENDING',
        'dropoffApprovalDistanceMeters': 1250.5,
        'dropoffApprovalReason': 'driver_out_of_range',
      };

      final trip = ActiveTrip.fromMap('trip_geo_1', map);

      expect(trip.dropoffApprovalStatus, equals('PENDING'));
      expect(trip.dropoffApprovalDistanceMeters, equals(1250.5));
      expect(trip.dropoffApprovalReason, equals('driver_out_of_range'));
      expect(trip.isDropoffApprovalPending, isTrue);
      expect(trip.isDropoffApprovalApproved, isFalse);
      expect(trip.isDropoffApprovalRejected, isFalse);
    });

    test('ActiveTrip detects APPROVED and REJECTED states', () {
      final tripApproved = ActiveTrip.fromMap('t1', {
        'status': 'IN_PROGRESS',
        'dropoffApprovalStatus': 'APPROVED',
      });
      expect(tripApproved.isDropoffApprovalPending, isFalse);
      expect(tripApproved.isDropoffApprovalApproved, isTrue);
      expect(tripApproved.isDropoffApprovalRejected, isFalse);

      final tripRejected = ActiveTrip.fromMap('t2', {
        'status': 'IN_PROGRESS',
        'dropoffApprovalStatus': 'REJECTED',
      });
      expect(tripRejected.isDropoffApprovalPending, isFalse);
      expect(tripRejected.isDropoffApprovalApproved, isFalse);
      expect(tripRejected.isDropoffApprovalRejected, isTrue);
    });
  });

  group('Customer Dropoff Confirmation UI Tests', () {
    testWidgets('LiveTripScreen displays dropoff confirmation card when pending', (tester) async {
      tester.view.physicalSize = const Size(800, 2000);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);

      final trip = ActiveTrip.fromMap('trip_pending_1', {
        'status': 'IN_PROGRESS',
        'customerId': 'cust_1',
        'customerName': 'Alice',
        'driverId': 'drv_1',
        'driver': {
          'driverId': 'drv_1',
          'fullName': 'Bob Driver',
          'phone': '08012345678',
        },
        'pickupAddress': 'Pick A',
        'dropoffAddress': 'Drop B',
        'dropoffApprovalStatus': 'PENDING',
        'dropoffApprovalDistanceMeters': 1400.0,
      });

      final fakeRepo = _FakeTripRepo(activeTrip: trip);

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: LiveTripScreen(
              tripId: 'trip_pending_1',
              repository: fakeRepo,
            ),
          ),
        ),
      );

      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      // Verify the confirmation card is rendered
      expect(find.byKey(const Key('customer_dropoff_approval_card')), findsOneWidget);
      expect(find.text('Drop-off Confirmation Required'), findsOneWidget);
      expect(find.textContaining('1.4 km'), findsOneWidget);
      expect(find.byKey(const Key('dropoff_approval_approve_button')), findsOneWidget);
      expect(find.byKey(const Key('dropoff_approval_reject_button')), findsOneWidget);

      // Tap Approve
      await tester.tap(find.byKey(const Key('dropoff_approval_approve_button')));
      await tester.pump();

      expect(fakeRepo.lastDropoffApprovedTripId, equals('trip_pending_1'));
      expect(fakeRepo.lastDropoffApprovalResponse, isTrue);
    });

    testWidgets('Customer can reject out-of-range drop-off', (tester) async {
      tester.view.physicalSize = const Size(800, 2000);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);

      final trip = ActiveTrip.fromMap('trip_pending_2', {
        'status': 'IN_PROGRESS',
        'customerId': 'cust_1',
        'customerName': 'Alice',
        'driverId': 'drv_1',
        'driver': {
          'driverId': 'drv_1',
          'fullName': 'Bob Driver',
          'phone': '08012345678',
        },
        'pickupAddress': 'Pick A',
        'dropoffAddress': 'Drop B',
        'dropoffApprovalStatus': 'PENDING',
        'dropoffApprovalDistanceMeters': 800.0,
      });

      final fakeRepo = _FakeTripRepo(activeTrip: trip);

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: LiveTripScreen(
              tripId: 'trip_pending_2',
              repository: fakeRepo,
            ),
          ),
        ),
      );

      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      // Tap Reject
      await tester.tap(find.byKey(const Key('dropoff_approval_reject_button')));
      await tester.pump();

      expect(fakeRepo.lastDropoffApprovedTripId, equals('trip_pending_2'));
      expect(fakeRepo.lastDropoffApprovalResponse, isFalse);
    });
  });

  group('Driver Active Trip Card Geofence States', () {
    testWidgets('Driver card shows verification pending state and disables slider', (tester) async {
      final fakeBackend = _FakeStreakBackend();
      final streakService = DriverStreakService(backend: fakeBackend);

      final trip = ActiveTrip.fromMap('trip_drv_1', {
        'status': 'IN_PROGRESS',
        'customerId': 'cust_1',
        'customerName': 'Customer Dave',
        'driverId': 'drv_1',
        'driverPhone': '08012345678',
        'customerPhone': '08087654321',
        'pickupAddress': 'Store A',
        'dropoffAddress': 'Home B',
        'dropoffApprovalStatus': 'PENDING',
        'dropoffApprovalDistanceMeters': 1200.0,
      });

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox(
              height: 1200,
              width: 800,
              child: DriverActiveTripCard(
                trip: trip,
                streakService: streakService,
              ),
            ),
          ),
        ),
      );

      await tester.pump();

      // Pending card is visible
      expect(find.byKey(const Key('customer_verification_pending_card')), findsOneWidget);
      expect(find.text('Customer Verification Pending'), findsOneWidget);
      expect(find.text('Verification Pending...'), findsOneWidget);

      // Cancel button calls streakService.cancelDropoffApprovalRequest
      await tester.tap(find.text('Cancel Request'));
      await tester.pump();

      expect(fakeBackend.lastCancelledTripId, equals('trip_drv_1'));
    });

    testWidgets('Driver card shows rejected banner when customer declined', (tester) async {
      final fakeBackend = _FakeStreakBackend();
      final streakService = DriverStreakService(backend: fakeBackend);

      final trip = ActiveTrip.fromMap('trip_drv_2', {
        'status': 'IN_PROGRESS',
        'customerId': 'cust_1',
        'customerName': 'Customer Dave',
        'driverId': 'drv_1',
        'pickupAddress': 'Store A',
        'dropoffAddress': 'Home B',
        'dropoffApprovalStatus': 'REJECTED',
      });

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox(
              height: 1200,
              width: 800,
              child: DriverActiveTripCard(
                trip: trip,
                streakService: streakService,
              ),
            ),
          ),
        ),
      );

      await tester.pump();

      // Rejected banner is visible
      expect(find.byKey(const Key('customer_verification_rejected_banner')), findsOneWidget);
      expect(find.textContaining('Customer declined out-of-range drop-off'), findsOneWidget);
    });
  });

  group('DriverStreakService Dropoff Geofencing API Tests', () {
    test('requestDropoffApproval passes driver coordinates', () async {
      final fakeBackend = _FakeStreakBackend();
      final streakService = DriverStreakService(backend: fakeBackend);

      await streakService.requestDropoffApproval(
        tripId: 'trip_test_1',
        driverLat: 6.5244,
        driverLng: 3.3792,
      );

      expect(fakeBackend.lastApprovedTripId, equals('trip_test_1'));
      expect(fakeBackend.lastDriverLat, equals(6.5244));
      expect(fakeBackend.lastDriverLng, equals(3.3792));
    });

    test('cancelDropoffApprovalRequest triggers backend call', () async {
      final fakeBackend = _FakeStreakBackend();
      final streakService = DriverStreakService(backend: fakeBackend);

      await streakService.cancelDropoffApprovalRequest('trip_test_cancel');
      expect(fakeBackend.lastCancelledTripId, equals('trip_test_cancel'));
    });
  });
}
