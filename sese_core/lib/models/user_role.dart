/// Shared user roles across sese_ride and sese_hub.
///
/// sese_ride: customer, driver
/// sese_hub: super, admin, agent
enum UserRole {
  customer,
  driver,
  agent,
  admin,
  superRole,
}

extension UserRoleExtension on UserRole {
  String get name {
    switch (this) {
      case UserRole.customer:
        return 'customer';
      case UserRole.driver:
        return 'driver';
      case UserRole.agent:
        return 'agent';
      case UserRole.admin:
        return 'admin';
      case UserRole.superRole:
        return 'super';
    }
  }

  static UserRole fromString(String role) {
    switch (role) {
      case 'driver':
        return UserRole.driver;
      case 'agent':
        return UserRole.agent;
      case 'admin':
        return UserRole.admin;
      case 'super':
        return UserRole.superRole;
      case 'customer':
      default:
        return UserRole.customer;
    }
  }

  /// Roles allowed to self-register in sese_ride.
  bool get isRideSelfRegistrable =>
      this == UserRole.customer || this == UserRole.driver;

  /// Roles provisioned inside sese_hub (no self-registration).
  bool get isHubManaged =>
      this == UserRole.agent ||
      this == UserRole.admin ||
      this == UserRole.superRole;
}
