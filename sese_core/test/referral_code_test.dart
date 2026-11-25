import 'package:flutter_test/flutter_test.dart';
import 'package:sese_core/sese_core.dart';

void main() {
  group('Unified Member ID & Referral Code Rules', () {
    test('normalizeReferralCode trims and uppercases input', () {
      expect(normalizeReferralCode('  sc0001  '), 'SC0001');
      expect(normalizeReferralCode('sd0042'), 'SD0042');
      expect(normalizeReferralCode('sh0001'), 'SH0001');
    });

    test('isPlausibleReferralCode accepts official verified Member IDs', () {
      expect(isPlausibleReferralCode('SC0001'), isTrue);
      expect(isPlausibleReferralCode('SD0001'), isTrue);
      expect(isPlausibleReferralCode('SH0001'), isTrue);
      expect(isPlausibleReferralCode('sc10000'), isTrue);
      expect(isPlausibleReferralCode('sd0099'), isTrue);
    });

    test('isPlausibleReferralCode rejects legacy or invalid formats', () {
      expect(isPlausibleReferralCode('MB1592'), isFalse);
      expect(isPlausibleReferralCode('BS0000'), isFalse);
      expect(isPlausibleReferralCode('SC001'), isFalse);
      expect(isPlausibleReferralCode('XX0001'), isFalse);
      expect(isPlausibleReferralCode(''), isFalse);
    });
  });
}
