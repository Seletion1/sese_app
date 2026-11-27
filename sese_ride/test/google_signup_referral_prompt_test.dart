import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sese_core/sese_core.dart';
import 'package:sese_ride/features/referral/referral_input_widget.dart';

void main() {
  group('Google Sign-Up Referral Prompt & Linking Flow', () {
    test('AppUser isNewRegistration flag defaults to false and can be set to true', () {
      final existingUser = AppUser(
        uid: 'user_123',
        fullName: 'Test User',
        email: 'test@example.com',
        phoneNumber: '+2348012345678',
        role: UserRole.customer,
        createdAt: DateTime.now(),
      );
      expect(existingUser.isNewRegistration, isFalse);

      final newUser = AppUser(
        uid: 'user_456',
        fullName: 'New User',
        email: 'new@example.com',
        phoneNumber: '+2348098765432',
        role: UserRole.customer,
        createdAt: DateTime.now(),
        isNewRegistration: true,
      );
      expect(newUser.isNewRegistration, isTrue);

      final copied = existingUser.copyWith(isNewRegistration: true);
      expect(copied.isNewRegistration, isTrue);
    });

    testWidgets('ReferralInputWidget emits both referrerId and code via onDetailsResolved', (tester) async {
      String? resolvedId;
      String? resolvedCode;

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ReferralInputWidget(
              referralService: const ReferralService(),
              onResolved: (id) => resolvedId = id,
              onDetailsResolved: (id, code) {
                resolvedId = id;
                resolvedCode = code;
              },
            ),
          ),
        ),
      );

      // Verify widget renders
      expect(find.byKey(const Key('referral_code_field')), findsOneWidget);

      // Entering an invalid format clears resolved callbacks
      await tester.enterText(find.byKey(const Key('referral_code_field')), 'INVALID');
      await tester.pump(const Duration(milliseconds: 500));

      expect(resolvedId, isNull);
      expect(resolvedCode, isNull);
      expect(find.textContaining('Invalid User ID'), findsOneWidget);

      // Clearing input clears error
      await tester.enterText(find.byKey(const Key('referral_code_field')), '');
      await tester.pump(const Duration(milliseconds: 500));
      expect(resolvedId, isNull);
      expect(resolvedCode, isNull);
      expect(find.textContaining('Invalid User ID'), findsNothing);
    });
  });
}
