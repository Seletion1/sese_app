import 'package:flutter_test/flutter_test.dart';
import 'package:sese_core/sese_core.dart';

void main() {
  group('VehicleCategory and Scope Matrix', () {
    test('Delivery matrix includes all 6 vehicle types', () {
      final deliveryVehicles = VehicleCategory.values
          .where((v) => v.isDeliveryEligible)
          .toList();

      expect(deliveryVehicles.length, 6);
      expect(deliveryVehicles, contains(VehicleCategory.bicycle));
      expect(deliveryVehicles, contains(VehicleCategory.motorcycle));
      expect(deliveryVehicles, contains(VehicleCategory.tricycle));
      expect(deliveryVehicles, contains(VehicleCategory.car));
      expect(deliveryVehicles, contains(VehicleCategory.van));
      expect(deliveryVehicles, contains(VehicleCategory.truck));
    });

    test('Passenger ride-hailing ONLY includes Car / Sedan', () {
      final rideHailingVehicles = VehicleCategory.values
          .where((v) => v.isRideHailingEligible)
          .toList();

      expect(rideHailingVehicles.length, 1);
      expect(rideHailingVehicles.first, VehicleCategory.car);
    });
  });

  group('VehicleTierClassifier - Car Year-Based Tiering Logic', () {
    const classifier = VehicleTierClassifier();

    test('Comfort Class: vehicles manufactured before 2010 (< 2010)', () {
      expect(
        classifier.classify(category: VehicleCategory.car, manufactureYear: 2005),
        RideTier.comfort,
      );
      expect(
        classifier.classify(category: VehicleCategory.car, manufactureYear: 2009),
        RideTier.comfort,
      );
    });

    test('Executive / Premium Class: vehicles manufactured between 2010 and 2019', () {
      expect(
        classifier.classify(category: VehicleCategory.car, manufactureYear: 2010),
        RideTier.premium,
      );
      expect(
        classifier.classify(category: VehicleCategory.car, manufactureYear: 2015),
        RideTier.premium,
      );
      expect(
        classifier.classify(category: VehicleCategory.car, manufactureYear: 2019),
        RideTier.premium,
      );
    });

    test('Luxe / Super Class: vehicles manufactured in 2020 or newer (>= 2020)', () {
      expect(
        classifier.classify(category: VehicleCategory.car, manufactureYear: 2020),
        RideTier.luxe,
      );
      expect(
        classifier.classify(category: VehicleCategory.car, manufactureYear: 2024),
        RideTier.luxe,
      );
    });

    test('Custom threshold rules from Super Admin Configuration Console', () {
      const customThresholds = CarTierThresholds(
        comfortMaxYear: 2012,
        premiumMinYear: 2013,
        premiumMaxYear: 2021,
        luxeMinYear: 2022,
      );
      final customClassifier = VehicleTierClassifier(customThresholds);

      expect(
        customClassifier.classify(category: VehicleCategory.car, manufactureYear: 2011),
        RideTier.comfort,
      );
      expect(
        customClassifier.classify(category: VehicleCategory.car, manufactureYear: 2017),
        RideTier.premium,
      );
      expect(
        customClassifier.classify(category: VehicleCategory.car, manufactureYear: 2023),
        RideTier.luxe,
      );
    });
  });

  group('ConfigResolutionEngine - 3-Tier Fallback Hierarchy', () {
    test('Resolves Global Default when no country or state specified', () {
      final resolved = ConfigResolutionEngine.resolve();

      expect(resolved.id, 'global_default');
      expect(resolved.currencyCode, 'NGN');
      expect(resolved.currencySymbol, '₦');
      expect(resolved.pricingRates[VehicleCategory.motorcycle]?.baseFee, 400.0);
    });

    test('Overrides with Country-Specific Rule', () {
      final global = RegionConfig.globalDefault();
      final nigeriaRule = RegionConfig(
        id: 'country_NG',
        countryCode: 'NG',
        stateOrRegion: '',
        currencyCode: 'NGN',
        currencySymbol: '₦',
        pricingRates: {
          VehicleCategory.motorcycle: const VehiclePricingRate(
            baseFee: 500.0,
            distanceRatePerKm: 150.0,
            timeRatePerMinute: 20.0,
          ),
        },
        updatedAt: DateTime.now(),
      );

      final resolved = ConfigResolutionEngine.resolve(
        globalDefault: global,
        countryRule: nigeriaRule,
      );

      // Motorcycle rate overridden by Nigeria rule
      expect(resolved.pricingRates[VehicleCategory.motorcycle]?.baseFee, 500.0);
      // Bicycle rate falls back to global default
      expect(resolved.pricingRates[VehicleCategory.bicycle]?.baseFee, 300.0);
    });

    test('Overrides with State-Specific Override', () {
      final global = RegionConfig.globalDefault();
      final nigeriaRule = RegionConfig(
        id: 'country_NG',
        countryCode: 'NG',
        currencyCode: 'NGN',
        currencySymbol: '₦',
        pricingRates: {
          VehicleCategory.car: const VehiclePricingRate(
            baseFee: 700.0,
            distanceRatePerKm: 200.0,
            timeRatePerMinute: 30.0,
          ),
        },
        updatedAt: DateTime.now(),
      );

      final lagosOverride = RegionConfig(
        id: 'state_NG_LAGOS',
        countryCode: 'NG',
        stateOrRegion: 'Lagos',
        currencyCode: 'NGN',
        currencySymbol: '₦',
        regionalSurgeMultiplier: 1.25, // Lagos peak surge
        pricingRates: {
          VehicleCategory.car: const VehiclePricingRate(
            baseFee: 1000.0,
            distanceRatePerKm: 250.0,
            timeRatePerMinute: 45.0,
          ),
        },
        updatedAt: DateTime.now(),
      );

      final resolved = ConfigResolutionEngine.resolve(
        globalDefault: global,
        countryRule: nigeriaRule,
        stateOverride: lagosOverride,
      );

      // Car base fee from Lagos state override
      expect(resolved.pricingRates[VehicleCategory.car]?.baseFee, 1000.0);
      expect(resolved.regionalSurgeMultiplier, 1.25);
      // Bicycle still falls back to global default
      expect(resolved.pricingRates[VehicleCategory.bicycle]?.baseFee, 300.0);
    });

    test('Inherits parent tier multipliers when child leaves defaults', () {
      final global = RegionConfig.globalDefault();
      final countryRule = RegionConfig(
        id: 'country_NG',
        countryCode: 'NG',
        currencyCode: 'NGN',
        currencySymbol: '₦',
        pricingRates: const {},
        carTierThresholds: const CarTierThresholds(
          premiumMultiplier: 1.5,
          luxeMultiplier: 2.0,
        ),
        updatedAt: DateTime.now(),
      );
      // State override touches only surge; thresholds stay model-default.
      final lagosOverride = RegionConfig(
        id: 'state_NG_LAGOS',
        countryCode: 'NG',
        stateOrRegion: 'Lagos',
        currencyCode: 'NGN',
        currencySymbol: '₦',
        regionalSurgeMultiplier: 1.25,
        pricingRates: const {},
        updatedAt: DateTime.now(),
      );

      final resolved = ConfigResolutionEngine.resolve(
        globalDefault: global,
        countryRule: countryRule,
        stateOverride: lagosOverride,
      );

      expect(resolved.carTierThresholds.premiumMultiplier, 1.5);
      expect(resolved.carTierThresholds.luxeMultiplier, 2.0);
      expect(resolved.carTierThresholds.comfortMultiplier, 1.0);
    });

    test('Merges streak rewards per-field instead of whole-object replace', () {
      final global = RegionConfig.globalDefault();
      final countryRule = RegionConfig(
        id: 'country_NG',
        countryCode: 'NG',
        currencyCode: 'NGN',
        currencySymbol: '₦',
        pricingRates: const {},
        streakRewards: const StreakRewardConfig(
          tiers: [
            StreakTier(completedTripsTrigger: 5, bonusPayout: 1500.0),
            StreakTier(completedTripsTrigger: 10, bonusPayout: 3000.0),
            StreakTier(completedTripsTrigger: 20, bonusPayout: 7000.0),
          ],
          grandCompletionCashAward: 25000.0,
          grandCompletionTargetTrips: 30,
        ),
        updatedAt: DateTime.now(),
      );
      // State override changes only the grand award; tiers stay default.
      final lagosOverride = RegionConfig(
        id: 'state_NG_LAGOS',
        countryCode: 'NG',
        stateOrRegion: 'Lagos',
        currencyCode: 'NGN',
        currencySymbol: '₦',
        pricingRates: const {},
        streakRewards: const StreakRewardConfig(
          grandCompletionCashAward: 40000.0,
        ),
        updatedAt: DateTime.now(),
      );

      final resolved = ConfigResolutionEngine.resolve(
        globalDefault: global,
        countryRule: countryRule,
        stateOverride: lagosOverride,
      );

      // Custom country tiers survive; state grand award applies.
      expect(resolved.streakRewards.tiers[0].bonusPayout, 1500.0);
      expect(resolved.streakRewards.grandCompletionCashAward, 40000.0);
      expect(resolved.streakRewards.grandCompletionTargetTrips, 30);
    });
  });

  group('PricingCalculator & Multi-Vehicle Pricing Guarantee', () {
    final config = RegionConfig.globalDefault();

    test('Calculates ride hailing with car tier multipliers', () {
      // 10 km, 20 minutes
      // Car base rate: baseFee=600, dist=180, time=25
      // Variable = (10*180 + 20*25) = 1800 + 500 = 2300

      // Comfort (multiplier 1.0)
      final comfortEstimate = PricingCalculator.calculateEstimate(
        config: config,
        category: VehicleCategory.car,
        tier: RideTier.comfort,
        distanceKm: 10.0,
        durationMinutes: 20.0,
      );
      // 600 + (2300 * 1.0 * 1.0) = 2900
      expect(comfortEstimate.totalFare, 2900.0);

      // Premium (multiplier 1.35)
      final premiumEstimate = PricingCalculator.calculateEstimate(
        config: config,
        category: VehicleCategory.car,
        tier: RideTier.premium,
        distanceKm: 10.0,
        durationMinutes: 20.0,
      );
      // 600 + (2300 * 1.35) = 600 + 3105 = 3705
      expect(premiumEstimate.totalFare, 3705.0);

      // Luxe (multiplier 1.75)
      final luxeEstimate = PricingCalculator.calculateEstimate(
        config: config,
        category: VehicleCategory.car,
        tier: RideTier.luxe,
        distanceKm: 10.0,
        durationMinutes: 20.0,
      );
      // 600 + (2300 * 1.75) = 600 + 4025 = 4625
      expect(luxeEstimate.totalFare, 4625.0);
    });

    test('Multi-Vehicle Broadcast Guarantee: each driver receives rate calculated on specific vehicle', () {
      final proposal = PricingCalculator.createMultiVehicleDispatch(
        orderId: 'order_123',
        customerId: 'cust_001',
        pickupAddress: 'Victoria Island, Lagos',
        dropoffAddress: 'Ikeja, Lagos',
        config: config,
        selectedCategories: [
          VehicleCategory.motorcycle,
          VehicleCategory.tricycle,
        ],
        distanceKm: 15.0,
        durationMinutes: 30.0,
      );

      expect(proposal.requestedCategories.length, 2);

      final motoEstimate = proposal.estimateFor(VehicleCategory.motorcycle);
      final kekeEstimate = proposal.estimateFor(VehicleCategory.tricycle);

      expect(motoEstimate, isNotNull);
      expect(kekeEstimate, isNotNull);

      // Motorcycle: base=400, dist=120, time=15 -> 400 + (15*120 + 30*15) = 400 + 1800 + 450 = 2650
      expect(motoEstimate!.totalFare, 2650.0);

      // Tricycle: base=450, dist=130, time=18 -> 450 + (15*130 + 30*18) = 450 + 1950 + 540 = 2940
      expect(kekeEstimate!.totalFare, 2940.0);

      // Pricing rates strictly differentiated per vehicle
      expect(motoEstimate.totalFare, isNot(equals(kekeEstimate.totalFare)));
    });
  });

  group('Driver Vehicle Verification Guard', () {
    test('Newly registered vehicle defaults to Pending Verification and cannot be approved by default', () {
      final vehicle = VehicleModel(
        id: 'v_101',
        driverId: 'd_555',
        category: VehicleCategory.car,
        tier: RideTier.premium,
        make: 'Toyota',
        model: 'Corolla',
        year: 2016,
        licensePlate: 'ABC-123-XY',
        color: 'Silver',
        createdAt: DateTime.now(),
        updatedAt: DateTime.now(),
      );

      expect(vehicle.verificationStatus, VehicleVerificationStatus.pending);
      expect(vehicle.isApproved, isFalse);
    });

    test('Approved vehicle satisfies verification guard', () {
      final vehicle = VehicleModel(
        id: 'v_101',
        driverId: 'd_555',
        category: VehicleCategory.car,
        tier: RideTier.premium,
        make: 'Toyota',
        model: 'Corolla',
        year: 2016,
        licensePlate: 'ABC-123-XY',
        color: 'Silver',
        verificationStatus: VehicleVerificationStatus.approved,
        createdAt: DateTime.now(),
        updatedAt: DateTime.now(),
      );

      expect(vehicle.verificationStatus, VehicleVerificationStatus.approved);
      expect(vehicle.isApproved, isTrue);
    });
  });
}
