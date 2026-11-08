/// Live dispatch domain models shared by the customer trip tracker,
// the Trips tab, and the booking confirmation flow.
///
/// The server ([Cloud Functions](../../../../../functions/src/trips.ts))
/// owns every status transition; the client only renders snapshots.
library;

import 'dart:math' as math;
import 'package:sese_core/utils/safe_json.dart';

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

  /// Terminal: explicitly rejected by driver or customer.
  rejected('REJECTED'),

  /// Terminal: ping expired or ignored without driver action.
  ignored('IGNORED'),

  /// Terminal: customer cancelled during paid waiting time and elected to pay
  /// the driver in cash. Driver must confirm cash collection before the trip
  /// is fully closed. Wire value: `CANCELLED_WAITING_CASH_SETTLEMENT`.
  cancelledWaitingCashSettlement('CANCELLED_WAITING_CASH_SETTLEMENT'),

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
///
/// Handles case-insensitivity, whitespace, and wire aliases (e.g. `finished`,
/// `completed`, `canceled`, `in_progress`).
TripStatus tripStatusFromString(String? raw) {
  if (raw == null || raw.trim().isEmpty) return TripStatus.unknown;
  final normalized = raw.trim().toUpperCase();

  switch (normalized) {
    case 'COMPLETED':
    case 'FINISHED':
    case 'DONE':
    case 'SETTLED':
      return TripStatus.completed;
    case 'CANCELLED':
    case 'CANCELED':
      return TripStatus.cancelled;
    case 'IN_PROGRESS':
    case 'INPROGRESS':
      return TripStatus.inProgress;
    case 'DRIVER_ACCEPTED':
    case 'ACCEPTED':
      return TripStatus.driverAccepted;
    case 'DRIVER_ARRIVING':
    case 'ARRIVING':
      return TripStatus.driverArriving;
    case 'DRIVER_ARRIVED':
    case 'ARRIVED':
      return TripStatus.driverArrived;
    case 'SEARCHING_DRIVER':
    case 'SEARCHING':
      return TripStatus.searchingDriver;
    case 'WAITING_FOR_ACCEPTANCE':
    case 'WAITING_ACCEPTANCE':
      return TripStatus.waitingForAcceptance;
    case 'DRIVER_PINGED':
      return TripStatus.driverPinged;
    case 'MARKETPLACE_OPEN':
      return TripStatus.marketplaceOpen;
    case 'MARKETPLACE_LIST':
      return TripStatus.marketplaceList;
    case 'CANCELLED_WAITING_CASH_SETTLEMENT':
      return TripStatus.cancelledWaitingCashSettlement;
    case 'NEEDS_CUSTOMER_ACTION':
      return TripStatus.needsCustomerAction;
    case 'BIDDING':
      return TripStatus.bidding;
    case 'REJECTED':
      return TripStatus.rejected;
    case 'IGNORED':
      return TripStatus.ignored;
  }

  for (final s in TripStatus.values) {
    if (s.wireValue.toUpperCase() == normalized) return s;
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
      rating: safeNum(map['rating'])?.toDouble() ?? 0.0,
      phone: (map['phone'] ?? map['phoneNumber'] ?? map['phoneNumberE164'] ?? '').toString(),
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
  final String customerName;
  final String customerPhotoUrl;

  /// The trip booker's own account number, minted server-side at `createTrip`
  /// from `users/{customerId}` — raw and NEVER masked, even when the booker
  /// hides secondary numbers. This is the driver's guaranteed lifeline to
  /// the person who ordered and paid: pickup/drop-off contacts are optional
  /// and may be empty or masked, but this line always resolves. Empty only
  /// on trips minted before the field existed (callers must fall back to
  /// [pickupPhone], then to in-app chat).
  final String customerPhone;
  final String serviceType;

  final double pickupLat;
  final double pickupLng;
  final String pickupAddress;

  /// Optional name of the person at the pickup point, supplied by the booker
  /// in Step 3 (e.g. "John Ade" for a third-party pickup). Empty when the
  /// booker did not supply a distinct pickup contact name — use [customerName]
  /// as fallback for the pre-pickup contact row on the driver card.
  final String pickupName;
  final String pickupPhone;

  final double dropoffLat;
  final double dropoffLng;
  final String dropoffAddress;

  /// Optional name of the person at the drop-off point (e.g. the parcel
  /// recipient). Empty on ride-hailing trips where the passenger IS the
  /// booker. When non-empty, the driver card post-pickup row displays this
  /// name instead of the generic "Drop-off receiver" label.
  final String dropoffName;
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

  /// Sequential or pool ping targets (WAITING_FOR_ACCEPTANCE / MARKETPLACE).
  final List<String> pingDriverIds;

  /// Cascade tier that produced this offer (1 = sequential 1-on-1, 3 = marketplace pool).
  final int dispatchTier;

  /// Server timestamp recorded when the driver tapped "Arrived".
  /// Powers the no-show wait timer in the driver app.
  final DateTime? arrivedAt;

  /// Server timestamp recorded when the driver arrived at drop-off.
  final DateTime? dropoffArrivedAt;

  /// Top-level completion timestamp set when trip enters COMPLETED.
  final DateTime? completedAt;

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
  final double commissionAmount;
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
  ///
  /// Consumers should use [isPrepaidTrip] rather than comparing this field
  /// directly, because new rails can be added server-side without a client
  /// release.
  final String paymentMethod;

  /// Vehicle category selected for the trip (e.g. 'car', 'bike', 'keke', 'courier').
  final String vehicleCategory;

  /// True when the trip involves split fare payments.
  final bool splitEnabled;

  /// Payment mode indicating who pays: 'sender_pays', 'receiver_pays', or 'split'.
  final String paymentMode;

  /// Custom contribution amount for the sender in split payments.
  final double? senderShareAmount;

  /// Remaining balance to be collected from the receiver in split payments.
  final double? receiverShareAmount;

  /// 4-digit security PIN issued for drop-off verification.
  /// Populated server-side when [deliveryPinRequired] is true.
  final String? deliveryPin;
  final bool deliveryPinRequired;

  /// True once the delivery PIN has been verified (or skipped after 10 min).
  /// Prevents the Skip OTP button from appearing after the trip is already resolved.
  final bool deliveryPinVerified;

  /// Global waiting time billing toggle snapshot from system config.
  final bool enableWaitingTimeBilling;

  /// Accumulated paid waiting fee billed to customer / credited to driver.
  final double paidWaitingFee;

  /// Pending cash fee owed from cash settlement waiting cancellation.
  final double pendingCashFee;

  /// Outstanding negative balance from previous unpaid cancellation / paid waiting
  /// included in this trip's total fare for cumulative cash collection.
  final double outstandingBalanceIncluded;

  /// Amount of the fare covered by customer's wallet / escrow.
  final double walletCoverageAmount;

  /// Remaining cash balance to be collected by the driver (from sender or receiver).
  final double cashToCollect;

  /// Where the cash must be collected: 'pickup' (Sender) or 'dropoff' (Receiver) or 'both'.
  final String collectAt;

  /// Who pays the cash: 'sender', 'receiver', or 'split'.
  final String payerRole;

  /// Number of times this order has been auto-reassigned after driver cancellation.
  final int reassignmentCount;

  /// Whether the customer's wallet balance is locked into active trip escrow.
  final bool escrowLocked;

  /// Audit log of rejections and skips by drivers.
  /// Each entry is a map: `{'driverId': string, 'action': 'skipped'|'rejected', 'timestamp': int}`.
  final List<Map<String, dynamic>> rejections;

  /// List of driver UIDs that have been attempted for dispatch on this trip.
  final List<String> attemptedDriverIds;

  /// True when drivers have submitted custom fare offers/bids on this trip.
  final bool hasActiveBids;

  const ActiveTrip({
    required this.tripId,
    required this.status,
    required this.customerId,
    this.customerName = 'Customer',
    this.customerPhotoUrl = '',
    this.customerPhone = '',
    this.serviceType = 'ride',
    this.pickupLat = 0,
    this.pickupLng = 0,
    this.pickupAddress = '',
    this.pickupName = '',
    this.pickupPhone = '',
    this.dropoffLat = 0,
    this.dropoffLng = 0,
    this.dropoffAddress = '',
    this.dropoffName = '',
    this.dropoffPhone = '',
    this.tierIds = const [],
    this.fareFormatted = '',
    this.distanceKm = 0,
    this.durationMins = 0,
    this.declineCount = 0,
    this.reassignmentCount = 0,
    this.driver,
    this.driverLat,
    this.driverLng,
    this.pingDriverId = '',
    this.pingDriverIds = const [],
    this.dispatchTier = 0,
    this.arrivedAt,
    this.dropoffArrivedAt,
    this.completedAt,
    this.settledAt,
    this.updatedAt,
    this.createdAt,
    this.fareAmount = 0,
    this.isVerifiedCustomer = false,
    this.streakLevel = 0,
    this.streakStep = 0,
    this.commissionRate = 0,
    this.commissionAmount = 0,
    this.cashBackAmount = 0,
    this.cashBonusAmount = 0,
    this.grandAwardTriggered = false,
    this.grandAwardAmount = 0,
    this.cancellationSource,
    this.baselineFare = 0,
    this.fareBoosted = false,
    this.boostPercent = 0,
    this.paymentMethod = 'cash',
    this.vehicleCategory = '',
    this.splitEnabled = false,
    this.paymentMode = 'sender_pays',
    this.senderShareAmount,
    this.receiverShareAmount,
    this.deliveryPin,
    this.deliveryPinRequired = false,
    this.deliveryPinVerified = false,
    this.enableWaitingTimeBilling = true,
    this.paidWaitingFee = 0.0,
    this.pendingCashFee = 0.0,
    this.outstandingBalanceIncluded = 0.0,
    this.walletCoverageAmount = 0.0,
    this.cashToCollect = 0.0,
    this.collectAt = 'pickup',
    this.payerRole = 'sender',
    this.escrowLocked = false,
    this.rejections = const [],
    this.attemptedDriverIds = const [],
    this.hasActiveBids = false,
  });

  /// Returns the specific action ('skipped' or 'rejected') logged for [driverId],
  /// or null if no active rejection entry exists for that driver.
  ///
  /// If the driver subsequently claimed/accepted the trip, or if the trip completed,
  /// preliminary skip/rejection logs are considered superseded and resolve to null.
  String? driverRejectionAction(String driverId) {
    if (rejections.isEmpty) return null;
    final isAssigned = (driver?.driverId == driverId || this.driverId == driverId);
    if (isAssigned &&
        (status == TripStatus.driverAccepted ||
            status == TripStatus.driverArriving ||
            status == TripStatus.driverArrived ||
            status == TripStatus.inProgress ||
            status == TripStatus.completed ||
            status == TripStatus.cancelledWaitingCashSettlement)) {
      return null;
    }
    if (status == TripStatus.completed) {
      return null;
    }
    for (final r in rejections.reversed) {
      if (r['driverId']?.toString() == driverId) {
        if (r['superseded'] == true || r['action'] == 'superseded') continue;
        return r['action']?.toString();
      }
    }
    return null;
  }

  /// True if [driverId] has skipped or ignored this trip.
  bool isDriverSkipped(String driverId) {
    final action = driverRejectionAction(driverId);
    return action == 'skipped' || action == 'ignored' || action == 'timeout';
  }

  /// True if [driverId] has rejected or declined this trip.
  bool isDriverRejected(String driverId) {
    final action = driverRejectionAction(driverId);
    return action == 'rejected' || action == 'declined';
  }

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

  /// Whether this trip involves split-fare payment.
  bool get isSplitTrip =>
      splitEnabled ||
      paymentMode.toLowerCase() == 'split' ||
      paymentMethod.toLowerCase() == 'split';

  /// Calculated cash amount strictly due from the sender at pickup.
  ///
  /// Returns 0.0 if:
  /// - The trip is 100% prepaid (card, wallet, paystack, etc.)
  /// - Payment mode is receiver_pays or collectAt is 'dropoff'
  /// - Sender's share is fully covered by wallet/escrow
  double get cashDueAtPickup {
    if (isPrepaidTrip) return 0.0;
    final mode = paymentMode.toLowerCase();
    if (mode == 'receiver_pays' || collectAt == 'dropoff') {
      return 0.0;
    }
    if (isSplitTrip) {
      final senderShare = senderShareAmount ?? (fareAmount / 2);
      final senderWallet = math.min(senderShare, walletCoverageAmount);
      final due = senderShare - senderWallet;
      return due > 0 ? due : 0.0;
    }
    // Standard trip (sender pays)
    if (walletCoverageAmount > 0) {
      final due = cashToCollect > 0
          ? cashToCollect
          : (fareAmount - walletCoverageAmount);
      return due > 0 ? due : 0.0;
    }
    return cashToCollect > 0 ? cashToCollect : fareAmount;
  }

  /// Calculated cash amount strictly due from the receiver at drop-off.
  ///
  /// Returns 0.0 if:
  /// - The trip is 100% prepaid
  /// - Payment was fully collected from the sender at pickup (standard trip)
  double get cashDueAtDropoff {
    if (isPrepaidTrip) return 0.0;
    final mode = paymentMode.toLowerCase();
    if (mode == 'receiver_pays') {
      return cashToCollect > 0 ? cashToCollect : fareAmount;
    }
    if (isSplitTrip) {
      final senderShare = senderShareAmount ?? (fareAmount / 2);
      final receiverShare = receiverShareAmount ?? (fareAmount - senderShare);
      return receiverShare > 0 ? receiverShare : 0.0;
    }
    if (collectAt == 'dropoff') {
      return cashToCollect > 0 ? cashToCollect : fareAmount;
    }
    return 0.0;
  }

  /// True if cash must be collected from the sender at pickup.
  bool get hasCashDueAtPickup => cashDueAtPickup > 0;

  /// True if cash must be collected from the receiver at drop-off.
  bool get hasCashDueAtDropoff => cashDueAtDropoff > 0;

  /// True while the trip still needs live tracking / re-entry restore.
  /// [needsCustomerAction], [bidding], and [cancelledWaitingCashSettlement]
  /// are also considered live: the first two still need customer input; the
  /// last requires the driver to confirm cash before it fully closes.
  bool get isLive =>
      status != TripStatus.completed &&
      status != TripStatus.cancelled &&
      status != TripStatus.rejected &&
      status != TripStatus.ignored;

  /// True while a trip is active from the customer's perspective.
  /// When a customer cancels during paid waiting in cash settlement mode,
  /// the trip is closed for the customer while the driver confirms cash.
  bool get isCustomerLive =>
      isLive && status != TripStatus.cancelledWaitingCashSettlement;

  /// Best available completion-ish timestamp for earnings bucketing.
  DateTime? get earningDate => completedAt ?? settledAt ?? updatedAt ?? createdAt;

  /// Best available completion / activity timestamp for history sorting.
  /// Prefers [completedAt] / [settledAt] / [updatedAt] / [arrivedAt] over initial [createdAt].
  DateTime get latestActivityDate =>
      completedAt ??
      settledAt ??
      updatedAt ??
      arrivedAt ??
      createdAt ??
      DateTime.fromMillisecondsSinceEpoch(0);

  /// Convenience getter for assigned driver's UID (or empty string if unassigned).
  String get driverId => driver?.driverId ?? '';

  factory ActiveTrip.fromMap(String tripId, Map<String, dynamic> map) {
    Map<String, dynamic> sub(dynamic v) =>
        v is Map ? Map<String, dynamic>.from(v) : <String, dynamic>{};

    final pickup = sub(map['pickup']);
    final dropoff = sub(map['dropoff']);
    final driverMap = sub(map['driver']);
    final loc = sub(map['driverLocation']);
    final settlement = sub(map['settlement']);

    /// Tolerates legacy docs persisting numbers as strings ("4100").
    double? n(dynamic v) {
      if (v is num) return v.toDouble();
      if (v is String) return double.tryParse(v.trim());
      if (v is Map && v['value'] != null) return n(v['value']);
      return null;
    }

    double numOf(Map<String, dynamic> m, String key) =>
        n(m[key])?.toDouble() ?? 0.0;

    /// Tolerates any list payload, coercing every element via toString().
    List<String> stringList(dynamic v) {
      if (v is! List) return const [];
      return v.map((e) => e.toString()).toList();
    }


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

    // Gross fare: prefer explicitly specified trip document fare amounts (fareAmount, proposedFare, etc.)
    // over raw baseline tier calculations in fareTiers.
    double fareAmount = n(map['fareAmount'])?.toDouble() ??
        n(map['proposedFare'])?.toDouble() ??
        n(map['fare'])?.toDouble() ??
        n(map['offeredFare'])?.toDouble() ??
        n(map['agreedFare'])?.toDouble() ??
        n(map['grossFare'])?.toDouble() ??
        n(settlement['fareAmount'])?.toDouble() ??
        (map['fareMinor'] is num ? (map['fareMinor'] as num).toDouble() / 100.0 : 0.0);

    if (fareAmount == 0) {
      final fareTiers = map['fareTiers'];
      if (fareTiers is List && fareTiers.isNotEmpty) {
        final selected =
            stringList(map['selectedTiers'] ?? map['tierIds']).toSet();
        Map<String, dynamic>? matched;
        for (final t in fareTiers) {
          if (t is Map) {
            final m = Map<String, dynamic>.from(t);
            if (selected.contains((m['tierId'] ?? '').toString())) {
              matched = m;
              break;
            }
            matched ??= m;
          }
        }
        if (matched != null) {
          fareAmount = n(matched['fareAmount'])?.toDouble() ?? 0;
        }
      }
    }

    final rawFareFormatted = (map['fareFormatted'] ?? '').toString();
    final fareFormatted = rawFareFormatted.isNotEmpty
        ? rawFareFormatted
        : (fareAmount > 0
            ? '₦${fareAmount.toStringAsFixed(0).replaceAllMapped(RegExp(r'(\d{1,3})(?=(\d{3})+(?!\d))'), (m) => '${m[1]},')}'
            : '');

    final parsedStatus = tripStatusFromString(map['status']?.toString());

    return ActiveTrip(
      tripId: tripId,
      status: parsedStatus,
      customerId: (map['customerId'] ??
              map['userId'] ??
              (map['customer'] is Map ? map['customer']['uid'] : null) ??
              '')
          .toString(),
      customerName: (map['customerName'] ??
              map['customer']?['name'] ??
              map['customer']?['fullName'] ??
              'Customer')
          .toString(),
      customerPhotoUrl: (map['customerPhotoUrl'] ??
              map['customerPhoto'] ??
              map['customer']?['photoUrl'] ??
              map['customer']?['photo'] ??
              map['customer']?['avatarUrl'] ??
              '')
          .toString(),
      customerPhone: (map['customerPhone'] ??
              (map['tripBooker'] is Map
                  ? map['tripBooker']['phone'] ?? map['tripBooker']['phoneNumber']
                  : null) ??
              (map['createdBy'] is Map ? map['createdBy']['phone'] : null) ??
              '')
          .toString(),
      serviceType: (map['serviceType'] ?? 'ride').toString(),
      pickupLat: numOf(pickup, 'lat'),
      pickupLng: numOf(pickup, 'lng'),
      pickupAddress: (pickup['address'] ?? '').toString(),
      pickupName: (pickup['name'] ?? '').toString(),
      pickupPhone: ((pickup['phone'] ?? map['pickupPhone']) ?? '').toString(),
      dropoffLat: numOf(dropoff, 'lat'),
      dropoffLng: numOf(dropoff, 'lng'),
      dropoffAddress: (dropoff['address'] ?? '').toString(),
      dropoffName: (dropoff['name'] ?? '').toString(),
      dropoffPhone: ((dropoff['phone'] ?? map['dropoffPhone']) ?? '')
          .toString(),
      tierIds: stringList(map['selectedTiers'] ?? map['tierIds']),
      fareFormatted: fareFormatted,
      distanceKm: n(map['distanceKm'])?.toDouble() ?? 0.0,
      durationMins: n(map['durationMins'])?.toDouble() ?? 0.0,
      declineCount: n(map['declineCount'])?.toInt() ?? 0,
      reassignmentCount: n(map['reassignmentCount'])?.toInt() ?? 0,
      driver: driverMap.isEmpty ? null : DriverInfo.fromMap(driverMap),
      driverLat: n(loc['lat'])?.toDouble(),
      driverLng: n(loc['lng'])?.toDouble(),
      pingDriverId: (map['pingDriverId'] ?? '').toString(),
      pingDriverIds: stringList(map['pingDriverIds']),
      dispatchTier: n(map['dispatchTier'])?.toInt() ?? 0,
      arrivedAt: dateOf(map['arrivedAt']),
      dropoffArrivedAt: dateOf(map['dropoffArrivedAt'] ?? map['arrivedDropoffAt']),
      completedAt: dateOf(map['completedAt']) ?? dateOf(settlement['commissionSettledAt']),
      settledAt: dateOf(settlement['settledAt']),
      updatedAt: dateOf(map['updatedAt']),
      createdAt: dateOf(map['createdAt']) ?? dateOf(map['requestedAt']),
      fareAmount: fareAmount,
      isVerifiedCustomer: map['isVerifiedCustomer'] == true,
      streakLevel: n(settlement['streakLevel'])?.toInt() ?? 0,
      streakStep: n(settlement['streakStep'])?.toInt() ?? 0,
      commissionRate: n(settlement['commissionRate'])?.toDouble() ?? 0,
      commissionAmount: n(settlement['commissionAmount'])?.toDouble() ?? 0,
      cashBackAmount: n(settlement['cashBackAmount'])?.toDouble() ?? 0,
      cashBonusAmount: n(settlement['cashBonusAmount'])?.toDouble() ?? 0,
      grandAwardTriggered: settlement['grandAwardTriggered'] == true,
      grandAwardAmount:
          n(settlement['grandAwardAmount'])?.toDouble() ?? 0,
      cancellationSource: (parsedStatus == TripStatus.completed ||
              parsedStatus == TripStatus.inProgress ||
              parsedStatus == TripStatus.driverAccepted ||
              parsedStatus == TripStatus.driverArriving ||
              parsedStatus == TripStatus.driverArrived)
          ? null
          : map['cancellationSource']?.toString(),
      baselineFare: n(map['baselineFare'])?.toDouble() ?? 0,
      fareBoosted: map['fareBoosted'] == true,
      boostPercent: n(map['boostPercent'])?.toInt() ?? 0,
      paymentMethod:
          (map['paymentMethod'] ?? map['paymentPlan'] ?? 'cash').toString(),
      vehicleCategory: (map['vehicleCategory'] ??
              map['category'] ??
              (map['selectedTiers'] as List?)?.firstOrNull ??
              (map['tierIds'] as List?)?.firstOrNull ??
              '')
          .toString(),
      splitEnabled: map['splitEnabled'] == true ||
          map['splitPayment'] != null ||
          map['paymentMethod'] == 'split',
      paymentMode: (map['paymentMode'] ??
              (map['paymentMethod'] == 'split' ? 'split' : 'sender_pays'))
          .toString(),
      senderShareAmount: n(map['senderShareAmount'])?.toDouble() ??
          n(map['splitPayment']?['senderShare'])?.toDouble(),
      receiverShareAmount: n(map['receiverShareAmount'])?.toDouble() ??
          n(map['splitPayment']?['receiverShare'])?.toDouble(),
      deliveryPin: null,
      deliveryPinRequired: map['deliveryPinRequired'] == true ||
          map['order']?['deliveryPinRequired'] == true ||
          map['forceDeliveryPinSystemWide'] == true,
      deliveryPinVerified: map['deliveryPinVerified'] == true ||
          map['deliveryPinSkipped'] == true,
      enableWaitingTimeBilling: map['enableWaitingTimeBilling'] != false,
      paidWaitingFee: n(map['paidWaitingFee'])?.toDouble() ?? 0.0,
      pendingCashFee: n(map['pendingCashFee'])?.toDouble() ??
          n(map['paidWaitingFee'])?.toDouble() ??
          0.0,
      outstandingBalanceIncluded:
          n(map['outstandingBalanceIncluded'])?.toDouble() ?? 0.0,
      walletCoverageAmount: n(map['walletCoverageAmount'])?.toDouble() ??
          n(map['paymentBreakdown']?['walletCoverageAmount'])?.toDouble() ??
          0.0,
      cashToCollect: n(map['cashToCollect'])?.toDouble() ??
          n(map['paymentBreakdown']?['cashToCollect'])?.toDouble() ??
          ((map['paymentMethod'] == 'wallet' || map['paymentMethod'] == 'prepaid')
              ? 0.0
              : fareAmount),
      collectAt: (map['collectAt'] ??
              map['paymentBreakdown']?['collectAt'] ??
              (map['paymentMode'] == 'receiver_pays' ? 'dropoff' : 'pickup'))
          .toString(),
      payerRole: (map['payerRole'] ??
              map['paymentBreakdown']?['payerRole'] ??
              (map['paymentMode'] == 'receiver_pays'
                  ? 'receiver'
                  : (map['paymentMode'] == 'split' ? 'split' : 'sender')))
          .toString(),
      escrowLocked: map['escrowLocked'] == true ||
          map['paymentBreakdown']?['escrowLocked'] == true,
      rejections: (map['rejections'] is List ? map['rejections'] as List : const [])
              .whereType<Map>()
              .map(Map<String, dynamic>.from)
              .toList(),
      attemptedDriverIds: stringList(map['attemptedDriverIds']),
      hasActiveBids: map['hasActiveBids'] == true,
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

  /// Optional name of the person at the pickup point (third-party sender,
  /// pickup contact). Pre-filled from the booker's [AppUser.fullName] when
  /// the booker IS at the pickup; editable for third-party bookings.
  /// Stored as `pickup.name` on the Firestore trip document so the driver
  /// can see who to look for without needing the raw phone number.
  final String pickupName;
  final String pickupPhone;
  final double dropoffLat;
  final double dropoffLng;
  final String dropoffAddress;

  /// Optional name of the drop-off recipient. Pre-filled from the booker's
  /// name in Receive-Item mode; blank for standard ride/send flows unless the
  /// customer explicitly provides a third-party receiver. Stored as
  /// `dropoff.name` on the trip document.
  final String dropoffName;
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

  /// Payment mode indicating who pays: 'sender_pays', 'receiver_pays', or 'split'.
  final String paymentMode;

  /// Custom contribution amount for the sender in split payments.
  final double? senderShareAmount;

  /// Remaining balance to be collected from the receiver in split payments.
  final double? receiverShareAmount;

  /// User choice toggle: whether a 4-digit security PIN is required.
  final bool requireDeliveryPin;

  /// Optional Receiver Phone for split payments
  final String? receiverPhone;

  /// Amount of the fare covered by customer's wallet / escrow.
  final double walletCoverageAmount;

  /// Remaining cash balance to be collected by the driver.
  final double cashToCollect;

  /// Where the cash must be collected: 'pickup' or 'dropoff' or 'both'.
  final String collectAt;

  /// Who pays the cash: 'sender', 'receiver', or 'split'.
  final String payerRole;

  const TripDraft({
    required this.customerId,
    required this.pickupLat,
    required this.pickupLng,
    required this.pickupAddress,
    this.pickupName = '',
    required this.pickupPhone,
    required this.dropoffLat,
    required this.dropoffLng,
    required this.dropoffAddress,
    this.dropoffName = '',
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
    this.paymentMode = 'sender_pays',
    this.senderShareAmount,
    this.receiverShareAmount,
    this.requireDeliveryPin = false,
    this.receiverPhone,
    this.walletCoverageAmount = 0.0,
    this.cashToCollect = 0.0,
    this.collectAt = 'pickup',
    this.payerRole = 'sender',
  });

  Map<String, dynamic> toMap() {
    final map = <String, dynamic>{
      'pickup': {
        'lat': pickupLat,
        'lng': pickupLng,
        'address': pickupAddress,
        // Name is stored alongside address so the driver card can show "John
        // Ade — Pickup contact" without exposing the raw phone number.
        if (pickupName.isNotEmpty) 'name': pickupName,
        'phone': pickupPhone,
      },
      'dropoff': {
        'lat': dropoffLat,
        'lng': dropoffLng,
        'address': dropoffAddress,
        if (dropoffName.isNotEmpty) 'name': dropoffName,
        'phone': dropoffPhone,
      },
      'pickupPhone': pickupPhone,
      'dropoffPhone': dropoffPhone,
      // Top-level name mirrors for quick reads (driver card + Hub console).
      if (pickupName.isNotEmpty) 'pickupName': pickupName,
      if (dropoffName.isNotEmpty) 'dropoffName': dropoffName,
      'serviceType': serviceType,
      'selectedTiers': selectedTiers,
      'fareToken': fareToken,
      'distanceKm': distanceKm,
      'durationMins': durationMins,
      'isVerifiedCustomer': isVerifiedCustomer,
      'paymentMethod': paymentMethod,
      'paymentMode': paymentMode,
      if (senderShareAmount != null) 'senderShareAmount': senderShareAmount,
      if (receiverShareAmount != null)
        'receiverShareAmount': receiverShareAmount,
      if (walletCoverageAmount > 0) 'walletCoverageAmount': walletCoverageAmount,
      if (cashToCollect > 0) 'cashToCollect': cashToCollect,
      'collectAt': collectAt,
      'payerRole': payerRole,
      'requireDeliveryPin': requireDeliveryPin,
    };
    if (receiverPhone != null && receiverPhone!.isNotEmpty) {
      map['receiverPhone'] = receiverPhone;
    }
    if (proposedFare != null) map['proposedFare'] = proposedFare;
    if (customTierFares != null && customTierFares!.isNotEmpty) {
      map['customTierFares'] = customTierFares;
    }
    return map;
  }
}
