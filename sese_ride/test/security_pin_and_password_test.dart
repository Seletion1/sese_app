import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sese_core/sese_core.dart';
import 'package:sese_ride/features/auth/auth_screen.dart';
import 'package:sese_ride/features/home/security_pin_screen.dart';
import 'package:sese_ride/features/wallet/transaction_pin_prompt.dart';
import 'package:sese_ride/widgets/osm_map_view.dart';

class _FakeAuthRepository extends StubAuthRepository {
  String? lastResetEmail;
  bool throwOnReset = false;

  @override
  Future<void> sendPasswordResetEmail({required String email}) async {
    if (throwOnReset) {
      throw const TransactionPinException('invalid-email', 'Invalid email address.');
    }
    lastResetEmail = email;
  }
}

void main() {
  setUp(() {
    OsmMapView.debugTileProviderOverride = BlankTileProvider();
  });

  tearDown(() {
    OsmMapView.debugTileProviderOverride = null;
  });

  group('AuthScreen Forgot Password Workflow', () {
    testWidgets('renders Forgot Password button in Sign In mode and sends email', (tester) async {
      final fakeAuth = _FakeAuthRepository();

      await tester.pumpWidget(
        MaterialApp(
          home: AuthScreen(
            auth: fakeAuth,
            initialSignUpMode: false,
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Verify Forgot Password button exists
      final forgotBtn = find.byKey(const Key('forgot_password_button'));
      expect(forgotBtn, findsOneWidget);

      // Scroll to button and tap
      await tester.ensureVisible(forgotBtn);
      await tester.pumpAndSettle();
      await tester.tap(forgotBtn);
      await tester.pumpAndSettle();

      // Verify Reset Password dialog is visible
      expect(find.text('Reset Password'), findsOneWidget);

      // Enter email
      final emailField = find.byKey(const Key('forgot_password_email_field'));
      expect(emailField, findsOneWidget);
      await tester.enterText(emailField, 'test@example.com');
      await tester.pumpAndSettle();

      // Tap Send Reset Link
      final submitBtn = find.byKey(const Key('forgot_password_submit_button'));
      await tester.tap(submitBtn);
      await tester.pumpAndSettle();

      // Assert auth repo received email
      expect(fakeAuth.lastResetEmail, 'test@example.com');
    });
  });

  group('SecurityPinScreen Widget Tests', () {
    testWidgets('renders PIN setup UI when user has no existing PIN', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: SecurityPinScreen(uid: 'test-uid-no-pin'),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('No PIN Set'), findsOneWidget);
      expect(find.byKey(const Key('security_pin_new_field')), findsOneWidget);
      expect(find.byKey(const Key('security_pin_confirm_field')), findsOneWidget);
      expect(find.byKey(const Key('security_pin_old_field')), findsNothing);
    });

    testWidgets('displays validation error when PINs do not match', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: SecurityPinScreen(uid: 'test-uid-no-pin'),
        ),
      );
      await tester.pumpAndSettle();

      await tester.enterText(find.byKey(const Key('security_pin_new_field')), '1234');
      await tester.enterText(find.byKey(const Key('security_pin_confirm_field')), '5678');
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('security_pin_save_button')));
      await tester.pumpAndSettle();

      expect(find.text('New PINs do not match.'), findsOneWidget);
    });
  });

  group('TransactionPinPrompt JIT Modal', () {
    testWidgets('collectPin renders setup or verify sheet', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (ctx) => ElevatedButton(
                onPressed: () => TransactionPinPrompt.collectPin(
                  ctx,
                  uid: 'test-uid',
                ),
                child: const Text('Collect PIN'),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('Collect PIN'));
      await tester.pumpAndSettle();

      // Verify modal sheet is presented
      expect(find.byKey(const Key('jit_setup_pin_field')), findsOneWidget);
    });
  });
}
