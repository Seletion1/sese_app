import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sese_core/sese_core.dart';
import 'package:sese_hub/features/verification/presentation/driver_profile_approvals_tab.dart';

void main() {
  testWidgets(
      'DriverProfileApprovalsTab renders Ready for Review and Incomplete Sign-Ups filters and switches cleanly',
      (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: DriverProfileApprovalsTab(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('filter_ready_for_review')), findsOneWidget);
    expect(find.byKey(const Key('filter_incomplete_signups')), findsOneWidget);
    expect(
      find.text('No pending driver profiles ready for review.'),
      findsOneWidget,
    );

    await tester.tap(find.byKey(const Key('filter_incomplete_signups')));
    await tester.pumpAndSettle();

    expect(find.text('No incomplete driver sign-ups.'), findsOneWidget);
  });

  test('DriverVerification separates pending_onboarding from submitted KYC', () {
    expect(
      DriverVerification.isPendingDriverKycDoc({
        'verificationStatus': 'pending_onboarding',
      }),
      isFalse,
    );
    expect(
      DriverVerification.isIncompleteOnboardingDoc({
        'verificationStatus': 'pending_onboarding',
      }),
      isTrue,
    );
    expect(
      DriverVerification.isPendingDriverKycDoc({
        'verificationStatus': 'pending',
        'profileStatus': 'pending_verification',
        'isPendingReview': true,
      }),
      isTrue,
    );
  });
}
