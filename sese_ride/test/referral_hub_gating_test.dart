import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sese_core/sese_core.dart';
import 'package:sese_ride/features/referral/referral_hub_screen.dart';

void main() {
  group('ReferralHubScreen verification gating', () {
    testWidgets('hides referral code card and copy/share buttons when unverified',
        (tester) async {
      final unverifiedUser = AppUser(
        uid: 'u_unverified',
        fullName: 'Unverified Rider',
        email: 'rider@test.com',
        phoneNumber: '+2348000000001',
        role: UserRole.customer,
        isActive: true,
        createdAt: DateTime(2026, 11, 24),
        verificationStatus: 'pending_verification',
        sequentialId: '',
      );

      await tester.pumpWidget(
        MaterialApp(home: ReferralHubScreen(user: unverifiedUser)),
      );
      await tester.pump();

      expect(
        find.byKey(const Key('referral_verification_prompt_card')),
        findsOneWidget,
      );
      expect(find.byKey(const Key('referral_code_card')), findsNothing);
      expect(find.byKey(const Key('referral_copy_button')), findsNothing);
      expect(find.byKey(const Key('referral_share_button')), findsNothing);
      expect(find.text('Account Verification Required'), findsOneWidget);
    });

    testWidgets('displays official verified Member ID (SD0001) with copy & share',
        (tester) async {
      final verifiedDriver = AppUser(
        uid: 'd_verified',
        fullName: 'Verified Driver',
        email: 'driver@test.com',
        phoneNumber: '+2348000000002',
        role: UserRole.driver,
        isActive: true,
        createdAt: DateTime(2026, 11, 24),
        verificationStatus: 'verified',
        sequentialId: 'SD0001',
      );

      await tester.pumpWidget(
        MaterialApp(home: ReferralHubScreen(user: verifiedDriver)),
      );
      await tester.pump();

      expect(find.byKey(const Key('referral_code_card')), findsOneWidget);
      expect(
        find.byKey(const Key('referral_verification_prompt_card')),
        findsNothing,
      );
      expect(find.text('SD0001'), findsOneWidget);
      expect(find.byKey(const Key('referral_copy_button')), findsOneWidget);
      expect(find.byKey(const Key('referral_share_button')), findsOneWidget);
    });
  });
}
