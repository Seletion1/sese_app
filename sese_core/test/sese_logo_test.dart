import 'package:flutter_test/flutter_test.dart';
import 'package:sese_core/widgets/sese_logo.dart';

void main() {
  group('SeSeLogo brand vectors', () {
    test('ride mark matches the brand arc + SeSe wordmark', () {
      expect(SeSeLogo.rawSvg, contains('seseGoldArc'));
      expect(SeSeLogo.rawSvg, contains('#FFC107'));
      expect(SeSeLogo.rawSvg, contains('#FF9800'));
      expect(SeSeLogo.rawSvg, contains('#E65100'));
      expect(SeSeLogo.rawSvg, contains('>SeSe<'));
    });

    test('hub mark adds the HUB wordmark', () {
      expect(SeSeLogo.rawSvgHub, contains('seseGoldArc'));
      expect(SeSeLogo.rawSvgHub, contains('>SeSe<'));
      expect(SeSeLogo.rawSvgHub, contains('HUB'));
    });

    test('variants default to ride', () {
      const logo = SeSeLogo();
      expect(logo.variant, SeSeLogoVariant.ride);
    });
  });
}
