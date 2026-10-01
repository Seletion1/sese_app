/// Scope of vehicles recognized across sese ecosystem.
///
/// Delivery Available Vehicles: Bicycle, Motorcycle, Tricycle (Keke), Car / Sedan, Van, Truck.
/// Passenger Ride-Hailing Available Vehicles: ONLY Car / Sedan variants.
enum VehicleCategory {
  bicycle,
  motorcycle,
  tricycle,
  car,
  van,
  truck;

  String get displayName {
    switch (this) {
      case VehicleCategory.bicycle:
        return 'Bicycle';
      case VehicleCategory.motorcycle:
        return 'Motorcycle';
      case VehicleCategory.tricycle:
        return 'Tricycle (Keke)';
      case VehicleCategory.car:
        return 'Car / Sedan';
      case VehicleCategory.van:
        return 'Van';
      case VehicleCategory.truck:
        return 'Truck';
    }
  }

  /// Whether this vehicle type is eligible for Package Delivery.
  bool get isDeliveryEligible => true;

  /// Whether this vehicle type is eligible for Passenger Ride-Hailing.
  /// Strictly restricted to Car / Sedan variants.
  bool get isRideHailingEligible => this == VehicleCategory.car;

  static VehicleCategory fromString(String val) {
    return VehicleCategory.values.firstWhere(
      (e) => e.name.toLowerCase() == val.toLowerCase() ||
             e.displayName.toLowerCase() == val.toLowerCase(),
      orElse: () => VehicleCategory.car,
    );
  }
}

/// Passenger car ride tiers based on year of manufacture.
enum RideTier {
  comfort,  // Standard / Comfort Class (e.g. pre-2010)
  premium,  // Executive / Premium Class (e.g. 2010 - 2019)
  luxe;     // Luxe / Super Class (e.g. 2020+)

  String get defaultDisplayName {
    switch (this) {
      case RideTier.comfort:
        return 'Standard / Comfort';
      case RideTier.premium:
        return 'Executive / Premium';
      case RideTier.luxe:
        return 'Luxe / Super';
    }
  }

  static RideTier fromString(String val) {
    return RideTier.values.firstWhere(
      (e) => e.name.toLowerCase() == val.toLowerCase(),
      orElse: () => RideTier.comfort,
    );
  }
}

/// Verification status for driver-registered vehicles.
enum VehicleVerificationStatus {
  pending,
  approved,
  rejected;

  String get displayName {
    switch (this) {
      case VehicleVerificationStatus.pending:
        return 'Pending Verification';
      case VehicleVerificationStatus.approved:
        return 'Verified';
      case VehicleVerificationStatus.rejected:
        return 'Rejected';
    }
  }

  static VehicleVerificationStatus fromString(String val) {
    switch (val.toUpperCase()) {
      case 'APPROVED':
      case 'VERIFIED':
        return VehicleVerificationStatus.approved;
      case 'REJECTED':
        return VehicleVerificationStatus.rejected;
      case 'PENDING':
      default:
        return VehicleVerificationStatus.pending;
    }
  }

  String toDbString() {
    switch (this) {
      case VehicleVerificationStatus.approved:
        return 'APPROVED';
      case VehicleVerificationStatus.rejected:
        return 'REJECTED';
      case VehicleVerificationStatus.pending:
        return 'PENDING';
    }
  }
}

/// Lifecycle status for registered vehicles (aligned with firestore.rules).
enum VehicleLifecycleStatus {
  active,
  deletionRequested,
  archived;

  static VehicleLifecycleStatus fromString(String val) {
    switch (val.toUpperCase()) {
      case 'DELETION_REQUESTED':
        return VehicleLifecycleStatus.deletionRequested;
      case 'ARCHIVED':
        return VehicleLifecycleStatus.archived;
      case 'ACTIVE':
      default:
        return VehicleLifecycleStatus.active;
    }
  }

  String toDbString() {
    switch (this) {
      case VehicleLifecycleStatus.deletionRequested:
        return 'DELETION_REQUESTED';
      case VehicleLifecycleStatus.archived:
        return 'ARCHIVED';
      case VehicleLifecycleStatus.active:
        return 'ACTIVE';
    }
  }
}
