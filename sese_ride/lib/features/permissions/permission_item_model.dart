import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:sese_core/sese_core.dart';

/// Represents an individual permission requested during pre-flight onboarding.
class PermissionItem {
  final String id;
  final String title;
  final String description;
  final IconData icon;
  final Permission permission;
  final bool isMandatory;

  const PermissionItem({
    required this.id,
    required this.title,
    required this.description,
    required this.icon,
    required this.permission,
    this.isMandatory = true,
  });

  /// Role-specific permission bundle for Customer / Rider mode.
  static List<PermissionItem> bundleForCustomer() {
    return const [
      PermissionItem(
        id: 'location',
        title: 'Location Access',
        description:
            'Required to find nearby rides, pinpoint your pickup location, and track your route in real time.',
        icon: Icons.location_on_rounded,
        permission: Permission.locationWhenInUse,
        isMandatory: true,
      ),
      PermissionItem(
        id: 'notifications',
        title: 'Notifications',
        description:
            'Required to send instant ride updates, driver arrival alerts, and secure delivery PINs.',
        icon: Icons.notifications_active_rounded,
        permission: Permission.notification,
        isMandatory: true,
      ),
    ];
  }

  /// Role-specific permission bundle for Driver / Delivery Partner mode.
  static List<PermissionItem> bundleForDriver() {
    return const [
      PermissionItem(
        id: 'precise_location',
        title: 'Precise Location',
        description:
            'Required to show your vehicle on the customer map, calculate exact route distances, and direct you to pickups.',
        icon: Icons.gps_fixed_rounded,
        permission: Permission.locationWhenInUse,
        isMandatory: true,
      ),
      PermissionItem(
        id: 'background_location',
        title: 'Background Location',
        description:
            'Required to maintain live tracking, stream telemetry, and keep receiving order dispatches while the app is in the background.',
        icon: Icons.explore_rounded,
        permission: Permission.locationAlways,
        isMandatory: true,
      ),
      PermissionItem(
        id: 'notifications',
        title: 'Notifications',
        description:
            'Required to send instant ride requests, earnings alerts, and critical system notifications.',
        icon: Icons.notifications_active_rounded,
        permission: Permission.notification,
        isMandatory: true,
      ),
      PermissionItem(
        id: 'photos_storage',
        title: 'Photos & Storage',
        description:
            'Required to upload vehicle documents, profile verification photos, and inspect vehicle state.',
        icon: Icons.photo_library_rounded,
        permission: Permission.photos,
        isMandatory: true,
      ),
    ];
  }

  /// Resolves the permission bundle appropriate for [role].
  static List<PermissionItem> bundleForRole(UserRole role) {
    switch (role) {
      case UserRole.driver:
        return bundleForDriver();
      case UserRole.customer:
      case UserRole.admin:
      case UserRole.superRole:
      case UserRole.agent:
        return bundleForCustomer();
    }
  }
}
