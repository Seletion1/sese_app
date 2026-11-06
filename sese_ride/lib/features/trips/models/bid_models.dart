library;

import 'package:sese_core/utils/safe_json.dart';

/// Bid models for the multi-driver bidding system.
///
/// A bid is written to `trips/{tripId}/bids/{driverId}` by the `submitBid`
/// Cloud Function. The customer reads bids via [TripRepository.bidsStream] and
/// accepts one with [TripRepository.acceptBid] (atomic transaction on server).

/// Lifecycle states of a single driver bid.
enum BidStatus {
  pending('pending'),
  accepted('accepted'),
  rejected('rejected'),
  expired('expired');

  final String wireValue;
  const BidStatus(this.wireValue);
}

BidStatus bidStatusFromString(String? raw) {
  for (final s in BidStatus.values) {
    if (s.wireValue == raw) return s;
  }
  return BidStatus.pending;
}

/// Snapshot of one driver's bid on a trip.
class BidModel {
  final String bidId; // same as driverId
  final String tripId;
  final String driverId;
  final String driverName;
  final String photoUrl;
  final double rating;
  final double offeredFare;
  final String fareFormatted;
  final int? etaMinutes;
  final BidStatus status;
  final String vehicleModel;
  final String plateNumber;
  final DateTime? createdAt;
  final DateTime? expiresAt;
  final int bidCountdownSeconds;
  final bool isVerifiedDriver;

  const BidModel({
    required this.bidId,
    this.tripId = '',
    required this.driverId,
    required this.driverName,
    this.photoUrl = '',
    this.rating = 0,
    required this.offeredFare,
    this.fareFormatted = '',
    this.etaMinutes,
    this.status = BidStatus.pending,
    this.vehicleModel = '',
    this.plateNumber = '',
    this.createdAt,
    this.expiresAt,
    this.bidCountdownSeconds = 10,
    this.isVerifiedDriver = false,
  });

  bool get isExpired {
    if (status == BidStatus.expired) return true;
    if (expiresAt != null) {
      return DateTime.now().isAfter(expiresAt!);
    }
    return false;
  }

  Duration get remainingDuration {
    if (expiresAt == null || isExpired) return Duration.zero;
    final diff = expiresAt!.difference(DateTime.now());
    return diff.isNegative ? Duration.zero : diff;
  }

  int get remainingSeconds {
    return remainingDuration.inSeconds;
  }

  factory BidModel.fromMap(String bidId, Map<String, dynamic> map) {
    DateTime? dateOf(dynamic v) {
      if (v == null) return null;
      if (v is DateTime) return v;
      try {
        final d = (v as dynamic).toDate();
        if (d is DateTime) return d;
      } catch (_) {}
      if (v is num) return DateTime.fromMillisecondsSinceEpoch(v.toInt());
      if (v is String) return DateTime.tryParse(v);
      return null;
    }

    return BidModel(
      bidId: bidId,
      tripId: (map['tripId'] ?? '').toString(),
      driverId: (map['driverId'] ?? bidId).toString(),
      driverName: (map['driverName'] ?? map['fullName'] ?? 'Driver').toString(),
      photoUrl: (map['photoUrl'] ?? '').toString(),
      rating: safeNum(map['rating'])?.toDouble() ?? 0,
      offeredFare: safeNum(map['offeredFare'])?.toDouble() ?? 0,
      fareFormatted: (map['fareFormatted'] ?? '').toString(),
      etaMinutes: safeNum(map['etaMinutes'])?.toInt(),
      status: bidStatusFromString(map['status']?.toString()),
      vehicleModel: (map['vehicleModel'] ?? '').toString(),
      plateNumber: (map['plateNumber'] ?? '').toString(),
      createdAt: dateOf(map['createdAt']),
      expiresAt: dateOf(map['expiresAt']),
      bidCountdownSeconds: safeNum(map['bidCountdownSeconds'])?.toInt() ?? 10,
      isVerifiedDriver: map['isVerifiedDriver'] == true ||
          map['isProfileVerified'] == true ||
          map['verificationStatus'] == 'approved' ||
          map['verificationStatus'] == 'verified',
    );
  }
}
