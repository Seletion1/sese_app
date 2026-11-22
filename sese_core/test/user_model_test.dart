import 'package:flutter_test/flutter_test.dart';
import 'package:sese_core/sese_core.dart';

void main() {
  group('AppUser & DriverVerification Sequential ID & Referral Code', () {
    test('AppUser.fromMap parses sequentialId and referralCode correctly', () {
      final map = {
        'uid': 'user_123',
        'fullName': 'Micheal Bamiduro',
        'email': 'mb@sese.com',
        'role': 'customer',
        'sequentialId': 'SC0042',
        'referralCode': 'MB1592',
      };

      final user = AppUser.fromMap(map);
      expect(user.uid, 'user_123');
      expect(user.sequentialId, 'SC0042');
      expect(user.referralCode, 'MB1592');
    });

    test('AppUser.fromMap defaults sequentialId and referralCode to empty strings', () {
      final map = {
        'uid': 'user_456',
        'fullName': 'New Customer',
        'email': 'nc@sese.com',
        'role': 'customer',
      };

      final user = AppUser.fromMap(map);
      expect(user.sequentialId, isEmpty);
      expect(user.referralCode, isEmpty);
    });

    test('AppUser.toMap serializes sequentialId and referralCode', () {
      final user = AppUser(
        uid: 'user_789',
        fullName: 'Driver Partner',
        email: 'driver@sese.com',
        phoneNumber: '+2348012345678',
        createdAt: DateTime.now(),
        role: UserRole.driver,
        sequentialId: 'SD0015',
        referralCode: 'DP9999',
      );

      final map = user.toMap();
      expect(map['sequentialId'], 'SD0015');
      expect(map['referralCode'], 'DP9999');
    });

    test('DriverVerification constants contain sequentialId and referralCode', () {
      expect(DriverVerification.sequentialId, 'sequentialId');
      expect(DriverVerification.referralCode, 'referralCode');
    });
  });
}
