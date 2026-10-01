import 'vehicle_category.dart';

/// Represents a vehicle registered in a driver's fleet under
/// `/drivers/{driverId}/vehicles/{vehicleId}`.
class VehicleModel {
  final String id;
  final String driverId;
  final VehicleCategory category;
  final RideTier? tier; // Non-null for Car / Sedan passenger ride-hailing
  final String make;
  final String model;
  final int year;
  final String licensePlate;
  final String color;
  final Map<String, String> documents; // documentType -> url / identifier
  final VehicleVerificationStatus verificationStatus;
  final VehicleLifecycleStatus lifecycleStatus;
  final bool isActiveSelected;
  final bool isDeletionRequested;
  final DateTime createdAt;
  final DateTime updatedAt;

  const VehicleModel({
    required this.id,
    required this.driverId,
    required this.category,
    this.tier,
    required this.make,
    required this.model,
    required this.year,
    required this.licensePlate,
    required this.color,
    this.documents = const {},
    this.verificationStatus = VehicleVerificationStatus.pending,
    this.lifecycleStatus = VehicleLifecycleStatus.active,
    this.isActiveSelected = false,
    this.isDeletionRequested = false,
    required this.createdAt,
    required this.updatedAt,
  });

  /// Strict Verification Guard: A vehicle must be APPROVED/VERIFIED before it
  /// can ever receive orders or be selected to go online.
  bool get isApproved =>
      verificationStatus == VehicleVerificationStatus.approved;

  /// User friendly vehicle summary, e.g. "2018 Toyota Corolla (ABC-123-XY)"
  String get displayTitle =>
      '$year $make $model ($licensePlate)';

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'driverId': driverId,
      'category': category.name,
      'tier': tier?.name,
      'make': make,
      'model': model,
      'year': year,
      'licensePlate': licensePlate,
      'color': color,
      'documents': documents,
      'verificationStatus': verificationStatus.toDbString(),
      'lifecycleStatus': lifecycleStatus.toDbString(),
      'isActiveSelected': isActiveSelected,
      'is_deletion_requested': isDeletionRequested,
      'createdAt': createdAt.toIso8601String(),
      'updatedAt': updatedAt.toIso8601String(),
    };
  }

  factory VehicleModel.fromMap(Map<String, dynamic> map, {String? id}) {
    final cat = VehicleCategory.fromString(map['category'] ?? 'car');
    RideTier? rideTier;
    if (map['tier'] != null) {
      rideTier = RideTier.fromString(map['tier']);
    }

    final docsRaw = map['documents'] as Map<String, dynamic>? ?? {};
    final docs = docsRaw.map((k, v) => MapEntry(k, v.toString()));

    // Legacy approval aliases written by sese_hub (`isVerified`, `status`):
    // an explicit admin approval flag upgrades the canonical status so old
    // and new clients agree. Never downgrades (spec: approvals stick).
    var verificationStatus = VehicleVerificationStatus.fromString(
      map['verificationStatus'] ?? 'PENDING',
    );
    if (map['isVerified'] == true) {
      verificationStatus = VehicleVerificationStatus.approved;
    }

    return VehicleModel(
      id: id ?? map['id'] ?? '',
      driverId: map['driverId'] ?? '',
      category: cat,
      tier: rideTier,
      make: map['make'] ?? '',
      model: map['model'] ?? '',
      year: (map['year'] as num?)?.toInt() ?? 2015,
      licensePlate: map['licensePlate'] ?? '',
      color: map['color'] ?? '',
      documents: docs,
      verificationStatus: verificationStatus,
      lifecycleStatus: VehicleLifecycleStatus.fromString(
        map['lifecycleStatus'] ?? 'ACTIVE',
      ),
      isActiveSelected: map['isActiveSelected'] == true,
      isDeletionRequested: map['is_deletion_requested'] == true,
      createdAt: _parseDateTime(map['createdAt']),
      updatedAt: _parseDateTime(map['updatedAt']),
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

  VehicleModel copyWith({
    String? id,
    String? driverId,
    VehicleCategory? category,
    RideTier? tier,
    String? make,
    String? model,
    int? year,
    String? licensePlate,
    String? color,
    Map<String, String>? documents,
    VehicleVerificationStatus? verificationStatus,
    VehicleLifecycleStatus? lifecycleStatus,
    bool? isActiveSelected,
    bool? isDeletionRequested,
    DateTime? createdAt,
    DateTime? updatedAt,
  }) {
    return VehicleModel(
      id: id ?? this.id,
      driverId: driverId ?? this.driverId,
      category: category ?? this.category,
      tier: tier ?? this.tier,
      make: make ?? this.make,
      model: model ?? this.model,
      year: year ?? this.year,
      licensePlate: licensePlate ?? this.licensePlate,
      color: color ?? this.color,
      documents: documents ?? this.documents,
      verificationStatus: verificationStatus ?? this.verificationStatus,
      lifecycleStatus: lifecycleStatus ?? this.lifecycleStatus,
      isActiveSelected: isActiveSelected ?? this.isActiveSelected,
      isDeletionRequested: isDeletionRequested ?? this.isDeletionRequested,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
    );
  }
}
