import 'package:flutter_test/flutter_test.dart';
import 'package:sese_core/sese_core.dart';
import 'package:sese_ride/features/customer/services/driver_to_customer_sync.dart';

/// Approved driver doc as written by driver onboarding submit.
Map<String, dynamic> _approvedDriver({
  String verificationStatus = 'approved',
  Map<String, dynamic>? overrides,
}) {
  final map = <String, dynamic>{
    'uid': 'driver-1',
    'firstName': 'Bamiduro',
    'lastName': 'Micheal',
    'fullName': 'Bamiduro Micheal',
    'email': 'bamiduromicheal@gmail.com',
    'phoneNumber': '+2348161561592',
    'phoneNumberE164': '+2348161561592',
    'dateOfBirth': '1990-05-14',
    'gender': 'Male',
    'homeAddress': '14 Isiaka jimoh street, Ikorodu',
    'idType': 'NIN',
    'idNumber': '12345678901',
    'idFrontUrl': 'https://example.com/id_front.jpg',
    'idBackUrl': 'https://example.com/id_back.jpg',
    'selfieUrl': 'https://example.com/selfie.jpg',
    'verificationStatus': verificationStatus,
    'isProfileVerified': true,
    'isVehicleVerified': true,
  };
  if (overrides != null) map.addAll(overrides);
  return map;
}

void main() {
  group('isApprovedDriverDoc', () {
    test('approved driver matches', () {
      expect(
          DriverToCustomerSync.isApprovedDriverDoc(_approvedDriver()),
          isTrue);
    });

    test('pending / rejected / missing docs do not match', () {
      expect(
          DriverToCustomerSync.isApprovedDriverDoc(
              _approvedDriver(verificationStatus: 'pending')),
          isFalse);
      expect(
          DriverToCustomerSync.isApprovedDriverDoc(
              _approvedDriver(verificationStatus: 'rejected')),
          isFalse);
      expect(DriverToCustomerSync.isApprovedDriverDoc(null), isFalse);
      expect(DriverToCustomerSync.isApprovedDriverDoc({}), isFalse);
    });
  });

  group('buildMirrorUpdate', () {
    test('fills empty customer profile from approved driver', () {
      final update = DriverToCustomerSync.buildMirrorUpdate(
        driver: _approvedDriver(),
        user: const {},
      );

      expect(update['firstName'], 'Bamiduro');
      expect(update['lastName'], 'Micheal');
      expect(update['fullName'], 'Bamiduro Micheal');
      expect(update['phoneNumber'], '+2348161561592');

      final kyc = update[CustomerVerification.fieldKycData] as Map;
      expect(kyc['firstName'], 'Bamiduro');
      expect(kyc['dateOfBirth'], '1990-05-14');
      expect(kyc['gender'], 'Male');
      expect(kyc['residentialAddress'], '14 Isiaka jimoh street, Ikorodu');
      expect(kyc['idType'], 'NIN');
      expect(kyc['idNumber'], '12345678901');
      expect(kyc['idFrontUrl'], 'https://example.com/id_front.jpg');
      expect(kyc['idBackUrl'], 'https://example.com/id_back.jpg');
      expect(kyc['selfieUrl'], 'https://example.com/selfie.jpg');

      // Verified flags are always asserted for approved drivers.
      expect(update[CustomerVerification.fieldStatus],
          CustomerVerification.verified);
      expect(update[CustomerVerification.fieldIsVerified], isTrue);
    });

    test('never overwrites existing customer data', () {
      final update = DriverToCustomerSync.buildMirrorUpdate(
        driver: _approvedDriver(),
        user: {
          'firstName': 'CustomerFirst',
          'phoneNumber': '+10000000000',
          CustomerVerification.fieldKycData: {
            'residentialAddress': 'Customer address',
            'idNumber': '999',
          },
        },
      );

      expect(update.containsKey('firstName'), isFalse);
      expect(update.containsKey('phoneNumber'), isFalse);
      // Last name was empty on the customer side → filled from driver.
      expect(update['lastName'], 'Micheal');

      final kyc = update[CustomerVerification.fieldKycData] as Map;
      expect(kyc['residentialAddress'], 'Customer address');
      expect(kyc['idNumber'], '999');
      // Empty customer KYC slots still fill.
      expect(kyc['selfieUrl'], 'https://example.com/selfie.jpg');

      // Flags still asserted.
      expect(update[CustomerVerification.fieldStatus],
          CustomerVerification.verified);
    });

    test('falls back to address/fullName parts when primary keys absent', () {
      final update = DriverToCustomerSync.buildMirrorUpdate(
        driver: _approvedDriver(overrides: {
          'fullName': '',
          'homeAddress': '',
          'address': 'Fallback address',
        }),
        user: const {},
      );

      expect(update['fullName'], 'Bamiduro Micheal');
      final kyc = update[CustomerVerification.fieldKycData] as Map;
      expect(kyc['residentialAddress'], 'Fallback address');
    });
  });

  group('syncIfApprovedDriver / isApprovedDriver (no backend)', () {
    test('empty uid short-circuits to false without touching Firestore',
        () async {
      expect(await DriverToCustomerSync.syncIfApprovedDriver(''), isFalse);
      expect(await DriverToCustomerSync.isApprovedDriver(''), isFalse);
    });
  });
}
