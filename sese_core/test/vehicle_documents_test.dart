import 'package:flutter_test/flutter_test.dart';
import 'package:sese_core/sese_core.dart';

void main() {
  group('VehicleDocumentRequirements', () {
    test('bicycle skips plate/license/insurance, needs receipt + ID + 1 photo',
        () {
      final req =
          VehicleDocumentRequirements.forCategory(VehicleCategory.bicycle);
      expect(req.requiresLicensePlate, isFalse);
      expect(
          req.documents.map((s) => s.label),
          containsAll([
            'Purchase Receipt / Proof of Ownership',
            'Government ID',
          ]));
      expect(req.documents.map((s) => s.label),
          isNot(contains('Vehicle License')));
      expect(req.documents.map((s) => s.label),
          isNot(contains('Insurance Certificate')));
      expect(req.inspections, hasLength(1));
      expect(req.inspections.first.label, 'Full Frame Side Profile');
    });

    test('motorcycle/keke need plate docs + 2 plate-visible photos', () {
      for (final cat in [VehicleCategory.motorcycle, VehicleCategory.tricycle]) {
        final req = VehicleDocumentRequirements.forCategory(cat);
        expect(req.requiresLicensePlate, isTrue);
        expect(req.documents.map((s) => s.label),
            containsAll(['Vehicle License', 'Insurance / Roadworthiness']));
        expect(req.inspections.map((s) => s.label),
            ['Front View (Plate Visible)', 'Rear View (Plate Visible)']);
      }
    });

    test('car/van/truck need plate docs + 5 photos', () {
      for (final cat in [
        VehicleCategory.car,
        VehicleCategory.van,
        VehicleCategory.truck
      ]) {
        final req = VehicleDocumentRequirements.forCategory(cat);
        expect(req.requiresLicensePlate, isTrue);
        expect(req.documents.map((s) => s.label),
            containsAll(['Vehicle License', 'Insurance Certificate']));
        expect(req.inspections, hasLength(5));
        expect(
            req.inspections.map((s) => s.label),
            containsAll([
              'Front View',
              'Rear View',
              'Driver Side',
              'Passenger Side',
              'Interior / Dashboard',
            ]));
      }
    });

    test('slot keys are stable identifiers shared with the hub desk', () {
      final car =
          VehicleDocumentRequirements.forCategory(VehicleCategory.car);
      expect(car.slots.map((s) => s.key),
          containsAll(['vehicle_license', 'inspection_front']));
      final bike =
          VehicleDocumentRequirements.forCategory(VehicleCategory.bicycle);
      expect(bike.slots.map((s) => s.key),
          containsAll(['purchase_receipt', 'government_id']));
    });
  });
}
