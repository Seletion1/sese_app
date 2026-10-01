import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sese_core/sese_core.dart';
import 'package:sese_ride/features/driver/presentation/driver_profile_screen.dart';
import 'package:sese_ride/features/driver/services/driver_profile_service.dart';
import 'package:sese_ride/features/driver/services/driver_streak_service.dart';
import 'package:sese_ride/features/home/driver_home_shell.dart';
import 'package:sese_ride/features/trips/models/trip_models.dart';

class _ProfileServiceStub extends DriverProfileService {
  final DriverProfile? stub;
  _ProfileServiceStub(this.stub);

  @override
  Stream<DriverProfile?> profileStream(String uid) =>
      Stream.value(stub);
}

class _IdleStreakStub extends DriverStreakService {
  @override
  Stream<ActiveTrip?> activeTripStream(String driverId) =>
      Stream.value(null);
}

class _OnTripStreakStub extends DriverStreakService {
  @override
  Stream<ActiveTrip?> activeTripStream(String driverId) => Stream.value(
        const ActiveTrip(
          tripId: 'trip_1',
          status: TripStatus.driverAccepted,
          customerId: 'cust_1',
        ),
      );
}

AppUser driverUser() => AppUser(
      uid: 'driver_1',
      fullName: 'Test Driver',
      email: 'driver@test.co',
      phoneNumber: '+2348012345678',
      role: UserRole.driver,
      createdAt: DateTime(2024),
    );

void main() {
  group('DriverProfileService.toE164', () {
    test('normalizes NG mobile numbers', () {
      expect(DriverProfileService.toE164('0803 123 4567'),
          '+2348031234567');
      expect(DriverProfileService.toE164('2348031234567'),
          '+2348031234567');
      expect(DriverProfileService.toE164('+2348031234567'),
          '+2348031234567');
    });

    test('rejects invalid input', () {
      expect(DriverProfileService.toE164(''), isNull);
      expect(DriverProfileService.toE164('123'), isNull);
      expect(DriverProfileService.toE164('abcdefg'), isNull);
    });
  });

  group('DriverProfileScreen', () {
    testWidgets('renders read-only fields with lock icons', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: DriverProfileScreen(
            user: driverUser(),
            profileService: _ProfileServiceStub(
              const DriverProfile(
                uid: 'driver_1',
                fullName: 'Test Driver',
                email: 'driver@test.co',
                verificationStatus: 'APPROVED',
              ),
            ),
            streakService: _IdleStreakStub(),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Test Driver'), findsWidgets);
      expect(find.byIcon(Icons.lock_outline), findsWidgets);
      expect(find.byKey(const Key('profile_avatar_capture')),
          findsOneWidget);
    });

    testWidgets('phone edit is enabled when no active trip', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: DriverProfileScreen(
            user: driverUser(),
            profileService: _ProfileServiceStub(null),
            streakService: _IdleStreakStub(),
          ),
        ),
      );
      await tester.pumpAndSettle();

      final edit = find.byKey(const Key('phone_edit_button'));
      expect(edit, findsOneWidget);
      await tester.tap(edit);
      await tester.pumpAndSettle();
      expect(find.text('Update Phone Number'), findsOneWidget);
    });

    testWidgets('phone edit is blocked during an active trip', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: DriverProfileScreen(
            user: driverUser(),
            profileService: _ProfileServiceStub(null),
            streakService: _OnTripStreakStub(),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(
        find.text(
            'Phone number cannot be updated during an active trip.'),
        findsOneWidget,
      );
      final button = tester.widget<TextButton>(
          find.byKey(const Key('phone_edit_button')));
      expect(button.onPressed, isNull);
    });
  });

  group('Driver menu profile card', () {
    testWidgets('tapping the profile card opens DriverProfileScreen',
        (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: DriverHomeShell(
            user: driverUser(),
            auth: const StubAuthRepository(),
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('Menu'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('menu_profile_card')));
      await tester.pumpAndSettle();

      expect(find.text('Driver Profile'), findsOneWidget);
    });
  });
}
