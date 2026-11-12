import 'package:flutter_test/flutter_test.dart';
import 'package:sese_core/sese_core.dart';
import 'package:sese_ride/features/trips/models/trip_models.dart';

void main() {
  group('Multi-Vehicle Ownership & Category Isolation Tests', () {
    final now = DateTime.now();

    final approvedTricycle = VehicleModel(
      id: 'v_tricycle',
      driverId: 'driver_123',
      category: VehicleCategory.tricycle,
      make: 'Piaggio',
      model: 'Ape',
      year: 2021,
      licensePlate: 'TRK-001-AA',
      color: 'Yellow',
      verificationStatus: VehicleVerificationStatus.approved,
      isActiveSelected: true,
      createdAt: now,
      updatedAt: now,
    );

    final pendingTruck = VehicleModel(
      id: 'v_truck',
      driverId: 'driver_123',
      category: VehicleCategory.truck,
      make: 'Fuso',
      model: 'Canter',
      year: 2019,
      licensePlate: 'TRK-999-ZZ',
      color: 'Blue',
      verificationStatus: VehicleVerificationStatus.pending,
      isActiveSelected: false,
      createdAt: now,
      updatedAt: now,
    );

    test('1. VehicleModel.isApproved returns true only for approved vehicles', () {
      expect(approvedTricycle.isApproved, isTrue);
      expect(pendingTruck.isApproved, isFalse);
    });

    test('2. Order feed category matching isolates non-matching order categories', () {
      final tricycleTrip = ActiveTrip(
        tripId: 'trip_keke',
        customerId: 'cust_123',
        status: TripStatus.marketplaceOpen,
        vehicleCategory: 'tricycle',
        selectedTiers: ['tricycle'],
        fareAmount: 2500,
        createdAt: now,
      );

      final truckTrip = ActiveTrip(
        tripId: 'trip_truck',
        customerId: 'cust_123',
        status: TripStatus.marketplaceOpen,
        vehicleCategory: 'truck',
        selectedTiers: ['truck'],
        fareAmount: 15000,
        createdAt: now,
      );

      final activeDriverCat = approvedTricycle.category.name; // 'tricycle'

      bool matchesActiveCategory(ActiveTrip trip) {
        final driverCat = activeDriverCat.trim().toLowerCase();
        final reqCat = trip.vehicleCategory.trim().toLowerCase();
        final reqTiers = trip.selectedTiers.map((s) => s.trim().toLowerCase()).toList();
        if (reqCat.isNotEmpty && reqCat == driverCat) return true;
        if (reqTiers.isNotEmpty && reqTiers.contains(driverCat)) return true;
        if (reqCat.isEmpty && reqTiers.isEmpty) return true;
        return false;
      }

      expect(matchesActiveCategory(tricycleTrip), isTrue);
      expect(matchesActiveCategory(truckTrip), isFalse);
    });

    test('3. Multi-tier trip matching allows driver if active category is in selectedTiers', () {
      final multiTierTrip = ActiveTrip(
        tripId: 'trip_multi',
        customerId: 'cust_123',
        status: TripStatus.marketplaceOpen,
        vehicleCategory: 'comfort',
        selectedTiers: ['comfort', 'tricycle'],
        fareAmount: 3000,
        createdAt: now,
      );

      final activeDriverCat = approvedTricycle.category.name; // 'tricycle'

      bool matchesActiveCategory(ActiveTrip trip) {
        final driverCat = activeDriverCat.trim().toLowerCase();
        final reqCat = trip.vehicleCategory.trim().toLowerCase();
        final reqTiers = trip.selectedTiers.map((s) => s.trim().toLowerCase()).toList();
        if (reqCat.isNotEmpty && reqCat == driverCat) return true;
        if (reqTiers.isNotEmpty && reqTiers.contains(driverCat)) return true;
        if (reqCat.isEmpty && reqTiers.isEmpty) return true;
        return false;
      }

      expect(matchesActiveCategory(multiTierTrip), isTrue);
    });
  });
}
