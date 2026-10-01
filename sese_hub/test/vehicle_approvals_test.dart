import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sese_core/sese_core.dart';
import 'package:sese_hub/features/verification/presentation/vehicle_approvals_screen.dart';
import 'package:sese_hub/features/verification/services/fleet_repository.dart';

/// Canned queue: one bicycle (receipt + gov ID + 1 photo) and one car
/// (license + insurance + 5 photos).
class _FakeFleet extends FleetRepository {
  const _FakeFleet();

  VehicleModel _vehicle({
    required String id,
    required VehicleCategory category,
    required Map<String, String> documents,
  }) {
    final isCar = category == VehicleCategory.car;
    return VehicleModel(
      id: id,
      driverId: 'driver-1',
      category: category,
      tier: isCar ? RideTier.premium : null,
      make: isCar ? 'Toyota' : 'Trinx',
      model: isCar ? 'Corolla' : 'M116 26"',
      year: isCar ? 2018 : 2023,
      licensePlate: isCar ? 'LAG-734-XY' : '',
      color: isCar ? 'Silver' : 'Red',
      documents: documents,
      createdAt: DateTime(2026, 9, 25),
      updatedAt: DateTime(2026, 9, 25),
    );
  }

  @override
  Stream<List<VehicleModel>> pendingVehiclesStream() =>
      Stream.value([
        _vehicle(
          id: 'bike-1',
          category: VehicleCategory.bicycle,
          documents: const {
            'Purchase Receipt / Proof of Ownership': 'https://ex.com/rcpt.jpg',
            'Government ID': 'https://ex.com/gov.jpg',
            'Full Frame Side Profile': 'https://ex.com/side.jpg',
          },
        ),
        _vehicle(
          id: 'car-1',
          category: VehicleCategory.car,
          documents: const {
            'Vehicle License': 'https://ex.com/license.jpg',
            'Insurance Certificate': 'https://ex.com/ins.jpg',
            'Front View': 'https://ex.com/front.jpg',
          },
        ),
      ]);
}

Future<void> _pumpDesk(WidgetTester tester) async {
  // Tall viewport: both vehicle cards render fully laid out so taps never
  // need programmatic scrolling (ListView.ensureVisible + tap is flaky).
  tester.view.physicalSize = const Size(800, 3000);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  await tester.pumpWidget(
    const MaterialApp(
      home: Scaffold(
        body: VehicleApprovalsScreen(fleetRepository: _FakeFleet()),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

Future<void> _tap(WidgetTester tester, Finder finder) async {
  await tester.tap(finder);
  await tester.pumpAndSettle();
}

void main() {
  group('Category-aware verification cards', () {
    testWidgets('all categories render with tailored sections', (tester) async {
      await _pumpDesk(tester);

      // Bicycle: ownership section, no plate banner.
      expect(find.text('Proof of Ownership & ID:'), findsOneWidget);
      expect(find.text('Purchase Receipt / Proof of Ownership'),
          findsOneWidget);
      expect(find.text('Inspection Photos (1/1 required):'), findsOneWidget);
      // Car: license section + plate cross-check + missing-photo warnings.
      expect(find.text('Licenses & Certificates:'), findsOneWidget);
      expect(
          find.textContaining('Plate entered: LAG-734-XY'), findsOneWidget);
      expect(find.text('Inspection Photos (1/5 required):'), findsOneWidget);
      expect(find.textContaining('Missing: Rear View'), findsOneWidget);
    });


    testWidgets('tapping a document opens the full-screen image viewer',
        (tester) async {
      await _pumpDesk(tester);

      await _tap(tester, find.text('Vehicle License').first);
      expect(
          find.text('2018 Toyota Corolla (LAG-734-XY) — Vehicle License'),
          findsOneWidget);
      expect(find.text('https://ex.com/license.jpg'), findsOneWidget);
    });

    testWidgets('plate cross-check opens the license photo', (tester) async {
      await _pumpDesk(tester);

      await _tap(tester, find.text('View License'));
      expect(find.text('Vehicle License — LAG-734-XY'), findsOneWidget);
    });

    testWidgets('reject prompts for a reason and records it', (tester) async {
      await _pumpDesk(tester);

      // Reject without a reason is refused inside the dialog.
      await _tap(tester, find.text('Reject').first);
      expect(find.text('Reject Vehicle'), findsOneWidget);
      await tester.tap(find.text('Confirm Reject'));
      await tester.pumpAndSettle();
      expect(find.text('Reject Vehicle'), findsOneWidget);
      expect(find.text('A rejection reason is required.'), findsOneWidget);

      // With a reason: Firestore write fails offline → error snackbar, no crash.
      await tester.enterText(
          find.widgetWithText(TextField, 'Rejection reason (required)'),
          'Plate unreadable');
      await tester.tap(find.text('Confirm Reject'));
      // Let the first snackbar expire so the queued error snackbar shows.
      await tester.pump(const Duration(seconds: 5));
      await tester.pumpAndSettle();
      expect(find.textContaining('Error rejecting vehicle'), findsOneWidget);
      // Release focus before teardown: ending a test with a focused
      // TextField trips a framework deactivation assertion that fails
      // every test running after this one.
      FocusManager.instance.primaryFocus?.unfocus();
      await tester.pumpAndSettle();
    });

    testWidgets('approve writes aliases live (error path offline)',
        (tester) async {
      await _pumpDesk(tester);

      await _tap(tester, find.text('Approve Vehicle').first);
      // Offline Firestore throws → caught → error snackbar, desk intact.
      expect(find.textContaining('Error approving vehicle'), findsOneWidget);
      expect(find.text('2018 Toyota Corolla (LAG-734-XY)'), findsOneWidget);
    });
  });
}
