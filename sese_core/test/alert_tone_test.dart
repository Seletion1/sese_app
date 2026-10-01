import 'package:flutter_test/flutter_test.dart';
import 'package:sese_core/services/app_sound_service.dart';

void main() {
  group('AlertTone', () {
    test('all five bundled tones exist with wav assets', () {
      expect(AlertTone.values.map((t) => t.name),
          ['high', 'pulse', 'chime', 'siren', 'digital']);
      for (final tone in AlertTone.values) {
        expect(tone.asset, endsWith('.wav'));
        expect(tone.asset, contains(tone.fileName));
        expect(tone.displayName, isNotEmpty);
      }
    });

    test('fromName resolves known tones, falls back to chime', () {
      expect(AlertTone.fromName('siren'), AlertTone.siren);
      expect(AlertTone.fromName('high'), AlertTone.high);
      expect(AlertTone.fromName('bogus'), AlertTone.chime);
      expect(AlertTone.fromName(null), AlertTone.chime);
    });

    test('service defaults to chime before prefs load', () {
      expect(AppSoundService.instance.selectedTone, AlertTone.chime);
    });
  });
}
