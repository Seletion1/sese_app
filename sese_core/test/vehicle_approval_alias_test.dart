import 'package:flutter_test/flutter_test.dart';
import 'package:sese_core/sese_core.dart';

/// Guards the sese_ride ↔ sese_hub fleet review contract:
/// - ride writes `drivers/{uid}/vehicles/{id}` with
///   `verificationStatus: 'PENDING'`;
/// - hub approves with `verificationStatus: 'APPROVED'` plus the legacy
///   aliases `isVerified: true` / `status: 'active'`;
/// - ride reads either shape as approved (live update, no re-registration).
void main() {
  Map<String, dynamic> pendingDoc() => {
        'id': 'veh_1',
        'driverId': 'driver_1',
        'category': 'car',
        'make': 'Toyota',
        'model': 'Corolla',
        'year': 2018,
        'licensePlate': 'LAG-734-XY',
        'color': 'Silver',
        'documents': <String, String>{},
        'verificationStatus': 'PENDING',
        'lifecycleStatus': 'ACTIVE',
        'isActiveSelected': false,
        'createdAt': '2024-01-01T00:00:00.000',
        'updatedAt': '2024-01-01T00:00:00.000',
      };

  group('fleet review contract', () {
    test('fresh registration parses as pending, not approved', () {
      final v = VehicleModel.fromMap(pendingDoc(), id: 'veh_1');
      expect(v.verificationStatus, VehicleVerificationStatus.pending);
      expect(v.isApproved, isFalse);
      expect(v.displayTitle, '2018 Toyota Corolla (LAG-734-XY)');
    });

    test('hub approval (canonical + aliases) parses as approved', () {
      final doc = pendingDoc()
        ..['verificationStatus'] = 'APPROVED'
        ..['isVerified'] = true
        ..['status'] = 'active';
      final v = VehicleModel.fromMap(doc, id: 'veh_1');
      expect(v.verificationStatus, VehicleVerificationStatus.approved);
      expect(v.isApproved, isTrue);
    });

    test('legacy isVerified alias alone upgrades to approved', () {
      final doc = pendingDoc()..['isVerified'] = true;
      final v = VehicleModel.fromMap(doc, id: 'veh_1');
      expect(v.isApproved, isTrue);
    });

    test('hub rejection parses as rejected, never approved', () {
      final doc = pendingDoc()
        ..['verificationStatus'] = 'REJECTED'
        ..['isVerified'] = false
        ..['status'] = 'rejected';
      final v = VehicleModel.fromMap(doc, id: 'veh_1');
      expect(v.verificationStatus, VehicleVerificationStatus.rejected);
      expect(v.isApproved, isFalse);
    });

    test('toDbString round-trips the hub queue filter value', () {
      expect(VehicleVerificationStatus.pending.toDbString(), 'PENDING');
      expect(VehicleVerificationStatus.approved.toDbString(), 'APPROVED');
      expect(VehicleVerificationStatus.rejected.toDbString(), 'REJECTED');
    });
  });
}
