import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sese_core/sese_core.dart';
import 'package:sese_ride/features/home/customer_home_shell.dart';
import 'package:sese_ride/features/trips/models/bid_models.dart';
import 'package:sese_ride/features/trips/models/trip_models.dart';
import 'package:sese_ride/features/trips/services/trip_service.dart';
import 'package:sese_ride/widgets/osm_map_view.dart';

class _FakeTripRepository implements TripRepository {
  final List<ActiveTrip> active;

  _FakeTripRepository({this.active = const []});

  @override
  Future<String> createTrip(TripDraft draft) async => 'trip-1';

  @override
  Stream<ActiveTrip?> tripStream(String tripId) => Stream.value(
        active.isEmpty
            ? null
            : active.firstWhere(
                (t) => t.tripId == tripId,
                orElse: () => active.first,
              ),
      );

  @override
  Stream<List<ActiveTrip>> activeTripsStream(String customerId) =>
      Stream.value(active);

  @override
  Stream<List<ActiveTrip>> userTripHistoryStream(String userId, {bool isDriver = false}) =>
      Stream.value(active);

  @override
  Future<void> cancelTrip(String tripId, {String? reason, bool useCashSettlement = false}) async {}

  @override
  Future<void> confirmCashCancellation(String tripId, {bool cashCollected = true}) async {}

  @override
  Future<void> submitBid(String tripId, double offeredFare, {int? etaMinutes}) async {}

  @override
  Future<void> rejectBid(String tripId, String driverId) async {}

  @override
  Future<void> acceptBid(String tripId, String driverId) async {}

  @override
  Future<void> increaseTripFare(String tripId, double newFare) async {}

  @override
  Future<void> reassignTrip(String tripId, {double? newFare}) async {}

  @override
  Future<void> keepSearchingTrip(String tripId) async {}

  @override
  Stream<List<BidModel>> bidsStream(String tripId) => Stream.value(const []);

  @override
  Stream<BidModel?> activeDriverBidStream(String driverId) =>
      Stream.value(null);

  @override
  Stream<BidModel?> driverBidForTripStream(String tripId, String driverId) =>
      Stream.value(null);
}

AppUser _user() => AppUser(
      uid: 'cust-1',
      fullName: 'Test Rider',
      email: 'rider@example.com',
      phoneNumber: '08012345678',
      role: UserRole.customer,
      createdAt: DateTime(2024),
    );

void main() {
  setUp(() {
    OsmMapView.debugTileProviderOverride = BlankTileProvider();
  });

  tearDown(() {
    OsmMapView.debugTileProviderOverride = null;
  });

  group('CustomerHomeShell bottom navigation', () {
    Future<void> pumpShell(
      WidgetTester tester, {
      List<ActiveTrip> active = const [],
    }) async {
      await tester.pumpWidget(
        MaterialApp(
          home: CustomerHomeShell(
            user: _user(),
            auth: const StubAuthRepository(),
            tripRepository: _FakeTripRepository(active: active),
          ),
        ),
      );
      if (active.isEmpty) {
        await tester.pumpAndSettle();
      } else {
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 200));
      }
    }

    testWidgets('defaults to Home map tab with booking cards', (tester) async {
      await pumpShell(tester);

      expect(find.text('Book Ride'), findsOneWidget);
      expect(find.text('Trips'), findsOneWidget); // bottom nav labels
      expect(find.text('Profile'), findsOneWidget);
      expect(find.byIcon(Icons.menu), findsNothing); // no hamburger
    });

    testWidgets('Trips tab shows empty state with no active trips',
        (tester) async {
      await pumpShell(tester);

      await tester.tap(find.text('Trips'));
      await tester.pumpAndSettle();

      expect(find.text('No trips available yet'), findsOneWidget);
    });

    testWidgets('Trips tab restores a live server-side request',
        (tester) async {
      await pumpShell(
        tester,
        active: [
          const ActiveTrip(
            tripId: 'trip-live-9',
            status: TripStatus.waitingForAcceptance,
            customerId: 'cust-1',
            pickupAddress: 'Ikorodu, Lagos State',
          ),
        ],
      );

      await tester.tap(find.text('Trips'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));

      expect(find.text('Ikorodu, Lagos State'), findsOneWidget);

      // Tapping re-opens live tracking (fixed pump: the live banner
      // spinner animates forever, so pumpAndSettle would time out).
      await tester.tap(find.text('Ikorodu, Lagos State'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));
      expect(find.text('Live Trip'), findsOneWidget);
      expect(find.byKey(const Key('live_trip_status')), findsOneWidget);
    });

    testWidgets('Profile tab shows account details and settings entry',
        (tester) async {
      await pumpShell(tester);

      await tester.tap(find.text('Profile'));
      await tester.pumpAndSettle();

      expect(find.text('Test Rider'), findsOneWidget);
      expect(find.text('rider@example.com'), findsOneWidget);
      // Sign-out/theme/delete moved to Settings; profile links there.
      expect(find.text('Sign Out'), findsNothing);
      expect(find.byKey(const Key('customer_settings_tile')),
          findsOneWidget);

      await tester.ensureVisible(
          find.byKey(const Key('customer_settings_tile')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('customer_settings_tile')));
      await tester.pumpAndSettle();
      expect(find.text('Settings'), findsWidgets);
      await tester.scrollUntilVisible(find.text('Sign Out'), 50);
      expect(find.text('Sign Out'), findsOneWidget);
      await tester.scrollUntilVisible(find.text('Delete Account'), 50);
      expect(find.text('Delete Account'), findsOneWidget);
    });

    testWidgets('Customer tabs navigate back step-by-step to Home, Home gate confirms exit',
        (tester) async {
      await pumpShell(tester);

      // Start on Home map
      expect(find.text('Book Ride'), findsOneWidget);

      // Navigate: Home -> Profile
      await tester.tap(find.text('Profile'));
      await tester.pumpAndSettle();
      expect(find.text('Test Rider'), findsOneWidget);

      // Navigate: Profile -> Trips
      await tester.tap(find.text('Trips'));
      await tester.pumpAndSettle();
      expect(find.text('No trips available yet'), findsOneWidget);

      // Back 1: Trips -> Profile
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.text('Test Rider'), findsOneWidget);

      // Back 2: Profile -> Home
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.text('Book Ride'), findsOneWidget);

      // Back 3 on Home: safe exit gate confirmation
      await tester.binding.handlePopRoute();
      await tester.pump();
      expect(find.text('Press back again to exit'), findsOneWidget);
      expect(find.text('Book Ride'), findsOneWidget);
    });
  });
}
