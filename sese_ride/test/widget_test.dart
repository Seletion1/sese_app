import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sese_core/sese_core.dart';
import 'package:sese_ride/main.dart';

/// Signed-out session so the auth gate renders the login screen
/// immediately (no Firebase in widget tests).
class _SignedOutAuth extends StubAuthRepository {
  const _SignedOutAuth();

  @override
  Stream<AppUser?> get authStateChanges => Stream.value(null);
}

/// Fake backend for the driver signup flow: mints a pending-onboarding
/// driver so the app routes to Step 2 (Personal Information).
class _SignupAuth extends _SignedOutAuth {
  const _SignupAuth();

  @override
  Future<AppUser> register({
    required String fullName,
    required String email,
    required String phoneNumber,
    required String password,
    required UserRole role,
    String? vehicleType,
    String? licenseNo,
  }) async {
    return AppUser(
      uid: 'driver-1',
      fullName: fullName,
      email: email,
      phoneNumber: phoneNumber,
      role: role,
      createdAt: DateTime(2026, 1, 1),
      verificationStatus: DriverVerification.pendingOnboarding,
    );
  }
}

Future<void> _pumpLogin(WidgetTester tester, AuthRepository auth) async {
  await tester.pumpWidget(MyApp(authRepository: auth));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('Welcome role selection shows logo, headlines, role cards, sign-in & legal disclaimer',
      (WidgetTester tester) async {
    await _pumpLogin(tester, const _SignedOutAuth());

    expect(find.text('Welcome to SeSe'), findsOneWidget);
    expect(find.text('Choose how you want to use the app'), findsOneWidget);
    expect(find.byKey(const Key('role_card_customer')), findsOneWidget);
    expect(find.text('Rider / Customer'), findsOneWidget);
    expect(find.text('Book rides & send deliveries'), findsOneWidget);
    expect(find.byKey(const Key('role_card_driver')), findsOneWidget);
    expect(find.text('Driver / Delivery Partner'), findsOneWidget);
    expect(find.text('Get a vehicle and start earning with us'), findsOneWidget);
    expect(find.byKey(const Key('direct_sign_in_button')), findsOneWidget);
    expect(find.textContaining('Terms of Use'), findsOneWidget);
    expect(find.textContaining('Privacy Policy'), findsOneWidget);
  });

  testWidgets('Customer role card navigates to AuthScreen form',
      (WidgetTester tester) async {
    await _pumpLogin(tester, const _SignedOutAuth());

    await tester.tap(find.byKey(const Key('role_card_customer')));
    await tester.pumpAndSettle();

    expect(find.text('Welcome back! Sign in as Customer'), findsOneWidget);
    expect(find.text('Email Address'), findsOneWidget);
    expect(find.text('Password'), findsOneWidget);

    // Switch to Create Account mode
    await tester.tap(find.text('Create Account'));
    await tester.pumpAndSettle();

    expect(find.text('Create your Customer account'), findsOneWidget);
    expect(find.text('First Name'), findsOneWidget);
    expect(find.text('Last Name'), findsOneWidget);
  });

  testWidgets('Driver signup routes to Step 2 onboarding UI',
      (WidgetTester tester) async {
    // Tall viewport: the signup form + submit button lay out fully.
    tester.view.physicalSize = const Size(800, 3000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    await _pumpLogin(tester, const _SignupAuth());

    // Pick Driver role card from the Welcome screen
    await tester.tap(find.byKey(const Key('role_card_driver')));
    await tester.pumpAndSettle();

    // Toggle to Create Account mode
    await tester.tap(find.text('Create Account'));
    await tester.pumpAndSettle();

    await tester.enterText(
        find.widgetWithText(TextFormField, 'First Name'), 'Adaeze');
    await tester.enterText(
        find.widgetWithText(TextFormField, 'Last Name'), 'Okonkwo');
    await tester.enterText(
        find.widgetWithText(TextFormField, 'Phone Number'), '08012345678');
    await tester.enterText(
        find.widgetWithText(TextFormField, 'Email Address'),
        'adaeze@example.com');
    await tester.enterText(
        find.widgetWithText(TextFormField, 'Password'), 'secret123');
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('create_account_submit_button')));
    await tester.pumpAndSettle();

    // Step 1 is the signup form itself; vehicle details moved to
    // Manage Fleet / Step 2 onboarding.
    expect(find.text('Step 2: Personal Information'), findsOneWidget);
    expect(find.text('Vehicle Type'), findsNothing);
    expect(find.text('License No.'), findsNothing);
  });
}

