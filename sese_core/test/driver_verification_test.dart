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
}
