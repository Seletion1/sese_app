import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sese_core/sese_core.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('SeseWebErrorDetector Unit Tests', () {
    test('isErrorStatusCode returns true for 4xx and 5xx status codes', () {
      expect(SeseWebErrorDetector.isErrorStatusCode(404), isTrue);
      expect(SeseWebErrorDetector.isErrorStatusCode(503), isTrue);
      expect(SeseWebErrorDetector.isErrorStatusCode(500), isTrue);
      expect(SeseWebErrorDetector.isErrorStatusCode(400), isTrue);

      expect(SeseWebErrorDetector.isErrorStatusCode(200), isFalse);
      expect(SeseWebErrorDetector.isErrorStatusCode(201), isFalse);
      expect(SeseWebErrorDetector.isErrorStatusCode(302), isFalse);
    });

    test('isFirebaseHostingPlaceholder detects default Firebase Hosting error pages', () {
      const firebaseHtml = '''
        <!DOCTYPE html>
        <html>
        <head><title>Site Not Found</title></head>
        <body>
          <h1>Site Not Found</h1>
          <p>Why am I seeing this?</p>
          <ol>
            <li>You haven't deployed an app yet.</li>
            <li>You may have deployed an empty directory.</li>
          </ol>
          <p>Refer to our hosting documentation to get started.</p>
        </body>
        </html>
      ''';

      expect(
        SeseWebErrorDetector.isFirebaseHostingPlaceholder(firebaseHtml, 'Site Not Found'),
        isTrue,
      );

      expect(
        SeseWebErrorDetector.isFirebaseHostingPlaceholder(
          'There are a few potential reasons: You haven\'t deployed an app yet.',
          null,
        ),
        isTrue,
      );

      expect(
        SeseWebErrorDetector.isFirebaseHostingPlaceholder(
          '<div>Welcome to SeseRide Customer Web</div>',
          'SeseRide Customer',
        ),
        isFalse,
      );
    });

    test('getCleanUserErrorMessage returns reassuring copy without raw stack traces', () {
      final msg404 = SeseWebErrorDetector.getCleanUserErrorMessage(statusCode: 404);
      expect(msg404, contains('404'));
      expect(msg404, isNot(contains('Exception')));

      final msgFb = SeseWebErrorDetector.getCleanUserErrorMessage(isFirebasePlaceholder: true);
      expect(msgFb, contains('currently unavailable'));
      expect(msgFb, isNot(contains('hosting documentation')));
    });
  });

  group('SeseWebErrorWidget Widget Tests', () {
    testWidgets('renders branded error widget with Retry and Go Back buttons', (tester) async {
      bool retried = false;
      bool wentBack = false;

      await tester.pumpWidget(
        MaterialApp(
          home: SeseWebErrorWidget(
            title: 'Web Service Unavailable',
            errorMessage: 'We could not connect to this resource.',
            onRetry: () => retried = true,
            onGoBack: () => wentBack = true,
          ),
        ),
      );

      expect(find.text('Web Service Unavailable'), findsOneWidget);
      expect(find.text('We could not connect to this resource.'), findsOneWidget);

      await tester.tap(find.byKey(const Key('sese_web_error_retry_btn')));
      await tester.pump();
      expect(retried, isTrue);

      await tester.tap(find.byKey(const Key('sese_web_error_back_btn')));
      await tester.pump();
      expect(wentBack, isTrue);
    });
  });
}
