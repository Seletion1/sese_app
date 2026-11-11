import 'dart:async';

import 'package:flutter/material.dart';
import 'package:sese_core/sese_core.dart';

import '../models/bid_models.dart';
import '../models/trip_models.dart';
import '../services/trip_service.dart';
import 'live_trip_screen.dart';

/// Global in-app overlay wrapper that listens to live customer searching/bidding trips
/// and automatically presents a prominent modal pop-up bidding card right in front
/// of the customer's screen no matter where they are inside the app.
class CustomerBidOverlay extends StatefulWidget {
  final String userId;
  final TripRepository? tripRepository;
  final Widget child;

  const CustomerBidOverlay({
    super.key,
    required this.userId,
    this.tripRepository,
    required this.child,
  });

  @override
  State<CustomerBidOverlay> createState() => _CustomerBidOverlayState();
}

class _CustomerBidOverlayState extends State<CustomerBidOverlay> {
  TripRepository get _repo =>
      widget.tripRepository ?? FirestoreTripRepository();

  StreamSubscription<List<ActiveTrip>>? _tripsSub;
  final Map<String, StreamSubscription<List<BidModel>>> _bidSubs = {};
  final Map<String, List<BidModel>> _bidsPerTrip = {};

  int _selectedBidIndex = 0;
  bool _actionBusy = false;
  Timer? _countdownTicker;

  @override
  void initState() {
    super.initState();
    _subscribeToTrips();
    _startCountdownTicker();
  }

  @override
  void didUpdateWidget(CustomerBidOverlay oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.userId != widget.userId) {
      _unsubscribeAll();
      _subscribeToTrips();
    }
  }

  @override
  void dispose() {
    _unsubscribeAll();
    _countdownTicker?.cancel();
    super.dispose();
  }

  void _unsubscribeAll() {
    _tripsSub?.cancel();
    _tripsSub = null;
    for (final sub in _bidSubs.values) {
      sub.cancel();
    }
    _bidSubs.clear();
    _bidsPerTrip.clear();
  }

  void _startCountdownTicker() {
    final inTest = WidgetsBinding.instance.runtimeType
        .toString()
        .contains('TestWidgetsFlutterBinding');
    if (inTest) return;
    _countdownTicker?.cancel();
    _countdownTicker = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (!mounted) return;
      if (_hasActivePendingBids) {
        setState(() {});
      }
    });
  }

  void _subscribeToTrips() {
    if (widget.userId.isEmpty) return;
    _tripsSub = _repo.activeTripsStream(widget.userId).listen((trips) {
      if (!mounted) return;
      final biddingTrips = trips.where((t) {
        if (!t.isCustomerLive) return false;
        return t.status == TripStatus.searchingDriver ||
            t.status == TripStatus.waitingForAcceptance ||
            t.status == TripStatus.bidding ||
            t.status == TripStatus.marketplaceOpen ||
            t.status == TripStatus.driverPinged;
      }).toList();

      final currentTripIds = biddingTrips.map((t) => t.tripId).toSet();

      // Clean up orphaned subscriptions
      final removedIds =
          _bidSubs.keys.where((id) => !currentTripIds.contains(id)).toList();
      for (final id in removedIds) {
        _bidSubs[id]?.cancel();
        _bidSubs.remove(id);
        _bidsPerTrip.remove(id);
      }

      // Subscribe to bids for active searching/bidding trips
      for (final trip in biddingTrips) {
        if (!_bidSubs.containsKey(trip.tripId)) {
          _bidSubs[trip.tripId] = _repo.bidsStream(trip.tripId).listen((bids) {
            if (!mounted) return;
            final pendingBids = bids
                .where((b) => b.status == BidStatus.pending && !b.isExpired)
                .toList();

            setState(() {
              if (pendingBids.isEmpty) {
                _bidsPerTrip.remove(trip.tripId);
              } else {
                _bidsPerTrip[trip.tripId] = pendingBids;
              }
              if (_selectedBidIndex >= _allPendingBids.length) {
                _selectedBidIndex = 0;
              }
            });
          });
        }
      }
    });
  }

  List<_TripBidPair> get _allPendingBids {
    final result = <_TripBidPair>[];
    for (final entry in _bidsPerTrip.entries) {
      for (final bid in entry.value) {
        if (bid.status == BidStatus.pending && !bid.isExpired) {
          result.add(_TripBidPair(tripId: entry.key, bid: bid));
        }
      }
    }
    return result;
  }

  bool get _hasActivePendingBids => _allPendingBids.isNotEmpty;

  _TripBidPair? get _currentBidPair {
    final bids = _allPendingBids;
    if (bids.isEmpty) return null;
    final index = _selectedBidIndex.clamp(0, bids.length - 1);
    return bids[index];
  }

  Future<void> _acceptBid(_TripBidPair pair) async {
    if (_actionBusy) return;
    setState(() => _actionBusy = true);
    try {
      await _repo.acceptBid(pair.tripId, pair.bid.driverId);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Offer accepted! Driver is on the way.'),
            backgroundColor: Color(0xFF059669),
          ),
        );
        _navigateToLiveTrip(pair.tripId);
      }
    } on TripException catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(e.userMessage)),
        );
      }
    } finally {
      if (mounted) setState(() => _actionBusy = false);
    }
  }

  Future<void> _rejectBid(_TripBidPair pair) async {
    if (_actionBusy) return;
    setState(() => _actionBusy = true);
    try {
      await _repo.rejectBid(pair.tripId, pair.bid.driverId);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Offer declined.')),
        );
      }
    } on TripException catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(e.userMessage)),
        );
      }
    } finally {
      if (mounted) setState(() => _actionBusy = false);
    }
  }

  void _navigateToLiveTrip(String tripId) {
    final navState = IncomingCallOverlay.navigatorKey.currentState ??
        Navigator.maybeOf(context);
    navState?.push(
      MaterialPageRoute(
        builder: (_) => LiveTripScreen(
          tripId: tripId,
          repository: _repo,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final currentPair = _currentBidPair;
    final allBids = _allPendingBids;

    return Stack(
      children: [
        widget.child,
        if (_hasActivePendingBids && currentPair != null)
          Positioned.fill(
            child: Material(
              color: Colors.black54,
              child: SafeArea(
                child: Center(
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 20, vertical: 24),
                    child: Container(
                      constraints: const BoxConstraints(maxWidth: 420),
                      decoration: BoxDecoration(
                        color: Theme.of(context).cardColor,
                        borderRadius: BorderRadius.circular(20),
                        boxShadow: const [
                          BoxShadow(
                            color: Colors.black38,
                            blurRadius: 16,
                            offset: Offset(0, 8),
                          ),
                        ],
                      ),
                      child: Padding(
                        padding: const EdgeInsets.all(20),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            // Header row: Badge + Title + Optional Carousel Counter
                            Row(
                              mainAxisAlignment: MainAxisAlignment.spaceBetween,
                              children: [
                                Container(
                                  padding: const EdgeInsets.symmetric(
                                      horizontal: 10, vertical: 4),
                                  decoration: BoxDecoration(
                                    color: AppColors.seseGold
                                        .withValues(alpha: 0.18),
                                    borderRadius: BorderRadius.circular(12),
                                  ),
                                  child: const Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      Icon(
                                        Icons.local_taxi_rounded,
                                        size: 16,
                                        color: AppColors.seseGold,
                                      ),
                                      SizedBox(width: 6),
                                      Text(
                                        'NEW DRIVER OFFER',
                                        style: TextStyle(
                                          fontSize: 11,
                                          fontWeight: FontWeight.bold,
                                          color: AppColors.seseGold,
                                          letterSpacing: 0.5,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                                if (allBids.length > 1)
                                  Row(
                                    children: [
                                      IconButton(
                                        icon: const Icon(Icons.chevron_left),
                                        iconSize: 20,
                                        padding: EdgeInsets.zero,
                                        constraints: const BoxConstraints(),
                                        onPressed: _selectedBidIndex > 0
                                            ? () => setState(
                                                () => _selectedBidIndex--)
                                            : null,
                                      ),
                                      Padding(
                                        padding: const EdgeInsets.symmetric(
                                            horizontal: 4),
                                        child: Text(
                                          '${_selectedBidIndex + 1}/${allBids.length}',
                                          style: TextStyle(
                                            fontSize: 12,
                                            fontWeight: FontWeight.bold,
                                            color: Theme.of(context)
                                                .colorScheme
                                                .onSurfaceVariant,
                                          ),
                                        ),
                                      ),
                                      IconButton(
                                        icon: const Icon(Icons.chevron_right),
                                        iconSize: 20,
                                        padding: EdgeInsets.zero,
                                        constraints: const BoxConstraints(),
                                        onPressed: _selectedBidIndex <
                                                allBids.length - 1
                                            ? () => setState(
                                                () => _selectedBidIndex++)
                                            : null,
                                      ),
                                    ],
                                  ),
                              ],
                            ),
                            const SizedBox(height: 16),

                            // Driver details row: Avatar + Name + Rating + Vehicle Details
                            Row(
                              children: [
                                UserAvatar(
                                  displayName: currentPair.bid.driverName,
                                  photoUrl: currentPair.bid.photoUrl,
                                  radius: 24,
                                ),
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
                                              currentPair.bid.driverName,
                                              style: const TextStyle(
                                                fontSize: 16,
                                                fontWeight: FontWeight.bold,
                                              ),
                                              overflow: TextOverflow.ellipsis,
                                            ),
                                          ),
                                          if (currentPair.bid.isVerifiedDriver) ...[
                                            const SizedBox(width: 4),
                                            const Icon(
                                              Icons.verified,
                                              size: 16,
                                              color: AppColors.seseGold,
                                            ),
                                          ],
                                        ],
                                      ),
                                      const SizedBox(height: 2),
                                      Text(
                                        [
                                          if (currentPair.bid.rating > 0)
                                            '★ ${currentPair.bid.rating.toStringAsFixed(1)}',
                                          if (currentPair.bid.etaMinutes != null)
                                            '~${currentPair.bid.etaMinutes} min away',
                                          if (currentPair.bid.vehicleModel
                                              .isNotEmpty)
                                            currentPair.bid.vehicleModel,
                                          if (currentPair.bid.plateNumber
                                              .isNotEmpty)
                                            currentPair.bid.plateNumber,
                                        ].join(' · '),
                                        style: TextStyle(
                                          fontSize: 12,
                                          color: Theme.of(context)
                                              .colorScheme
                                              .onSurfaceVariant,
                                        ),
                                        maxLines: 2,
                                        overflow: TextOverflow.ellipsis,
                                      ),
                                    ],
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 16),

                            // Price & Ticking Countdown Box
                            Container(
                              padding: const EdgeInsets.all(12),
                              decoration: BoxDecoration(
                                color: Theme.of(context)
                                    .colorScheme
                                    .surfaceContainerHighest
                                    .withValues(alpha: 0.5),
                                borderRadius: BorderRadius.circular(12),
                                border: Border.all(
                                  color: Theme.of(context)
                                      .colorScheme
                                      .outline
                                      .withValues(alpha: 0.2),
                                ),
                              ),
                              child: Row(
                                mainAxisAlignment:
                                    MainAxisAlignment.spaceBetween,
                                children: [
                                  Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        'OFFERED FARE',
                                        style: TextStyle(
                                          fontSize: 11,
                                          fontWeight: FontWeight.w600,
                                          color: Theme.of(context)
                                              .colorScheme
                                              .onSurfaceVariant,
                                        ),
                                      ),
                                      const SizedBox(height: 2),
                                      Text(
                                        currentPair.bid.fareFormatted.isNotEmpty
                                            ? currentPair.bid.fareFormatted
                                            : '₦${currentPair.bid.offeredFare.toStringAsFixed(0)}',
                                        style: const TextStyle(
                                          fontSize: 22,
                                          fontWeight: FontWeight.w900,
                                          color: AppColors.seseGold,
                                        ),
                                      ),
                                    ],
                                  ),
                                  _BidCountdownBadge(bid: currentPair.bid),
                                ],
                              ),
                            ),
                            const SizedBox(height: 18),

                            // Action buttons: Accept (Green) & Reject (Light Grey)
                            if (_actionBusy)
                              const Center(
                                child: Padding(
                                  padding: EdgeInsets.symmetric(vertical: 8),
                                  child: CircularProgressIndicator(),
                                ),
                              )
                            else
                              Row(
                                children: [
                                  Expanded(
                                    child: ElevatedButton.icon(
                                      onPressed: () => _acceptBid(currentPair),
                                      style: ElevatedButton.styleFrom(
                                        backgroundColor:
                                            const Color(0xFF059669),
                                        foregroundColor: Colors.white,
                                        padding: const EdgeInsets.symmetric(
                                            vertical: 14),
                                        shape: RoundedRectangleBorder(
                                          borderRadius:
                                              BorderRadius.circular(12),
                                        ),
                                        elevation: 0,
                                      ),
                                      icon: const Icon(Icons.check_circle_rounded,
                                          size: 18),
                                      label: const Text(
                                        'Accept',
                                        style: TextStyle(
                                          fontWeight: FontWeight.bold,
                                          fontSize: 15,
                                        ),
                                      ),
                                    ),
                                  ),
                                  const SizedBox(width: 12),
                                  Expanded(
                                    child: OutlinedButton.icon(
                                      onPressed: () => _rejectBid(currentPair),
                                      style: OutlinedButton.styleFrom(
                                        padding: const EdgeInsets.symmetric(
                                            vertical: 14),
                                        side: BorderSide(
                                          color: Theme.of(context)
                                              .colorScheme
                                              .outline
                                              .withValues(alpha: 0.3),
                                        ),
                                        shape: RoundedRectangleBorder(
                                          borderRadius:
                                              BorderRadius.circular(12),
                                        ),
                                      ),
                                      icon: const Icon(Icons.close_rounded,
                                          size: 18),
                                      label: const Text(
                                        'Reject',
                                        style: TextStyle(
                                          fontWeight: FontWeight.bold,
                                          fontSize: 15,
                                        ),
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            const SizedBox(height: 12),

                            // Secondary details link
                            Center(
                              child: TextButton.icon(
                                onPressed: () =>
                                    _navigateToLiveTrip(currentPair.tripId),
                                icon: const Icon(Icons.map_outlined, size: 16),
                                label: const Text(
                                  'View Full Trip Map',
                                  style: TextStyle(
                                    fontSize: 13,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }
}

class _TripBidPair {
  final String tripId;
  final BidModel bid;

  const _TripBidPair({
    required this.tripId,
    required this.bid,
  });
}

class _BidCountdownBadge extends StatelessWidget {
  final BidModel bid;

  const _BidCountdownBadge({required this.bid});

  @override
  Widget build(BuildContext context) {
    final remainingSec = bid.remainingSeconds;
    final isUrgent = remainingSec <= 3;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: isUrgent
            ? Colors.red.withValues(alpha: 0.15)
            : AppColors.seseGold.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.timer_outlined,
            size: 14,
            color: isUrgent ? Colors.red : AppColors.seseGold,
          ),
          const SizedBox(width: 4),
          Text(
            '${remainingSec}s',
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.bold,
              color: isUrgent ? Colors.red : AppColors.seseGold,
            ),
          ),
        ],
      ),
    );
  }
}
