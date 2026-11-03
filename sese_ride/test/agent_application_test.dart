import 'package:flutter_test/flutter_test.dart';
import 'package:sese_core/sese_core.dart';

void main() {
  group('AdminApplication Model Tests', () {
    final now = DateTime(2026, 11, 3, 12, 0, 0);

    test('serialization toMap and fromMap works correctly', () {
      final app = AdminApplication(
        uid: 'user_123',
        fullName: 'Micheal Bamiduro',
        firstName: 'Micheal',
        middleName: 'O',
        lastName: 'Bamiduro',
        email: 'micheal@example.com',
        phoneNumber: '+2348161561592',
        dob: '1998-12-31',
        idType: 'NIN',
        idUrl: 'https://storage.example.com/id.jpg',
        proofOfAddressUrl: 'https://storage.example.com/address.jpg',
        selfieUrl: 'https://storage.example.com/selfie.jpg',
        deviceMetadata: {'platform': 'android', 'osVersion': '14'},
        status: 'pending',
        submittedAt: now,
        updatedAt: now,
      );

      final map = app.toMap();
      expect(map['uid'], 'user_123');
      expect(map['fullName'], 'Micheal Bamiduro');
      expect(map['status'], 'pending');

      final reconstructed = AdminApplication.fromMap('user_123', map);
      expect(reconstructed.uid, 'user_123');
      expect(reconstructed.fullName, 'Micheal Bamiduro');
      expect(reconstructed.firstName, 'Micheal');
      expect(reconstructed.idType, 'NIN');
      expect(reconstructed.isPending, isTrue);
      expect(reconstructed.isApproved, isFalse);
      expect(reconstructed.isRejected, isFalse);
    });

    test('status getters work as expected', () {
      final pendingApp = AdminApplication(
        uid: 'u1',
        fullName: 'Test User',
        firstName: 'Test',
        lastName: 'User',
        email: 'test@example.com',
        phoneNumber: '+234123456789',
        dob: '2000-01-01',
        idType: 'Passport',
        idUrl: 'id.jpg',
        proofOfAddressUrl: 'proof.jpg',
        selfieUrl: 'selfie.jpg',
        status: 'pending',
        submittedAt: now,
        updatedAt: now,
      );

      expect(pendingApp.isPending, isTrue);
      expect(pendingApp.isApproved, isFalse);
      expect(pendingApp.isRejected, isFalse);

      final approvedApp = pendingApp.copyWith(status: 'approved');
      expect(approvedApp.isPending, isFalse);
      expect(approvedApp.isApproved, isTrue);
      expect(approvedApp.isRejected, isFalse);

      final rejectedApp = pendingApp.copyWith(
        status: 'rejected',
        rejectionReason: 'ID expired',
      );
      expect(rejectedApp.isPending, isFalse);
      expect(rejectedApp.isApproved, isFalse);
      expect(rejectedApp.isRejected, isTrue);
      expect(rejectedApp.rejectionReason, 'ID expired');
    });
  });
}
