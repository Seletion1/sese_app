import 'package:flutter_test/flutter_test.dart';
import 'package:sese_core/sese_core.dart';

void main() {
  group('DailyStreakConfig defaults (active by default)', () {
    test('global default is active with spec defaults', () {
      const cfg = DailyStreakConfig();
      expect(cfg.streakEnabled, isTrue);
      expect(cfg.baseCommissionRate, 0.20);
      expect(cfg.noShowWaitMinutes, 10);
      expect(cfg.completionCashAward, 10000.0);
      expect(cfg.disabledCountries, isEmpty);
      expect(cfg.disabledStates, isEmpty);
    });

    test('isEnabledForRegion honors country/state disables', () {
      const cfg = DailyStreakConfig(
        disabledCountries: ['KE'],
        disabledStates: ['NG_LAGOS'],
      );
      expect(
          cfg.isEnabledForRegion(countryCode: 'NG', stateOrRegion: 'Abuja'),
          isTrue);
      expect(
          cfg.isEnabledForRegion(countryCode: 'KE', stateOrRegion: 'Nairobi'),
          isFalse);
      expect(
          cfg.isEnabledForRegion(countryCode: 'NG', stateOrRegion: 'Lagos'),
          isFalse);
    });

    test('round-trips through toMap/fromMap', () {
      const cfg = DailyStreakConfig(
        streakEnabled: false,
        baseCommissionRate: 0.25,
        noShowWaitMinutes: 15,
        completionCashAward: 20000.0,
        disabledCountries: ['KE'],
        disabledStates: ['NG_LAGOS'],
      );
      final restored = DailyStreakConfig.fromMap(cfg.toMap());
      expect(restored.streakEnabled, isFalse);
      expect(restored.baseCommissionRate, 0.25);
      expect(restored.noShowWaitMinutes, 15);
      expect(restored.completionCashAward, 20000.0);
      expect(restored.disabledCountries, ['KE']);
      expect(restored.disabledStates, ['NG_LAGOS']);
    });
  });

  group('ConfigResolutionEngine daily-streak merge', () {
    RegionConfig docWithDaily(String id, String country, String state,
        DailyStreakConfig daily) {
      final base = RegionConfig.globalDefault();
      return RegionConfig(
        id: id,
        countryCode: country,
        stateOrRegion: state,
        currencyCode: base.currencyCode,
        currencySymbol: base.currencySymbol,
        pricingRates: base.pricingRates,
        dailyStreakConfig: daily,
        updatedAt: DateTime.now(),
      );
    }

    test('disable cascades: country disable survives state override', () {
      final global = RegionConfig.globalDefault();
      final country = docWithDaily('country_KE', 'KE', '',
          const DailyStreakConfig(disabledCountries: ['KE']));
      final resolved = ConfigResolutionEngine.resolve(
        globalDefault: global,
        countryRule: country,
      );
      expect(
          resolved.dailyStreakConfig.isEnabledForRegion(
              countryCode: 'KE', stateOrRegion: 'Nairobi'),
          isFalse);
      expect(
          resolved.dailyStreakConfig.isEnabledForRegion(
              countryCode: 'NG', stateOrRegion: 'Lagos'),
          isTrue);
    });

    test('scalar override applies only when customized', () {
      final global = RegionConfig.globalDefault();
      final country = docWithDaily('country_NG', 'NG', '',
          const DailyStreakConfig(baseCommissionRate: 0.25));
      final resolved = ConfigResolutionEngine.resolve(
        globalDefault: global,
        countryRule: country,
      );
      expect(resolved.dailyStreakConfig.baseCommissionRate, 0.25);
      // Untouched scalars inherit the parent value.
      expect(resolved.dailyStreakConfig.noShowWaitMinutes, 10);
      expect(resolved.dailyStreakConfig.completionCashAward, 10000.0);
    });

    test('master toggle off disables everywhere below', () {
      final global = docWithDaily('global_default', 'GLOBAL', '',
          const DailyStreakConfig(streakEnabled: false));
      final resolved = ConfigResolutionEngine.resolveFromList(
        allConfigs: [global],
        countryCode: 'NG',
        stateOrRegion: 'Lagos',
      );
      expect(
          resolved.dailyStreakConfig.isEnabledForRegion(
              countryCode: 'NG', stateOrRegion: 'Lagos'),
          isFalse);
    });
  });

  group('DriverStreakState history alias + labels', () {
    test('reads the spec alias level1PaidCommissionHistory', () {
      final state = DriverStreakState.fromMap('d1', {
        'currentLevel': 2,
        'currentStep': 0,
        'level1PaidCommissionHistory': [150.0, 125.0, 100.0, 75.0, 50.0, 25.0],
        'dailyStreakCompleted': false,
      });
      expect(state.level1PaidHistory, hasLength(6));
      // Level 2 Step 0 refunds history[5] (the 2.5% step payment).
      expect(
          state.streakLabel(fareAmount: 1000, symbol: '₦'),
          contains('₦25 Refund'));
    });

    test('toMap writes both history keys in sync', () {
      const state = DriverStreakState(
        driverId: 'd1',
        level1PaidHistory: [150.0, 125.0],
      );
      final map = state.toMap();
      expect(map['level1PaidHistory'], [150.0, 125.0]);
      expect(map['level1PaidCommissionHistory'], [150.0, 125.0]);
    });

    test('level/step labels match the spec tag format', () {
      const l1 = DriverStreakState(
          driverId: 'd1',
          currentLevel: StreakLevel.level1,
          currentStep: 1);
      expect(l1.streakLabel(), 'Streak Rate: 12.5% Fee');

      const l3 = DriverStreakState(
          driverId: 'd1',
          currentLevel: StreakLevel.level3,
          currentStep: 6);
      expect(l3.streakLabel(), contains('20.0% Cash Bonus'));
    });
  });
}
