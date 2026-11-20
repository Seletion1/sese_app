import 'package:flutter_test/flutter_test.dart';
import 'package:sese_core/sese_core.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  group('CustomerKycDraft Serialization & Immutability', () {
    test('toJson and fromJson preserves all fields', () {
      final now = DateTime(2026, 11, 20, 10, 30);
      final draft = CustomerKycDraft(
        firstName: 'Micheal',
        lastName: 'Bamiduro',
        dob: '2000-01-15',
        gender: 'Male',
        address: '12 Marina Road, Lagos',
        proofOfAddressPath: '/data/user/0/com.sesetech.ride/kyc_drafts/proof.jpg',
        occupation: 'Software Engineer',
        orgName: 'SeSe Tech',
        orgAddress: 'Victoria Island, Lagos',
        idType: 'NIN',
        idNumber: '12345678901',
        idFrontPath: '/data/user/0/com.sesetech.ride/kyc_drafts/front.jpg',
        idBackPath: '/data/user/0/com.sesetech.ride/kyc_drafts/back.jpg',
        selfiePath: '/data/user/0/com.sesetech.ride/kyc_drafts/selfie.jpg',
        updatedAt: now,
      );

      final json = draft.toJson();
      final restored = CustomerKycDraft.fromJson(json);

      expect(restored.firstName, 'Micheal');
      expect(restored.lastName, 'Bamiduro');
      expect(restored.dob, '2000-01-15');
      expect(restored.gender, 'Male');
      expect(restored.address, '12 Marina Road, Lagos');
      expect(restored.proofOfAddressPath, '/data/user/0/com.sesetech.ride/kyc_drafts/proof.jpg');
      expect(restored.occupation, 'Software Engineer');
      expect(restored.orgName, 'SeSe Tech');
      expect(restored.orgAddress, 'Victoria Island, Lagos');
      expect(restored.idType, 'NIN');
      expect(restored.idNumber, '12345678901');
      expect(restored.idFrontPath, '/data/user/0/com.sesetech.ride/kyc_drafts/front.jpg');
      expect(restored.idBackPath, '/data/user/0/com.sesetech.ride/kyc_drafts/back.jpg');
      expect(restored.selfiePath, '/data/user/0/com.sesetech.ride/kyc_drafts/selfie.jpg');
      expect(restored.updatedAt.isAtSameMomentAs(now), isTrue);
    });

    test('copyWith updates specific fields cleanly', () {
      final initial = CustomerKycDraft(
        firstName: 'John',
        lastName: 'Doe',
        updatedAt: DateTime.now(),
      );

      final updated = initial.copyWith(
        firstName: 'Jane',
        proofOfAddressPath: '/path/to/bill.jpg',
      );

      expect(updated.firstName, 'Jane');
      expect(updated.lastName, 'Doe');
      expect(updated.proofOfAddressPath, '/path/to/bill.jpg');
    });
  });

  group('DriverOnboardingDraft Serialization & Immutability', () {
    test('toJson and fromJson preserves all fields', () {
      final now = DateTime(2026, 11, 20, 11, 45);
      final draft = DriverOnboardingDraft(
        firstName: 'David',
        lastName: 'Ade',
        phone: '+2348161561592',
        dob: '1995-05-20',
        gender: 'Male',
        country: 'Nigeria',
        stateOrRegion: 'Lagos',
        address: '15 Broad Street, Lagos Island',
        addressLat: 6.4531,
        addressLng: 3.3958,
        idType: 'Driver\'s License',
        idNumber: 'DL12345678',
        idExpiryDate: '2028-12-31',
        kinName: 'Mary Ade',
        kinRelationship: 'Spouse (Wife / Husband)',
        kinRelationshipOther: '',
        kinPhone: '+2348022223333',
        kinAddress: '15 Broad Street, Lagos Island',
        idFrontPath: '/path/to/dl_front.jpg',
        idBackPath: '/path/to/dl_back.jpg',
        selfiePath: '/path/to/selfie.jpg',
        updatedAt: now,
      );

      final json = draft.toJson();
      final restored = DriverOnboardingDraft.fromJson(json);

      expect(restored.firstName, 'David');
      expect(restored.lastName, 'Ade');
      expect(restored.phone, '+2348161561592');
      expect(restored.dob, '1995-05-20');
      expect(restored.addressLat, 6.4531);
      expect(restored.addressLng, 3.3958);
      expect(restored.idType, 'Driver\'s License');
      expect(restored.idExpiryDate, '2028-12-31');
      expect(restored.kinName, 'Mary Ade');
      expect(restored.kinRelationship, 'Spouse (Wife / Husband)');
      expect(restored.idFrontPath, '/path/to/dl_front.jpg');
      expect(restored.idBackPath, '/path/to/dl_back.jpg');
      expect(restored.selfiePath, '/path/to/selfie.jpg');
      expect(restored.updatedAt.isAtSameMomentAs(now), isTrue);
    });
  });

  group('FormDraftManager Route & Target Tracking', () {
    test('pending picker target records and retrieves correctly', () async {
      final manager = FormDraftManager.instance;
      await manager.recordPendingPickerTarget(
        field: 'proof_of_address',
        userId: 'user_123',
        screen: 'customer_verification',
      );

      final target = await manager.getPendingPickerTarget();
      expect(target, isNotNull);
      expect(target!.field, 'proof_of_address');
      expect(target.screen, 'customer_verification');
      expect(target.userId, 'user_123');

      await manager.clearPendingPickerTarget();
      final cleared = await manager.getPendingPickerTarget();
      expect(cleared, isNull);
    });

    test('pending restore route persists and clears', () async {
      final manager = FormDraftManager.instance;
      await manager.setPendingRestoreRoute('user_456', 'customer_verification');

      final route = await manager.getPendingRestoreRoute('user_456');
      expect(route, 'customer_verification');

      await manager.clearPendingRestoreRoute('user_456');
      final clearedRoute = await manager.getPendingRestoreRoute('user_456');
      expect(clearedRoute, isNull);
    });

    test('customer KYC draft saving, loading and clearing', () async {
      final manager = FormDraftManager.instance;
      final draft = CustomerKycDraft(
        firstName: 'Test',
        lastName: 'User',
        dob: '1999-09-09',
        address: 'Test Address',
        updatedAt: DateTime.now(),
      );

      expect(await manager.hasCustomerKycDraft('test_uid'), isFalse);
      await manager.saveCustomerKycDraft('test_uid', draft);
      expect(await manager.hasCustomerKycDraft('test_uid'), isTrue);

      final loaded = await manager.loadCustomerKycDraft('test_uid');
      expect(loaded, isNotNull);
      expect(loaded!.firstName, 'Test');
      expect(loaded.lastName, 'User');

      await manager.clearCustomerKycDraft('test_uid');
      expect(await manager.hasCustomerKycDraft('test_uid'), isFalse);
    });

    test('driver onboarding draft saving, loading and clearing', () async {
      final manager = FormDraftManager.instance;
      final draft = DriverOnboardingDraft(
        firstName: 'Driver',
        lastName: 'Test',
        phone: '+2348000000000',
        idNumber: '123456',
        updatedAt: DateTime.now(),
      );

      expect(await manager.hasDriverOnboardingDraft('driver_uid'), isFalse);
      await manager.saveDriverOnboardingDraft('driver_uid', draft);
      expect(await manager.hasDriverOnboardingDraft('driver_uid'), isTrue);

      final loaded = await manager.loadDriverOnboardingDraft('driver_uid');
      expect(loaded, isNotNull);
      expect(loaded!.firstName, 'Driver');
      expect(loaded.idNumber, '123456');

      await manager.clearDriverOnboardingDraft('driver_uid');
      expect(await manager.hasDriverOnboardingDraft('driver_uid'), isFalse);
    });
  });
}
