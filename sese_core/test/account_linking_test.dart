import 'package:flutter_test/flutter_test.dart';
import 'package:sese_core/models/user_model.dart';
import 'package:sese_core/models/user_role.dart';

void main() {
  group('Account Linking & Single UID Consistency Tests', () {
    test('Manual registration initializes AppUser with correct UID and role', () {
      const uid = 'manual-user-uid-123';
      const email = 'manual.user@example.com';
      const fullName = 'Manual User';

      final user = AppUser(
        uid: uid,
        fullName: fullName,
        email: email,
        phoneNumber: '+2348012345678',
        role: UserRole.customer,
        isActive: true,
        createdAt: DateTime(2026, 11, 11),
      );

      final mapData = user.toMap();
      expect(mapData['uid'], equals(uid));
      expect(mapData['email'], equals(email));
      expect(mapData['role'], equals('customer'));

      final reconstructed = AppUser.fromMap(mapData);
      expect(reconstructed.uid, equals(uid));
      expect(reconstructed.email, equals(email));
      expect(reconstructed.role, equals(UserRole.customer));
    });

    test('Account linking merges Google metadata and preserves canonical UID', () {
      const canonicalUid = 'canonical-manual-uid-999';
      const googleAliasUid = 'google-oauth-uid-888';
      const email = 'shared.account@example.com';

      // Existing manual user document profile
      final manualProfileMap = <String, dynamic>{
        'uid': canonicalUid,
        'fullName': 'Shared User',
        'email': email,
        'phoneNumber': '+2348099998888',
        'role': 'customer',
        'authProviders': ['password'],
        'createdAt': '2026-11-10T10:00:00.000Z',
      };

      // Google Sign-In linking alias map pointing to canonicalUid
      final aliasLinkMap = <String, dynamic>{
        'linkedUid': canonicalUid,
        'email': email,
        'role': 'customer',
        'authProviders': ['password', 'google.com'],
      };

      expect(aliasLinkMap['linkedUid'], equals(canonicalUid));

      // Resolving canonical profile from alias link
      final resolvedUid = (aliasLinkMap['linkedUid'] as String?) ?? googleAliasUid;
      manualProfileMap['uid'] = resolvedUid;

      final linkedUser = AppUser.fromMap(manualProfileMap);

      // Session maps cleanly to single consistent UID
      expect(linkedUser.uid, equals(canonicalUid));
      expect(linkedUser.email, equals(email));
      expect(linkedUser.role, equals(UserRole.customer));
    });

    test('Driver account linking preserves driver onboarding status and canonical UID', () {
      const canonicalDriverUid = 'driver-canonical-uid-555';
      const email = 'driver.linking@example.com';

      final driverProfileMap = <String, dynamic>{
        'uid': canonicalDriverUid,
        'fullName': 'Licensed Driver',
        'email': email,
        'phoneNumber': '+2348077776666',
        'role': 'driver',
        'verificationStatus': 'approved',
        'authProviders': ['password', 'google.com'],
        'createdAt': '2026-10-01T12:00:00.000Z',
      };

      final driverUser = AppUser.fromMap(driverProfileMap);
      expect(driverUser.uid, equals(canonicalDriverUid));
      expect(driverUser.role, equals(UserRole.driver));
      expect(driverUser.verificationStatus, equals('approved'));
    });
  });
}
