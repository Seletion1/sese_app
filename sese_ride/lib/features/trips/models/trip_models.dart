/// Live dispatch domain models shared by the customer trip tracker,
// the Trips tab, and the booking confirmation flow.
///
/// The server ([Cloud Functions](../../../../../functions/src/trips.ts))
/// owns every status transition; the client only renders snapshots.
library;

/// Lifecycle states of a customer trip / delivery request.
///
/// Wire values match the Firestore `trips/{tripId}.status` field exactly.
enum TripStatus {
  /// Broadcast is live; matchmaking is looking for nearby drivers.
  searchingDriver('SEARCHING_DRIVER'),

  /// A driver was pinged; awaiting accept / decline before the timeout.
  /// `DRIVER_PINGED` is the legacy/spec alias some surfaces emit for the
  /// same state — parsed identically to [waitingForAcceptance].
  waitingForAcceptance('WAITING_FOR_ACCEPTANCE'),
  driverPinged('DRIVER_PINGED'),

  /// Tier 3 broadcast: open marketplace visible in every nearby
  /// driver's home feed; first tap claims the trip atomically.
  marketplaceOpen('MARKETPLACE_OPEN'),

  /// Tier 3 recycled pool: ignored / rejected / timed-out orders re-listed
  /// in the 3km–5km outer-radius marketplace pool. Renders exactly like
  /// [marketplaceOpen] (order card + first-tap atomic claim).
  marketplaceList('MARKETPLACE_LIST'),

  /// Driver accepted; sheet + live tracking are shown.
  driverAccepted('DRIVER_ACCEPTED'),

  /// Driver is en route to the pickup point.
  driverArriving('DRIVER_ARRIVING'),

  /// Driver tapped "Arrived" at pickup; the no-show wait timer is running.
  driverArrived('DRIVER_ARRIVED'),

  /// Passenger picked up / parcel collected; trip underway.
  inProgress('IN_PROGRESS'),

  /// Terminal: completed and settled.
  completed('COMPLETED'),

  /// Terminal: cancelled by customer, driver, or system.
  cancelled('CANCELLED'),

  /// Auto-reassignment exhausted (3 attempts). Customer must raise the fare
  /// or cancel. Maps to 'needs_customer_action' on the wire.
  needsCustomerAction('needs_customer_action'),

  /// Marketplace-style driver bidding is active for this trip.
  /// Drivers submit custom fares; customer accepts the best bid.
  bidding('bidding'),

  /// Unknown / future-proof fallback (never thrown — renders as searching).
  unknown('UNKNOWN');

  final String wireValue;
  const TripStatus(this.wireValue);
}

/// Parses a Firestore status string into a [TripStatus].
TripStatus tripStatusFromString(String? raw) {
  for (final s in TripStatus.values) {
    if (s.wireValue == raw) return s;
  }
  return TripStatus.unknown;
}

/// Snapshot of the driver assigned to a trip.
class DriverInfo {
  final String driverId;
  final String fullName;
  final String photoUrl;
  final double rating;
  final String phone;
  final String plateNumber;
  final String vehicleModel;
  final String vehicleColor;
  final bool isVerifiedDriver;

  const DriverInfo({
    required this.driverId,
    required this.fullName,
    this.photoUrl = '',
    this.rating = 0.0,
    required this.phone,
    this.vehicleModel = '',
    this.plateNumber = '',
    this.vehicleColor = '',
    this.isVerifiedDriver = false,
  });

  factory DriverInfo.fromMap(Map<String, dynamic> map) {
    return DriverInfo(
      driverId: (map['driverId'] ?? '').toString(),
      fullName: (map['fullName'] ?? map['name'] ?? 'Driver').toString(),
      photoUrl: (map['photoUrl'] ?? '').toString(),
      rating: (map['rating'] as num?)?.toDouble() ?? 0.0,
      phone: (map['phone'] ?? '').toString(),
      plateNumber: (map['plateNumber'] ?? map['licensePlate'] ?? '').toString(),
      vehicleModel: (map['vehicleModel'] ?? map['model'] ?? '').toString(),
      vehicleColor: (map['vehicleColor'] ?? map['color'] ?? '').toString(),
      isVerifiedDriver:
          map['isVerifiedDriver'] == true ||
          map['isProfileVerified'] == true ||
          map['verificationStatus'] == 'approved' ||
          map['verificationStatus'] == 'verified',
    );
  }

  /// "ABC-123-ZZ · Honda Accord" (omits blanks).
  String get vehicleLabel {
    final parts = [
      if (plateNumber.isNotEmpty) plateNumber,
      if (vehicleModel.isNotEmpty) vehicleModel,
    ];
    return parts.join(' · ');
  }
}

/// Client-side snapshot of a `trips/{tripId}` document.
class ActiveTrip {
  final String tripId;
  final TripStatus status;
  final String customerId;
  final String serviceType;

  final double pickupLat;
  final double pickupLng;
  final String pickupAddress;
  final String pickupPhone;

  final double dropoffLat;
  final double dropoffLng;
  final String dropoffAddress;
  final String dropoffPhone;

  final List<String> tierIds;
  final String fareFormatted;
  final double distanceKm;
  final double durationMins;

  /// How many pinged drivers declined (drives the "looking again" message).
  final int declineCount;

  final DriverInfo? driver;
  final double? driverLat;
  final double? driverLng;

  /// Driver currently pinged for acceptance (WAITING_FOR_ACCEPTANCE).
  final String pingDriverId;

  /// Simultaneous Tier 2 ping targets (WAITING_FOR_ACCEPTANCE).
  final List<String> pingDriverIds;

  /// Cascade tier that produced this offer (1, 2, or 3 = marketplace).
  final int dispatchTier;

  /// Server timestamp recorded when the driver tapped "Arrived".
  /// Powers the no-show wait timer in the driver app.
  final DateTime? arrivedAt;

  /// Backend settlement timestamp (`settlement.settledAt`), then document
  /// `updatedAt`/`createdAt` fallbacks. Drives earnings period bucketing —
  /// for COMPLETED trips this approximates completion time.
  final DateTime? settledAt;
  final DateTime? updatedAt;
  final DateTime? createdAt;

  /// Gross fare for the selected tier (drives streak tag refund/bonus text).
  final double fareAmount;

  /// True when the requesting customer is hub-verified. Drivers render a
  /// gold [Verified Customer] badge on the incoming request card.
  final bool isVerifiedCustomer;

  /// Streak settlement annotated by the backend on COMPLETED trips
  /// (see functions/src/driverStreak.ts `settlement.*`).
  final int streakLevel;
  final int streakStep;
  final double commissionRate;
  final double cashBackAmount;
  final double cashBonusAmount;
  final bool grandAwardTriggered;
  final double grandAwardAmount;

  /// Who cancelled: 'customer' | 'driver' | 'system' | null.
  final String? cancellationSource;

  /// The server-computed minimum baseline fare for this trip.
  /// Used to validate customer fare boosts / bids — cannot go below this.
  final double baselineFare;

  /// True when the customer boosted the fare via `increaseTripFare`
  /// (drives the HIGHER FARE badge on driver order cards).
  final bool fareBoosted;

  /// Boost size in percent over the pre-boost fare (informational).
  final int boostPercent;

  /// How the customer intends to pay: 'cash' (default), 'split', or a
  /// prepaid rail ('prepaid' | 'wallet' | 'card' | 'paystack' | 'online').
  /// Drives departure protection: only prepaid trips auto-start.
  final String paymentMethod;

  const ActiveTrip({
    required this.tripId,
    required this.status,
    required this.customerId,
    this.serviceType = 'ride',
    this.pickupLat = 0,
    this.pickupLng = 0,
    this.pickupAddress = '',
    this.pickupPhone = '',
    this.dropoffLat = 0,
    this.dropoffLng = 0,
    this.dropoffAddress = '',
    this.dropoffPhone = '',
    this.tierIds = const [],
    this.fareFormatted = '',
    this.distanceKm = 0,
    this.durationMins = 0,
    this.declineCount = 0,
    this.driver,
    this.driverLat,
    this.driverLng,
    this.pingDriverId = '',
    this.pingDriverIds = const [],
    this.dispatchTier = 0,
    this.arrivedAt,
    this.settledAt,
    this.updatedAt,
    this.createdAt,
    this.fareAmount = 0,
    this.isVerifiedCustomer = false,
    this.streakLevel = 0,
    this.streakStep = 0,
    this.commissionRate = 0,
    this.cashBackAmount = 0,
    this.cashBonusAmount = 0,
    this.grandAwardTriggered = false,
    this.grandAwardAmount = 0,
    this.cancellationSource,
    this.baselineFare = 0,
    this.fareBoosted = false,
    this.boostPercent = 0,
    this.paymentMethod = 'cash',
  });

  /// True for prepaid rails (auto-start eligible); cash/split/unknown
  /// trips must never auto-start (departure protection).
  bool get isPrepaidTrip {
    switch (paymentMethod.toLowerCase()) {
      case 'prepaid':
      case 'wallet':
      case 'card':
      case 'paystack':
      case 'online':
        return true;
      default:
        return false;
    }
  }

  /// True while the trip still needs live tracking / re-entry restore.
  /// needsCustomerAction and bidding are also live states.
  bool get isLive =>
      status != TripStatus.completed && status != TripStatus.cancelled;

  /// Best available completion-ish timestamp for earnings bucketing.
  DateTime? get earningDate => settledAt ?? updatedAt ?? createdAt;

  factory ActiveTrip.fromMap(String tripId, Map<String, dynamic> map) {
    Map<String, dynamic> sub(dynamic v) =>
        v is Map ? Map<String, dynamic>.from(v) : <String, dynamic>{};

    final pickup = sub(map['pickup']);
    final dropoff = sub(map['dropoff']);
    final driverMap = sub(map['driver']);
    final loc = sub(map['driverLocation']);
    final settlement = sub(map['settlement']);

    double numOf(Map<String, dynamic> m, String key) =>
        (m[key] as num?)?.toDouble() ?? 0.0;

    DateTime? dateOf(dynamic v) {
      if (v == null) return null;
      if (v is DateTime) return v;
      // Firestore Timestamp exposes toDate(); guard with dynamic dispatch
      // so unit tests can pass DateTime or millis directly.
      try {
        final d = (v as dynamic).toDate();
        if (d is DateTime) return d;
      } catch (_) {}
      if (v is num) return DateTime.fromMillisecondsSinceEpoch(v.toInt());
      if (v is String) return DateTime.tryParse(v);
      return null;
    }

    // Gross fare: prefer the selected tier's fareAmount, else first tier.
    double fareAmount = 0;
    final fareTiers = map['fareTiers'];
    if (fareTiers is List && fareTiers.isNotEmpty) {
      final selected =
          ((map['selectedTiers'] ?? map['tierIds']) as List<dynamic>?)
              ?.map((t) => t.toString())
              .toSet();
      Map<String, dynamic>? matched;
      for (final t in fareTiers) {
        if (t is Map) {
          final m = Map<String, dynamic>.from(t);
          if (selected != null &&
              selected.contains((m['tierId'] ?? '').toString())) {
            matched = m;
            break;
          }
          matched ??= m;
        }
      }
      if (matched != null) {
        fareAmount = (matched['fareAmount'] as num?)?.toDouble() ?? 0;
      }
    }

    return ActiveTrip(
      tripId: tripId,
      status: tripStatusFromString(map['status']?.toString()),
      customerId: (map['customerId'] ?? '').toString(),
      serviceType: (map['serviceType'] ?? 'ride').toString(),
      pickupLat: numOf(pickup, 'lat'),
      pickupLng: numOf(pickup, 'lng'),
      pickupAddress: (pickup['address'] ?? '').toString(),
      pickupPhone: ((pickup['phone'] ?? map['pickupPhone']) ?? '').toString(),
      dropoffLat: numOf(dropoff, 'lat'),
      dropoffLng: numOf(dropoff, 'lng'),
      dropoffAddress: (dropoff['address'] ?? '').toString(),
      dropoffPhone: ((dropoff['phone'] ?? map['dropoffPhone']) ?? '')
          .toString(),
      tierIds:
          ((map['selectedTiers'] ?? map['tierIds']) as List<dynamic>?)
              ?.map((t) => t.toString())
              .toList() ??
          const [],
      fareFormatted: (map['fareFormatted'] ?? '').toString(),
      distanceKm: (map['distanceKm'] as num?)?.toDouble() ?? 0.0,
      durationMins: (map['durationMins'] as num?)?.toDouble() ?? 0.0,
      declineCount: (map['declineCount'] as num?)?.toInt() ?? 0,
      driver: driverMap.isEmpty ? null : DriverInfo.fromMap(driverMap),
      driverLat: (loc['lat'] as num?)?.toDouble(),
      driverLng: (loc['lng'] as num?)?.toDouble(),
      pingDriverId: (map['pingDriverId'] ?? '').toString(),
      pingDriverIds:
          ((map['pingDriverIds']) as List<dynamic>?)
              ?.map((t) => t.toString())
              .toList() ??
          const [],
      dispatchTier: (map['dispatchTier'] as num?)?.toInt() ?? 0,
      arrivedAt: dateOf(map['arrivedAt']),
      settledAt: dateOf(settlement['settledAt']),
      updatedAt: dateOf(map['updatedAt']),
      createdAt: dateOf(map['createdAt']) ?? dateOf(map['requestedAt']),
      fareAmount: fareAmount,
      isVerifiedCustomer: map['isVerifiedCustomer'] == true,
      streakLevel: (settlement['streakLevel'] as num?)?.toInt() ?? 0,
      streakStep: (settlement['streakStep'] as num?)?.toInt() ?? 0,
      commissionRate: (settlement['commissionRate'] as num?)?.toDouble() ?? 0,
      cashBackAmount: (settlement['cashBackAmount'] as num?)?.toDouble() ?? 0,
      cashBonusAmount: (settlement['cashBonusAmount'] as num?)?.toDouble() ?? 0,
      grandAwardTriggered: settlement['grandAwardTriggered'] == true,
      grandAwardAmount:
          (settlement['grandAwardAmount'] as num?)?.toDouble() ?? 0,
      cancellationSource: map['cancellationSource']?.toString(),
      baselineFare: (map['baselineFare'] as num?)?.toDouble() ?? 0,
      fareBoosted: map['fareBoosted'] == true,
      boostPercent: (map['boostPercent'] as num?)?.toInt() ?? 0,
      paymentMethod:
          (map['paymentMethod'] ?? map['paymentPlan'] ?? 'cash').toString(),
    );
  }
}

/// Draft payload for the `createTrip` callable (see `dispatchPayload` in
/// the booking screen — same shape, minus client-only keys).
class TripDraft {
  final String customerId;
  final double pickupLat;
  final double pickupLng;
  final String pickupAddress;
  final String pickupPhone;
  final double dropoffLat;
  final double dropoffLng;
  final String dropoffAddress;
  final String dropoffPhone;
  final String serviceType;
  final List<String> selectedTiers;
  final String fareToken;
  final double distanceKm;
  final double durationMins;

  /// Customer-proposed fare (must be ≥ baseline calculated by the server).
  /// Null means use the server baseline.
  final double? proposedFare;

  /// Per-tier custom fares keyed by tierId (e.g. {'standard': 1500.0}).
  /// Validated server-side: each value must be ≥ corresponding tier baseline.
  final Map<String, double>? customTierFares;

  /// Client-side hint of customer verification (the backend resolves
  /// `isVerifiedCustomer` authoritatively from `users/{uid}` on mint).
  final bool isVerifiedCustomer;

  /// How the customer intends to pay ('cash' default, 'split', or a
  /// prepaid rail). Minted onto the trip doc; drives departure protection.
  final String paymentMethod;

  const TripDraft({
    required this.customerId,
    required this.pickupLat,
    required this.pickupLng,
    required this.pickupAddress,
    required this.pickupPhone,
    required this.dropoffLat,
    required this.dropoffLng,
    required this.dropoffAddress,
    required this.dropoffPhone,
    required this.serviceType,
    required this.selectedTiers,
    required this.fareToken,
    required this.distanceKm,
    required this.durationMins,
    this.proposedFare,
    this.customTierFares,
    this.isVerifiedCustomer = false,
    this.paymentMethod = 'cash',
  });

  Map<String, dynamic> toMap() {
    final map = <String, dynamic>{
      'pickup': {
        'lat': pickupLat,
        'lng': pickupLng,
        'address': pickupAddress,
        'phone': pickupPhone,
      },
      'dropoff': {
        'lat': dropoffLat,
        'lng': dropoffLng,
        'address': dropoffAddress,
        'phone': dropoffPhone,
      },
      'pickupPhone': pickupPhone,
      'dropoffPhone': dropoffPhone,
      'serviceType': serviceType,
      'selectedTiers': selectedTiers,
      'fareToken': fareToken,
      'distanceKm': distanceKm,
      'durationMins': durationMins,
      'isVerifiedCustomer': isVerifiedCustomer,
      'paymentMethod': paymentMethod,
    };
    if (proposedFare != null) map['proposedFare'] = proposedFare;
    if (customTierFares != null && customTierFares!.isNotEmpty) {
      map['customTierFares'] = customTierFares;
    }
    return map;
  }
}
