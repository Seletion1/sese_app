import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sese_core/sese_core.dart';
import 'package:sese_ride/features/trips/presentation/trip_rating_dialog.dart';
import 'package:sese_ride/features/trips/services/trip_rating_service.dart';

class _FakeRatingService implements TripRatingService {
  String? lastTripId;
  String? lastRaterId;
  String? lastRatedUserId;
  int? lastRating;
  String? lastComment;
  bool? lastIsDriver;

  @override
  Future<void> submitRating({
    required String tripId,
    required String raterId,
    required String ratedUserId,
    required int rating,
    String? comment,
    bool isRatedUserDriver = false,
  }) async {
    lastTripId = tripId;
    lastRaterId = raterId;
    lastRatedUserId = ratedUserId;
    lastRating = rating;
    lastComment = comment;
    lastIsDriver = isRatedUserDriver;
  }

  @override
  Future<bool> hasRated(String tripId, String raterId) async {
    return lastTripId == tripId && lastRaterId == raterId;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  test('AppUser model handles cumulative rating fields correctly', () {
    final user = AppUser(
      uid: 'user_1',
      fullName: 'Test Customer',
      email: 'test@sese.app',
      phoneNumber: '08012345678',
      role: UserRole.customer,
      createdAt: DateTime(2025),
      averageRating: 4.8,
      totalRatingSum: 24,
      totalRatingCount: 5,
    );

    final map = user.toMap();
    expect(map['averageRating'], 4.8);
    expect(map['totalRatingSum'], 24);
    expect(map['totalRatingCount'], 5);

    final deserialized = AppUser.fromMap(map);
    expect(deserialized.averageRating, 4.8);
    expect(deserialized.totalRatingSum, 24);
    expect(deserialized.totalRatingCount, 5);

    final updated = user.copyWith(averageRating: 4.9);
    expect(updated.averageRating, 4.9);
  });

  testWidgets('TripRatingDialog renders stars, accepts comment, and submits',
      (tester) async {
    final fakeService = _FakeRatingService();

    bool? dialogResult;

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => ElevatedButton(
              onPressed: () async {
                dialogResult = await TripRatingDialog.show(
                  context,
                  tripId: 'trip_999',
                  raterId: 'customer_1',
                  ratedUserId: 'driver_1',
                  ratedUserName: 'Micheal Bamiduro',
                  isRatedUserDriver: true,
                  ratingService: fakeService,
                );
              },
              child: const Text('Open Rating'),
            ),
          ),
        ),
      ),
    );

    // Open dialog
    await tester.tap(find.text('Open Rating'));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('trip_rating_dialog')), findsOneWidget);
    expect(find.text('Rate your trip with Micheal'), findsOneWidget);

    // Select 4 stars
    await tester.tap(find.byKey(const Key('rating_star_4')));
    await tester.pump();
    expect(find.text('Very Good'), findsOneWidget);

    // Type comment
    await tester.enterText(
        find.byKey(const Key('rating_comment_field')), 'Great driver and clean vehicle!');
    await tester.pump();

    // Submit
    await tester.tap(find.byKey(const Key('rating_submit_button')));
    await tester.pumpAndSettle();

    expect(dialogResult, isTrue);
    expect(fakeService.lastTripId, 'trip_999');
    expect(fakeService.lastRaterId, 'customer_1');
    expect(fakeService.lastRatedUserId, 'driver_1');
    expect(fakeService.lastRating, 4);
    expect(fakeService.lastComment, 'Great driver and clean vehicle!');
    expect(fakeService.lastIsDriver, isTrue);
  });

  testWidgets('TripRatingDialog skip button dismisses with false',
      (tester) async {
    final fakeService = _FakeRatingService();
    bool? dialogResult;

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => ElevatedButton(
              onPressed: () async {
                dialogResult = await TripRatingDialog.show(
                  context,
                  tripId: 'trip_888',
                  raterId: 'driver_1',
                  ratedUserId: 'customer_1',
                  ratedUserName: 'Sarah Okafor',
                  isRatedUserDriver: false,
                  ratingService: fakeService,
                );
              },
              child: const Text('Open Rating'),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('Open Rating'));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('trip_rating_dialog')), findsOneWidget);
    await tester.tap(find.byKey(const Key('rating_skip_button')));
    await tester.pumpAndSettle();

    expect(dialogResult, isFalse);
    expect(fakeService.lastTripId, isNull);
  });
}
