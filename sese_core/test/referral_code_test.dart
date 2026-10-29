import 'package:flutter_test/flutter_test.dart';
import 'package:sese_core/referral/referral_code.dart';

void main() {
  group('Referral Code Generation Rules', () {
    test('Format Rule: FirstInitial + LastInitial + Last4Digits (Micheal Bamiduro)', () {
      final code = generateReferralCode(
        fullName: 'Micheal Bamiduro',
        phoneNumber: '08161561592',
      );
      expect(code, 'MB1592');
    });

    test('Single-word full name uses same initial twice', () {
      final code = generateReferralCode(
        fullName: 'Micheal',
        phoneNumber: '08161561592',
      );
      expect(code, 'MM1592');
    });

    test('Short phone number left-padded with 0s', () {
      final code = generateReferralCode(
        fullName: 'John Doe',
        phoneNumber: '92',
      );
      expect(code, 'JD0092');
    });

    test('generateReferralCodeFromNames matches specification', () {
      final code = generateReferralCodeFromNames(
        'Micheal',
        'Bamiduro',
        '08161561592',
      );
      expect(code, 'MB1592');
    });

    test('Collision Handling: Incrementally appends counter', () {
      final base = generateReferralCode(
        fullName: 'Micheal Bamiduro',
        phoneNumber: '08161561592',
      ); // MB1592

      expect(withCounterUniqueness(base, 0), 'MB1592');
      expect(withCounterUniqueness(base, 1), 'MB15921');
      expect(withCounterUniqueness(base, 2), 'MB15922');
      expect(withCounterUniqueness(base, 3), 'MB15923');
    });

    test('isPlausibleReferralCode validates base and counter-appended codes', () {
      expect(isPlausibleReferralCode('MB1592'), isTrue);
      expect(isPlausibleReferralCode('MB15921'), isTrue);
      expect(isPlausibleReferralCode('MB15922'), isTrue);
      expect(isPlausibleReferralCode('MB15923'), isTrue);
      expect(isPlausibleReferralCode('mb1592'), isTrue);
      expect(isPlausibleReferralCode('MB1592-2'), isTrue); // legacy suffix format
      expect(isPlausibleReferralCode('INVALID'), isFalse);
      expect(isPlausibleReferralCode('M1592'), isFalse);
    });
  });
}
