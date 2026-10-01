import 'package:flutter_test/flutter_test.dart';
import 'package:sese_core/services/privacy_service.dart';

void main() {
  group('PrivacyMasking.maskPhone', () {
    test('masks middle digits, keeps head and tail', () {
      expect(PrivacyMasking.maskPhone('08012345678'), '080****5678');
    });

    test('strips formatting before masking', () {
      expect(PrivacyMasking.maskPhone('+234 801 234 5678'), '234****5678');
    });

    test('short input returns fixed placeholder', () {
      expect(PrivacyMasking.maskPhone('123'), '••••••');
      expect(PrivacyMasking.maskPhone(''), '••••••');
    });

    test('display honors the toggle', () {
      expect(
          PrivacyMasking.display('08012345678', hide: true), '080****5678');
      expect(
          PrivacyMasking.display('08012345678', hide: false), '08012345678');
    });
  });
}
