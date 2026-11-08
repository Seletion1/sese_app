import 'package:flutter_test/flutter_test.dart';
import 'package:sese_core/sese_core.dart';

void main() {
  group('MapInteractionController Tests', () {
    test('initial state is non-immersive and non-interacting', () {
      final controller = MapInteractionController();
      expect(controller.isImmersive, isFalse);
      expect(controller.isInteracting, isFalse);
      expect(controller.lastInteractionTime, isNull);
      controller.dispose();
    });

    test('notifyInteractionStarted triggers immersive mode and collapse callbacks', () {
      final controller = MapInteractionController(
        inactivityDuration: const Duration(milliseconds: 2000),
      );
      bool collapseCalled = false;
      bool? immersiveChanged;

      controller.onCollapseSheet = () => collapseCalled = true;
      controller.onImmersiveChanged = (val) => immersiveChanged = val;

      controller.notifyInteractionStarted(currentLat: 6.5244, currentLng: 3.3792);

      expect(controller.isImmersive, isTrue);
      expect(controller.isInteracting, isTrue);
      expect(controller.lastInteractionTime, isNotNull);
      expect(collapseCalled, isTrue);
      expect(immersiveChanged, isTrue);

      controller.dispose();
    });

    test('notifyInteractionEnded schedules inactivity timer and restores UI after duration', () async {
      final controller = MapInteractionController(
        inactivityDuration: const Duration(milliseconds: 50),
      );
      bool restoreCalled = false;
      controller.onRestoreSheet = () => restoreCalled = true;

      controller.notifyInteractionStarted(currentLat: 6.5244, currentLng: 3.3792);
      expect(controller.isImmersive, isTrue);

      controller.notifyInteractionEnded();
      expect(controller.isInteracting, isFalse);
      expect(controller.isImmersive, isTrue); // Still immersive during countdown

      await Future<void>.delayed(const Duration(milliseconds: 80));

      expect(controller.isImmersive, isFalse);
      expect(restoreCalled, isTrue);

      controller.dispose();
    });

    test('onLocationUpdate triggers immediate restoration and recenter on vehicle speed movement', () {
      final controller = MapInteractionController(
        inactivityDuration: const Duration(milliseconds: 2000),
        minMovementSpeedMps: 1.2,
      );
      bool recenterCalled = false;
      bool restoreCalled = false;

      controller.onRecenter = () => recenterCalled = true;
      controller.onRestoreSheet = () => restoreCalled = true;

      controller.notifyInteractionStarted(currentLat: 6.5244, currentLng: 3.3792);
      expect(controller.isImmersive, isTrue);

      // Stationary update: speed 0.2 m/s -> should NOT restore
      controller.onLocationUpdate(6.5244, 3.3792, speed: 0.2);
      expect(controller.isImmersive, isTrue);
      expect(recenterCalled, isFalse);

      // Vehicle moves: speed 2.5 m/s (> 1.2 m/s) -> instant restoration!
      controller.onLocationUpdate(6.5245, 3.3793, speed: 2.5);
      expect(controller.isImmersive, isFalse);
      expect(recenterCalled, isTrue);
      expect(restoreCalled, isTrue);

      controller.dispose();
    });

    test('onLocationUpdate triggers immediate restoration on coordinate distance shift (>10m)', () {
      final controller = MapInteractionController(
        inactivityDuration: const Duration(milliseconds: 2000),
        minMovementDistanceMeters: 10.0,
      );
      bool recenterCalled = false;
      controller.onRecenter = () => recenterCalled = true;

      // Interaction begins at Lagos origin
      controller.notifyInteractionStarted(currentLat: 6.5244, currentLng: 3.3792);
      expect(controller.isImmersive, isTrue);

      // Shift > 100 meters away without native speed
      controller.onLocationUpdate(6.5260, 3.3800, speed: 0.0);
      expect(controller.isImmersive, isFalse);
      expect(recenterCalled, isTrue);

      controller.dispose();
    });
  });
}
