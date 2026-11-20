import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sese_core/sese_core.dart';

void main() {
  group('LegalTermsConfig & URLs', () {
    test('default configuration points to sesetech.com official URLs', () {
      final config = LegalTermsConfig.defaultConfig();
      expect(config.termsUrl, 'https://sesetech.com/terms');
      expect(config.privacyUrl, 'https://sesetech.com/privacy');
      expect(config.accountDeletionUrl, 'https://sesetech.com/delete');
      expect(config.termsVersion, '2026.11.20');
      expect(config.forceReaccept, isFalse);
    });

    test('toMap and fromMap serialize properly', () {
      const config = LegalTermsConfig(
        termsVersion: '2026.11.20',
        termsUrl: 'https://sesetech.com/terms',
        privacyUrl: 'https://sesetech.com/privacy',
        accountDeletionUrl: 'https://sesetech.com/delete',
        forceReaccept: true,
      );
      final map = config.toMap();
      final parsed = LegalTermsConfig.fromMap(map);

      expect(parsed.termsVersion, '2026.11.20');
      expect(parsed.termsUrl, 'https://sesetech.com/terms');
      expect(parsed.privacyUrl, 'https://sesetech.com/privacy');
      expect(parsed.accountDeletionUrl, 'https://sesetech.com/delete');
      expect(parsed.forceReaccept, isTrue);
    });
  });

  group('LegalDocumentContent', () {
    test('contains comprehensive terms incorporating platform rules', () {
      final terms = LegalDocumentContent.termsOfServiceText;
      expect(terms, contains('SESE TECHNOLOGY LTD'));
      expect(terms, contains('https://sesetech.com/terms'));
      expect(terms, contains('ESCROW'));
      expect(terms, contains('CANCELLATION'));
      expect(terms, contains('WAITING FEE'));
      expect(terms, contains('BIDDING'));

      final title = LegalDocumentContent.titleFor(LegalDocType.terms);
      expect(title, 'Terms of Use');
    });

    test('contains privacy policy with background location and audio permissions', () {
      final privacy = LegalDocumentContent.privacyPolicyText;
      expect(privacy, contains('ACCESS_BACKGROUND_LOCATION'));
      expect(privacy, contains('RECORD_AUDIO'));
      expect(privacy, contains('SYSTEM_ALERT_WINDOW'));
      expect(privacy, contains('https://sesetech.com/delete'));

      final title = LegalDocumentContent.titleFor(LegalDocType.privacy);
      expect(title, 'Privacy Policy');
    });

    test('contains account deletion policy and Google Play / NDPA rights', () {
      final deletion = LegalDocumentContent.accountDeletionText;
      expect(deletion, contains('ACCOUNT & DATA DELETION POLICY'));
      expect(deletion, contains('https://sesetech.com/delete'));
      expect(deletion, contains('30-Day Regulatory Retention'));
      expect(deletion, contains('support@sesetech.com'));

      final title = LegalDocumentContent.titleFor(LegalDocType.accountDeletion);
      expect(title, 'Account & Data Deletion');
    });
  });

  group('LegalDocumentViewer Widget', () {
    testWidgets('renders terms document content cleanly', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: LegalDocumentViewer(type: LegalDocType.terms),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Terms of Use'), findsOneWidget);
      expect(find.text('Official SESE Technology LTD Compliance Document'), findsOneWidget);
      expect(find.byType(SelectableText), findsOneWidget);
    });

    testWidgets('renders account deletion document content cleanly', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: LegalDocumentViewer(type: LegalDocType.accountDeletion),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Account & Data Deletion'), findsOneWidget);
      expect(find.text('Official SESE Technology LTD Compliance Document'), findsOneWidget);
      expect(find.byIcon(Icons.person_remove_outlined), findsOneWidget);
    });
  });
}
