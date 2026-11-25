import 'package:flutter_test/flutter_test.dart';
import 'package:sese_core/sese_core.dart';

void main() {
  group('AppUser & DriverVerification Unified Member ID', () {
    test('AppUser.fromMap parses sequentialId and verificationStatus correctly',
        () {
      final map = {
        'uid': 'user_123',
        'fullName': 'Micheal Bamiduro',
        'email': 'mb@sese.com',
        'role': 'customer',
        'verificationStatus': 'verified',
        'sequentialId': 'SC0042',
      };

      final user = AppUser.fromMap(map);
      expect(user.uid, 'user_123');
      expect(user.sequentialId, 'SC0042');
      expect(user.isVerified, isTrue);
    });

    test('AppUser.fromMap defaults sequentialId to empty string for unverified users',
        () {
      final map = {
        'uid': 'user_456',
        'fullName': 'New Customer',
        'email': 'nc@sese.com',
        'role': 'customer',
      };

      final user = AppUser.fromMap(map);
      expect(user.sequentialId, isEmpty);
      expect(user.isVerified, isFalse);
    });

    test('AppUser.toMap serializes sequentialId', () {
      final user = AppUser(
        uid: 'user_789',
        fullName: 'Driver Partner',
        email: 'driver@sese.com',
        phoneNumber: '+2348012345678',
        createdAt: DateTime.now(),
        role: UserRole.driver,
        verificationStatus: 'approved',
        sequentialId: 'SD0015',
      );

      final map = user.toMap();
      expect(map['sequentialId'], 'SD0015');
      expect(user.isVerified, isTrue);
    });

    test('DriverVerification constants contain sequentialId', () {
      expect(DriverVerification.sequentialId, 'sequentialId');
    });
  });
}
