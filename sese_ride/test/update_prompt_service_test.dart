import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sese_ride/core/services/remote_config_service.dart';
import 'package:sese_ride/core/services/update_prompt_service.dart';

Widget _host(WidgetBuilder bodyBuilder) {
  return MaterialApp(
    home: Builder(
      builder: (context) => Scaffold(body: bodyBuilder(context)),
    ),
  );
}

void main() {
  setUp(() {
    UpdatePromptService.resetSessionGuard();
    RemoteConfigService.debugSetOverrides(null);
  });

  tearDown(() {
    UpdatePromptService.resetSessionGuard();
    RemoteConfigService.debugSetOverrides(null);
  });

  group('UpdatePromptService.evaluate', () {
    test('does not prompt when 0, 1, or 2 versions behind (default threshold 3)',
        () {
      expect(
        UpdatePromptService.evaluate(
          currentBuildNumber: 22,
          latestBuildNumber: 22,
        ).shouldPrompt,
        isFalse,
      );
      expect(
        UpdatePromptService.evaluate(
          currentBuildNumber: 22,
          latestBuildNumber: 23,
        ).shouldPrompt,
        isFalse,
      );
      expect(
        UpdatePromptService.evaluate(
          currentBuildNumber: 22,
          latestBuildNumber: 24,
        ).shouldPrompt,
        isFalse,
      );
    });

    test('prompts when 3 or more versions behind', () {
      final decision = UpdatePromptService.evaluate(
        currentBuildNumber: 22,
        latestBuildNumber: 25,
      );
      expect(decision.shouldPrompt, isTrue);
      expect(decision.versionsBehind, 3);
      expect(decision.forceWhenThresholdReached, isFalse);
    });

    test('marks forced when versionsBehind >= forceThreshold', () {
      final soft = UpdatePromptService.evaluate(
        currentBuildNumber: 22,
        latestBuildNumber: 25,
        forceThreshold: 5,
      );
      expect(soft.shouldPrompt, isTrue);
      expect(soft.forceWhenThresholdReached, isFalse);

      final forced = UpdatePromptService.evaluate(
        currentBuildNumber: 20,
        latestBuildNumber: 25,
        forceThreshold: 5,
      );
      expect(forced.shouldPrompt, isTrue);
      expect(forced.versionsBehind, 5);
      expect(forced.forceWhenThresholdReached, isTrue);
    });

    test('does not prompt when latestBuildNumber is 0 or invalid', () {
      expect(
        UpdatePromptService.evaluate(
          currentBuildNumber: 22,
          latestBuildNumber: 0,
        ).shouldPrompt,
        isFalse,
      );
      expect(
        UpdatePromptService.evaluate(
          currentBuildNumber: 0,
          latestBuildNumber: 25,
        ).shouldPrompt,
        isFalse,
      );
    });
  });

  group('RemoteConfigService build lag keys', () {
    test('compiled defaults disable prompt and set lag threshold to 3', () {
      expect(RemoteConfigService.latestBuildNumber, 0);
      expect(RemoteConfigService.updatePromptLagThreshold, 3);
      expect(RemoteConfigService.forceUpdateLagThreshold, 0);
    });

    test('overrides control build lag getters', () {
      RemoteConfigService.debugSetOverrides({
        RemoteConfigKeys.latestBuildNumber: 28,
        RemoteConfigKeys.updatePromptLagThreshold: 3,
        RemoteConfigKeys.forceUpdateLagThreshold: 5,
      });
      expect(RemoteConfigService.latestBuildNumber, 28);
      expect(RemoteConfigService.updatePromptLagThreshold, 3);
      expect(RemoteConfigService.forceUpdateLagThreshold, 5);
    });
  });

  group('UpdatePromptService dialog', () {
    testWidgets('shows dismissible dialog when 3 versions behind',
        (tester) async {
      Uri? launched;
      await tester.pumpWidget(
        _host((context) => ElevatedButton(
              onPressed: () {
                UpdatePromptService.checkAndPromptUpdate(
                  context: context,
                  latestBuildNumber: 25,
                  currentBuildNumberOverride: 22,
                  playStoreUrl: 'https://play.google.com/store/apps/details?id=com.sese.ride',
                  launchUrlOverride: (uri) async {
                    launched = uri;
                    return true;
                  },
                );
              },
              child: const Text('Check'),
            )),
      );

      await tester.tap(find.text('Check'));
      await tester.pumpAndSettle();

      expect(find.text('Update Available'), findsOneWidget);
      expect(find.textContaining('3 versions behind'), findsOneWidget);
      expect(find.text('Later'), findsOneWidget);
      expect(find.text('Update Now'), findsOneWidget);

      await tester.tap(find.text('Update Now'));
      await tester.pump();
      expect(
        launched?.toString(),
        'https://play.google.com/store/apps/details?id=com.sese.ride',
      );

      await tester.tap(find.text('Later'));
      await tester.pumpAndSettle();
      expect(find.text('Update Available'), findsNothing);
    });

    testWidgets('hides Later button when forced threshold is reached',
        (tester) async {
      await tester.pumpWidget(
        _host((context) => ElevatedButton(
              onPressed: () {
                UpdatePromptService.checkAndPromptUpdate(
                  context: context,
                  latestBuildNumber: 27,
                  currentBuildNumberOverride: 22,
                  forceThreshold: 5,
                  playStoreUrl: 'https://play.google.com/store/apps/details?id=com.sese.ride',
                );
              },
              child: const Text('Check'),
            )),
      );

      await tester.tap(find.text('Check'));
      await tester.pumpAndSettle();

      expect(find.text('Update Available'), findsOneWidget);
      expect(find.textContaining('5 versions behind'), findsOneWidget);
      expect(find.text('Later'), findsNothing);
      expect(find.text('Update Now'), findsOneWidget);
    });

    testWidgets('does not show dialog when only 2 versions behind',
        (tester) async {
      await tester.pumpWidget(
        _host((context) => ElevatedButton(
              onPressed: () {
                UpdatePromptService.checkAndPromptUpdate(
                  context: context,
                  latestBuildNumber: 24,
                  currentBuildNumberOverride: 22,
                  playStoreUrl: 'https://play.google.com/store/apps/details?id=com.sese.ride',
                );
              },
              child: const Text('Check'),
            )),
      );

      await tester.tap(find.text('Check'));
      await tester.pumpAndSettle();

      expect(find.text('Update Available'), findsNothing);
    });
  });
}
