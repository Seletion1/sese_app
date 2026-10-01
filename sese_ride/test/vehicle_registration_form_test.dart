import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image_picker/image_picker.dart';
import 'package:sese_core/sese_core.dart';
import 'package:sese_ride/features/driver/presentation/widgets/photo_guide_modal.dart';
import 'package:sese_ride/features/driver/presentation/widgets/vehicle_registration_form.dart';
import 'package:sese_ride/features/driver/services/driver_fleet_service.dart';
import 'package:sese_ride/features/driver/services/vehicle_catalog.dart';

Future<XFile?> _fakePick({required ImageSource source}) async =>
    XFile('/tmp/fake_upload.jpg');

Future<String> _fakeUpload(
        {required String docType, required String localPath}) async =>
    'https://example.com/$docType.jpg';

Future<void> _pumpForm(
  WidgetTester tester, {
  void Function(VehicleModel)? onRegistered,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: SingleChildScrollView(
          child: VehicleRegistrationForm(
            fleetService: DriverFleetService(),
            driverId: 'test_driver',
            pickImage: _fakePick,
            uploadDocument: _fakeUpload,
            onRegistered: onRegistered,
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

Future<void> _selectDropdown(
    WidgetTester tester, String fieldLabel, String option) async {
  final field = find.widgetWithText(
      DropdownButtonFormField<String>, fieldLabel);
  await tester.ensureVisible(field);
  await tester.tap(field);
  await tester.pumpAndSettle();
  await tester.tap(find.text(option).last);
  await tester.pumpAndSettle();
}

Future<void> _selectCategory(
    WidgetTester tester, String option) async {
  final field = find.widgetWithText(
      DropdownButtonFormField<VehicleCategory>, 'Vehicle Scope Category');
  await tester.ensureVisible(field);
  await tester.tap(field);
  await tester.pumpAndSettle();
  await tester.tap(find.text(option).last);
  await tester.pumpAndSettle();
}

Future<void> _uploadChip(WidgetTester tester, String chipLabel) async {
  final chip =
      find.widgetWithText(ActionChip, 'Upload $chipLabel');
  await tester.ensureVisible(chip);
  await tester.tap(chip);
  await tester.pumpAndSettle();
  await tester.tap(find.text('Take Photo (Camera)'));
  await tester.pumpAndSettle();
}

void main() {
  group('VehicleRegistrationForm validation', () {
    testWidgets('register stays disabled until everything completes',
        (tester) async {
      await _pumpForm(tester);

      FilledButton btn() => tester.widget<FilledButton>(
          find.widgetWithText(FilledButton, 'Register Vehicle to Fleet'));
      expect(btn().enabled, isFalse);

      // Fill fields only — still disabled without uploads.
      await _selectDropdown(tester, 'Vehicle Make', 'Toyota');
      await _selectDropdown(tester, 'Vehicle Model', 'Corolla');
      await _selectDropdown(
          tester, 'Manufacture Year', '${catalogYears().first}');
      await _selectDropdown(tester, 'Color', 'Silver');
      await tester.enterText(
          find.widgetWithText(TextField, 'License Plate Number'),
          'LAG-734-XY');
      await tester.pumpAndSettle();
      expect(btn().enabled, isFalse);
    });

    testWidgets('Other make expands a custom text field', (tester) async {
      await _pumpForm(tester);

      await _selectDropdown(tester, 'Vehicle Make', 'Other');
      expect(find.widgetWithText(TextField, 'Custom Make'), findsOneWidget);
      // Custom make → model becomes free text.
      expect(find.widgetWithText(TextField, 'Vehicle Model'), findsOneWidget);
    });

    testWidgets('bicycle hides plate/license/insurance, shows 1 photo slot',
        (tester) async {
      await _pumpForm(tester);
      await _selectCategory(tester, 'Bicycle');

      expect(find.widgetWithText(TextField, 'License Plate Number'),
          findsNothing);
      expect(find.text('Upload Vehicle License'), findsNothing);
      expect(find.text('Upload Purchase Receipt / Proof of Ownership'),
          findsOneWidget);
      expect(find.text('Upload Government ID'), findsOneWidget);
      expect(find.text('Upload Full Frame Side Profile'), findsOneWidget);
      expect(find.textContaining('1 angle required'), findsOneWidget);
    });

    testWidgets('motorcycle shows 2 plate-photo slots', (tester) async {
      await _pumpForm(tester);
      await _selectCategory(tester, 'Motorcycle');

      expect(find.widgetWithText(TextField, 'License Plate Number'),
          findsOneWidget);
      expect(find.text('Upload Front View (Plate Visible)'), findsOneWidget);
      expect(find.text('Upload Rear View (Plate Visible)'), findsOneWidget);
    });

    testWidgets('photo guide modal lists every inspection angle',
        (tester) async {
      await _pumpForm(tester);

      await tester.tap(find.text('View Photo Guide'));
      await tester.pumpAndSettle();
      expect(find.text('Photo Guide — Car / Sedan'), findsOneWidget);
      expect(find.text('Front View'), findsOneWidget);
      expect(find.text('Interior / Dashboard'), findsOneWidget);
      await tester.tap(find.text('Got It'));
      await tester.pumpAndSettle();
      expect(find.text('Photo Guide — Car / Sedan'), findsNothing);
    });

    testWidgets('full car flow enables and submits registration',
        (tester) async {
      VehicleModel? registered;
      await _pumpForm(tester,
          onRegistered: (v) => registered = v);

      await _selectDropdown(tester, 'Vehicle Make', 'Toyota');
      await _selectDropdown(tester, 'Vehicle Model', 'Corolla');
      await _selectDropdown(
          tester, 'Manufacture Year', '${catalogYears().first}');
      await _selectDropdown(tester, 'Color', 'Silver');
      await tester.enterText(
          find.widgetWithText(TextField, 'License Plate Number'),
          'LAG-734-XY');
      await tester.pumpAndSettle();

      for (final label in [
        'Vehicle License',
        'Insurance Certificate',
        'Front View',
        'Rear View',
        'Driver Side',
        'Passenger Side',
        'Interior / Dashboard',
      ]) {
        await _uploadChip(tester, label);
        expect(find.text('$label (Attached)'), findsOneWidget);
      }

      final btn = tester.widget<FilledButton>(
          find.widgetWithText(FilledButton, 'Register Vehicle to Fleet'));
      expect(btn.enabled, isTrue);

      final registerFinder =
          find.widgetWithText(FilledButton, 'Register Vehicle to Fleet');
      await tester.ensureVisible(registerFinder);
      await tester.pumpAndSettle();
      await tester.tap(registerFinder);
      await tester.pumpAndSettle();

      expect(registered, isNotNull);
      expect(registered!.licensePlate, 'LAG-734-XY');
      expect(registered!.make, 'Toyota');
      expect(registered!.documents, hasLength(7));
    });
  });

  group('showVehiclePhotoGuide', () {
    testWidgets('bicycle guide shows its single slot', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (ctx) => FilledButton(
              onPressed: () => showVehiclePhotoGuide(
                  ctx, VehicleCategory.bicycle),
              child: const Text('open'),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      expect(find.text('Full Frame Side Profile'), findsOneWidget);
    });
  });
}
