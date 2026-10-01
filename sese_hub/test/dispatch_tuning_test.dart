import 'package:flutter_test/flutter_test.dart';
import 'package:sese_hub/features/config/services/system_config_service.dart';

void main() {
  group('DispatchTuning', () {
    test('defaults match the live engine constants', () {
      const t = DispatchTuning();
      expect(t.dispatchRadiusKm, 15);
      expect(t.tier1TimeoutSec, 15);
      expect(t.tier2TimeoutSec, 15);
      expect(t.pingTimeoutSec, 60);
      expect(t.repingIntervalSec, 30);
      expect(t.tier2Count, 2);
      expect(t.candidateLimit, 25);
      expect(t.recycleWindowMin, 25);
      expect(t.maxRecycles, 5);
    });

    test('fromMap reads console values, toMap round-trips', () {
      final t = DispatchTuning.fromMap({
        'dispatchRadiusKm': 5,
        'tier1TimeoutSec': 6,
        'tier2TimeoutSec': 6,
        'pingTimeoutSec': 30,
        'repingIntervalSec': 20,
        'tier2Count': 3,
        'candidateLimit': 40,
        'recycleWindowMin': 20,
        'maxRecycles': 8,
      });
      expect(t.dispatchRadiusKm, 5);
      expect(t.tier1TimeoutSec, 6);
      expect(t.recycleWindowMin, 20);
      final back = DispatchTuning.fromMap(t.toMap());
      expect(back.toMap(), t.toMap());
    });

    test('fromMap tolerates missing/partial docs', () {
      final t = DispatchTuning.fromMap(null);
      expect(t.dispatchRadiusKm, 15);
      final partial = DispatchTuning.fromMap({'dispatchRadiusKm': 3});
      expect(partial.dispatchRadiusKm, 3);
      expect(partial.tier1TimeoutSec, 15);
    });
  });
}
