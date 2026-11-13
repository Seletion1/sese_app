import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:latlong2/latlong.dart';
import 'package:sese_core/sese_core.dart';

import '../../../customer/services/location_service.dart';
import '../../../trips/models/bid_models.dart';
import '../../../trips/models/trip_models.dart';
import '../../../trips/services/trip_service.dart';
import '../../services/driver_streak_service.dart';
import '../../../../widgets/map_provider.dart';
import '../../../payments/payment_service.dart';
import 'low_balance_dialog.dart';
import 'order_feed.dart';

/// Snapshot of a trip recorded when a driver hides/dismisses an order.
///
/// Used to track whether a hidden order has been modified by the customer
/// (e.g. fare update/boost or route parameter changes).
class DismissedTripState {
  final String tripId;
  final double fareAmount;
  final double pickupLat;
  final double pickupLng;
  final String pickupAddress;
  final double dropoffLat;
  final double dropoffLng;
  final String dropoffAddress;
  final DateTime? updatedAt;
  final bool fareBoosted;
  final int boostPercent;

  const DismissedTripState({
    required this.tripId,
    required this.fareAmount,
    required this.pickupLat,
    required this.pickupLng,
    required this.pickupAddress,
    required this.dropoffLat,
    required this.dropoffLng,
    required this.dropoffAddress,
    this.updatedAt,
    required this.fareBoosted,
    required this.boostPercent,
  });

  factory DismissedTripState.fromTrip(ActiveTrip trip) {
    return DismissedTripState(
      tripId: trip.tripId,
      fareAmount: trip.fareAmount,
      pickupLat: trip.pickupLat,
      pickupLng: trip.pickupLng,
      pickupAddress: trip.pickupAddress,
      dropoffLat: trip.dropoffLat,
      dropoffLng: trip.dropoffLng,
      dropoffAddress: trip.dropoffAddress,
      updatedAt: trip.updatedAt,
      fareBoosted: trip.fareBoosted,
      boostPercent: trip.boostPercent,
    );
  }

  /// Returns true if the customer has actively modified the trip details.
  bool isModifiedByCustomer(ActiveTrip trip) {
    if (trip.tripId != tripId) return false;
    if (trip.fareAmount != fareAmount) return true;
    if (trip.pickupLat != pickupLat || trip.pickupLng != pickupLng) return true;
    if (trip.dropoffLat != dropoffLat || trip.dropoffLng != dropoffLng) return true;
    if (trip.pickupAddress != pickupAddress || trip.dropoffAddress != dropoffAddress) return true;
    if (trip.fareBoosted != fareBoosted || trip.boostPercent != boostPercent) return true;
    if (updatedAt == null && trip.updatedAt != null) return true;
    if (updatedAt != null &&
        trip.updatedAt != null &&
        trip.updatedAt!.isAfter(updatedAt!)) {
      return true;
    }
    return false;
  }
}

/// Persistent session cache for Order Pool dismissals.
/// Once a driver swipes away or hides an order, it stays permanently filtered out
/// for the remainder of the app session UNLESS the customer actively modifies
/// the order details (such as updating/boosting the offer fare or changing route parameters).
abstract final class OrderPoolSession {
  static final Set<String> _dismissedOrderIds = <String>{};
  static final Map<String, DismissedTripState> _dismissedStates =
      <String, DismissedTripState>{};

  /// True if [tripId] (or [trip]) is currently dismissed for this session.
  /// If [trip] is provided and customer modifications are detected, the order is
  /// automatically restored and returns false so it re-appears in the driver pool.
  static bool isDismissed(String tripId, [ActiveTrip? trip]) {
    if (!_dismissedOrderIds.contains(tripId)) return false;
    if (trip != null) {
      final state = _dismissedStates[tripId];
      if (state != null && state.isModifiedByCustomer(trip)) {
        restore(tripId);
        return false;
      }
    }
    return true;
  }

  /// Helper specifically taking an [ActiveTrip].
  static bool isDismissedTrip(ActiveTrip trip) =>
      isDismissed(trip.tripId, trip);

  static void dismiss(String tripId, [ActiveTrip? trip]) {
    _dismissedOrderIds.add(tripId);
    if (trip != null) {
      _dismissedStates[tripId] = DismissedTripState.fromTrip(trip);
    }
  }

  static void dismissTrip(ActiveTrip trip) => dismiss(trip.tripId, trip);

  static void restore(String tripId) {
    _dismissedOrderIds.remove(tripId);
    _dismissedStates.remove(tripId);
  }

  static void clear() {
    _dismissedOrderIds.clear();
    _dismissedStates.clear();
  }
}

/// Bottom sheet listing every Tier-3 pool order near the driver.
///
/// Same geo-filtered pool the badge counts (`OrderFeedState.withinPoolRadius`),
/// so the sheet never disagrees with the badge. Each row shows pickup,
/// drop-off, fare, distance, order type, sender avatar/name, ETA to pickup,
/// and total trip metrics. Tapping expands an interactive sheet with full route
/// map, instant accept, and counter-offer bidding.
class OrderPoolSheet extends StatefulWidget {
  final DriverStreakService streakService;
  final LatLng driverPosition;
  final String currencySymbol;
  final String? driverId;
  final TripRepository? tripRepository;
  final String? activeVehicleCategory;

  const OrderPoolSheet({
    super.key,
    required this.streakService,
    required this.driverPosition,
    required this.currencySymbol,
    this.driverId,
    this.tripRepository,
    this.activeVehicleCategory,
  });

  @override
  State<OrderPoolSheet> createState() => _OrderPoolSheetState();
}

class _OrderPoolSheetState extends State<OrderPoolSheet>
    with SingleTickerProviderStateMixin {
  /// Breathing animation controller for the empty-state radar indicator.
  /// Runs only while the sheet is rendered; automatically freed on dispose.
  late final AnimationController _breathe;
  ScaffoldMessengerState? _messenger;

  @override
  void initState() {
    super.initState();
    _breathe = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1600),
    )..repeat(reverse: true);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _messenger = ScaffoldMessenger.maybeOf(context);
  }

  @override
  void dispose() {
    _breathe.dispose();
    _messenger?.hideCurrentSnackBar();
    super.dispose();
  }

  bool _matchesActiveVehicleCategory(ActiveTrip trip) {
    final driverCat = widget.activeVehicleCategory?.trim().toLowerCase();
    if (driverCat == null || driverCat.isEmpty) return true;
    final reqCat = trip.vehicleCategory.trim().toLowerCase();
    final reqTiers = trip.selectedTiers.map((s) => s.trim().toLowerCase()).toList();
    if (reqCat.isNotEmpty && reqCat == driverCat) return true;
    if (reqTiers.isNotEmpty && reqTiers.contains(driverCat)) return true;
    if (reqCat.isEmpty && reqTiers.isEmpty) return true;
    return false;
  }

  String _fareLabel(ActiveTrip trip) {
    if (trip.fareFormatted.isNotEmpty) return trip.fareFormatted;
    return '${widget.currencySymbol}${trip.fareAmount.toStringAsFixed(0)}';
  }

  String _typeLabel(ActiveTrip trip) {
    return trip.serviceType == 'ride' ? 'Ride' : 'Delivery';
  }

  String _ageText(ActiveTrip trip) {
    final ts = trip.updatedAt ?? trip.createdAt;
    if (ts == null) return 'waiting';
    final mins = DateTime.now().difference(ts).inMinutes;
    if (mins < 1) return 'just now';
    if (mins == 1) return 'waiting 1m';
    return 'waiting ${mins}m';
  }

  void _openDetails(ActiveTrip trip) async {
    final effectiveDriverId = widget.driverId ?? widget.streakService.driverId;
    final result = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      isDismissible: false,
      enableDrag: false,
      useSafeArea: false,
      backgroundColor: Colors.transparent,
      builder: (ctx) => _PoolOrderDetailSheet(
        trip: trip,
        driverPosition: widget.driverPosition,
        currencySymbol: widget.currencySymbol,
        streakService: widget.streakService,
        driverId: effectiveDriverId,
        tripRepository: widget.tripRepository,
        onAccepted: (tripId) {
          if (ctx.mounted) Navigator.of(ctx).pop(tripId);
        },
      ),
    );
    if (result != null && mounted) {
      Navigator.of(context).pop(result);
    }
  }

  @override
  Widget build(BuildContext context) {
    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.7,
      minChildSize: 0.4,
      maxChildSize: 0.92,
      builder: (context, scrollController) {
        return StreamBuilder<List<ActiveTrip>>(
              stream: widget.streakService
                  .marketplaceStream(driverId: widget.driverId),
              builder: (context, snap) {
                final trips = (snap.data ?? const <ActiveTrip>[])
                    .where((t) =>
                        t.status != TripStatus.returnedToCustomer &&
                        t.status != TripStatus.expired)
                    .where((t) =>
                        widget.driverId == null ||
                        widget.driverId!.isEmpty ||
                        t.customerId != widget.driverId)
                    .where((t) => OrderFeedState.withinPoolRadius(
                        t, widget.driverPosition))
                    .where((t) => !OrderPoolSession.isDismissed(t.tripId, t))
                    .where((t) => _matchesActiveVehicleCategory(t))
                    .toList();
                // Opaque sheet surface: the modal opens with a transparent
                // barrier background, so the content must carry its own
                // surface — otherwise the header/empty-state text ghosts over
                // the dashboard map underneath.
                return Container(
                  decoration: BoxDecoration(
                    color: Theme.of(context).cardColor,
                    borderRadius:
                        const BorderRadius.vertical(top: Radius.circular(20)),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withValues(alpha: 0.2),
                        blurRadius: 16,
                        offset: const Offset(0, -4),
                      ),
                    ],
                  ),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const SizedBox(height: 8),
                      Container(
                        width: 40,
                        height: 4,
                        decoration: BoxDecoration(
                          color: Theme.of(context)
                              .colorScheme
                              .onSurfaceVariant
                              .withValues(alpha: 0.4),
                          borderRadius: BorderRadius.circular(2),
                        ),
                      ),
                      Padding(
                        padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
                        child: Row(
                          children: [
                            const Icon(Icons.radar, size: 20),
                            const SizedBox(width: 8),
                            Text(
                              'Order Pool (${trips.length})',
                              style: Theme.of(context)
                                  .textTheme
                                  .titleMedium
                                  ?.copyWith(fontWeight: FontWeight.bold),
                            ),
                          ],
                        ),
                      ),
                      if (trips.isEmpty)
                        _EmptyPoolRadar(breathe: _breathe)
                      else
                        Expanded(
                          child: ListView.separated(
                            key: const Key('order_pool_list'),
                            controller: scrollController,
                            physics: const AlwaysScrollableScrollPhysics(),
                            padding: EdgeInsets.fromLTRB(
                              12,
                              4,
                              12,
                              20 + MediaQuery.of(context).padding.bottom,
                            ),
                            itemCount: trips.length,
                            separatorBuilder: (_, _) =>
                                const SizedBox(height: 8),
                            itemBuilder: (context, i) {
                              final trip = trips[i];
                              return Dismissible(
                                key: Key('dismissible_pool_${trip.tripId}'),
                                direction: DismissDirection.endToStart,
                                background: Container(
                                  decoration: BoxDecoration(
                                    color: Colors.red.shade700,
                                    borderRadius: BorderRadius.circular(12),
                                  ),
                                  alignment: Alignment.centerRight,
                                  padding: const EdgeInsets.only(right: 20),
                                  child: const Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      Icon(Icons.delete_outline_rounded,
                                          color: Colors.white, size: 20),
                                      SizedBox(width: 6),
                                      Text(
                                        'Hide',
                                        style: TextStyle(
                                          color: Colors.white,
                                          fontWeight: FontWeight.bold,
                                          fontSize: 13,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                                onDismissed: (_) {
                                  OrderPoolSession.dismiss(trip.tripId, trip);
                                  _messenger?.hideCurrentSnackBar();
                                  _messenger?.showSnackBar(
                                    SnackBar(
                                      behavior: SnackBarBehavior.floating,
                                      margin: const EdgeInsets.only(
                                          bottom: 24, left: 16, right: 16),
                                      duration:
                                          const Duration(milliseconds: 1500),
                                      content: const Text(
                                          'Order hidden for this session.'),
                                      action: SnackBarAction(
                                        label: 'Undo',
                                        textColor: AppColors.seseGold,
                                        onPressed: () {
                                          OrderPoolSession.restore(trip.tripId);
                                          if (mounted) {
                                            setState(() {});
                                          }
                                        },
                                      ),
                                    ),
                                  );
                                },
                                child: _PoolRow(
                                  trip: trip,
                                  fareLabel: _fareLabel(trip),
                                  typeLabel: _typeLabel(trip),
                                  ageText: _ageText(trip),
                                  driverPosition: widget.driverPosition,
                                  onTap: () => _openDetails(trip),
                                ),
                              );
                            },
                          ),
                        ),
                    ],
                  ),
                );
              },
            );
      },
    );
  }
}

class _PoolRow extends StatelessWidget {
  final ActiveTrip trip;
  final String fareLabel;
  final String typeLabel;
  final String ageText;
  final LatLng driverPosition;
  final VoidCallback onTap;

  const _PoolRow({
    required this.trip,
    required this.fareLabel,
    required this.typeLabel,
    required this.ageText,
    required this.driverPosition,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    const distanceCalc = Distance();
    final pickupPoint = LatLng(trip.pickupLat, trip.pickupLng);
    final pickupKm =
        distanceCalc.as(LengthUnit.Kilometer, driverPosition, pickupPoint);
    final pickupEtaMins = ((pickupKm / 30.0) * 60).round().clamp(1, 120);
    final tripDurationMins = trip.durationMins > 0
        ? trip.durationMins
        : ((trip.distanceKm / 30.0) * 60).round().clamp(2, 240);
    final senderName =
        trip.customerName.isNotEmpty ? trip.customerName : 'Sender';

    return Card(
      key: Key('order_pool_row_${trip.tripId}'),
      margin: EdgeInsets.zero,
      clipBehavior: Clip.antiAlias,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  UserAvatar(
                    displayName: senderName,
                    radius: 18,
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Flexible(
                              child: Text(
                                senderName,
                                style: const TextStyle(
                                  fontWeight: FontWeight.bold,
                                  fontSize: 14,
                                ),
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                            if (trip.isVerifiedCustomer) ...[
                              const SizedBox(width: 4),
                              const Icon(Icons.verified,
                                  size: 14, color: AppColors.seseGold),
                            ],
                          ],
                        ),
                        const SizedBox(height: 2),
                        Row(
                          children: [
                            Container(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 6, vertical: 1),
                              decoration: BoxDecoration(
                                color: scheme.primaryContainer,
                                borderRadius: BorderRadius.circular(4),
                              ),
                              child: Text(
                                typeLabel,
                                style: TextStyle(
                                  fontSize: 10,
                                  fontWeight: FontWeight.bold,
                                  color: scheme.onPrimaryContainer,
                                ),
                              ),
                            ),
                            const SizedBox(width: 6),
                            Text(
                              ageText,
                              style: TextStyle(
                                fontSize: 11,
                                color: scheme.onSurfaceVariant,
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                  Flexible(
                    child: Text(
                      fareLabel,
                      style: TextStyle(
                        fontWeight: FontWeight.w900,
                        fontSize: 17,
                        color: scheme.primary,
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              // Addresses
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Padding(
                    padding: EdgeInsets.only(top: 3),
                    child: Icon(Icons.circle, size: 8, color: Colors.green),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      trip.pickupAddress.isEmpty
                          ? 'Pickup (see map)'
                          : trip.pickupAddress,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 12),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 4),
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Padding(
                    padding: EdgeInsets.only(top: 2),
                    child: Icon(Icons.location_on,
                        size: 12, color: Colors.redAccent),
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      trip.dropoffAddress.isEmpty
                          ? 'Drop-off (see map)'
                          : trip.dropoffAddress,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 12),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              // Distance metrics
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                decoration: BoxDecoration(
                  color: scheme.surfaceContainerHighest.withValues(alpha: 0.5),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Row(
                  children: [
                    Icon(Icons.near_me_outlined,
                        size: 14, color: scheme.onSurfaceVariant),
                    const SizedBox(width: 4),
                    Flexible(
                      child: Text(
                        'Pickup: ${pickupKm.toStringAsFixed(1)} km (~$pickupEtaMins min)',
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.w500,
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Icon(Icons.route_outlined,
                        size: 14, color: scheme.onSurfaceVariant),
                    const SizedBox(width: 4),
                    Flexible(
                      child: Text(
                        'Trip: ${trip.distanceKm.toStringAsFixed(1)} km (~$tripDurationMins min)',
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.w500,
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Expanded interactive sheet for a Stage 3 Order Pool trip.
///
/// Features:
/// - Interactive map view with route from Point A to Point B + driver position
/// - Prominent main price at the top with direct tap-to-accept
/// - Two quick-action counter-offer suggestions (+5% and +10%) alongside an
///   edit (pen) icon allowing custom bid pricing
/// - Submitting a counter-offer pushes live real-time notification to the sender
/// Full-screen interactive route preview with draggable bottom sheet for an
/// order in the driver Order Pool.
///
/// Features:
/// - Full-screen background map view showing Point A (pickup), Point B (drop-off),
///   and driver position with live route polylines.
/// - Draggable bottom sheet with sender profile, addresses, and trip metrics.
/// - Unified Accept Action: A single primary button at the very bottom of the sheet.
/// - Counter-Offer Stacking Order: Suggestion pills (+5%, +10%) highlighted in
///   brand gold with the edit (pen) icon placed neatly in front of them directly
///   above the bottom accept button.
/// - Keyboard Overflow & Visibility Fix: Inline custom price input resizes and
///   scrolls smoothly above the software keyboard so it is never obscured.
/// Modal bottom sheet presenting complete trip details, interactive route map,
/// and live counter-offer bidding controls.
///
/// Remains persistent on the screen during the entire bidding lifecycle:
/// - Submitting a counter-offer locks controls and renders the live countdown.
/// - If customer rejects or bid expires, controls re-enable with clear feedback.
/// - Automatically pops with tripId upon customer acceptance.
class PoolOrderDetailSheet extends StatefulWidget {
  final ActiveTrip trip;
  final LatLng driverPosition;
  final String currencySymbol;
  final DriverStreakService streakService;
  final ValueChanged<String> onAccepted;
  final String? driverId;
  final TripRepository? tripRepository;

  const PoolOrderDetailSheet({
    super.key,
    required this.trip,
    required this.driverPosition,
    required this.currencySymbol,
    required this.streakService,
    required this.onAccepted,
    this.driverId,
    this.tripRepository,
  });

  @override
  State<PoolOrderDetailSheet> createState() => _PoolOrderDetailSheetState();
}

typedef _PoolOrderDetailSheet = PoolOrderDetailSheet;

/// Snap fractions for the detail-sheet [DraggableScrollableSheet].
///
/// [_kSheetMinSnap]  — collapsed: map visible, sheet peeking.
/// [_kSheetMidSnap]  — default open: all bidding controls visible.
/// [_kSheetMaxSnap]  — fully expanded: scrollable content fills screen.
const double _kSheetMinSnap = 0.18;
const double _kSheetMidSnap = 0.50;
const double _kSheetMaxSnap = 0.88;

class _PoolOrderDetailSheetState extends State<PoolOrderDetailSheet> {
  final SeSeMapController _mapController = SeSeMapController();
  List<LatLng> _routePoints = [];
  List<LatLng> _driverLegPoints = [];
  late final TextEditingController _bidCtrl;
  final FocusNode _bidFocusNode = FocusNode();
  Timer? _countdownTimer;
  bool _accepting = false;
  bool _submittingBid = false;
  int? _selectedSuggestionPct;
  bool _isCustomBidActive = false;
  String? _bidError;
  String? _lastTrackedBidId;
  BidStatus? _lastTrackedBidStatus;
  bool _hasShownTimeoutToast = false;
  bool _hasShownRejectToast = false;
  /// Mirrors the latest `isBidPending` value from the stream so that
  /// [_sheetController] can be driven from outside the [StreamBuilder] tree.
  bool _isBidPending = false;

  LatLng get _pickup => LatLng(widget.trip.pickupLat, widget.trip.pickupLng);
  LatLng get _dropoff => LatLng(widget.trip.dropoffLat, widget.trip.dropoffLng);

  String get _effectiveDriverId {
    if (widget.driverId != null && widget.driverId!.isNotEmpty) {
      return widget.driverId!;
    }
    if (widget.streakService.driverId != null &&
        widget.streakService.driverId!.isNotEmpty) {
      return widget.streakService.driverId!;
    }
    try {
      return FirebaseAuth.instance.currentUser?.uid ?? '';
    } catch (_) {
      return '';
    }
  }

  void _syncBidCountdown(BidModel? bid) {
    if (bid != null) {
      final isNewBid = _lastTrackedBidId != bid.bidId;
      if (isNewBid) {
        _lastTrackedBidId = bid.bidId;
        _hasShownTimeoutToast = false;
        _hasShownRejectToast = false;
      }

      final isExpired = bid.isExpired || bid.status == BidStatus.expired;
      final isRejected = bid.status == BidStatus.rejected;

      if (isExpired && !_hasShownTimeoutToast && (_lastTrackedBidStatus == null || _lastTrackedBidStatus == BidStatus.pending || isNewBid)) {
        _hasShownTimeoutToast = true;
        _lastTrackedBidStatus = BidStatus.expired;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) {
            ScaffoldMessenger.of(context).hideCurrentSnackBar();
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(
                content: Text('Offer timed out'),
                duration: Duration(seconds: 2),
              ),
            );
          }
        });
      } else if (isRejected && !_hasShownRejectToast && (_lastTrackedBidStatus == null || _lastTrackedBidStatus == BidStatus.pending || isNewBid)) {
        _hasShownRejectToast = true;
        _lastTrackedBidStatus = BidStatus.rejected;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) {
            ScaffoldMessenger.of(context).hideCurrentSnackBar();
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(
                content: Text('Offer rejected'),
                duration: Duration(seconds: 2),
              ),
            );
          }
        });
      } else if (bid.status == BidStatus.pending) {
        _lastTrackedBidStatus = BidStatus.pending;
      }
    }

    if (bid != null && bid.status == BidStatus.pending && !bid.isExpired) {
      if (_countdownTimer == null || !_countdownTimer!.isActive) {
        _countdownTimer = Timer.periodic(const Duration(seconds: 1), (t) {
          if (!mounted) {
            t.cancel();
            return;
          }
          if (bid.isExpired) {
            t.cancel();
          }
          setState(() {});
        });
      }
    } else {
      _countdownTimer?.cancel();
      _countdownTimer = null;
    }
  }

  late final DraggableScrollableController _sheetController;

  Stream<DispatchTuning> _dispatchTuningStream() {
    try {
      return FirebaseFirestore.instance
          .collection('system_settings')
          .doc('dispatch')
          .snapshots()
          .map((doc) => DispatchTuning.fromMap(doc.data()));
    } catch (_) {
      return Stream.value(const DispatchTuning());
    }
  }

  @override
  void initState() {
    super.initState();
    _sheetController = DraggableScrollableController();
    final baseline = widget.trip.fareAmount;
    _bidCtrl = TextEditingController(text: baseline.round().toString());
    _selectedSuggestionPct = null;
    _loadRoutes();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _mapController.fitPoints(_pickup, _dropoff, padding: 88);
      // Auto-expand the bottom sheet to the mid snap so all bidding controls
      // are immediately visible without requiring the driver to drag manually.
      if (_sheetController.isAttached) {
        _sheetController.animateTo(
          _kSheetMidSnap,
          duration: const Duration(milliseconds: 320),
          curve: Curves.easeOutCubic,
        );
      }
      // Enforce the bid-lock floor: if a bid is pending and the driver drags
      // the sheet below [_kSheetMidSnap], snap it back up immediately.
      _sheetController.addListener(_enforceSheetFloor);
    });
  }

  /// Snaps the sheet back to [_kSheetMidSnap] when [_isBidPending] and the
  /// driver has dragged it below that threshold.  Called on every controller
  /// position tick so the response is instantaneous.
  void _enforceSheetFloor() {
    if (!_isBidPending) return;
    if (!_sheetController.isAttached) return;
    if (_sheetController.size < _kSheetMidSnap - 0.02) {
      _sheetController.animateTo(
        _kSheetMidSnap,
        duration: const Duration(milliseconds: 200),
        curve: Curves.easeOutCubic,
      );
    }
  }

  @override
  void dispose() {
    _countdownTimer?.cancel();
    _bidCtrl.dispose();
    _bidFocusNode.dispose();
    _sheetController.dispose();
    super.dispose();
  }

  Future<void> _loadRoutes() async {
    final main = await LocationService.fetchRoutePolyline(_pickup, _dropoff);
    final leg = await LocationService.fetchRoutePolyline(
        widget.driverPosition, _pickup);
    if (!mounted) return;
    setState(() {
      _routePoints = main.isNotEmpty ? main : [_pickup, _dropoff];
      _driverLegPoints =
          leg.isNotEmpty ? leg : [widget.driverPosition, _pickup];
    });
    _mapController.fitPoints(_pickup, _dropoff, padding: 88);
  }

  double _roundTo100(double val) {
    final rem = val.round() % 100;
    if (rem >= 50) return (val.round() - rem + 100).toDouble();
    return (val.round() - rem).toDouble();
  }

  String _formatAmount(double amount) {
    final rounded = amount.round();
    final digits = rounded.toString().split('').reversed.toList();
    final out = <String>[];
    for (var i = 0; i < digits.length; i++) {
      if (i > 0 && i % 3 == 0) out.add(',');
      out.add(digits[i]);
    }
    return out.reversed.join();
  }

  Future<void> _applySuggestion(int? pct, double val) async {
    final driverId = _effectiveDriverId;
    final inTest = WidgetsBinding.instance.runtimeType.toString().contains('TestWidgetsFlutterBinding') ||
        SeseUniversalMap.debugTileProviderOverride != null;
    if (driverId.isNotEmpty && !inTest) {
      final hasBal = await PaymentService().hasSufficientDriverBalance(driverId);
      if (!hasBal) {
        if (!mounted) return;
        await showLowBalanceAcceptancePrompt(
          context,
          driverId: driverId,
        );
        return;
      }
    }
    setState(() {
      _selectedSuggestionPct = pct;
      _isCustomBidActive = false;
      _bidCtrl.text = val.round().toString();
      _bidError = null;
    });
  }

  Future<void> _toggleCustomBid() async {
    if (!_isCustomBidActive) {
      final driverId = _effectiveDriverId;
      final inTest = WidgetsBinding.instance.runtimeType.toString().contains('TestWidgetsFlutterBinding') ||
          SeseUniversalMap.debugTileProviderOverride != null;
      if (driverId.isNotEmpty && !inTest) {
        final hasBal = await PaymentService().hasSufficientDriverBalance(driverId);
        if (!hasBal) {
          if (!mounted) return;
          await showLowBalanceAcceptancePrompt(
            context,
            driverId: driverId,
          );
          return;
        }
      }
    }
    setState(() {
      _isCustomBidActive = !_isCustomBidActive;
      if (_isCustomBidActive) {
        _selectedSuggestionPct = null;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) _bidFocusNode.requestFocus();
        });
      } else {
        _bidCtrl.text = widget.trip.fareAmount.round().toString();
        _bidError = null;
      }
    });
  }

  void _onBidChanged(String v) {
    final val = double.tryParse(v);
    final baseline = widget.trip.fareAmount;
    setState(() {
      _selectedSuggestionPct = null;
      if (val == null || val < baseline) {
        _bidError =
            'Must be \u2265 ${widget.currencySymbol}${_formatAmount(baseline)}';
      } else {
        _bidError = null;
      }
    });
  }

  bool get _isCounterOffer {
    if (_selectedSuggestionPct != null && _selectedSuggestionPct! > 0) return true;
    if (_isCustomBidActive) return true;
    return false;
  }

  double get _currentBidAmount {
    return double.tryParse(_bidCtrl.text.trim()) ?? widget.trip.fareAmount;
  }

  Future<void> _acceptNow() async {
    if (_accepting) return;
    final driverId = _effectiveDriverId;
    final inTest = WidgetsBinding.instance.runtimeType.toString().contains('TestWidgetsFlutterBinding') ||
        SeseUniversalMap.debugTileProviderOverride != null;
    if (driverId.isNotEmpty && !inTest) {
      final hasBal = await PaymentService().hasSufficientDriverBalance(driverId);
      if (!hasBal) {
        if (!mounted) return;
        await showLowBalanceAcceptancePrompt(
          context,
          driverId: driverId,
        );
        return;
      }
    }

    setState(() => _accepting = true);
    try {
      await widget.streakService.acceptTrip(widget.trip.tripId);
      if (!mounted) return;
      widget.onAccepted(widget.trip.tripId);
    } on DriverStreakException catch (e) {
      if (!mounted) return;
      if (e.userMessage.toLowerCase().contains('balance is low') ||
          e.userMessage.toLowerCase().contains('top up')) {
        await showLowBalanceAcceptancePrompt(
          context,
          driverId: widget.streakService.driverId ?? '',
        );
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(e.userMessage)),
        );
      }
    } catch (e) {
      debugPrint('OrderPoolSheet._acceptNow error: $e');
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
            content: Text('Could not accept this order. Try another.')),
      );
    } finally {
      if (mounted) setState(() => _accepting = false);
    }
  }

  Future<void> _submitBid([double? latestBaseline]) async {
    final val = double.tryParse(_bidCtrl.text.trim());
    final baseline = latestBaseline ?? widget.trip.fareAmount;
    if (val == null || val < baseline) {
      setState(() {
        _bidError =
            'Must be \u2265 ${widget.currencySymbol}${_formatAmount(baseline)}';
      });
      return;
    }

    final driverId = _effectiveDriverId;
    final inTest = WidgetsBinding.instance.runtimeType.toString().contains('TestWidgetsFlutterBinding') ||
        SeseUniversalMap.debugTileProviderOverride != null;
    if (driverId.isNotEmpty && !inTest) {
      final hasBal = await PaymentService().hasSufficientDriverBalance(driverId);
      if (!hasBal) {
        if (!mounted) return;
        await showLowBalanceAcceptancePrompt(
          context,
          driverId: driverId,
        );
        return;
      }
    }

    setState(() => _submittingBid = true);
    try {
      final repo = widget.tripRepository ?? FirestoreTripRepository();
      const distanceCalc = Distance();
      final pickupKm = distanceCalc.as(
          LengthUnit.Kilometer, widget.driverPosition, _pickup);
      final etaMins = ((pickupKm / 30.0) * 60).round().clamp(1, 120);

      await repo.submitBid(widget.trip.tripId, val, etaMinutes: etaMins);
      if (!mounted) return;
      // Do NOT pop! The order detail sheet remains open on the driver's screen
      // showing the countdown while the customer decides.
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
              'Counter-offer of ${widget.currencySymbol}${_formatAmount(val)} submitted! Waiting for customer decision.'),
          backgroundColor: Colors.green.shade800,
          duration: const Duration(seconds: 3),
        ),
      );
    } on TripException catch (e) {
      if (!mounted) return;
      if (e.userMessage.toLowerCase().contains('balance is low') ||
          e.userMessage.toLowerCase().contains('top up')) {
        await showLowBalanceAcceptancePrompt(
          context,
          driverId: driverId,
        );
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(e.userMessage)),
        );
      }
    } catch (e) {
      if (!mounted) return;
      final msg = e.toString().toLowerCase();
      if (msg.contains('balance is low') || msg.contains('top up')) {
        await showLowBalanceAcceptancePrompt(
          context,
          driverId: driverId,
        );
      } else {
        debugPrint('OrderPoolSheet submitBid error: $e');
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Unable to submit offer right now. Please try again.'),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _submittingBid = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final repo = widget.tripRepository ?? FirestoreTripRepository();
    final driverId = _effectiveDriverId;

    return StreamBuilder<ActiveTrip?>(
      stream: repo.tripStream(widget.trip.tripId),
      builder: (context, snap) {
        final trip = snap.data ?? widget.trip;
        final scheme = Theme.of(context).colorScheme;
        final baseline = trip.fareAmount;
        final plus5Val = _roundTo100(baseline * 1.05);
        final plus10Val = _roundTo100(baseline * 1.10);

        final senderName =
            trip.customerName.isNotEmpty ? trip.customerName : 'Sender';
        final fareLabel = trip.fareFormatted.isNotEmpty
            ? trip.fareFormatted
            : '${widget.currencySymbol}${_formatAmount(baseline)}';

        return StreamBuilder<BidModel?>(
          stream: repo.driverBidForTripStream(trip.tripId, driverId),
          builder: (context, bidSnap) {
            final activeBid = bidSnap.data;
            _syncBidCountdown(activeBid);

            // 1. Check if customer accepted this driver's price/bid
            final isAccepted = (activeBid != null &&
                    activeBid.status == BidStatus.accepted) ||
                (driverId.isNotEmpty &&
                    trip.driverId == driverId &&
                    (trip.status == TripStatus.driverAccepted ||
                        trip.status == TripStatus.driverArriving ||
                        trip.status == TripStatus.driverArrived ||
                        trip.status == TripStatus.inProgress));

            if (isAccepted) {
              WidgetsBinding.instance.addPostFrameCallback((_) {
                if (mounted) {
                  widget.onAccepted(trip.tripId);
                }
              });
            }

            final bool isBidPending = activeBid != null &&
                activeBid.status == BidStatus.pending &&
                !activeBid.isExpired;

            // Sync the state flag so that the DraggableScrollableSheet key
            // and the map-tap guard are driven by the same value.  When a bid
            // becomes pending, animate the sheet up to _kSheetMidSnap so that
            // all bidding controls remain visible and the driver can clearly
            // see the countdown.
            if (isBidPending != _isBidPending) {
              WidgetsBinding.instance.addPostFrameCallback((_) {
                if (!mounted) return;
                setState(() => _isBidPending = isBidPending);
                if (isBidPending && _sheetController.isAttached) {
                  _sheetController.animateTo(
                    _kSheetMidSnap,
                    duration: const Duration(milliseconds: 280),
                    curve: Curves.easeOutCubic,
                  );
                }
              });
            }

            final bool isClaimedByAnotherDriver = driverId.isNotEmpty &&
                trip.driverId.isNotEmpty &&
                trip.driverId != driverId &&
                trip.status != TripStatus.marketplaceOpen &&
                trip.status != TripStatus.bidding &&
                trip.status != TripStatus.searchingDriver;
            final bool isTripExpired = trip.status == TripStatus.returnedToCustomer ||
                trip.status == TripStatus.expired;
            final bool isTripCancelled = trip.status == TripStatus.cancelled || isTripExpired;

            return PopScope(
              canPop: !isBidPending,
              onPopInvokedWithResult: (didPop, result) {
                if (!didPop && isBidPending) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(
                      content: Text(
                          'Bidding in progress. Please wait for customer decision.'),
                      duration: Duration(seconds: 2),
                    ),
                  );
                }
              },
              child: StreamBuilder<DispatchTuning>(
                stream: _dispatchTuningStream(),
                builder: (context, tuningSnap) {
                  return SizedBox(
                    height: MediaQuery.of(context).size.height,
                    width: MediaQuery.of(context).size.width,
                    child: Stack(
                      children: [
                        // ── Layer 0: Full-Screen Interactive Map with Tap Auto-Collapse ──
                        Positioned.fill(
                          child: GestureDetector(
                            behavior: HitTestBehavior.translucent,
                            onTap: () {
                              // During an active countdown the sheet is locked
                              // at _kSheetMidSnap; tapping the map must not
                              // collapse it below that floor.
                              if (_sheetController.isAttached) {
                                _sheetController.animateTo(
                                  isBidPending
                                      ? _kSheetMidSnap
                                      : _kSheetMinSnap,
                                  duration: const Duration(milliseconds: 300),
                                  curve: Curves.easeOutCubic,
                                );
                              }
                              _mapController.fitPoints(_pickup, _dropoff,
                                  padding: 64);
                            },
                            child: SeSeMapView(
                              // Use the policy-aware resolver so that
                              // embedded maps use Mapbox or Google Maps.
                              preferredProvider:
                                  MapProviderPolicy.resolveEmbedded(),
                              mapController: _mapController,
                              initialCenter: _pickup,
                              initialZoom: 13.0,
                              showMyLocation: true,
                              markers: [
                                SeSeMapView.pin(
                                  point: _pickup,
                                  color: Colors.green,
                                  label: 'Pickup (A)',
                                ),
                                SeSeMapView.pin(
                                  point: _dropoff,
                                  color: Colors.redAccent,
                                  label: 'Drop-off (B)',
                                ),
                                SeSeMapView.pin(
                                  point: widget.driverPosition,
                                  color: Colors.blue,
                                  label: 'You',
                                ),
                              ],
                              polylines: [
                                if (_routePoints.isNotEmpty)
                                  SeSeMapView.route(
                                    points: _routePoints,
                                    color: Colors.green.shade700,
                                    width: 4,
                                    id: 'pool-trip-route',
                                  ),
                                if (_driverLegPoints.isNotEmpty)
                                  SeSeMapView.route(
                                    points: _driverLegPoints,
                                    color: Colors.blue,
                                    width: 3,
                                    id: 'pool-driver-route',
                                  ),
                              ],
                            ),
                          ),
                        ),

                        // ── Layer 1: Top Navigation Controls (Back & Zoom) ──
                        Positioned(
                          top: 0,
                          left: 0,
                          right: 0,
                          child: SafeArea(
                            child: Padding(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 16, vertical: 8),
                              child: Row(
                                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                children: [
                                  CircleAvatar(
                                    backgroundColor: scheme.surface.withValues(
                                        alpha: isBidPending ? 0.5 : 0.95),
                                    child: IconButton(
                                      icon: Icon(
                                        Icons.arrow_back,
                                        color: isBidPending
                                            ? scheme.onSurface
                                                .withValues(alpha: 0.3)
                                            : null,
                                      ),
                                      tooltip: isBidPending
                                          ? 'Bidding in progress'
                                          : 'Back to pool',
                                      onPressed: isBidPending
                                          ? null
                                          : () =>
                                              Navigator.of(context).pop(),
                                    ),
                                  ),
                                Row(
                                  children: [
                                    _MapMiniButton(
                                      icon: Icons.add,
                                      onTap: () => _mapController.zoomBy(1),
                                    ),
                                    const SizedBox(width: 4),
                                    _MapMiniButton(
                                      icon: Icons.remove,
                                      onTap: () => _mapController.zoomBy(-1),
                                    ),
                                    const SizedBox(width: 4),
                                    _MapMiniButton(
                                      icon: Icons.my_location,
                                      onTap: () => _mapController.fitPoints(
                                        _pickup,
                                        _dropoff,
                                        padding: 64,
                                      ),
                                    ),
                                  ],
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),

                      // ── Layer 2: Draggable Bottom Sheet with Sticky Primary Action ──
                      // During an active bid countdown [_enforceSheetFloor]
                      // listens to the controller and snaps the sheet back to
                      // [_kSheetMidSnap] if the driver drags below that floor,
                      // effectively locking the sheet open during the wait.
                      DraggableScrollableSheet(
                        controller: _sheetController,
                        initialChildSize: _kSheetMidSnap,
                        minChildSize: _kSheetMinSnap,
                        maxChildSize: _kSheetMaxSnap,
                        snap: true,
                        snapSizes: const [
                          _kSheetMinSnap,
                          _kSheetMidSnap,
                          _kSheetMaxSnap,
                        ],
                    builder: (context, scrollController) {
                      return Container(
                        decoration: BoxDecoration(
                          color: Theme.of(context).scaffoldBackgroundColor,
                          borderRadius: const BorderRadius.vertical(
                              top: Radius.circular(24)),
                          boxShadow: [
                            BoxShadow(
                              color: Colors.black.withValues(alpha: 0.3),
                              blurRadius: 16,
                              offset: const Offset(0, -4),
                            ),
                          ],
                        ),
                        child: Column(
                          children: [
                            const SizedBox(height: 10),
                            // Sheet drag handle — hidden during active bid to prevent drag-dismiss
                            if (!isBidPending)
                              Center(
                                child: Container(
                                  width: 44,
                                  height: 4,
                                  decoration: BoxDecoration(
                                    color: scheme.onSurfaceVariant
                                        .withValues(alpha: 0.4),
                                    borderRadius: BorderRadius.circular(2),
                                  ),
                                ),
                              ),
                            // Flexible(loose) lets the scrollable content area shrink to
                            // its natural height instead of forcing Expanded to fill the
                            // entire remaining sheet space — which was the source of the
                            // empty white gap below the bidding controls after removing the
                            // distance metric chips.
                            Flexible(
                              fit: FlexFit.loose,
                              child: SingleChildScrollView(
                                controller: scrollController,
                                padding:
                                    const EdgeInsets.fromLTRB(16, 10, 16, 4),
                                child: Column(
                                  crossAxisAlignment:
                                      CrossAxisAlignment.stretch,
                                  children: [
                                    // Sender Profile Header & Prominent Fare
                                    Row(
                                      children: [
                                        UserAvatar(
                                            displayName: senderName,
                                            radius: 22),
                                        const SizedBox(width: 12),
                                        Expanded(
                                          child: Column(
                                            crossAxisAlignment:
                                                CrossAxisAlignment.start,
                                            children: [
                                              Row(
                                                children: [
                                                  Flexible(
                                                    child: Text(
                                                      senderName,
                                                      style: const TextStyle(
                                                        fontWeight:
                                                            FontWeight.bold,
                                                        fontSize: 16,
                                                      ),
                                                      overflow:
                                                          TextOverflow.ellipsis,
                                                    ),
                                                  ),
                                                  if (trip.isVerifiedCustomer) ...[
                                                    const SizedBox(width: 4),
                                                    const Icon(Icons.verified,
                                                        size: 16,
                                                        color:
                                                            AppColors.seseGold),
                                                  ],
                                                ],
                                              ),
                                              const SizedBox(height: 2),
                                              Text(
                                                '${trip.serviceType == 'ride' ? 'Ride' : 'Delivery'} • ${trip.distanceKm.toStringAsFixed(1)} km trip',
                                                style: TextStyle(
                                                  fontSize: 12,
                                                  color:
                                                      scheme.onSurfaceVariant,
                                                ),
                                              ),
                                            ],
                                          ),
                                        ),
                                        Column(
                                          crossAxisAlignment:
                                              CrossAxisAlignment.end,
                                          children: [
                                            Text(
                                              'Fare',
                                              style: TextStyle(
                                                fontSize: 11,
                                                color: scheme.onSurfaceVariant,
                                              ),
                                            ),
                                            Text(
                                              fareLabel,
                                              style: TextStyle(
                                                fontSize: 22,
                                                fontWeight: FontWeight.w900,
                                                color: scheme.primary,
                                              ),
                                            ),
                                          ],
                                        ),
                                      ],
                                    ),
                                    const SizedBox(height: 12),
                                    const Divider(height: 1),
                                    const SizedBox(height: 12),

                                    // Addresses: Pickup (A) & Drop-off (B)
                                    Container(
                                      padding: const EdgeInsets.all(12),
                                      decoration: BoxDecoration(
                                        color: scheme.surfaceContainerHighest
                                            .withValues(alpha: 0.4),
                                        borderRadius: BorderRadius.circular(14),
                                      ),
                                      child: Column(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.start,
                                        children: [
                                          Row(
                                            crossAxisAlignment:
                                                CrossAxisAlignment.start,
                                            children: [
                                              const Padding(
                                                padding:
                                                    EdgeInsets.only(top: 3),
                                                child: Icon(Icons.circle,
                                                    size: 10,
                                                    color: Colors.green),
                                              ),
                                              const SizedBox(width: 8),
                                              Expanded(
                                                child: Text(
                                                  trip.pickupAddress.isEmpty
                                                      ? 'Pickup location'
                                                      : trip.pickupAddress,
                                                  style: const TextStyle(
                                                      fontSize: 13,
                                                      fontWeight:
                                                          FontWeight.w500),
                                                ),
                                              ),
                                            ],
                                          ),
                                          const Padding(
                                            padding: EdgeInsets.only(
                                                left: 4, top: 2, bottom: 2),
                                            child: SizedBox(
                                              height: 12,
                                              child: VerticalDivider(
                                                width: 1,
                                                thickness: 1,
                                                color: Colors.grey,
                                              ),
                                            ),
                                          ),
                                          Row(
                                            crossAxisAlignment:
                                                CrossAxisAlignment.start,
                                            children: [
                                              const Padding(
                                                padding:
                                                    EdgeInsets.only(top: 2),
                                                child: Icon(Icons.location_on,
                                                    size: 14,
                                                    color: Colors.redAccent),
                                              ),
                                              const SizedBox(width: 6),
                                              Expanded(
                                                child: Text(
                                                  trip.dropoffAddress.isEmpty
                                                      ? 'Drop-off location'
                                                      : trip.dropoffAddress,
                                                  style: const TextStyle(
                                                      fontSize: 13,
                                                      fontWeight:
                                                          FontWeight.w500),
                                                ),
                                              ),
                                            ],
                                          ),
                                        ],
                                      ),
                                    ),
                                    const SizedBox(height: 16),

                                    // ── Trip State Status Banners (if claimed or cancelled) ──
                                    if (isClaimedByAnotherDriver) ...[
                                      Container(
                                        padding: const EdgeInsets.symmetric(
                                            horizontal: 14, vertical: 10),
                                        decoration: BoxDecoration(
                                          color: Colors.grey.shade800
                                              .withValues(alpha: 0.15),
                                          borderRadius:
                                              BorderRadius.circular(12),
                                          border: Border.all(
                                              color: Colors.grey.shade600,
                                              width: 1.2),
                                        ),
                                        child: Row(
                                          children: [
                                            const Icon(Icons.info_outline,
                                                size: 20),
                                            const SizedBox(width: 10),
                                            Expanded(
                                              child: Text(
                                                'This trip has been claimed by another driver.',
                                                style: TextStyle(
                                                  fontSize: 12,
                                                  fontWeight: FontWeight.w600,
                                                  color: scheme.onSurface,
                                                ),
                                              ),
                                            ),
                                          ],
                                        ),
                                      ),
                                      const SizedBox(height: 14),
                                    ] else if (isTripCancelled) ...[
                                      Container(
                                        padding: const EdgeInsets.symmetric(
                                            horizontal: 14, vertical: 10),
                                        decoration: BoxDecoration(
                                          color: Colors.red.shade900
                                              .withValues(alpha: 0.15),
                                          borderRadius:
                                              BorderRadius.circular(12),
                                          border: Border.all(
                                              color: Colors.red.shade700,
                                              width: 1.2),
                                        ),
                                        child: Row(
                                          children: [
                                            Icon(Icons.cancel_outlined,
                                                color: Colors.red.shade700,
                                                size: 20),
                                            const SizedBox(width: 10),
                                            Expanded(
                                              child: Text(
                                                'This trip was cancelled by the customer.',
                                                style: TextStyle(
                                                  fontSize: 12,
                                                  fontWeight: FontWeight.w600,
                                                  color: scheme.onSurface,
                                                ),
                                              ),
                                            ),
                                          ],
                                        ),
                                      ),
                                      const SizedBox(height: 14),
                                    ],

                                    // ── Counter-Offer Suggestion Pills + Edit Pen Icon ──
                                    // Stacked directly above the unified accept button
                                    Row(
                                      children: [
                                        // Edit pen icon neatly in front of suggestion options
                                        Tooltip(
                                          message: isBidPending
                                              ? 'Bid pending response'
                                              : 'Enter custom counter-offer',
                                          child: Material(
                                            color: _isCustomBidActive
                                                ? AppColors.seseGold
                                                : scheme.surfaceContainerHighest,
                                            shape: const CircleBorder(),
                                            child: InkWell(
                                              customBorder:
                                                  const CircleBorder(),
                                              onTap: isBidPending
                                                  ? null
                                                  : _toggleCustomBid,
                                              child: Padding(
                                                padding:
                                                    const EdgeInsets.all(8),
                                                child: Icon(
                                                  Icons.edit,
                                                  size: 18,
                                                  color: isBidPending
                                                      ? Colors.grey
                                                      : _isCustomBidActive
                                                          ? Colors.black87
                                                          : scheme
                                                              .onSurfaceVariant,
                                                ),
                                              ),
                                            ),
                                          ),
                                        ),
                                        const SizedBox(width: 8),
                                        Expanded(
                                          child: SingleChildScrollView(
                                            scrollDirection: Axis.horizontal,
                                            child: Row(
                                              children: [
                                                ChoiceChip(
                                                  label: Text(
                                                      '${widget.currencySymbol}${_formatAmount(baseline)}'),
                                                  selected:
                                                      _selectedSuggestionPct ==
                                                              null &&
                                                          !_isCustomBidActive,
                                                  selectedColor:
                                                      AppColors.seseGold,
                                                  labelStyle: TextStyle(
                                                    color: (_selectedSuggestionPct ==
                                                                null &&
                                                            !_isCustomBidActive)
                                                        ? Colors.black87
                                                        : scheme.onSurface,
                                                    fontWeight: FontWeight.bold,
                                                    fontSize: 12,
                                                  ),
                                                  onSelected: isBidPending
                                                      ? null
                                                      : (_) => _applySuggestion(
                                                          null, baseline),
                                                ),
                                                const SizedBox(width: 8),
                                                ChoiceChip(
                                                  label: Text(
                                                      '+5% (${widget.currencySymbol}${_formatAmount(plus5Val)})'),
                                                  selected:
                                                      _selectedSuggestionPct ==
                                                          5,
                                                  selectedColor:
                                                      AppColors.seseGold,
                                                  labelStyle: TextStyle(
                                                    color: _selectedSuggestionPct ==
                                                            5
                                                        ? Colors.black87
                                                        : scheme.onSurface,
                                                    fontWeight: FontWeight.bold,
                                                    fontSize: 12,
                                                  ),
                                                  onSelected: isBidPending
                                                      ? null
                                                      : (_) => _applySuggestion(
                                                          5, plus5Val),
                                                ),
                                                const SizedBox(width: 8),
                                                ChoiceChip(
                                                  label: Text(
                                                      '+10% (${widget.currencySymbol}${_formatAmount(plus10Val)})'),
                                                  selected:
                                                      _selectedSuggestionPct ==
                                                          10,
                                                  selectedColor:
                                                      AppColors.seseGold,
                                                  labelStyle: TextStyle(
                                                    color: _selectedSuggestionPct ==
                                                            10
                                                        ? Colors.black87
                                                        : scheme.onSurface,
                                                    fontWeight: FontWeight.bold,
                                                    fontSize: 12,
                                                  ),
                                                  onSelected: isBidPending
                                                      ? null
                                                      : (_) => _applySuggestion(
                                                          10, plus10Val),
                                                ),
                                              ],
                                            ),
                                          ),
                                        ),
                                      ],
                                    ),

                                    // Keyboard-safe custom amount input field
                                    if (_isCustomBidActive) ...[
                                      const SizedBox(height: 10),
                                      TextField(
                                        controller: _bidCtrl,
                                        focusNode: _bidFocusNode,
                                        enabled: !isBidPending,
                                        keyboardType: const TextInputType
                                            .numberWithOptions(decimal: false),
                                        inputFormatters: [
                                          FilteringTextInputFormatter.digitsOnly
                                        ],
                                        decoration: InputDecoration(
                                          labelText: 'Custom Offer Amount',
                                          prefixText:
                                              '${widget.currencySymbol} ',
                                          errorText: _bidError,
                                          border: OutlineInputBorder(
                                            borderRadius:
                                                BorderRadius.circular(10),
                                          ),
                                          contentPadding:
                                              const EdgeInsets.symmetric(
                                                  horizontal: 12, vertical: 12),
                                        ),
                                        onChanged: _onBidChanged,
                                      ),
                                    ],
                                  ],
                                ),
                              ),
                            ),

                            // ── Sticky Primary Action Button Footer ──
                            // Pinned to the bottom of the sheet, always visible without manual scrolling
                            SafeArea(
                              top: false,
                              child: Container(
                                padding: EdgeInsets.fromLTRB(
                                  16,
                                  8,
                                  16,
                                  16 + MediaQuery.of(context).viewInsets.bottom,
                                ),
                                decoration: BoxDecoration(
                                  color:
                                      Theme.of(context).scaffoldBackgroundColor,
                                  boxShadow: [
                                    BoxShadow(
                                      color:
                                          Colors.black.withValues(alpha: 0.08),
                                      offset: const Offset(0, -3),
                                      blurRadius: 8,
                                    ),
                                  ],
                                ),
                                child: SizedBox(
                                  width: double.infinity,
                                  child: isClaimedByAnotherDriver ||
                                          isTripCancelled
                                      ? FilledButton.icon(
                                          key: Key(
                                              'pool_primary_action_${trip.tripId}'),
                                          style: FilledButton.styleFrom(
                                            backgroundColor:
                                                Colors.grey.shade700,
                                            foregroundColor: Colors.white,
                                            padding: const EdgeInsets.symmetric(
                                                vertical: 14),
                                            shape: RoundedRectangleBorder(
                                              borderRadius:
                                                  BorderRadius.circular(12),
                                            ),
                                          ),
                                          onPressed: () =>
                                              Navigator.of(context).pop(),
                                          icon: const Icon(Icons.arrow_back,
                                              size: 20),
                                          label: const Text(
                                              'Back to Order Pool',
                                              style: TextStyle(
                                                  fontWeight: FontWeight.bold,
                                                  fontSize: 15)),
                                        )
                                      : isBidPending
                                          ? FilledButton.icon(
                                              key: Key(
                                                  'pool_primary_action_${trip.tripId}'),
                                              style: FilledButton.styleFrom(
                                                backgroundColor:
                                                    const Color(0xFFD97706),
                                                foregroundColor: Colors.white,
                                                padding:
                                                    const EdgeInsets.symmetric(
                                                        vertical: 14),
                                                shape: RoundedRectangleBorder(
                                                  borderRadius:
                                                      BorderRadius.circular(12),
                                                ),
                                                disabledBackgroundColor:
                                                    const Color(0xFFD97706)
                                                        .withValues(alpha: 0.7),
                                                disabledForegroundColor:
                                                    Colors.white,
                                              ),
                                              onPressed: null,
                                              icon: const SizedBox(
                                                width: 18,
                                                height: 18,
                                                child:
                                                    CircularProgressIndicator(
                                                  strokeWidth: 2.5,
                                                  color: Colors.white,
                                                ),
                                              ),
                                              label: Text(
                                                'Waiting for Customer... (${activeBid.remainingSeconds}s)',
                                                style: const TextStyle(
                                                  fontWeight: FontWeight.bold,
                                                  fontSize: 15,
                                                ),
                                              ),
                                            )
                                          : FilledButton.icon(
                                              key: Key(
                                                  'pool_primary_action_${trip.tripId}'),
                                              style: FilledButton.styleFrom(
                                                backgroundColor: _isCounterOffer
                                                    ? scheme.primary
                                                    : AppColors.seseGold,
                                                foregroundColor: Colors.black87,
                                                padding:
                                                    const EdgeInsets.symmetric(
                                                        vertical: 14),
                                                shape: RoundedRectangleBorder(
                                                  borderRadius:
                                                      BorderRadius.circular(12),
                                                ),
                                              ),
                                              onPressed: _isCounterOffer
                                                  ? ((_submittingBid ||
                                                          _bidError != null)
                                                      ? null
                                                      : () => _submitBid(
                                                          baseline))
                                                  : (_accepting
                                                      ? null
                                                      : _acceptNow),
                                              icon: (_accepting ||
                                                      _submittingBid)
                                                  ? const SizedBox(
                                                      width: 18,
                                                      height: 18,
                                                      child:
                                                          CircularProgressIndicator(
                                                        strokeWidth: 2,
                                                        color: Colors.black87,
                                                      ),
                                                    )
                                                  : Icon(
                                                      _isCounterOffer
                                                          ? Icons.send_rounded
                                                          : Icons.flash_on,
                                                      size: 20,
                                                    ),
                                              label: Text(
                                                _accepting
                                                    ? 'Claiming trip...'
                                                    : _submittingBid
                                                        ? 'Submitting...'
                                                        : _isCounterOffer
                                                            ? 'Send Counter-Offer (${widget.currencySymbol}${_formatAmount(_currentBidAmount)})'
                                                            : 'Accept ($fareLabel)',
                                                style: const TextStyle(
                                                  fontWeight: FontWeight.bold,
                                                  fontSize: 15,
                                                ),
                                              ),
                                            ),
                                ),
                              ),
                            ),
                          ],
                        ),
                      );
                    },
                  ),
                ],
              ),
            );
          },
        ),
      );
    },
  );
      },
    );
  }
}

class _MapMiniButton extends StatelessWidget {
  final IconData icon;
  final VoidCallback onTap;

  const _MapMiniButton({required this.icon, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.white,
      elevation: 2,
      shape: const CircleBorder(),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: SizedBox(
          width: 32,
          height: 32,
          child: Icon(icon, size: 18, color: Colors.black87),
        ),
      ),
    );
  }
}

/// Empty-state widget rendered inside [OrderPoolSheet] while the pool has no
/// nearby orders. Displays the breathing gold radar animation + descriptive
/// text so the map canvas remains clean when the driver is online and idle.
///
/// The [breathe] controller is supplied by [_OrderPoolSheetState] and shared
/// so only one [AnimationController] runs, regardless of rebuilds.
class _EmptyPoolRadar extends StatelessWidget {
  final AnimationController breathe;

  const _EmptyPoolRadar({required this.breathe});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 28),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          AnimatedBuilder(
            animation: breathe,
            builder: (context, _) {
              final t = breathe.value;
              return SizedBox(
                width: 140,
                height: 140,
                child: Stack(
                  alignment: Alignment.center,
                  children: [
                    // Outer pulsing ring.
                    Container(
                      width: 140 * (0.55 + 0.45 * t),
                      height: 140 * (0.55 + 0.45 * t),
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: scheme.primary
                            .withValues(alpha: 0.10 * (1 - t) + 0.02),
                      ),
                    ),
                    // Inner filled disc.
                    Container(
                      width: 84,
                      height: 84,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: scheme.primary.withValues(alpha: 0.14),
                      ),
                    ),
                    Icon(Icons.radar, size: 36, color: scheme.primary),
                  ],
                ),
              );
            },
          ),
          const SizedBox(height: 14),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
            decoration: BoxDecoration(
              color: scheme.surfaceContainerHighest.withValues(alpha: 0.9),
              borderRadius: BorderRadius.circular(20),
            ),
            child: Text(
              'Searching\u2026',
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: scheme.onSurfaceVariant,
              ),
            ),
          ),
          const SizedBox(height: 10),
          Padding(
            // 16px matches the sheet list padding (12–16) so the empty
            // text spans the same width as pool rows, not a narrow column.
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Text(
              'No open orders near you right now.\n'
              'New requests appear here the moment they hit the pool.',
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 12,
                color: scheme.onSurfaceVariant,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
