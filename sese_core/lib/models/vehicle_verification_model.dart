/// Verification audit log entry for driver pre-online selfie/plate verification.
/// Stored in Firestore under `/driver_vehicle_verification/{verificationId}`.
/// Aligned with firestore.rules:
/// `captureMode == 'camera_only'` and `status in ['pending', 'verified']`.
class VehicleVerificationRecord {
  final String id;
  final String driverId;
  final String vehicleId;
  final String photoUrl;
  final String captureMode; // Strictly 'camera_only'
  final String status;      // 'pending', 'verified', 'rejected'
  final String? licensePlateDetected;
  final String? auditNotes;
  final DateTime capturedAt;

  const VehicleVerificationRecord({
    required this.id,
    required this.driverId,
    required this.vehicleId,
    required this.photoUrl,
    this.captureMode = 'camera_only',
    this.status = 'pending',
    this.licensePlateDetected,
    this.auditNotes,
    required this.capturedAt,
  });

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'driverId': driverId,
      'vehicleId': vehicleId,
      'photoUrl': photoUrl,
      'captureMode': captureMode,
      'status': status,
      'licensePlateDetected': licensePlateDetected,
      'auditNotes': auditNotes,
      'capturedAt': capturedAt.toIso8601String(),
    };
  }

  factory VehicleVerificationRecord.fromMap(Map<String, dynamic> map, {String? id}) {
    return VehicleVerificationRecord(
      id: id ?? map['id'] ?? '',
      driverId: map['driverId'] ?? '',
      vehicleId: map['vehicleId'] ?? '',
      photoUrl: map['photoUrl'] ?? '',
      captureMode: map['captureMode'] ?? 'camera_only',
      status: map['status'] ?? 'pending',
      licensePlateDetected: map['licensePlateDetected'],
      auditNotes: map['auditNotes'],
      capturedAt: _parseDateTime(map['capturedAt']),
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
}
