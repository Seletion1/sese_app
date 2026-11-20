import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sese_core/sese_core.dart';

/// Comprehensive legal compliance tests verifying all 3 official SESE URLs:
///   - Terms of Service:  https://sesetech.com/terms
///   - Privacy Policy:    https://sesetech.com/PrivacyPolicy
///   - Account Deletion:  https://sesetech.com/delete
void main() {
  group('LegalTermsConfig & URLs', () {
    test('default config points to all 3 official sesetech.com URLs', () {
      final config = LegalTermsConfig.defaultConfig();
      expect(config.termsUrl, 'https://sesetech.com/terms');
      expect(config.privacyUrl, 'https://sesetech.com/PrivacyPolicy');
      expect(config.accountDeletionUrl, 'https://sesetech.com/delete');
      expect(config.termsVersion, '2026.11.20');
      expect(config.forceReaccept, isFalse);
    });

    test('toMap and fromMap round-trip preserves all 3 URLs', () {
      const config = LegalTermsConfig(
        termsVersion: '2026.11.20',
        termsUrl: 'https://sesetech.com/terms',
        privacyUrl: 'https://sesetech.com/PrivacyPolicy',
        accountDeletionUrl: 'https://sesetech.com/delete',
        forceReaccept: true,
      );
      final map = config.toMap();
      final parsed = LegalTermsConfig.fromMap(map);

      expect(parsed.termsUrl, 'https://sesetech.com/terms');
      expect(parsed.privacyUrl, 'https://sesetech.com/PrivacyPolicy');
      expect(parsed.accountDeletionUrl, 'https://sesetech.com/delete');
      expect(parsed.forceReaccept, isTrue);
    });

    test('fromMap uses correct defaults for all 3 URLs when data is null', () {
      final config = LegalTermsConfig.fromMap(null);
      expect(config.termsUrl, 'https://sesetech.com/terms');
      expect(config.privacyUrl, 'https://sesetech.com/PrivacyPolicy');
      expect(config.accountDeletionUrl, 'https://sesetech.com/delete');
    });
  });

  group('LegalDocumentContent — Terms of Service', () {
    test('contains all 3 official URLs embedded in terms text', () {
      final terms = LegalDocumentContent.termsOfServiceText;
      // Official URLs
      expect(terms, contains('https://sesetech.com/terms'));
      expect(terms, contains('https://sesetech.com/PrivacyPolicy'));
      expect(terms, contains('https://sesetech.com/delete'));
    });

    test('contains all required platform business rules', () {
      final terms = LegalDocumentContent.termsOfServiceText;
      expect(terms, contains('SESE TECHNOLOGY LTD'));
      expect(terms, contains('ESCROW'));
      expect(terms, contains('CANCELLATION'));
      expect(terms, contains('WAITING FEE'));
      expect(terms, contains('BIDDING'));
      expect(terms, contains('KYC'));
      expect(terms, contains('SHA-256'));
      expect(terms, contains('IN_PROGRESS'));
      expect(terms, contains('WebRTC'));
      expect(terms, contains('Agora'));
      expect(terms, contains('SOS'));
      expect(terms, contains('SYSTEM_ALERT_WINDOW'));
      expect(terms, contains('30-day regulatory soft-archive'));
    });

    test('title is correct', () {
      expect(LegalDocumentContent.titleFor(LegalDocType.terms), 'Terms of Use');
    });
  });

  group('LegalDocumentContent — Privacy Policy', () {
    test('contains all 3 official URLs in privacy policy', () {
      final privacy = LegalDocumentContent.privacyPolicyText;
      expect(privacy, contains('https://sesetech.com/PrivacyPolicy'));
      expect(privacy, contains('https://sesetech.com/delete'));
      expect(privacy, contains('https://sesetech.com/terms'));
    });

    test('discloses all Android runtime permissions', () {
      final privacy = LegalDocumentContent.privacyPolicyText;
      expect(privacy, contains('ACCESS_FINE_LOCATION'));
      expect(privacy, contains('ACCESS_BACKGROUND_LOCATION'));
      expect(privacy, contains('READ_CONTACTS'));
      expect(privacy, contains('RECORD_AUDIO'));
      expect(privacy, contains('SYSTEM_ALERT_WINDOW'));
      expect(privacy, contains('POST_NOTIFICATIONS'));
      expect(privacy, contains('USE_FULL_SCREEN_INTENT'));
      expect(privacy, contains('CAMERA'));
    });

    test('covers NDPA, encryption, and third-party processors', () {
      final privacy = LegalDocumentContent.privacyPolicyText;
      expect(privacy, contains('Nigeria Data Protection Act'));
      expect(privacy, contains('TLS 1.3'));
      expect(privacy, contains('SHA-256'));
      expect(privacy, contains('Paystack'));
      expect(privacy, contains('Google Maps Platform'));
      expect(privacy, contains('Agora RTC'));
      expect(privacy, contains('Firebase'));
    });

    test('title is correct', () {
      expect(LegalDocumentContent.titleFor(LegalDocType.privacy), 'Privacy Policy');
    });
  });

  group('LegalDocumentContent — Account Deletion Policy', () {
    test('contains all 3 official URLs in deletion policy', () {
      final deletion = LegalDocumentContent.accountDeletionText;
      expect(deletion, contains('https://sesetech.com/delete'));
      expect(deletion, contains('https://sesetech.com/PrivacyPolicy'));
      expect(deletion, contains('https://sesetech.com/terms'));
    });

    test('covers NDPA rights, prerequisites, and 30-day retention', () {
      final deletion = LegalDocumentContent.accountDeletionText;
      expect(deletion, contains('ACCOUNT & DATA DELETION POLICY'));
      expect(deletion, contains('Nigeria Data Protection Act'));
      expect(deletion, contains('30-Day Regulatory Retention'));
      expect(deletion, contains('₦0.00'));
      expect(deletion, contains('support@sesetech.com'));
      expect(deletion, contains('privacy@sesetech.com'));
    });

    test('title is correct', () {
      expect(
        LegalDocumentContent.titleFor(LegalDocType.accountDeletion),
        'Account & Data Deletion',
      );
    });
  });

  group('LegalDocumentViewer Widget', () {
    testWidgets('renders Terms of Use title cleanly', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(body: LegalDocumentViewer(type: LegalDocType.terms)),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Terms of Use'), findsOneWidget);
      expect(
        find.text('Official SESE Technology LTD Compliance Document'),
        findsOneWidget,
      );
      expect(find.byType(SelectableText), findsOneWidget);
    });

    testWidgets('renders Privacy Policy title and icon cleanly', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(body: LegalDocumentViewer(type: LegalDocType.privacy)),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Privacy Policy'), findsOneWidget);
      expect(find.byIcon(Icons.privacy_tip_outlined), findsOneWidget);
    });

    testWidgets('renders Account Deletion title and icon cleanly', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(body: LegalDocumentViewer(type: LegalDocType.accountDeletion)),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Account & Data Deletion'), findsOneWidget);
      expect(
        find.text('Official SESE Technology LTD Compliance Document'),
        findsOneWidget,
      );
      expect(find.byIcon(Icons.person_remove_outlined), findsOneWidget);
    });
  });
}
