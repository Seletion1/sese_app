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
  testWidgets('Login shows role cards, Google + password options',
      (WidgetTester tester) async {
    await _pumpLogin(tester, const _SignedOutAuth());

    expect(find.text('SeSe Ride'), findsOneWidget);
    expect(find.textContaining('Welcome back!'), findsOneWidget);
    expect(find.text('Customer'), findsOneWidget);
    expect(find.text('Book rides & deliveries'), findsOneWidget);
    expect(find.text('Driver'), findsOneWidget);
    expect(find.text('Earn on your schedule'), findsOneWidget);
    expect(find.text('Continue with Google'), findsOneWidget);
    expect(find.text('Email Address'), findsOneWidget);
    expect(find.text('Password'), findsOneWidget);
    // Sign In labels both the mode toggle and the submit button.
    expect(find.text('Sign In'), findsNWidgets(2));
    expect(find.text('Create Account'), findsOneWidget);
  });

  testWidgets('Create-account toggle opens registration form',
      (WidgetTester tester) async {
    await _pumpLogin(tester, const _SignedOutAuth());

    await tester.tap(find.text('Create Account'));
    await tester.pumpAndSettle();

    expect(
        find.text('Create your account to get started'), findsOneWidget);
    expect(find.text('First Name'), findsOneWidget);
    expect(find.text('Last Name'), findsOneWidget);
    expect(find.text('Phone Number'), findsOneWidget);
    expect(find.text('Sign up with Google'), findsOneWidget);
    // Submit button is keyed (the toggle shares the label text).
    expect(
        find.byKey(const Key('create_account_submit_button')),
        findsOneWidget);
  });

  testWidgets('Driver signup routes to Step 2 onboarding UI',
      (WidgetTester tester) async {
    // Tall viewport: the signup form + submit button lay out fully.
    tester.view.physicalSize = const Size(800, 3000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    await _pumpLogin(tester, const _SignupAuth());

    // Switch to Create Account, then pick the Driver role card.
    await tester.tap(find.text('Create Account'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('role_driver_tile')));
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
