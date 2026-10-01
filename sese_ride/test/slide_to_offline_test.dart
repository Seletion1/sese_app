import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sese_ride/features/driver/presentation/widgets/slide_to_offline.dart';

void main() {
  Future<void> pumpSlider(
    WidgetTester tester, {
    bool enabled = true,
    required VoidCallback onComplete,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: 320,
              child: SlideToOffline(
                enabled: enabled,
                onSlideComplete: onComplete,
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  group('SlideToOffline', () {
    testWidgets('full slide fires onSlideComplete and resets thumb',
        (tester) async {
      var completed = 0;
      await pumpSlider(tester, onComplete: () => completed++);

      expect(find.text('Slide to go offline'), findsOneWidget);
      final thumb = find.byKey(const Key('slide_thumb'));
      await tester.drag(thumb, const Offset(300, 0));
      await tester.pumpAndSettle();

      expect(completed, 1);
      final state =
          tester.state<SlideToOfflineState>(find.byType(SlideToOffline));
      expect(state.dragDistance, 0);
    });

    testWidgets('short drag does not complete and snaps back', (tester) async {
      var completed = 0;
      await pumpSlider(tester, onComplete: () => completed++);

      await tester.drag(
          find.byKey(const Key('slide_thumb')), const Offset(20, 0));
      await tester.pumpAndSettle();

      expect(completed, 0);
      final state =
          tester.state<SlideToOfflineState>(find.byType(SlideToOffline));
      expect(state.dragDistance, 0);
    });

    testWidgets('disabled slider ignores drags', (tester) async {
      var completed = 0;
      await pumpSlider(
          tester, enabled: false, onComplete: () => completed++);

      await tester.drag(
          find.byKey(const Key('slide_thumb')), const Offset(300, 0));
      await tester.pumpAndSettle();

      expect(completed, 0);
    });
  });
}
