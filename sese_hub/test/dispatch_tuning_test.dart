import 'package:flutter_test/flutter_test.dart';
import 'package:sese_hub/features/config/services/system_config_service.dart';

void main() {
  group('DispatchTuning', () {
    test('defaults match the live engine constants', () {
      const t = DispatchTuning();
      expect(t.dispatchRadiusKm, 10);
      expect(t.tier1RadiusKm, 3);
      expect(t.tier3RadiusKm, 10);
      expect(t.tier1TimeoutSec, 15);
      expect(t.pingTimeoutSec, 60);
      expect(t.repingIntervalSec, 30);
      expect(t.candidateLimit, 25);
      expect(t.recycleWindowMin, 25);
      expect(t.maxRecycles, 5);
      expect(t.maxOfferBoostPct, 100.0);
      expect(t.cameraPickupDwellSec, 5);
      expect(t.cameraDropoffDwellSec, 2);
    });

    test('fromMap reads console values, toMap round-trips', () {
      final t = DispatchTuning.fromMap({
        'dispatchRadiusKm': 5,
        'tier1TimeoutSec': 6,
        'pingTimeoutSec': 30,
        'repingIntervalSec': 20,
        'candidateLimit': 40,
        'recycleWindowMin': 20,
        'maxRecycles': 8,
        'maxOfferBoostPct': 150.0,
      });
      expect(t.dispatchRadiusKm, 5);
      expect(t.tier1TimeoutSec, 6);
      expect(t.recycleWindowMin, 20);
      expect(t.maxOfferBoostPct, 150.0);
      final back = DispatchTuning.fromMap(t.toMap());
      expect(back.toMap(), t.toMap());
    });

    test('fromMap tolerates missing/partial docs', () {
      final t = DispatchTuning.fromMap(null);
      expect(t.dispatchRadiusKm, 10);
      expect(t.maxOfferBoostPct, 100.0);
      final partial = DispatchTuning.fromMap({'dispatchRadiusKm': 3});
      expect(partial.dispatchRadiusKm, 3);
      expect(partial.tier1TimeoutSec, 15);
      expect(partial.maxOfferBoostPct, 100.0);
      expect(partial.cameraPickupDwellSec, 5);
      expect(partial.cameraDropoffDwellSec, 2);
    });

    test('radiusForTier resolves correct radius per dispatch tier', () {
      const t = DispatchTuning(
        tier1RadiusKm: 2.5,
        tier3RadiusKm: 12.0,
      );
      expect(t.radiusForTier(1), 2.5);
      expect(t.radiusForTier(0), 2.5);
      expect(t.radiusForTier(3), 12.0);
    });
  });
}
