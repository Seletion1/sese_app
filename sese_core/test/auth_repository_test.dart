import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sese_core/auth/firebase_auth_repository.dart';
import 'package:sese_core/models/user_model.dart';
import 'package:sese_core/models/user_role.dart';

void main() {
  group('FirebaseAuthRepository Google OAuth configuration', () {
    test('exposes defaultServerClientId matching Firebase Web OAuth client ID', () {
      expect(
        FirebaseAuthRepository.defaultServerClientId,
        '618721373016-m544iaqof5f8rss97282imlno0bhgbl7.apps.googleusercontent.com',
      );
    });

    test('instantiates with defaultServerClientId without throwing', () {
      final repo = FirebaseAuthRepository();
      expect(repo, isNotNull);
    });

    test('accepts custom serverClientId override', () {
      const customClientId = 'custom-test-client-id.apps.googleusercontent.com';
      final repo = FirebaseAuthRepository(serverClientId: customClientId);
      expect(repo, isNotNull);
    });
  });

  group('AppUser.fromMap date parsing robustness', () {
    test('correctly parses Firestore Timestamp without throwing', () {
      final now = DateTime.now();
      final timestamp = Timestamp.fromDate(now);
      final user = AppUser.fromMap({
        'uid': 'test-uid-123',
        'fullName': 'Test User',
        'email': 'test@example.com',
        'role': 'customer',
        'createdAt': timestamp,
      });

      expect(user.uid, 'test-uid-123');
      expect(user.role, UserRole.customer);
      expect(user.createdAt.millisecondsSinceEpoch, equals(now.millisecondsSinceEpoch));
    });

    test('correctly parses ISO-8601 String', () {
      final now = DateTime(2026, 9, 20, 8, 30, 0);
      final user = AppUser.fromMap({
        'uid': 'test-uid-456',
        'fullName': 'Test User 2',
        'email': 'test2@example.com',
        'role': 'driver',
        'createdAt': now.toIso8601String(),
      });

      expect(user.createdAt, equals(now));
    });
  });
}

