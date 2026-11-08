import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:sese_core/sese_core.dart';
import 'package:sese_ride/widgets/map_provider.dart';
import 'package:sese_ride/widgets/osm_map_view.dart';

void main() {
  setUp(() {
    OsmMapView.debugTileProviderOverride = BlankTileProvider();
  });

  tearDown(() {
    OsmMapView.debugTileProviderOverride = null;
  });

  group('Immersive Multi-Provider Map Gesture & Sheet Collapse Tests', () {
    testWidgets('Tapping map canvas triggers interaction controller and minimizes bottom sheet',
        (tester) async {
      final sheetController = DraggableScrollableController();
      final interactionController = MapInteractionController(
        inactivityDuration: const Duration(milliseconds: 500),
        sheetCollapsedExtent: 0.18,
        sheetStandardExtent: 0.44,
        sheetController: sheetController,
      );
      final mapController = SeSeMapController();

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Stack(
              children: [
                Positioned.fill(
                  child: SeseUniversalMap(
                    mapController: mapController,
                    interactionController: interactionController,
                    initialCenter: const LatLng(6.5244, 3.3792),
                  ),
                ),
                DraggableScrollableSheet(
                  controller: sheetController,
                  initialChildSize: 0.44,
                  minChildSize: 0.18,
                  maxChildSize: 0.88,
                  snap: true,
                  snapSizes: const [0.18, 0.44, 0.88],
                  builder: (context, scrollCtrl) {
                    return Container(
                      key: const Key('test_bottom_sheet'),
                      color: Colors.white,
                      child: ListView(
                        controller: scrollCtrl,
                        children: const [
                          Text('Active Trip Bottom Sheet'),
                        ],
                      ),
                    );
                  },
                ),
              ],
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(interactionController.isImmersive, isFalse);
      expect(sheetController.size, closeTo(0.44, 0.01));

      // 1. Tap anywhere on map canvas
      await tester.tapAt(const Offset(200, 200));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      // 2. Verified: Sheet collapsed to snap-to-edge size 0.18, NOT closed or opacity 0
      expect(interactionController.isImmersive, isTrue);
      expect(find.byKey(const Key('test_bottom_sheet')), findsOneWidget);

      // 3. Inactivity timer triggers automatic restoration after 500ms
      await tester.pump(const Duration(milliseconds: 600));
      await tester.pumpAndSettle();

      expect(interactionController.isImmersive, isFalse);
      expect(sheetController.size, closeTo(0.44, 0.02));

      interactionController.dispose();
      sheetController.dispose();
    });

    testWidgets('Manual drag on map canvas triggers sheet collapse and autohide',
        (tester) async {
      final sheetController = DraggableScrollableController();
      final interactionController = MapInteractionController(
        inactivityDuration: const Duration(milliseconds: 500),
        sheetCollapsedExtent: 0.18,
        sheetStandardExtent: 0.44,
        sheetController: sheetController,
      );
      final mapController = SeSeMapController();

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Stack(
              children: [
                Positioned.fill(
                  child: SeseUniversalMap(
                    mapController: mapController,
                    interactionController: interactionController,
                    initialCenter: const LatLng(6.5244, 3.3792),
                  ),
                ),
                ListenableBuilder(
                  listenable: interactionController,
                  builder: (context, _) {
                    return AnimatedOpacity(
                      duration: const Duration(milliseconds: 200),
                      opacity: interactionController.isImmersive ? 0.0 : 1.0,
                      child: const Card(
                        key: Key('floating_search_card'),
                        child: Text('Where to?'),
                      ),
                    );
                  },
                ),
                DraggableScrollableSheet(
                  controller: sheetController,
                  initialChildSize: 0.44,
                  minChildSize: 0.18,
                  maxChildSize: 0.88,
                  builder: (context, scrollCtrl) {
                    return Container(
                      color: Colors.white,
                      child: ListView(
                        controller: scrollCtrl,
                        children: const [Text('Sheet')],
                      ),
                    );
                  },
                ),
              ],
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Drag across map surface
      await tester.dragFrom(const Offset(200, 200), const Offset(0, -60));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      expect(interactionController.isImmersive, isTrue);

      // Verify floating UI element is hidden
      final opacityWidget = tester.widget<AnimatedOpacity>(
        find.ancestor(
          of: find.byKey(const Key('floating_search_card')),
          matching: find.byType(AnimatedOpacity),
        ),
      );
      expect(opacityWidget.opacity, 0.0);

      // Inactivity timer restores UI automatically
      await tester.pump(const Duration(milliseconds: 600));
      await tester.pumpAndSettle();

      expect(interactionController.isImmersive, isFalse);
      expect(sheetController.size, closeTo(0.44, 0.02));

      interactionController.dispose();
      sheetController.dispose();
    });

    testWidgets('Live GPS movement immediately restores UI and recenters map without waiting for timer',
        (tester) async {
      final sheetController = DraggableScrollableController();
      bool recentered = false;
      final interactionController = MapInteractionController(
        inactivityDuration: const Duration(seconds: 10), // Long timer to verify immediate bypass
        sheetCollapsedExtent: 0.18,
        sheetStandardExtent: 0.44,
        sheetController: sheetController,
        onRecenter: () => recentered = true,
      );
      final mapController = SeSeMapController();

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Stack(
              children: [
                Positioned.fill(
                  child: SeseUniversalMap(
                    mapController: mapController,
                    interactionController: interactionController,
                    initialCenter: const LatLng(6.5244, 3.3792),
                  ),
                ),
                DraggableScrollableSheet(
                  controller: sheetController,
                  initialChildSize: 0.44,
                  minChildSize: 0.18,
                  maxChildSize: 0.88,
                  builder: (context, scrollCtrl) {
                    return Container(
                      color: Colors.white,
                      child: ListView(
                        controller: scrollCtrl,
                        children: const [Text('Sheet')],
                      ),
                    );
                  },
                ),
              ],
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // User interacts with map
      interactionController.notifyInteractionStarted(currentLat: 6.5244, currentLng: 3.3792);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 350));
      expect(interactionController.isImmersive, isTrue);
      expect(sheetController.size, closeTo(0.18, 0.02));

      // Device/driver starts driving (speed 2.5 m/s > 1.2 m/s)
      interactionController.onLocationUpdate(6.5250, 3.3800, speed: 2.5);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 350));

      // Verified: Immediate restoration occurred without waiting 10s!
      expect(interactionController.isImmersive, isFalse);
      expect(recentered, isTrue);
      expect(sheetController.size, closeTo(0.44, 0.02));

      interactionController.dispose();
      sheetController.dispose();
    });
  });
}
