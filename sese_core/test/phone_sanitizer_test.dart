import 'package:flutter_test/flutter_test.dart';
import 'package:sese_core/services/phone_sanitizer.dart';

void main() {
  group('SesePhoneSanitizer', () {
    test('parses local Nigerian number without leading zero as NG, not JP', () {
      final res = SesePhoneSanitizer.parse('8161561592', defaultIsoCode: 'NG');
      expect(res.isoCode, equals('NG'));
      expect(res.dialCode, equals('+234'));
      expect(res.nationalNumber, equals('8161561592'));
      expect(res.e164, equals('+2348161561592'));
      expect(res.hasExplicitCountryPrefix, isFalse);
    });

    test('parses local Nigerian number with leading zero as NG', () {
      final res = SesePhoneSanitizer.parse('08161561592', defaultIsoCode: 'NG');
      expect(res.isoCode, equals('NG'));
      expect(res.dialCode, equals('+234'));
      expect(res.e164, equals('+2348161561592'));
    });

    test('parses full E.164 Nigerian number (+2348161561592) as NG', () {
      final res = SesePhoneSanitizer.parse('+2348161561592', defaultIsoCode: 'NG');
      expect(res.isoCode, equals('NG'));
      expect(res.dialCode, equals('+234'));
      expect(res.nationalNumber, equals('8161561592'));
      expect(res.e164, equals('+2348161561592'));
      expect(res.hasExplicitCountryPrefix, isTrue);
    });

    test('parses un-prefixed dial code 2348161561592 as NG with explicit prefix', () {
      final res = SesePhoneSanitizer.parse('2348161561592', defaultIsoCode: 'NG');
      expect(res.isoCode, equals('NG'));
      expect(res.dialCode, equals('+234'));
      expect(res.nationalNumber, equals('8161561592'));
      expect(res.e164, equals('+2348161561592'));
    });

    test('parses explicitly prefixed foreign number (+8161561592) as JP', () {
      final res = SesePhoneSanitizer.parse('+8161561592', defaultIsoCode: 'NG');
      expect(res.isoCode, equals('JP'));
      expect(res.dialCode, equals('+81'));
      expect(res.hasExplicitCountryPrefix, isTrue);
    });
  });
}
