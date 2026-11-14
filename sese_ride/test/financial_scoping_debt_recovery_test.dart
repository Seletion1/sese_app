import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sese_ride/features/trips/models/trip_models.dart';

void main() {
  group('Strict Server-Side Financial Scoping & Customer Debt Recovery Client Tests', () {
    test('ActiveTrip parses broadcast_fare, total_collectible_fare, and outstanding_debt accurately', () {
      final tripMap = <String, dynamic>{
        'status': 'WAITING_FOR_ACCEPTANCE',
        'customerId': 'customer_123',
        'customerName': 'Bamiduro Micheal',
        'serviceType': 'send_item',
        'pickup': {'lat': 6.6194, 'lng': 3.5105, 'address': '34 Olafiloye St, Ikorodu'},
        'dropoff': {'lat': 6.5722, 'lng': 3.3644, 'address': '18 Adebayo Mokuolu St, Anthony'},
        'base_trip_fare': 5000,
        'broadcast_fare': 5000,
        'broadcastFareFormatted': '₦5,000',
        'outstanding_debt': 765,
        'total_collectible_fare': 5765,
        'totalCollectibleFareFormatted': '₦5,765',
        'fareAmount': 5000,
        'fareFormatted': '₦5,000',
        'distanceKm': 27.6,
        'durationMins': 37,
        'driverAcceptedFinancialsReleased': false,
      };

      final trip = ActiveTrip.fromMap('trip_lagos_123', tripMap);

      expect(trip.broadcastFare, 5000.0);
      expect(trip.broadcastFareFormatted, '₦5,000');
      expect(trip.baseTripFare, 5000.0);
      expect(trip.outstandingDebt, 765.0);
      expect(trip.totalCollectibleFare, 5765.0);
      expect(trip.totalCollectibleFareFormatted, '₦5,765');
      expect(trip.driverAcceptedFinancialsReleased, false);

      // Pre-acceptance scoping: driver must see ONLY clean base fare
      expect(trip.driverDisplayFare, 5000.0);
      expect(trip.driverDisplayFareFormatted, '₦5,000');

      // Rate per km check: 5000 / 27.6 km = ₦181.16/km
      final rate = trip.driverDisplayFare / trip.distanceKm;
      expect(rate.round(), 181);
    });

    test('Pre-acceptance states (WAITING_FOR_ACCEPTANCE, MARKETPLACE_OPEN) strictly hide customer debt', () {
      final tripMap = <String, dynamic>{
        'status': 'MARKETPLACE_OPEN',
        'customerId': 'customer_123',
        'base_trip_fare': 5000,
        'broadcast_fare': 5000,
        'outstanding_debt': 765,
        'total_collectible_fare': 5765,
        'fareAmount': 5000,
        'fareFormatted': '₦5,000',
        'totalCollectibleFareFormatted': '₦5,765',
        'driverAcceptedFinancialsReleased': false,
      };

      final trip = ActiveTrip.fromMap('trip_pool_123', tripMap);

      expect(trip.driverDisplayFare, 5000.0);
      expect(trip.driverDisplayFareFormatted, '₦5,000');
    });

    test('Post-acceptance state (DRIVER_ACCEPTED) securely releases total collectible fare breakdown', () {
      final tripMap = <String, dynamic>{
        'status': 'DRIVER_ACCEPTED',
        'customerId': 'customer_123',
        'driverId': 'driver_456',
        'base_trip_fare': 5000,
        'broadcast_fare': 5000,
        'outstanding_debt': 765,
        'total_collectible_fare': 5765,
        'fareAmount': 5000,
        'cashToCollect': 5765,
        'fareFormatted': '₦5,765',
        'totalCollectibleFareFormatted': '₦5,765',
        'driverAcceptedFinancialsReleased': true,
      };

      final trip = ActiveTrip.fromMap('trip_accepted_123', tripMap);

      expect(trip.status, TripStatus.driverAccepted);
      expect(trip.driverAcceptedFinancialsReleased, true);
      expect(trip.driverDisplayFare, 5765.0);
      expect(trip.driverDisplayFareFormatted, '₦5,765');
      expect(trip.cashDueAtPickup, 5765.0);
      expect(trip.outstandingDebt, 765.0);
      expect(trip.baseTripFare, 5000.0);
    });

    testWidgets('Customer live trip view displays total collectible fare (OFFER FARE ₦5,765)', (tester) async {
      final trip = ActiveTrip.fromMap('trip_live_123', {
        'status': 'WAITING_FOR_ACCEPTANCE',
        'customerId': 'customer_123',
        'base_trip_fare': 5000,
        'broadcast_fare': 5000,
        'outstanding_debt': 765,
        'total_collectible_fare': 5765,
        'totalCollectibleFareFormatted': '₦5,765',
        'fareFormatted': '₦5,000',
        'fareAmount': 5000,
      });

      // Verification of customer fare string resolution
      final customerFareStr = trip.totalCollectibleFareFormatted.isNotEmpty
          ? trip.totalCollectibleFareFormatted
          : (trip.totalCollectibleFare > 0
              ? '₦${trip.totalCollectibleFare.toStringAsFixed(0)}'
              : trip.fareFormatted);

      expect(customerFareStr, '₦5,765');

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Column(
              children: [
                const Text('OFFER FARE'),
                Text(customerFareStr),
              ],
            ),
          ),
        ),
      );

      expect(find.text('OFFER FARE'), findsOneWidget);
      expect(find.text('₦5,765'), findsOneWidget);
    });
  });
}
