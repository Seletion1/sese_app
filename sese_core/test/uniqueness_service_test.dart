import 'package:flutter_test/flutter_test.dart';
import 'package:sese_core/sese_core.dart';

void main() {
  group('UniquenessService Normalization Tests', () {
    test('Phone normalization handles local and formatted numbers', () {
      expect(UniquenessService.normalizePhone('08012345678'), '+2348012345678');
      expect(UniquenessService.normalizePhone('080-1234-5678'), '+2348012345678');
      expect(UniquenessService.normalizePhone('+234 801 234 5678'), '+2348012345678');
      expect(UniquenessService.normalizePhone('2348012345678'), '+2348012345678');
      expect(UniquenessService.normalizePhone('+1 (555) 123-4567'), '+15551234567');
    });

    test('Email normalization canonicalizes Gmail dots and plus aliases', () {
      expect(
        UniquenessService.normalizeEmail('john.doe@gmail.com'),
        'johndoe@gmail.com',
      );
      expect(
        UniquenessService.normalizeEmail('johndoe+ride@gmail.com'),
        'johndoe@gmail.com',
      );
      expect(
        UniquenessService.normalizeEmail('John.Doe+promo99@googlemail.com'),
        'johndoe@gmail.com',
      );
      expect(
        UniquenessService.normalizeEmail('Staff.User@Company.org'),
        'staff.user@company.org',
      );
    });

    test('NIN and BVN normalizers strip non-numeric characters', () {
      expect(UniquenessService.normalizeNin('123-456-789-01'), '12345678901');
      expect(UniquenessService.normalizeNin(' 12345678901 '), '12345678901');
      expect(UniquenessService.normalizeBvn('BVN: 22334455667'), '22334455667');
    });

    test('Vehicle plate and passport normalizers uppercase and strip symbols', () {
      expect(UniquenessService.normalizePlateNumber('lag-123-aa'), 'LAG123AA');
      expect(UniquenessService.normalizePlateNumber(' kja 456 xy '), 'KJA456XY');
      expect(UniquenessService.normalizePassport(' a12345678 '), 'A12345678');
    });

    test('IdentifierAvailabilityResult parses response correctly and sanitizes error message', () {
      final res = IdentifierAvailabilityResult.fromMap({
        'available': false,
        'selfOwned': false,
        'maskedValue': '+234••••••78',
        'message': 'Please check your details and try again.',
      });
      expect(res.available, false);
      expect(res.selfOwned, false);
      expect(res.maskedValue, '+234••••••78');
      expect(res.message, 'Please check your details and try again.');
    });
  });
}
