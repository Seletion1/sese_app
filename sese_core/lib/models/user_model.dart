import 'driver_verification.dart';
import 'user_role.dart';

/// Single source of truth for authenticated users in sese_ride + sese_hub.
class AppUser {
  final String uid;
  final String fullName;
  final String email;
  final String phoneNumber;
  final UserRole role;
  final bool isActive;
  final DateTime createdAt;
  final String photoUrl;

  /// Driver onboarding state mirror from `drivers/{uid}.verificationStatus`
  /// (`pending_onboarding` / `pending` / `approved`). Empty for customers
  /// and hub staff. Drives AuthGate routing (onboarding vs home).
  final String verificationStatus;

  /// Cumulative rating metrics
  final double averageRating;
  final int totalRatingSum;
  final int totalRatingCount;

  AppUser({
    required this.uid,
    required this.fullName,
    required this.email,
    required this.phoneNumber,
    required this.role,
    this.isActive = true,
    required this.createdAt,
    this.photoUrl = '',
    this.verificationStatus = '',
    this.averageRating = 5.0,
    this.totalRatingSum = 0,
    this.totalRatingCount = 0,
  });

  /// Drivers are created pending — require admin approval in sese_hub.
  bool get isPendingDriver => role == UserRole.driver && !isActive;

  /// True while the driver has not yet submitted the Step 2 onboarding form.
  bool get isPendingOnboarding =>
      role == UserRole.driver &&
      verificationStatus == DriverVerification.pendingOnboarding;

  Map<String, dynamic> toMap() {
    final map = <String, dynamic>{
      'uid': uid,
      'fullName': fullName,
      'email': email,
      'role': role.name,
      'isActive': isActive,
      'createdAt': createdAt.toIso8601String(),
      'photoUrl': photoUrl,
      'verificationStatus': verificationStatus,
      'averageRating': averageRating,
      'totalRatingSum': totalRatingSum,
      'totalRatingCount': totalRatingCount,
    };
    final trimmedPhone = phoneNumber.trim();
    if (trimmedPhone.isNotEmpty) {
      map['phoneNumber'] = trimmedPhone;
      map['phoneNumberE164'] = trimmedPhone;
    }
    return map;
  }

  factory AppUser.fromMap(Map<String, dynamic> map) {
    return AppUser(
      uid: map['uid'] ?? '',
      fullName: map['fullName'] ?? '',
      email: map['email'] ?? '',
      phoneNumber: map['phoneNumber'] ?? '',
      role: UserRoleExtension.fromString(map['role'] ?? 'customer'),
      isActive: map['isActive'] ?? true,
      createdAt: _parseDateTime(map['createdAt']),
      photoUrl: (map['photoUrl'] ?? map['photoURL'] ?? '').toString(),
      verificationStatus: (map['verificationStatus'] ?? '').toString(),
      averageRating: (map['averageRating'] as num?)?.toDouble() ?? 5.0,
      totalRatingSum: (map['totalRatingSum'] as num?)?.toInt() ?? 0,
      totalRatingCount: (map['totalRatingCount'] as num?)?.toInt() ?? 0,
    );
  }

  static DateTime _parseDateTime(dynamic value) {
    if (value == null) return DateTime.now();
    if (value is DateTime) return value;
    if (value is int) return DateTime.fromMillisecondsSinceEpoch(value);
    if (value is String) return DateTime.tryParse(value) ?? DateTime.now();
    try {
      final dynamic dyn = value;
      return dyn.toDate() as DateTime;
    } catch (_) {}
    return DateTime.now();
  }

  AppUser copyWith({
    String? uid,
    String? fullName,
    String? email,
    String? phoneNumber,
    UserRole? role,
    bool? isActive,
    DateTime? createdAt,
    String? photoUrl,
    String? verificationStatus,
    double? averageRating,
    int? totalRatingSum,
    int? totalRatingCount,
  }) {
    return AppUser(
      uid: uid ?? this.uid,
      fullName: fullName ?? this.fullName,
      email: email ?? this.email,
      phoneNumber: phoneNumber ?? this.phoneNumber,
      role: role ?? this.role,
      isActive: isActive ?? this.isActive,
      createdAt: createdAt ?? this.createdAt,
      photoUrl: photoUrl ?? this.photoUrl,
      verificationStatus: verificationStatus ?? this.verificationStatus,
      averageRating: averageRating ?? this.averageRating,
      totalRatingSum: totalRatingSum ?? this.totalRatingSum,
      totalRatingCount: totalRatingCount ?? this.totalRatingCount,
    );
  }
}
