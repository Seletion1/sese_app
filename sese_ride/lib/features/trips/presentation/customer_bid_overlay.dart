import 'dart:async';

import 'package:flutter/material.dart';
import 'package:sese_core/sese_core.dart';

import '../models/bid_models.dart';
import '../models/trip_models.dart';
import '../services/trip_service.dart';
import 'live_trip_screen.dart';

/// Global in-app overlay wrapper that listens to live customer searching/bidding
/// trips and presents non-blocking, stacked floating banner cards for each
/// pending driver bid.
///
/// Design rules:
/// - **Never blocks navigation** — banners are compact and sit at the top of
///   the screen without a modal backdrop, so the customer can scroll, navigate,
///   or perform any action while bids are displayed.
/// - **Zero-second destruction** — a precision `Timer` fires at the exact
///   millisecond each bid's `expiresAt` elapses and immediately removes it from
///   the visible queue; no "0s" zombie state is ever rendered.
/// - **Priority-queue stacking** — multiple bids from different drivers stack
///   neatly top-to-bottom. The soonest-expiring bid surfaces first.
/// - **No expired-state rendering** — there is no "Expired" card, no disabled
///   Accept button on a stale offer; expired bids simply vanish.
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

  /// Canonical list of live pending bids, sorted soonest-expiring first.
  final List<_TripBidPair> _pendingBids = [];

  /// Precision expiry timers keyed by bidId — each fires at the exact
  /// millisecond the bid expires and removes it from [_pendingBids].
  final Map<String, Timer> _expiryTimers = {};

  bool _actionBusy = false;

  @override
  void initState() {
    super.initState();
    _subscribeToTrips();
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
    super.dispose();
  }

  void _unsubscribeAll() {
    _tripsSub?.cancel();
    _tripsSub = null;
    for (final sub in _bidSubs.values) {
      sub.cancel();
    }
    _bidSubs.clear();
    for (final t in _expiryTimers.values) {
      t.cancel();
    }
    _expiryTimers.clear();
    _pendingBids.clear();
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

      // Cancel subscriptions for trips no longer in bidding state.
      final removedIds =
          _bidSubs.keys.where((id) => !currentTripIds.contains(id)).toList();
      for (final id in removedIds) {
        _bidSubs[id]?.cancel();
        _bidSubs.remove(id);
        _removeBidsForTrip(id);
      }

      // Subscribe to bids for each active bidding trip.
      for (final trip in biddingTrips) {
        if (!_bidSubs.containsKey(trip.tripId)) {
          _bidSubs[trip.tripId] =
              _repo.bidsStream(trip.tripId).listen((bids) {
            if (!mounted) return;
            _mergeBids(trip.tripId, bids);
          });
        }
      }
    });
  }

  /// Merges a fresh list of bids for [tripId] into [_pendingBids].
  ///
  /// - Adds newly arrived pending bids and arms their expiry timers.
  /// - Removes bids that are no longer pending or already expired.
  /// - Keeps the list sorted soonest-expiring first.
  void _mergeBids(String tripId, List<BidModel> incomingBids) {
    final nowMs = DateTime.now().millisecondsSinceEpoch;

    final pending = incomingBids
        .where((b) =>
            b.status == BidStatus.pending &&
            !b.isExpired &&
            b.expiresAt != null &&
            b.expiresAt!.millisecondsSinceEpoch > nowMs)
        .toList();

    final incomingIds = pending.map((b) => b.bidId).toSet();

    // Remove stale entries for this trip that are no longer in the incoming set.
    _pendingBids.removeWhere(
        (p) => p.tripId == tripId && !incomingIds.contains(p.bid.bidId));

    for (final bid in pending) {
      final alreadyPresent =
          _pendingBids.any((p) => p.bid.bidId == bid.bidId);
      if (!alreadyPresent) {
        _pendingBids.add(_TripBidPair(tripId: tripId, bid: bid));
        _armExpiryTimer(bid);
      }
    }

    // Sort: soonest-expiring first so the most urgent offer is shown at the top.
    _pendingBids.sort((a, b) {
      final aMs = a.bid.expiresAt?.millisecondsSinceEpoch ?? 0;
      final bMs = b.bid.expiresAt?.millisecondsSinceEpoch ?? 0;
      return aMs.compareTo(bMs);
    });

    setState(() {});
  }

  /// Arms a one-shot timer that fires at the exact millisecond [bid] expires
  /// and removes it from [_pendingBids] with zero residual zombie rendering.
  void _armExpiryTimer(BidModel bid) {
    _expiryTimers[bid.bidId]?.cancel();
    if (bid.expiresAt == null) return;

    final delay = bid.expiresAt!.difference(DateTime.now());
    if (delay.isNegative) {
      // Already expired — remove immediately.
      _removeBid(bid.bidId);
      return;
    }

    _expiryTimers[bid.bidId] = Timer(delay, () {
      if (mounted) _removeBid(bid.bidId);
    });
  }

  void _removeBid(String bidId) {
    _expiryTimers[bidId]?.cancel();
    _expiryTimers.remove(bidId);
    final hadBid = _pendingBids.any((p) => p.bid.bidId == bidId);
    _pendingBids.removeWhere((p) => p.bid.bidId == bidId);
    if (hadBid && mounted) setState(() {});
  }

  void _removeBidsForTrip(String tripId) {
    final removed = _pendingBids.where((p) => p.tripId == tripId).toList();
    for (final p in removed) {
      _expiryTimers[p.bid.bidId]?.cancel();
      _expiryTimers.remove(p.bid.bidId);
    }
    _pendingBids.removeWhere((p) => p.tripId == tripId);
    if (mounted) setState(() {});
  }

  Future<void> _acceptBid(_TripBidPair pair) async {
    if (_actionBusy) return;
    // Guard: re-check expiry at the moment of tap before calling server.
    if (pair.bid.isExpired) {
      _removeBid(pair.bid.bidId);
      return;
    }
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
        // If the server rejected due to expiry, the banner is already gone;
        // show a brief snack for user awareness.
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(e.userMessage)),
        );
        // Force-remove the stale card regardless of Firestore stream lag.
        _removeBid(pair.bid.bidId);
      }
    } finally {
      if (mounted) setState(() => _actionBusy = false);
    }
  }

  Future<void> _rejectBid(_TripBidPair pair) async {
    if (_actionBusy) return;
    setState(() => _actionBusy = true);
    // Optimistically remove immediately so the UI feels instant.
    _removeBid(pair.bid.bidId);
    try {
      await _repo.rejectBid(pair.tripId, pair.bid.driverId);
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
    return Stack(
      children: [
        widget.child,
        // Stacked non-blocking bid banners positioned at the top of the screen.
        // Each banner is independently ticking; no modal backdrop.
        if (_pendingBids.isNotEmpty)
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: SafeArea(
              bottom: false,
              child: Padding(
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    for (int i = 0; i < _pendingBids.length; i++)
                      _BidBannerCard(
                        key: ValueKey('bid_banner_${_pendingBids[i].bid.bidId}'),
                        pair: _pendingBids[i],
                        isBusy: _actionBusy,
                        onAccept: () => _acceptBid(_pendingBids[i]),
                        onReject: () => _rejectBid(_pendingBids[i]),
                      ),
                  ],
                ),
              ),
            ),
          ),
      ],
    );
  }
}

// ── Data Helpers ──────────────────────────────────────────────────────────────

class _TripBidPair {
  final String tripId;
  final BidModel bid;

  const _TripBidPair({required this.tripId, required this.bid});
}

// ── Compact Floating Bid Card ─────────────────────────────────────────────────

/// Single floating offer card — compact style identical to the Live Trip bid
/// list (`_BidCard`).
///
/// Layout:
/// - **Row 1**: avatar · name + verified chip | inline countdown + fare (gold)
/// - **Row 2**: star + rating · vehicle details (plate, model, ETA)
/// - **Row 3**: Accept (green filled) | Reject (surface outlined)
///
/// No modal backdrop, no "OFFERED FARE" box, no "NEW DRIVER OFFER" badge,
/// no "View Full Trip Map" link. Every card in the stack — first or queued —
/// uses this identical compact layout.
class _BidBannerCard extends StatefulWidget {
  final _TripBidPair pair;
  final bool isBusy;
  final VoidCallback onAccept;
  final VoidCallback onReject;

  const _BidBannerCard({
    super.key,
    required this.pair,
    required this.isBusy,
    required this.onAccept,
    required this.onReject,
  });

  @override
  State<_BidBannerCard> createState() => _BidBannerCardState();
}

class _BidBannerCardState extends State<_BidBannerCard> {
  Timer? _ticker;

  @override
  void initState() {
    super.initState();
    _startTicker();
  }

  @override
  void didUpdateWidget(_BidBannerCard old) {
    super.didUpdateWidget(old);
    if (old.pair.bid.bidId != widget.pair.bid.bidId) {
      _ticker?.cancel();
      _startTicker();
    }
  }

  void _startTicker() {
    _ticker?.cancel();
    // Tick every 500 ms for a smooth countdown display without excessive
    // rebuilds.
    _ticker = Timer.periodic(const Duration(milliseconds: 500), (_) {
      if (!mounted) return;
      setState(() {});
    });
  }

  @override
  void dispose() {
    _ticker?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // Defence-in-depth: the overlay's precision expiry timer removes cards
    // before they ever reach 0 s, but guard here just in case.
    if (widget.pair.bid.isExpired) return const SizedBox.shrink();

    final bid = widget.pair.bid;
    final remaining = bid.remainingSeconds;
    final isUrgent = remaining <= 3;
    final timerColour = isUrgent ? Colors.red : AppColors.seseGold;
    final fareLabel = bid.fareFormatted.isNotEmpty
        ? bid.fareFormatted
        : '₦${bid.offeredFare.toStringAsFixed(0)}';
    final vehicleDetails = [
      if (bid.etaMinutes != null) '~${bid.etaMinutes} min away',
      bid.vehicleModel,
      bid.plateNumber,
    ].where((s) => s.trim().isNotEmpty).join(' · ');
    final cs = Theme.of(context).colorScheme;

    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Material(
        color: Theme.of(context).cardColor,
        borderRadius: BorderRadius.circular(14),
        elevation: 6,
        shadowColor: Colors.black26,
        child: Padding(
          padding: const EdgeInsets.all(10),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // ── Row 1: avatar | name + verified  ·  countdown + fare ──────
              Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  UserAvatar(
                    displayName: bid.driverName,
                    photoUrl: bid.photoUrl,
                    radius: 16,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        // Name + verified badge
                        Flexible(
                          child: Row(
                            children: [
                              Flexible(
                                child: Text(
                                  bid.driverName,
                                  style: const TextStyle(
                                    fontWeight: FontWeight.bold,
                                    fontSize: 13,
                                  ),
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                              if (bid.isVerifiedDriver) ...[
                                const SizedBox(width: 4),
                                const Icon(
                                  Icons.verified,
                                  size: 14,
                                  color: AppColors.seseGold,
                                ),
                              ],
                            ],
                          ),
                        ),
                        const SizedBox(width: 8),
                        // Inline countdown badge + fare amount
                        Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Container(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 6, vertical: 2),
                              decoration: BoxDecoration(
                                color: timerColour.withValues(alpha: 0.15),
                                borderRadius: BorderRadius.circular(8),
                              ),
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Icon(Icons.timer_outlined,
                                      size: 11, color: timerColour),
                                  const SizedBox(width: 3),
                                  Text(
                                    '${remaining}s',
                                    style: TextStyle(
                                      fontSize: 11,
                                      fontWeight: FontWeight.bold,
                                      color: timerColour,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            const SizedBox(width: 6),
                            Text(
                              fareLabel,
                              style: const TextStyle(
                                fontWeight: FontWeight.bold,
                                fontSize: 16,
                                color: AppColors.seseGold,
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 4),

              // ── Row 2: rating · vehicle details ───────────────────────────
              Row(
                children: [
                  if (bid.rating > 0) ...[
                    const Icon(Icons.star, size: 12, color: Colors.amber),
                    const SizedBox(width: 2),
                    Text(
                      bid.rating.toStringAsFixed(1),
                      style: const TextStyle(
                          fontSize: 11, fontWeight: FontWeight.bold),
                    ),
                    const SizedBox(width: 6),
                    Text('·', style: TextStyle(color: cs.onSurfaceVariant)),
                    const SizedBox(width: 6),
                  ],
                  Expanded(
                    child: Text(
                      vehicleDetails.isNotEmpty
                          ? vehicleDetails
                          : 'Vehicle details available',
                      style:
                          TextStyle(fontSize: 11, color: cs.onSurfaceVariant),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),

              // ── Row 3: Accept | Reject ─────────────────────────────────────
              if (widget.isBusy)
                const Center(
                  child: Padding(
                    padding: EdgeInsets.symmetric(vertical: 4),
                    child: SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                  ),
                )
              else
                Row(
                  children: [
                    Expanded(
                      child: FilledButton.icon(
                        onPressed: widget.onAccept,
                        style: FilledButton.styleFrom(
                          backgroundColor: Colors.green.shade700,
                          foregroundColor: Colors.white,
                          padding: EdgeInsets.zero,
                          minimumSize: const Size(0, 32),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(8),
                          ),
                        ),
                        icon: const Icon(Icons.check, size: 14),
                        label: const Text(
                          'Accept',
                          style: TextStyle(
                              fontSize: 12, fontWeight: FontWeight.bold),
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed: widget.onReject,
                        style: OutlinedButton.styleFrom(
                          padding: EdgeInsets.zero,
                          minimumSize: const Size(0, 32),
                          side: BorderSide.none,
                          backgroundColor: cs.surfaceContainerHighest,
                          foregroundColor: cs.onSurface,
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(8),
                          ),
                        ),
                        icon: const Icon(Icons.close, size: 14),
                        label: const Text(
                          'Reject',
                          style: TextStyle(fontSize: 12),
                        ),
                      ),
                    ),
                  ],
                ),
            ],
          ),
        ),
      ),
    );
  }
}
