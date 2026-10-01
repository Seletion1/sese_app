import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';
import 'package:http/http.dart' as http;
import 'package:image_picker/image_picker.dart';
import 'package:sese_core/sese_core.dart';
import 'package:sese_ride/features/driver/presentation/driver_onboarding_screen.dart';
import 'package:sese_ride/features/driver/presentation/widgets/verified_customer_badge.dart';
import 'package:sese_ride/features/trips/models/trip_models.dart';

void main() {
  group('DriverOnboardingService.isAdult', () {
    test('requires 18 years', () {
      final now = DateTime(2026, 9, 25);
      expect(
          DriverOnboardingService.isAdult(DateTime(2008, 9, 25), now: now),
          isTrue);
      expect(
          DriverOnboardingService.isAdult(DateTime(2008, 9, 26), now: now),
          isFalse);
      expect(
          DriverOnboardingService.isAdult(DateTime(2015, 1, 1), now: now),
          isFalse);
    });
  });

  group('DriverOnboardingService.submitOnboarding validation', () {
    DriverOnboardingService service() => DriverOnboardingService(
          uploadOverride: (file, path) async => 'https://example.com/$path',
        );

    DateTime adultDob() => DateTime(1995, 5, 5);

    test('rejects underage drivers before any upload', () async {
      var uploads = 0;
      final svc = DriverOnboardingService(
        uploadOverride: (file, path) async {
          uploads++;
          return 'https://example.com/x.jpg';
        },
      );
      await expectLater(
        svc.submitOnboarding(
          driverId: 'd1',
          firstName: 'A',
          lastName: 'B',
          phone: '+2348012345678',
          dateOfBirth: DateTime(2015, 1, 1),
          gender: 'Male',
          country: 'Nigeria',
          homeAddress: 'Lagos',
          latitude: 6.5,
          longitude: 3.3,
          idType: 'NIN',
          idNumber: '123',
          selfie: XFile('/tmp/selfie.jpg'),
          kinName: 'Kin',
          kinRelationship: 'Brother',
          kinPhone: '+2348098765432',
        ),
        throwsA(isA<DriverOnboardingException>()),
      );
      expect(uploads, 0);
    });

    test('rejects missing selfie and missing driver id', () async {
      await expectLater(
        service().submitOnboarding(
          driverId: 'd1',
          firstName: 'A',
          lastName: 'B',
          phone: '+2348012345678',
          dateOfBirth: adultDob(),
          gender: 'Male',
          country: 'Nigeria',
          homeAddress: 'Lagos',
          latitude: 6.5,
          longitude: 3.3,
          idType: 'NIN',
          idNumber: '123',
          kinName: 'Kin',
          kinRelationship: 'Brother',
          kinPhone: '+2348098765432',
        ),
        throwsA(isA<DriverOnboardingException>()),
      );
      await expectLater(
        service().submitOnboarding(
          driverId: '',
          firstName: 'A',
          lastName: 'B',
          phone: '+2348012345678',
          dateOfBirth: adultDob(),
          gender: 'Male',
          country: 'Nigeria',
          homeAddress: 'Lagos',
          latitude: 6.5,
          longitude: 3.3,
          idType: 'NIN',
          idNumber: '123',
          selfie: XFile('/tmp/selfie.jpg'),
          kinName: 'Kin',
          kinRelationship: 'Brother',
          kinPhone: '+2348098765432',
        ),
        throwsA(isA<DriverOnboardingException>()),
      );
    });
  });

  group('Nominatim address search', () {
    test('parses display_name/lat/lon results', () async {
      final mock = MockClient((request) async {
        expect(request.url.host, 'nominatim.openstreetmap.org');
        return http.Response(
          '[{"display_name":"Ikeja, Lagos, Nigeria","lat":"6.6018","lon":"3.3515"}]',
          200,
          headers: {'content-type': 'application/json'},
        );
      });
      final svc = DriverOnboardingService(httpClient: mock);
      final results = await svc.searchAddress('Ikeja');
      expect(results, hasLength(1));
      expect(results.first.displayName, contains('Ikeja'));
      expect(results.first.lat, closeTo(6.6018, 0.0001));
      expect(results.first.lng, closeTo(3.3515, 0.0001));
    });

    test('returns empty on server error', () async {
      final mock = MockClient(
          (request) async => http.Response('error', 500));
      final svc = DriverOnboardingService(httpClient: mock);
      expect(await svc.searchAddress('Lagos'), isEmpty);
    });
  });

  group('Verified customer ride tags', () {
    test('TripDraft carries isVerifiedCustomer (default false)', () {
      const draft = TripDraft(
        customerId: 'c1',
        pickupLat: 6.5,
        pickupLng: 3.3,
        pickupAddress: 'A',
        pickupPhone: '08161561592',
        dropoffLat: 6.6,
        dropoffLng: 3.4,
        dropoffAddress: 'B',
        dropoffPhone: '07080286030',
        serviceType: 'ride',
        selectedTiers: ['comfort'],
        fareToken: 'tok',
        distanceKm: 10,
        durationMins: 20,
      );
      expect(draft.toMap()['isVerifiedCustomer'], isFalse);
      const verified = TripDraft(
        customerId: 'c1',
        pickupLat: 6.5,
        pickupLng: 3.3,
        pickupAddress: 'A',
        pickupPhone: '08161561592',
        dropoffLat: 6.6,
        dropoffLng: 3.4,
        dropoffAddress: 'B',
        dropoffPhone: '07080286030',
        serviceType: 'ride',
        selectedTiers: ['comfort'],
        fareToken: 'tok',
        distanceKm: 10,
        durationMins: 20,
        isVerifiedCustomer: true,
      );
      expect(verified.toMap()['isVerifiedCustomer'], isTrue);
    });

    test('ActiveTrip.fromMap reads the verified flag', () {
      final trip = ActiveTrip.fromMap('t1', {
        'status': 'SEARCHING_DRIVER',
        'customerId': 'c1',
        'isVerifiedCustomer': true,
      });
      expect(trip.isVerifiedCustomer, isTrue);
      final plain = ActiveTrip.fromMap('t2', {
        'status': 'SEARCHING_DRIVER',
        'customerId': 'c1',
      });
      expect(plain.isVerifiedCustomer, isFalse);
    });

    testWidgets('VerifiedCustomerBadge renders gold pill', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(body: VerifiedCustomerBadge()),
        ),
      );
      expect(find.byKey(const Key('verified_customer_badge')),
          findsOneWidget);
      expect(find.text('Verified Customer'), findsOneWidget);
    });
  });

  group('DriverOnboardingScreen navigation and exit controls', () {
    final testUser = AppUser(
      uid: 'u1',
      fullName: 'Test Driver',
      email: 'driver@example.com',
      phoneNumber: '+2348012345678',
      role: UserRole.driver,
      verificationStatus: DriverVerification.pendingOnboarding,
      createdAt: DateTime(2026, 1, 1),
    );

    testWidgets('renders SeseAppBar back arrow and Cancel action button', (tester) async {
      final stubAuth = StubAuthRepository();
      await tester.pumpWidget(
        MaterialApp(
          home: DriverOnboardingScreen(
            user: testUser,
            auth: stubAuth,
          ),
        ),
      );

      expect(find.text('Step 2: Personal Information'), findsOneWidget);
      expect(find.byIcon(Icons.arrow_back), findsOneWidget);
      expect(find.widgetWithText(TextButton, 'Cancel'), findsOneWidget);
    });

    testWidgets('tapping Cancel opens Exit Registration dialog', (tester) async {
      final stubAuth = StubAuthRepository();
      await tester.pumpWidget(
        MaterialApp(
          home: DriverOnboardingScreen(
            user: testUser,
            auth: stubAuth,
          ),
        ),
      );

      await tester.tap(find.widgetWithText(TextButton, 'Cancel'));
      await tester.pumpAndSettle();

      expect(find.text('Exit Registration?'), findsOneWidget);
      expect(find.text('Switch to Customer Mode'), findsOneWidget);
      expect(find.text('Sign Out'), findsOneWidget);
      expect(find.text('Continue Registration'), findsOneWidget);
    });
  });
}
