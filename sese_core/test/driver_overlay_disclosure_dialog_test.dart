import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sese_core/sese_core.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  group('DriverOverlayDisclosureDialog Tests', () {
    testWidgets('renders disclosure copy and compliance bullets', (tester) async {
      bool agreed = false;
      bool declined = false;

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: DriverOverlayDisclosureDialog(
              onAgree: () => agreed = true,
              onDecline: () => declined = true,
            ),
          ),
        ),
      );

      // Verify header and title
      expect(find.text('Floating Quick-Return Bubble'), findsOneWidget);
      expect(find.byIcon(Icons.picture_in_picture_alt_rounded), findsOneWidget);

      // Verify compliance bullets
      expect(find.text('Active only while ONLINE'), findsOneWidget);
      expect(find.text('Instant 1-Tap Return'), findsOneWidget);
      expect(find.text('Privacy & Control'), findsOneWidget);

      // Tap Agree
      await tester.tap(find.byKey(const Key('driver_overlay_consent_agree_button')));
      await tester.pumpAndSettle();
      expect(agreed, isTrue);

      // Tap Decline
      await tester.tap(find.byKey(const Key('driver_overlay_consent_decline_button')));
      await tester.pumpAndSettle();
      expect(declined, isTrue);
    });

    test('shouldShowDisclosure and recordConsent work correctly', () async {
      SharedPreferences.setMockInitialValues({});
      expect(await DriverOverlayDisclosureDialog.shouldShowDisclosure(), isTrue);

      await DriverOverlayDisclosureDialog.recordConsent(consented: true);
      expect(await DriverOverlayDisclosureDialog.shouldShowDisclosure(), isFalse);
    });
  });
}
