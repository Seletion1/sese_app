import 'package:flutter_test/flutter_test.dart';
import 'package:sese_core/sese_core.dart';

void main() {
  group('DriverVerification constants', () {
    test('lifecycle tokens match the onboarding contract', () {
      expect(DriverVerification.pendingOnboarding, 'pending_onboarding');
      expect(DriverVerification.pending, 'pending');
      expect(DriverVerification.approved, 'approved');
      expect(DriverVerification.fieldProfileVerified, 'isProfileVerified');
      expect(DriverVerification.fieldVehicleVerified, 'isVehicleVerified');
      expect(DriverVerification.fieldCanGoOnline, 'canGoOnline');
    });

    test('customer verification tokens match the profile contract', () {
      expect(CustomerVerification.pending, 'pending');
      expect(CustomerVerification.verified, 'verified');
      expect(CustomerVerification.fieldStatus, 'customerVerificationStatus');
      expect(CustomerVerification.fieldIsVerified, 'isVerifiedCustomer');
    });
  });

  group('AppUser verification routing', () {
    test('pending_onboarding drivers route to Step 2', () {
      final user = AppUser(
        uid: 'd1',
        fullName: 'Driver One',
        email: 'd@example.com',
        phoneNumber: '+2348012345678',
        role: UserRole.driver,
        isActive: false,
        createdAt: DateTime(2026, 1, 1),
        verificationStatus: DriverVerification.pendingOnboarding,
      );
      expect(user.isPendingOnboarding, isTrue);
      expect(user.isPendingDriver, isTrue);
    });

    test('verificationStatus round-trips through toMap/fromMap', () {
      final user = AppUser(
        uid: 'd2',
        fullName: 'Driver Two',
        email: 'd2@example.com',
        phoneNumber: '',
        role: UserRole.driver,
        isActive: false,
        createdAt: DateTime(2026, 1, 1),
        verificationStatus: DriverVerification.pending,
      );
      final restored = AppUser.fromMap(user.toMap());
      expect(restored.verificationStatus, DriverVerification.pending);
      expect(restored.isPendingOnboarding, isFalse);
    });

    test('customers default to empty status', () {
      final user = AppUser(
        uid: 'c1',
        fullName: 'Customer',
        email: 'c@example.com',
        phoneNumber: '',
        role: UserRole.customer,
        createdAt: DateTime(2026, 1, 1),
      );
      expect(user.verificationStatus, isEmpty);
      expect(user.isPendingOnboarding, isFalse);
    });
  });

  group('FieldReviewStatus model', () {
    test('creates approved, pending, and rejected statuses', () {
      expect(FieldReviewStatus.approved.isApproved, isTrue);
      expect(FieldReviewStatus.approved.isRejected, isFalse);
      expect(FieldReviewStatus.approved.reason, isNull);

      expect(FieldReviewStatus.pending.isPending, isTrue);

      final rej = FieldReviewStatus.rejected('Blurry ID document');
      expect(rej.isRejected, isTrue);
      expect(rej.isApproved, isFalse);
      expect(rej.reason, 'Blurry ID document');
    });

    test('serializes toMap and deserializes fromMap', () {
      final status = FieldReviewStatus.rejected('License expired');
      final map = status.toMap();
      expect(map['status'], 'rejected');
      expect(map['reason'], 'License expired');

      final restored = FieldReviewStatus.fromMap(map);
      expect(restored.status, 'rejected');
      expect(restored.reason, 'License expired');
      expect(restored.isRejected, isTrue);
    });
  });

  group('VehicleModel rejection and granular review status', () {
    test('round-trips rejectionReason and fieldReviewStatus', () {
      final vehicle = VehicleModel(
        id: 'v1',
        driverId: 'd1',
        category: VehicleCategory.car,
        make: 'Toyota',
        model: 'Corolla',
        year: 2020,
        licensePlate: 'ABC-123',
        color: 'Silver',
        verificationStatus: VehicleVerificationStatus.rejected,
        rejectionReason: 'Insurance document expired',
        fieldReviewStatus: {
          'insurance': FieldReviewStatus.rejected('Expired last week'),
          'inspection': FieldReviewStatus.approved,
        },
        createdAt: DateTime(2026, 1, 1),
        updatedAt: DateTime(2026, 1, 2),
      );

      expect(vehicle.isRejected, isTrue);
      expect(vehicle.isApproved, isFalse);
      expect(vehicle.rejectionReason, 'Insurance document expired');
      expect(vehicle.fieldReviewStatus['insurance']?.isRejected, isTrue);
      expect(vehicle.fieldReviewStatus['inspection']?.isApproved, isTrue);

      final map = vehicle.toMap();
      expect(map['rejectionReason'], 'Insurance document expired');
      expect(map['verificationStatus'], 'REJECTED');

      final restored = VehicleModel.fromMap(map, id: 'v1');
      expect(restored.isRejected, isTrue);
      expect(restored.rejectionReason, 'Insurance document expired');
      expect(restored.fieldReviewStatus['insurance']?.reason, 'Expired last week');
      expect(restored.fieldReviewStatus['inspection']?.isApproved, isTrue);
    });
  });
}
