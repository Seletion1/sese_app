import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:sese_ride/features/customer/models/fare_models.dart';
import 'package:sese_ride/features/customer/services/fare_service.dart';

class MockFareBackend implements FareBackend {
  final Map<String, dynamic> responseData;

  MockFareBackend(this.responseData);

  @override
  Future<Map<String, dynamic>> callCalculateFare(Map<String, dynamic> payload) async {
    return responseData;
  }
}

void main() {
  group('Zero-Trust FareService & FareModels', () {
    test('FareResponse deserializes server payload and parses tiers verbatim', () async {
      final mockData = {
        'distanceKm': 14.2,
        'durationMins': 35.0,
        'tiers': [
          {
            'tierId': 'motorcycle',
            'name': 'Motorcycle',
            'isRecommended': true,
            'fareFormatted': '₦1,850.00',
            'fareAmount': 1850.0,
          },
          {
            'tierId': 'car_standard',
            'name': 'Standard / Comfort',
            'isRecommended': false,
            'fareFormatted': '₦4,010.00',
            'fareAmount': 4010.0,
          },
        ],
        'fareToken': 'mock_signed_hmac_jwt_hash',
      };

      final service = FareService(MockFareBackend(mockData));

      final response = await service.calculateFare(
        pickup: const LatLng(6.5244, 3.3792),
        dropoff: const LatLng(6.6018, 3.3515),
        serviceType: FareServiceType.sendItem,
        selectedTiers: ['motorcycle', 'car_standard'],
      );

      expect(response.distanceKm, 14.2);
      expect(response.durationMins, 35.0);
      expect(response.fareToken, 'mock_signed_hmac_jwt_hash');
      expect(response.tiers.length, 2);

      final moto = response.tierById('motorcycle');
      expect(moto, isNotNull);
      expect(moto!.name, 'Motorcycle');
      expect(moto.isRecommended, isTrue);
      expect(moto.fareFormatted, '₦1,850.00');
      expect(moto.fareAmount, 1850.0);

      final car = response.tierById('car_standard');
      expect(car, isNotNull);
      expect(car!.name, 'Standard / Comfort');
      expect(car.isRecommended, isFalse);
      expect(car.fareFormatted, '₦4,010.00');
      expect(car.fareAmount, 4010.0);

      expect(response.recommendedTier, equals(moto));
    });

    test('FareRequest maps correct serviceType strings for cloud functions', () {
      final reqRide = const FareRequest(
        pickup: LatLng(6.5, 3.3),
        dropoff: LatLng(6.6, 3.4),
        serviceType: FareServiceType.ride,
        selectedTiers: ['comfort'],
      ).toMap();

      final reqSend = const FareRequest(
        pickup: LatLng(6.5, 3.3),
        dropoff: LatLng(6.6, 3.4),
        serviceType: FareServiceType.sendItem,
        selectedTiers: ['motorcycle'],
      ).toMap();

      final reqReceive = const FareRequest(
        pickup: LatLng(6.5, 3.3),
        dropoff: LatLng(6.6, 3.4),
        serviceType: FareServiceType.receiveItem,
        selectedTiers: ['motorcycle'],
      ).toMap();

      expect(reqRide['serviceType'], 'ride');
      expect(reqSend['serviceType'], 'send_item');
      expect(reqReceive['serviceType'], 'receive_item');
    });
  });
}
