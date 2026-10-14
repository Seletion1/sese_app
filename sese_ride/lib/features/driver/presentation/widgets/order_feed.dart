import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:latlong2/latlong.dart';

import '../../../trips/models/trip_models.dart';
import '../../services/driver_streak_service.dart';
import 'order_card.dart';
import 'order_empty_state.dart';

/// Vertical feed of incoming ride offers on the driver Home tab.
///
/// Fills the space between the GO ONLINE pill and the streak banner:
/// - Merges Tier 1 (exclusive ping) + Tier 2 (2-driver ping group) +
///   Tier 3 (marketplace broadcast) offers into one scrollable list.
/// - Inserts each new trip at the **top** of the feed so older offers stay
///   discoverable below.
/// - Floating "Show new requests" pill appears only when new trips arrive
///   while the driver is scrolled down; tapping it jumps to the top.
///
/// The caller (dashboard scaffold) is responsible for keeping this widget
/// between the status pill and the fixed streak banner.
class OrderFeed extends StatefulWidget {
  final String driverId;
  final LatLng driverPosition;
  final String currencySymbol;
  final String streakTag;
  final DriverStreakService streakService;
  final bool isOnline;

  const OrderFeed({
    super.key,
    required this.driverId,
    required this.driverPosition,
    required this.currencySymbol,
    required this.streakTag,
    required this.streakService,
    required this.isOnline,
  });

  @override
  State<OrderFeed> createState() => OrderFeedState();
}

/// Exposed for widget tests (new-requests count, scroll-to-top).
class OrderFeedState extends State<OrderFeed> {
  late final ScrollController scrollController;
  int _unseenNew = 0;
  int _lastTripCount = 0;

  @override
  void initState() {
    super.initState();
    scrollController = ScrollController();
    scrollController.addListener(_onScroll);
  }

  void _onScroll() {
    if (!scrollController.hasClients) return;
    if (scrollController.position.pixels <= 40 && _unseenNew > 0) {
      setState(() => _unseenNew = 0);
    }
  }

  @override
  void dispose() {
    scrollController.removeListener(_onScroll);
    scrollController.dispose();
    super.dispose();
  }

  /// Scrolls the feed list to the top (pool badge tap target).
  void scrollToTop() {
    if (!scrollController.hasClients) return;
    scrollController.animateTo(
      0,
      duration: const Duration(milliseconds: 300),
      curve: Curves.easeOut,
    );
  }

  /// Merges Tier 1/2/3 offers, de-duplicates by `tripId`.
  ///
  /// Exclusive offers first (Tier 1, then Tier 2), marketplace broadcast
  /// below — a trip only ever sits in one tier at a time, so later tiers
  /// never overwrite an exclusive ping.
  ///
  /// Marketplace rows are additionally geo-filtered to the 5km outer pool:
  /// the server broadcasts pool-wide, so without this a Lagos driver renders
  /// Abuja orders. Tier 1/2 pings are server-targeted and never filtered.
  /// Trips without coordinates pass through (never hide for missing data).
  List<ActiveTrip> _mergedOffers(
    ActiveTrip? tier1,
    List<ActiveTrip> tier2,
    List<ActiveTrip> marketplace,
  ) {
    final byId = <String, ActiveTrip>{};
    if (tier1 != null) {
      byId[tier1.tripId] = tier1;
    }
    for (final t in tier2) {
      byId.putIfAbsent(t.tripId, () => t);
    }
    for (final t in marketplace) {
      if (_withinPoolRadius(t)) {
        byId.putIfAbsent(t.tripId, () => t);
      }
    }
    return byId.values.toList();
  }

  /// True when the trip pickup is within the marketplace outer pool
  /// (5km) of the driver, or when either side lacks coordinates.
  static const double poolRadiusKm = 5.0;

  /// Shared by the feed merge and the pool badge so both agree on the count.
  static bool withinPoolRadius(ActiveTrip trip, LatLng driverPosition) {
    final plat = trip.pickupLat;
    final plng = trip.pickupLng;
    final dlat = driverPosition.latitude;
    final dlng = driverPosition.longitude;
    if ((plat == 0 && plng == 0) || (dlat == 0 && dlng == 0)) return true;
    return haversineKm(dlat, dlng, plat, plng) <= poolRadiusKm;
  }

  bool _withinPoolRadius(ActiveTrip trip) =>
      withinPoolRadius(trip, widget.driverPosition);

  static double haversineKm(
      double lat1, double lng1, double lat2, double lng2) {
    // Zero coordinates mean "unknown" — sort last / treat as infinitely
    // far rather than computing a meaningless distance from Null Island.
    if ((lat1 == 0 && lng1 == 0) || (lat2 == 0 && lng2 == 0)) {
      return double.infinity;
    }
    const r = 6371.0;
    const rad = 0.017453292519943295;
    final dLat = (lat2 - lat1) * rad;
    final dLng = (lng2 - lng1) * rad;
    final a = math.sin(dLat / 2) * math.sin(dLat / 2) +
        math.cos(lat1 * rad) *
            math.cos(lat2 * rad) *
            math.sin(dLng / 2) *
            math.sin(dLng / 2);
    return 2 * r * math.asin(math.sqrt(a));
  }

  /// Tracks arrivals for the "Show new requests" pill. UI-affecting
  /// mutations go through `setState` (this runs in a post-frame callback —
  /// a bare mutation would never rebuild, so the pill would never appear).
  /// `setState` fires only on an actual change, so the post-frame re-run
  /// after each rebuild is a no-op and cannot loop.
  void _maybeMarkUnseen(int nextCount) {
    final last = _lastTripCount;
    if (nextCount == last) return;
    final atTop =
        !scrollController.hasClients || scrollController.position.pixels <= 40;
    if (nextCount > last && !atTop) {
      setState(() {
        _unseenNew += nextCount - last;
        _lastTripCount = nextCount;
      });
    } else if (nextCount < last && _unseenNew > 0) {
      setState(() {
        _unseenNew = 0;
        _lastTripCount = nextCount;
      });
    } else {
      _lastTripCount = nextCount;
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.isOnline) {
      return const SizedBox.shrink();
    }
    return StreamBuilder<ActiveTrip?>(
      stream: widget.streakService.pingStream(widget.driverId),
      builder: (context, pingSnap) {
        return StreamBuilder<List<ActiveTrip>>(
          stream: widget.streakService.tier2PingStream(widget.driverId),
          builder: (context, tier2Snap) {
            return StreamBuilder<List<ActiveTrip>>(
              stream: widget.streakService.marketplaceStream(),
              builder: (context, marketSnap) {
                final offers = _mergedOffers(
                  pingSnap.data,
                  tier2Snap.data ?? const [],
                  marketSnap.data ?? const [],
                );
                WidgetsBinding.instance.addPostFrameCallback((_) {
                  if (mounted) _maybeMarkUnseen(offers.length);
                });
                // AnimatedSwitcher cross-fades between the pulsing radar
                // empty state and the order list, so the first pooled order
                // renders smoothly in place of the "Searching" widget.
                return AnimatedSwitcher(
                  duration: const Duration(milliseconds: 350),
                  switchInCurve: Curves.easeOut,
                  switchOutCurve: Curves.easeIn,
                  child: offers.isEmpty
                      ? const OrderEmptyState(key: ValueKey('empty_state'))
                      : _buildOfferList(offers),
                );
              },
            );
          },
        );
      },
    );
  }

  /// Scrollable order-card list with the floating "Show new requests" pill.
  /// Keyed so [AnimatedSwitcher] can cross-fade it against the empty state.
  Widget _buildOfferList(List<ActiveTrip> offers) {
    return Stack(
      key: const ValueKey('offer_list'),
      children: [
        ListView.builder(
          key: const Key('order_feed_list'),
          controller: scrollController,
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
          itemCount: offers.length,
          itemBuilder: (context, i) => OrderCard(
            trip: offers[i],
            driverPosition: widget.driverPosition,
            currencySymbol: widget.currencySymbol,
            streakService: widget.streakService,
            streakTag: widget.streakTag,
          ),
        ),
        if (_unseenNew > 0)
          Positioned(
            top: 4,
            left: 0,
            right: 0,
            child: Center(
              child: Material(
                color: Colors.black,
                borderRadius: BorderRadius.circular(20),
                elevation: 4,
                child: InkWell(
                  key: const Key('show_new_requests_pill'),
                  borderRadius: BorderRadius.circular(20),
                  onTap: () {
                    scrollController.animateTo(
                      0,
                      duration: const Duration(milliseconds: 300),
                      curve: Curves.easeOut,
                    );
                    setState(() => _unseenNew = 0);
                  },
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 14,
                      vertical: 8,
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(
                          Icons.arrow_upward,
                          size: 14,
                          color: Colors.white,
                        ),
                        const SizedBox(width: 6),
                        Text(
                          _unseenNew == 1
                              ? 'Show new request'
                              : 'Show $_unseenNew new requests',
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ],
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

/// Floating marketplace count badge for the dashboard header area.
///
/// Streams the same pool the feed renders (geo-filtered identically, so the
/// count always agrees with the list below). Shows `Order Pool (X)` with a
/// pulse animation while orders are available, `Order Pool (0)` inactive
/// otherwise. Tapping scrolls the feed to the top via [onTap].
class PoolBadge extends StatefulWidget {
  final DriverStreakService streakService;
  final LatLng driverPosition;
  final VoidCallback? onTap;

  const PoolBadge({
    super.key,
    required this.streakService,
    required this.driverPosition,
    this.onTap,
  });

  @override
  State<PoolBadge> createState() => _PoolBadgeState();
}

class _PoolBadgeState extends State<PoolBadge>
    with SingleTickerProviderStateMixin {
  late final AnimationController _pulse;

  @override
  void initState() {
    super.initState();
    _pulse = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1200),
    )..repeat(reverse: true);
  }

  @override
  void dispose() {
    _pulse.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<List<ActiveTrip>>(
      stream: widget.streakService.marketplaceStream(),
      builder: (context, snap) {
        final trips = snap.data ?? const <ActiveTrip>[];
        final count = trips
            .where((t) => OrderFeedState.withinPoolRadius(
                t, widget.driverPosition))
            .length;
        final active = count > 0;

        // Gold gradient pill matching the brand "Quick Order" reference design.
        final badge = GestureDetector(
          onTap: widget.onTap,
          child: Container(
            key: const Key('pool_badge'),
            padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
            decoration: BoxDecoration(
              gradient: LinearGradient(
                colors: active
                    ? const [Color(0xFFE59400), Color(0xFFFFB800)]
                    : const [Color(0xFF8A5C00), Color(0xFFAD7500)],
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
              ),
              borderRadius: BorderRadius.circular(24),
              boxShadow: [
                BoxShadow(
                  // ignore: deprecated_member_use
                  color: const Color(0xFFFFB800).withOpacity(active ? 0.40 : 0.15),
                  blurRadius: 14,
                  offset: const Offset(0, 4),
                ),
              ],
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(
                  Icons.shopping_bag_rounded,
                  size: 20,
                  color: Color(0xFF1A1200),
                ),
                const SizedBox(width: 8),
                Text(
                  count > 0 ? 'Quick Order ($count)' : 'Quick Order',
                  style: const TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w700,
                    color: Color(0xFF1A1200),
                    letterSpacing: 0.2,
                  ),
                ),
              ],
            ),
          ),
        );

        if (!active) return badge;
        // Pulse-scale while orders are in the pool.
        return AnimatedBuilder(
          animation: _pulse,
          builder: (context, child) => Transform.scale(
            scale: 1.0 + _pulse.value * 0.05,
            child: Opacity(
              opacity: 0.93 + _pulse.value * 0.07,
              child: child,
            ),
          ),
          child: badge,
        );
      },
    );
  }
}
