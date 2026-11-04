
/// Representation of an Agent ("Become an Admin / Work With Us") onboarding application.
///
/// Stored in Firestore collection `admin_applications/{uid}`.
class AdminApplication {
  final String uid;
  final String fullName;
  final String firstName;
  final String middleName;
  final String lastName;
  final String email;
  final String phoneNumber;
  final String dob;
  final String idType; // e.g. 'nin', 'passport', 'drivers_license', 'voters_card'
  final String idUrl;
  final String proofOfAddressUrl;
  final String selfieUrl;
  final Map<String, dynamic> deviceMetadata;
  final String status; // 'pending', 'approved', 'rejected'
  final DateTime submittedAt;
  final DateTime updatedAt;
  final String reviewedBy;
  final DateTime? reviewedAt;
  final String rejectionReason;

  const AdminApplication({
    required this.uid,
    required this.fullName,
    required this.firstName,
    this.middleName = '',
    required this.lastName,
    required this.email,
    required this.phoneNumber,
    required this.dob,
    required this.idType,
    required this.idUrl,
    required this.proofOfAddressUrl,
    required this.selfieUrl,
    this.deviceMetadata = const {},
    this.status = 'pending',
    required this.submittedAt,
    required this.updatedAt,
    this.reviewedBy = '',
    this.reviewedAt,
    this.rejectionReason = '',
  });

  bool get isPending => status == 'pending';
  bool get isApproved => status == 'approved';
  bool get isRejected => status == 'rejected';

  factory AdminApplication.fromMap(String uid, Map<String, dynamic> map) {
    return AdminApplication(
      uid: uid,
      fullName: (map['fullName'] ?? '').toString(),
      firstName: (map['firstName'] ?? '').toString(),
      middleName: (map['middleName'] ?? '').toString(),
      lastName: (map['lastName'] ?? '').toString(),
      email: (map['email'] ?? '').toString(),
      phoneNumber: (map['phoneNumber'] ?? '').toString(),
      dob: (map['dob'] ?? '').toString(),
      idType: (map['idType'] ?? 'nin').toString(),
      idUrl: (map['idUrl'] ?? '').toString(),
      proofOfAddressUrl: (map['proofOfAddressUrl'] ?? '').toString(),
      selfieUrl: (map['selfieUrl'] ?? '').toString(),
      deviceMetadata: map['deviceMetadata'] is Map
          ? Map<String, dynamic>.from(map['deviceMetadata'] as Map)
          : <String, dynamic>{},
      status: (map['status'] ?? 'pending').toString(),
      submittedAt: _parseDateTime(map['submittedAt']),
      updatedAt: _parseDateTime(map['updatedAt']),
      reviewedBy: (map['reviewedBy'] ?? '').toString(),
      reviewedAt: map['reviewedAt'] != null ? _parseDateTime(map['reviewedAt']) : null,
      rejectionReason: (map['rejectionReason'] ?? '').toString(),
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'uid': uid,
      'fullName': fullName,
      'firstName': firstName,
      'middleName': middleName,
      'lastName': lastName,
      'email': email,
      'phoneNumber': phoneNumber,
      'dob': dob,
      'idType': idType,
      'idUrl': idUrl,
      'proofOfAddressUrl': proofOfAddressUrl,
      'selfieUrl': selfieUrl,
      'deviceMetadata': deviceMetadata,
      'status': status,
      'submittedAt': submittedAt.toIso8601String(),
      'updatedAt': updatedAt.toIso8601String(),
      'reviewedBy': reviewedBy,
      'reviewedAt': reviewedAt?.toIso8601String(),
      'rejectionReason': rejectionReason,
    };
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

  AdminApplication copyWith({
    String? uid,
    String? fullName,
    String? firstName,
    String? middleName,
    String? lastName,
    String? email,
    String? phoneNumber,
    String? dob,
    String? idType,
    String? idUrl,
    String? proofOfAddressUrl,
    String? selfieUrl,
    Map<String, dynamic>? deviceMetadata,
    String? status,
    DateTime? submittedAt,
    DateTime? updatedAt,
    String? reviewedBy,
    DateTime? reviewedAt,
    String? rejectionReason,
  }) {
    return AdminApplication(
      uid: uid ?? this.uid,
      fullName: fullName ?? this.fullName,
      firstName: firstName ?? this.firstName,
      middleName: middleName ?? this.middleName,
      lastName: lastName ?? this.lastName,
      email: email ?? this.email,
      phoneNumber: phoneNumber ?? this.phoneNumber,
      dob: dob ?? this.dob,
      idType: idType ?? this.idType,
      idUrl: idUrl ?? this.idUrl,
      proofOfAddressUrl: proofOfAddressUrl ?? this.proofOfAddressUrl,
      selfieUrl: selfieUrl ?? this.selfieUrl,
      deviceMetadata: deviceMetadata ?? this.deviceMetadata,
      status: status ?? this.status,
      submittedAt: submittedAt ?? this.submittedAt,
      updatedAt: updatedAt ?? this.updatedAt,
      reviewedBy: reviewedBy ?? this.reviewedBy,
      reviewedAt: reviewedAt ?? this.reviewedAt,
      rejectionReason: rejectionReason ?? this.rejectionReason,
    );
  }
}
