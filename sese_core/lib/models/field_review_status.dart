/// Per-item verification status for a single submitted field or document.
///
/// Stored as a map entry in `fieldReviewStatus` on `drivers/{driverId}` and
/// on vehicle documents. The hub writes this during review; the driver reads
/// it to know which fields need correction.
class FieldReviewStatus {
  /// One of: `approved`, `rejected`, `pending`.
  final String status;

  /// Hub-provided reason, required when [status] is `rejected`.
  final String? reason;

  const FieldReviewStatus({required this.status, this.reason});

  /// Convenience constructors.
  static const FieldReviewStatus approved =
      FieldReviewStatus(status: 'approved');
  static const FieldReviewStatus pending =
      FieldReviewStatus(status: 'pending');

  static FieldReviewStatus rejected(String reason) =>
      FieldReviewStatus(status: 'rejected', reason: reason);

  bool get isApproved => status == 'approved';
  bool get isRejected => status == 'rejected';
  bool get isPending => status == 'pending';

  factory FieldReviewStatus.fromMap(Map<String, dynamic> map) {
    return FieldReviewStatus(
      status: (map['status'] ?? 'pending').toString(),
      reason: map['reason']?.toString(),
    );
  }

  Map<String, dynamic> toMap() => {
        'status': status,
        if (reason != null) 'reason': reason,
      };

  @override
  String toString() =>
      'FieldReviewStatus(status: $status, reason: $reason)';
}
