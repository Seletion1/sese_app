import 'vehicle_category.dart';

/// Kind of a registration document slot.
enum VehicleDocKind {
  /// Ownership / legal paperwork (license, insurance, receipt, gov ID).
  document,

  /// Angle-specific vehicle inspection photo.
  inspection,
}

/// One required upload slot for a vehicle category.
///
/// [key] is the stable Firestore map key stored in
/// `VehicleModel.documents` — shared by the sese_ride registration form
/// and the sese_hub verification desk, so both sides always agree.
/// [label] is the human-readable slot name shown in both apps.
class VehicleDocSlot {
  final String key;
  final String label;
  final VehicleDocKind kind;

  /// Short framing instruction shown in the sese_ride photo guide.
  final String guide;

  const VehicleDocSlot({
    required this.key,
    required this.label,
    required this.kind,
    this.guide = '',
  });
}

/// Category-specific registration contract shared by the sese_ride
/// Deploy form and the sese_hub verification desk.
///
/// - Bicycles need no plate/license/insurance: proof of ownership + gov
///   ID + a single side-profile photo.
/// - Motorcycles/tricycles: plate + license + roadworthiness + 2 photos.
/// - Cars/vans/trucks: plate + license + insurance + 5 photos.
class VehicleDocumentRequirements {
  final bool requiresLicensePlate;
  final List<VehicleDocSlot> slots;

  const VehicleDocumentRequirements({
    required this.requiresLicensePlate,
    required this.slots,
  });

  List<VehicleDocSlot> get documents => slots
      .where((s) => s.kind == VehicleDocKind.document)
      .toList(growable: false);

  List<VehicleDocSlot> get inspections => slots
      .where((s) => s.kind == VehicleDocKind.inspection)
      .toList(growable: false);

  static VehicleDocumentRequirements forCategory(VehicleCategory category) {
    switch (category) {
      case VehicleCategory.bicycle:
        return const VehicleDocumentRequirements(
          requiresLicensePlate: false,
          slots: [
            VehicleDocSlot(
              key: 'purchase_receipt',
              label: 'Purchase Receipt / Proof of Ownership',
              kind: VehicleDocKind.document,
            ),
            VehicleDocSlot(
              key: 'government_id',
              label: 'Government ID',
              kind: VehicleDocKind.document,
            ),
            VehicleDocSlot(
              key: 'inspection_side_profile',
              label: 'Full Frame Side Profile',
              kind: VehicleDocKind.inspection,
              guide: 'Stand back and capture the entire bicycle from the '
                  'side — both wheels, frame, and handlebar fully in frame.',
            ),
          ],
        );
      case VehicleCategory.motorcycle:
      case VehicleCategory.tricycle:
        return const VehicleDocumentRequirements(
          requiresLicensePlate: true,
          slots: [
            VehicleDocSlot(
              key: 'vehicle_license',
              label: 'Vehicle License',
              kind: VehicleDocKind.document,
            ),
            VehicleDocSlot(
              key: 'insurance_roadworthiness',
              label: 'Insurance / Roadworthiness',
              kind: VehicleDocKind.document,
            ),
            VehicleDocSlot(
              key: 'inspection_front_plate',
              label: 'Front View (Plate Visible)',
              kind: VehicleDocKind.inspection,
              guide: 'Face the bike head-on: headlamp centered and the '
                  'front plate number clearly readable.',
            ),
            VehicleDocSlot(
              key: 'inspection_rear_plate',
              label: 'Rear View (Plate Visible)',
              kind: VehicleDocKind.inspection,
              guide: 'Stand directly behind: tail lamp centered and the '
                  'rear plate number clearly readable.',
            ),
          ],
        );
      case VehicleCategory.car:
      case VehicleCategory.van:
      case VehicleCategory.truck:
        return const VehicleDocumentRequirements(
          requiresLicensePlate: true,
          slots: [
            VehicleDocSlot(
              key: 'vehicle_license',
              label: 'Vehicle License',
              kind: VehicleDocKind.document,
            ),
            VehicleDocSlot(
              key: 'insurance_certificate',
              label: 'Insurance Certificate',
              kind: VehicleDocKind.document,
            ),
            VehicleDocSlot(
              key: 'inspection_front',
              label: 'Front View',
              kind: VehicleDocKind.inspection,
              guide: 'Face the vehicle head-on: full width, headlamps and '
                  'plate clearly visible.',
            ),
            VehicleDocSlot(
              key: 'inspection_rear',
              label: 'Rear View',
              kind: VehicleDocKind.inspection,
              guide: 'Stand directly behind: full width, tail lamps and '
                  'plate clearly visible.',
            ),
            VehicleDocSlot(
              key: 'inspection_driver_side',
              label: 'Driver Side',
              kind: VehicleDocKind.inspection,
              guide: 'Full driver-side profile: both doors, mirrors, and '
                  'wheels fully in frame.',
            ),
            VehicleDocSlot(
              key: 'inspection_passenger_side',
              label: 'Passenger Side',
              kind: VehicleDocKind.inspection,
              guide: 'Full passenger-side profile: both doors, mirrors, '
                  'and wheels fully in frame.',
            ),
            VehicleDocSlot(
              key: 'inspection_interior',
              label: 'Interior / Dashboard',
              kind: VehicleDocKind.inspection,
              guide: 'From the driver door: steering wheel, dashboard, '
                  'and front seats clearly visible.',
            ),
          ],
        );
    }
  }
}
