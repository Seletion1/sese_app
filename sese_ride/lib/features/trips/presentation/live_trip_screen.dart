import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:latlong2/latlong.dart';
import 'package:sese_core/sese_core.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../widgets/map_provider.dart';
import '../../../widgets/verified_badge.dart';
import '../../customer/services/location_service.dart';
import '../models/bid_models.dart';
import '../models/trip_models.dart';
import '../services/trip_service.dart';
import 'cancel_trip_dialog.dart';
import 'split_request_sheet.dart';
import 'trip_chat_screen.dart';

/// Live dispatch tracker for one trip.
///
/// Fully server-driven: renders snapshots from [TripRepository.tripStream]
/// (status banner, driver sheet, live OpenStreetMap driver marker). The backend owns
/// every transition — matchmaking, ping timeouts, re-broadcasts — so the
/// customer may close the app and restore this screen later from Trips.
class LiveTripScreen extends StatelessWidget {
  final String tripId;
  final TripRepository repository;

  const LiveTripScreen({
    super.key,
    required this.tripId,
    required this.repository,
  });

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Live Trip')),
      body: StreamBuilder<ActiveTrip?>(
        stream: repository.tripStream(tripId),
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.waiting) {
            return const Center(child: CircularProgressIndicator());
          }
          if (snapshot.hasError) {
            return _MessageState(
              icon: Icons.error_outline,
              title: 'Could not load this trip',
              body: 'Check your connection and try again.',
              onClose: () => Navigator.of(context).pop(),
            );
          }
          final trip = snapshot.data;
          if (trip == null) {
            return _MessageState(
              icon: Icons.search_off,
              title: 'Trip no longer available',
              body: 'It may have been cancelled or removed.',
              onClose: () => Navigator.of(context).pop(),
            );
          }
          if (trip.status == TripStatus.completed) {
            return _MessageState(
              icon: Icons.check_circle,
              iconColor: Colors.green,
              title: 'Trip completed',
              body: 'Thanks for riding with SESE.',
              onClose: () => Navigator.of(context).pop(),
            );
          }
          if (trip.status == TripStatus.cancelled) {
            final reason = trip.cancellationSource == 'driver'
                ? 'This trip was cancelled by the driver.'
                : trip.cancellationSource == 'customer'
                ? 'You cancelled this trip.'
                : 'This request is no longer active.';
            return _MessageState(
              icon: Icons.cancel_outlined,
              title: 'Trip cancelled',
              body: reason,
              onClose: () => Navigator.of(context).pop(),
            );
          }
          // Special state: auto-reassignment exhausted — prompt fare boost.
          if (trip.status == TripStatus.needsCustomerAction) {
            return _NeedsActionBody(trip: trip, repository: repository);
          }
          return _LiveTripBody(trip: trip, repository: repository);
        },
      ),
    );
  }
}

// ── NeedsCustomerAction prompt ────────────────────────────────────────────────

/// Shown when auto-reassignment has failed 3 times. The customer must raise
/// the fare (or cancel) to get a driver.
class _NeedsActionBody extends StatefulWidget {
  final ActiveTrip trip;
  final TripRepository repository;

  const _NeedsActionBody({required this.trip, required this.repository});

  @override
  State<_NeedsActionBody> createState() => _NeedsActionBodyState();
}

class _NeedsActionBodyState extends State<_NeedsActionBody> {
  final _controller = TextEditingController();
  bool _loading = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    // Pre-fill with current fare so the customer can see what to beat.
    final current = widget.trip.fareAmount;
    if (current > 0) {
      _controller.text = current.toStringAsFixed(0);
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _boostFare() async {
    final val = double.tryParse(_controller.text.replaceAll(',', ''));
    if (val == null || val <= widget.trip.fareAmount) {
      setState(
        () => _error =
            'Enter an amount higher than the current fare (${widget.trip.fareFormatted})',
      );
      return;
    }
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      await widget.repository.increaseTripFare(widget.trip.tripId, val);
      // Backend resets to SEARCHING_DRIVER — the StreamBuilder will rebuild.
    } on TripException catch (e) {
      if (mounted) setState(() => _error = e.userMessage);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _cancel() async {
    // Reason-first: the dialog returns null on dismiss, committing nothing.
    final reason =
        await CancelTripDialog.show(context, isDriver: false);
    if (reason == null || !mounted) return;
    try {
      await widget.repository.cancelTrip(widget.trip.tripId, reason: reason);
      if (mounted) Navigator.of(context).pop();
    } on TripException catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(e.userMessage)));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.warning_amber_rounded, size: 64, color: cs.error),
          const SizedBox(height: 16),
          Text(
            'No drivers available',
            style: Theme.of(context).textTheme.headlineSmall
                ?.copyWith(fontWeight: FontWeight.bold),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 8),
          Text(
            'We tried 3 times but couldn\'t find a driver for your trip.\n'
            'Increase your offer to attract more drivers, or cancel.',
            textAlign: TextAlign.center,
            style: TextStyle(color: cs.onSurfaceVariant),
          ),
          const SizedBox(height: 24),
          // Quick boost presets: +5% / +10% / +20% over the current fare.
          Wrap(
            alignment: WrapAlignment.center,
            spacing: 8,
            children: [5, 10, 20].map((pct) {
              final base = widget.trip.fareAmount;
              final boosted = (base * (100 + pct) / 100).round();
              return OutlinedButton(
                onPressed: _loading
                    ? null
                    : () => setState(() {
                          _controller.text = boosted.toString();
                          _error = null;
                        }),
                child: Text('+$pct%'),
              );
            }).toList(),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _controller,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            inputFormatters: [
              FilteringTextInputFormatter.allow(RegExp(r'[\d,.]')),
            ],
            decoration: InputDecoration(
              labelText: 'New fare amount',
              prefixText: '₦ ',
              errorText: _error,
              helperText:
                  'Current: ${widget.trip.fareFormatted.isNotEmpty ? widget.trip.fareFormatted : '₦${widget.trip.fareAmount.toStringAsFixed(0)}'}',
            ),
          ),
          const SizedBox(height: 16),
          SizedBox(
            width: double.infinity,
            child: FilledButton.icon(
              icon: _loading
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: Colors.white,
                      ),
                    )
                  : const Icon(Icons.bolt),
              label: Text(_loading ? 'Boosting...' : 'Boost Fare'),
              onPressed: _loading ? null : _boostFare,
              style: FilledButton.styleFrom(
                minimumSize: const Size.fromHeight(48),
              ),
            ),
          ),
          const SizedBox(height: 12),
          SizedBox(
            width: double.infinity,
            child: OutlinedButton.icon(
              icon: const Icon(Icons.close),
              label: const Text('Cancel trip'),
              onPressed: _cancel,
              style: OutlinedButton.styleFrom(
                minimumSize: const Size.fromHeight(44),
                side: BorderSide.none,
                backgroundColor: Theme.of(context)
                    .colorScheme
                    .surfaceContainerHighest,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ── Active (non-terminal) tracking view ───────────────────────────────────────

/// Active (non-terminal) tracking view: status banner + OSM map +
/// accepted-driver sheet + bid carousel + cancel action.
class _LiveTripBody extends StatefulWidget {
  final ActiveTrip trip;
  final TripRepository repository;

  const _LiveTripBody({required this.trip, required this.repository});

  @override
  State<_LiveTripBody> createState() => _LiveTripBodyState();
}

class _LiveTripBodyState extends State<_LiveTripBody> {
  final SeSeMapController _mapController = SeSeMapController();

  /// Road-network route (OSRM). Empty until loaded — the straight
  /// pickup→dropoff segment below is the fallback, never the plan.
  List<LatLng> _routePoints = [];

  @override
  void initState() {
    super.initState();
    _fitRoute();
    _loadRoadRoute();
  }

  @override
  void didUpdateWidget(covariant _LiveTripBody oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.trip.pickupLat != widget.trip.pickupLat ||
        oldWidget.trip.pickupLng != widget.trip.pickupLng ||
        oldWidget.trip.dropoffLat != widget.trip.dropoffLat ||
        oldWidget.trip.dropoffLng != widget.trip.dropoffLng) {
      _fitRoute();
      _loadRoadRoute();
    }
  }

  LatLng get _pickup => LatLng(widget.trip.pickupLat, widget.trip.pickupLng);
  LatLng get _dropoff => LatLng(widget.trip.dropoffLat, widget.trip.dropoffLng);

  void _fitRoute() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _mapController.fitPoints(_pickup, _dropoff, padding: 72);
    });
  }

  /// Fetches the drivable road geometry. Skipped in widget tests (map
  /// placeholder renders, no geometry needed — keeps tests hermetic).
  Future<void> _loadRoadRoute() async {
    if (SeSeMapView.debugTileProviderOverride != null) return;
    final points = await LocationService.fetchRoutePolyline(_pickup, _dropoff);
    if (!mounted || points.isEmpty) return;
    setState(() => _routePoints = points);
  }

  bool get _showBids =>
      widget.trip.status == TripStatus.bidding ||
      widget.trip.status == TripStatus.marketplaceOpen ||
      widget.trip.status == TripStatus.marketplaceList ||
      widget.trip.status == TripStatus.searchingDriver;

  /// True while the trip has no driver yet and the backend is actively
  /// broadcasting/pinging — the searching radar overlay runs in these
  /// states (same set as [_showBids] plus the exclusive-ping states).
  bool get _isSearching =>
      _showBids ||
      widget.trip.status == TripStatus.waitingForAcceptance ||
      widget.trip.status == TripStatus.driverPinged;

  @override
  Widget build(BuildContext context) {
    final trip = widget.trip;
    final pickup = _pickup;
    final dropoff = _dropoff;
    final hasDriverFix = trip.driverLat != null && trip.driverLng != null;
    final focus = hasDriverFix
        ? LatLng(trip.driverLat!, trip.driverLng!)
        : LatLng(
            (pickup.latitude + dropoff.latitude) / 2,
            (pickup.longitude + dropoff.longitude) / 2,
          );

    final markers = [
      SeSeMapView.pin(point: pickup, color: Colors.green),
      SeSeMapView.pin(point: dropoff, color: Colors.red),
      if (hasDriverFix)
        SeSeMapView.pin(
          point: LatLng(trip.driverLat!, trip.driverLng!),
          color: Colors.blue,
        ),
    ];

    final polylines = [
      SeSeMapView.route(
        points: _routePoints.isNotEmpty ? _routePoints : [pickup, dropoff],
      ),
    ];

    return Column(
      children: [
        _StatusBanner(trip: trip),
        // ── Delivery PIN badge (shown when PIN protection is active) ──────
        if (trip.deliveryPinRequired && trip.deliveryPin != null)
          _DeliveryPinBanner(pin: trip.deliveryPin!),
        Expanded(
          child: Stack(
            children: [
              SeSeMapView(
                mapContext: MapContext.realtimeTracking,
                mapController: _mapController,
                initialCenter: focus,
                initialZoom: 14.0,
                showMyLocation: true,
                markers: markers,
                polylines: polylines,
              ),
              // Live broadcast radar while the backend is still matching —
              // motion proves the request is actively radiating, which the
              // static banner text alone could not convey. Pointer-transparent
              // so map gestures always pass through.
              if (_isSearching)
                const Positioned(
                  top: 10,
                  left: 0,
                  right: 0,
                  child: IgnorePointer(
                    child: Center(child: _SearchingOverlay()),
                  ),
                ),
              Positioned(
                right: 12,
                bottom: 12,
                child: MapRecenterButton(
                  key: const Key('live_trip_recenter'),
                  icon: Icons.fit_screen,
                  onTap: _fitRoute,
                ),
              ),
            ],
          ),
        ),
        // ── Bid carousel (shown while searching / marketplace / bidding) ──
        if (_showBids) _BidCarousel(trip: trip, repository: widget.repository),
        // ── Accepted driver info sheet ────────────────────────────────────
        if (trip.driver != null &&
            (trip.status == TripStatus.driverAccepted ||
                trip.status == TripStatus.driverArriving ||
                trip.status == TripStatus.driverArrived ||
                trip.status == TripStatus.inProgress))
          _AcceptedDriverSheet(driver: trip.driver!, trip: trip),
        SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                SizedBox(
                  width: double.infinity,
                  child: OutlinedButton.icon(
                    key: const Key('split_fare_button'),
                    icon: const Icon(Icons.group_add_outlined),
                    label: const Text('Split fare with friends'),
                    onPressed: () async {
                      final splitId = await SplitRequestSheet.show(
                        context,
                        tripId: trip.tripId,
                      );
                      if (splitId != null && context.mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(
                            content: Text(
                              'Invites sent. The split activates once '
                              'everyone accepts — no one is charged yet.',
                            ),
                          ),
                        );
                      }
                    },
                    style: OutlinedButton.styleFrom(
                      side: BorderSide.none,
                      backgroundColor: Theme.of(context)
                          .colorScheme
                          .surfaceContainerHighest,
                    ),
                  ),
                ),
                const SizedBox(height: 8),
                SizedBox(
                  width: double.infinity,
                  child: OutlinedButton.icon(
                    icon: const Icon(Icons.close),
                    label: const Text('Cancel trip'),
                    onPressed: () => _cancel(context),
                    style: OutlinedButton.styleFrom(
                      side: BorderSide.none,
                      backgroundColor: Theme.of(context)
                          .colorScheme
                          .surfaceContainerHighest,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Future<void> _cancel(BuildContext context) async {
    // Reason-first: the dialog returns null on dismiss, committing nothing.
    final reason =
        await CancelTripDialog.show(context, isDriver: false);
    if (reason == null) return;
    try {
      await widget.repository.cancelTrip(widget.trip.tripId, reason: reason);
      if (context.mounted) Navigator.of(context).pop();
    } on TripException catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(e.userMessage)));
      }
    }
  }
}

// ── Bid carousel ──────────────────────────────────────────────────────────────

/// Horizontal scrolling carousel of driver bids (max 5 visible).
/// Shown while the trip is in a "still searching" state so the customer
/// can accept the best bid without waiting for the automatic assignment.
class _BidCarousel extends StatelessWidget {
  static const int _maxVisible = 5;

  final ActiveTrip trip;
  final TripRepository repository;

  const _BidCarousel({required this.trip, required this.repository});

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<List<BidModel>>(
      stream: repository.bidsStream(trip.tripId),
      builder: (context, snapshot) {
        final bids =
            snapshot.data
                ?.where((b) => b.status == BidStatus.pending)
                .take(_maxVisible)
                .toList() ??
            const [];
        if (bids.isEmpty) return const SizedBox.shrink();
        return Container(
          color: Theme.of(context).colorScheme.surfaceContainerLow,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 10, 16, 4),
                child: Text(
                  '${bids.length} driver${bids.length == 1 ? '' : 's'} offered a fare',
                  style: Theme.of(context).textTheme.labelMedium
                      ?.copyWith(fontWeight: FontWeight.bold),
                ),
              ),
              SizedBox(
                height: 148,
                child: ListView.separated(
                  scrollDirection: Axis.horizontal,
                  padding: const EdgeInsets.fromLTRB(12, 0, 12, 10),
                  separatorBuilder: (context, index) =>
                      const SizedBox(width: 10),
                  itemCount: bids.length,
                  itemBuilder: (ctx, i) => _BidCard(
                    bid: bids[i],
                    onAccept: () => _accept(ctx, bids[i].driverId),
                    onReject: () => _reject(ctx, bids[i].driverId),
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Future<void> _accept(BuildContext context, String driverId) async {
    try {
      await repository.acceptBid(trip.tripId, driverId);
    } on TripException catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(e.userMessage)));
      }
    }
  }

  Future<void> _reject(BuildContext context, String driverId) async {
    try {
      await repository.rejectBid(trip.tripId, driverId);
    } on TripException catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(e.userMessage)));
      }
    }
  }
}

class _BidCard extends StatelessWidget {
  final BidModel bid;
  final VoidCallback onAccept;
  final VoidCallback onReject;

  const _BidCard({
    required this.bid,
    required this.onAccept,
    required this.onReject,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final fareLabel = bid.fareFormatted.isNotEmpty
        ? bid.fareFormatted
        : '₦${bid.offeredFare.toStringAsFixed(0)}';
    return Card(
      margin: EdgeInsets.zero,
      child: SizedBox(
        width: 160,
        child: Padding(
          padding: const EdgeInsets.all(10),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      UserAvatar(
                        displayName: bid.driverName,
                        photoUrl: bid.photoUrl,
                        radius: 16,
                      ),
                      if (bid.isVerifiedDriver) ...[
                        const SizedBox(height: 2),
                        const VerifiedBadge(
                          variant: VerifiedBadgeVariant.driver,
                        ),
                      ],
                    ],
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Row(
                      children: [
                        Flexible(
                          child: Text(
                            bid.driverName.split(' ').first,
                            style: const TextStyle(
                              fontWeight: FontWeight.bold,
                              fontSize: 12,
                            ),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        if (bid.isVerifiedDriver) ...[
                          const SizedBox(width: 4),
                          const Icon(
                            Icons.verified,
                            size: 12,
                            color: Colors.blue,
                          ),
                        ],
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 4),
              if (bid.rating > 0)
                Row(
                  children: [
                    const Icon(Icons.star, size: 11, color: Colors.amber),
                    const SizedBox(width: 2),
                    Text(
                      bid.rating.toStringAsFixed(1),
                      style: const TextStyle(fontSize: 10),
                    ),
                    if (bid.etaMinutes != null) ...{
                      const SizedBox(width: 6),
                      Text(
                        '~${bid.etaMinutes} min',
                        style: TextStyle(
                          fontSize: 10,
                          color: cs.onSurfaceVariant,
                        ),
                      ),
                    },
                  ],
                ),
              const Spacer(),
              Text(
                fareLabel,
                style: TextStyle(
                  fontWeight: FontWeight.bold,
                  fontSize: 16,
                  color: cs.primary,
                ),
              ),
              const SizedBox(height: 6),
              Row(
                children: [
                  Expanded(
                    child: FilledButton(
                      onPressed: onAccept,
                      style: FilledButton.styleFrom(
                        backgroundColor: Colors.green.shade700,
                        padding: EdgeInsets.zero,
                        minimumSize: const Size(0, 28),
                        textStyle: const TextStyle(fontSize: 11),
                      ),
                      child: const Text('Accept'),
                    ),
                  ),
                  const SizedBox(width: 4),
                  Expanded(
                    child: OutlinedButton(
                      onPressed: onReject,
                      style: OutlinedButton.styleFrom(
                        padding: EdgeInsets.zero,
                        minimumSize: const Size(0, 28),
                        textStyle: const TextStyle(fontSize: 11),
                        side: BorderSide.none,
                        backgroundColor: Theme.of(context)
                            .colorScheme
                            .surfaceContainerHighest,
                      ),
                      child: const Text('Reject'),
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

// ── Delivery PIN banner ────────────────────────────────────────────────────────

/// Prominently surfaces the 4-digit delivery security PIN to the customer
/// so they can share it with the driver at drop-off.
///
/// Appears only when [ActiveTrip.deliveryPinRequired] is true and the trip
/// has a server-issued [ActiveTrip.deliveryPin]. The server generates this
/// PIN inside `createTrip` when the customer opted-in or when the Hub's
/// `forceDeliveryPinSystemWide` flag is active.
class _DeliveryPinBanner extends StatelessWidget {
  final String pin;

  const _DeliveryPinBanner({required this.pin});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      key: const Key('delivery_pin_banner'),
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      color: Colors.amber.shade700,
      // Trailing hint is Flexible (not a fixed Text) so the 24px PIN with
      // wide letter-spacing never squeezes on narrow phones.
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          const Icon(Icons.lock_outline, color: Colors.white, size: 20),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text(
                  'Delivery Security PIN',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                    letterSpacing: 0.5,
                  ),
                  softWrap: true,
                ),
                Text(
                  pin,
                  key: const Key('delivery_pin_value'),
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 24,
                    fontWeight: FontWeight.bold,
                    letterSpacing: 8,
                  ),
                  softWrap: false,
                  overflow: TextOverflow.visible,
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          Flexible(
            child: Text(
              'Share with\ndriver at drop-off',
              style: TextStyle(
                color: cs.onError.withValues(alpha: 0.85),
                fontSize: 10,
              ),
              textAlign: TextAlign.right,
              softWrap: true,
            ),
          ),
        ],
      ),
    );
  }
}

// ── Live broadcast radar overlay ────────────────────────────────────────────

/// Floating "actively broadcasting" card pinned over the live-trip map while
/// the backend is still matching (searching / pinging / marketplace).
///
/// Three staggered expanding rings around a pulsing vehicle marker prove at
/// a glance that the request is radiating — the static banner text alone
/// could sit frozen on a dead screen. Runs for rides and deliveries alike
/// (it keys off trip status, never service type). Fully pointer-transparent
/// via the [IgnorePointer] at the call site; the card itself is compact and
/// top-anchored so route pins stay visible beneath it.
class _SearchingOverlay extends StatefulWidget {
  const _SearchingOverlay();

  @override
  State<_SearchingOverlay> createState() => _SearchingOverlayState();
}

class _SearchingOverlayState extends State<_SearchingOverlay>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 2400),
  )..repeat();

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      key: const Key('searching_radar_overlay'),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
      decoration: BoxDecoration(
        color: scheme.surface.withValues(alpha: 0.92),
        borderRadius: BorderRadius.circular(24),
        boxShadow: const [
          BoxShadow(color: Colors.black12, blurRadius: 8),
        ],
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          AnimatedBuilder(
            animation: _ctrl,
            builder: (_, _) => CustomPaint(
              size: const Size(40, 40),
              painter: _BroadcastRadarPainter(
                progress: _ctrl.value,
                color: scheme.primary,
              ),
              child: Center(
                child: Container(
                  width: 22,
                  height: 22,
                  decoration: BoxDecoration(
                    color: scheme.primary,
                    shape: BoxShape.circle,
                  ),
                  child: const Icon(
                    Icons.directions_car_filled,
                    size: 13,
                    color: Colors.white,
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(width: 10),
          const Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Broadcasting to nearby drivers…',
                style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold),
              ),
              Text(
                'First driver to accept wins',
                style: TextStyle(fontSize: 10, color: Colors.grey),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// Three staggered expanding rings; each ring fades as it grows, looping.
class _BroadcastRadarPainter extends CustomPainter {
  final double progress;
  final Color color;

  const _BroadcastRadarPainter({required this.progress, required this.color});

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final maxRadius = size.width / 2;
    for (var i = 0; i < 3; i++) {
      final t = (progress + i / 3) % 1;
      canvas.drawCircle(
        center,
        maxRadius * (0.35 + 0.65 * t),
        Paint()
          ..color = color.withValues(alpha: (1 - t) * 0.5)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.6,
      );
    }
  }

  @override
  bool shouldRepaint(_BroadcastRadarPainter old) =>
      old.progress != progress || old.color != color;
}

// ── Animated status banner ────────────────────────────────────────────────────

/// Animated status banner driven by the live trip state machine.
class _StatusBanner extends StatelessWidget {
  final ActiveTrip trip;

  const _StatusBanner({required this.trip});
  @override
  Widget build(BuildContext context) {
    final String message;
    switch (trip.status) {
      case TripStatus.searchingDriver:
      case TripStatus.unknown:
        message = trip.declineCount > 0
            ? "First driver didn't accept... Looking for available drivers"
            : 'Searching for nearby available drivers...';
      case TripStatus.waitingForAcceptance:
      case TripStatus.driverPinged:
        message = 'Driver connected... Waiting for driver to accept';
      case TripStatus.marketplaceOpen:
      case TripStatus.marketplaceList:
        message = 'Broadcasting to nearby drivers...';
      case TripStatus.bidding:
        message = 'Drivers are submitting bids — choose the best offer below';
      case TripStatus.driverAccepted:
      case TripStatus.driverArriving:
        final name = trip.driver?.fullName ?? 'Your driver';
        message = '$name is on the way to pickup';
      case TripStatus.driverArrived:
        message = 'Your driver has arrived at the pickup point';
      case TripStatus.inProgress:
        message = 'Trip in progress — sit back and relax';
      case TripStatus.needsCustomerAction:
      case TripStatus.completed:
      case TripStatus.cancelled:
        message = '';
    }

    return Container(
      key: const Key('live_trip_status'),
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      color: Theme.of(context).colorScheme.primaryContainer,
      child: Row(
        children: [
          const SizedBox(
            width: 18,
            height: 18,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              message,
              style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
            ),
          ),
        ],
      ),
    );
  }
}

// ── Accepted-driver sheet ─────────────────────────────────────────────────────

/// Accepted-driver sheet: photo, name, rating, plate/model + Call/Message.
///
/// Honors "Hide Phone Number" ([PrivacyMasking]): when enabled, the raw
/// number renders masked and direct tel:/sms: actions hide — parties
/// coordinate through the in-app tri-party trip chat instead (WebRTC/VoIP
/// relay requires backend telephony infra; chat is the masked fallback).
class _AcceptedDriverSheet extends StatefulWidget {
  final DriverInfo driver;
  final ActiveTrip trip;

  const _AcceptedDriverSheet({required this.driver, required this.trip});

  @override
  State<_AcceptedDriverSheet> createState() => _AcceptedDriverSheetState();
}

class _AcceptedDriverSheetState extends State<_AcceptedDriverSheet> {
  bool _hidePhones = false;

  @override
  void initState() {
    super.initState();
    PrivacyMasking.hidePhonesEnabled().then((v) {
      if (mounted) setState(() => _hidePhones = v);
    });
  }

  Future<void> _openUri(BuildContext context, Uri uri) async {
    try {
      if (await canLaunchUrl(uri)) {
        await launchUrl(uri);
      } else if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not open ${uri.scheme}: link')),
        );
      }
    } catch (_) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Could not place the call.')),
        );
      }
    }
  }

  void _openTripChat(BuildContext context) {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => TripChatScreen(
          tripId: widget.trip.tripId,
          currentUid: widget.trip.customerId,
          senderRole: 'customer',
          peerName: widget.driver.fullName.isEmpty
              ? 'Trip chat'
              : widget.driver.fullName,
          peerPhone: widget.driver.phone,
          hidePhones: _hidePhones,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final driver = widget.driver;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surface,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(16)),
        boxShadow: const [
          BoxShadow(
            color: Colors.black12,
            blurRadius: 8,
            offset: Offset(0, -2),
          ),
        ],
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  UserAvatar(
                    displayName: driver.fullName,
                    photoUrl: driver.photoUrl,
                    radius: 26,
                  ),
                  if (driver.isVerifiedDriver) ...[
                    const SizedBox(height: 4),
                    const VerifiedBadge(variant: VerifiedBadgeVariant.driver),
                  ],
                ],
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Flexible(
                          child: Text(
                            driver.fullName,
                            style: const TextStyle(
                              fontWeight: FontWeight.bold,
                              fontSize: 16,
                            ),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        if (driver.isVerifiedDriver) ...[
                          const SizedBox(width: 6),
                          const Icon(
                            Icons.verified,
                            size: 16,
                            color: Colors.blue,
                          ),
                        ],
                      ],
                    ),
                    Row(
                      children: [
                        const Icon(Icons.star, size: 14, color: Colors.amber),
                        const SizedBox(width: 4),
                        Text(
                          driver.rating > 0
                              ? driver.rating.toStringAsFixed(1)
                              : 'New driver',
                          style: const TextStyle(fontSize: 12),
                        ),
                        if (driver.vehicleLabel.isNotEmpty) ...[
                          const SizedBox(width: 8),
                          Flexible(
                            child: Text(
                              driver.vehicleLabel,
                              style: const TextStyle(
                                fontSize: 12,
                                color: Colors.grey,
                              ),
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        ],
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              if (!_hidePhones) ...[
                Expanded(
                  child: FilledButton.icon(
                    icon: const Icon(Icons.call),
                    label: const Text('Call'),
                    onPressed: driver.phone.isEmpty
                        ? null
                        : () => _openUri(
                              context,
                              Uri(scheme: 'tel', path: driver.phone),
                            ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: OutlinedButton.icon(
                    icon: const Icon(Icons.message),
                    label: const Text('Message'),
                    onPressed: driver.phone.isEmpty
                        ? null
                        : () => _openUri(
                              context,
                              Uri(
                                scheme: 'sms',
                                path: driver.phone,
                                queryParameters: {
                                  'body': 'Hello, I am your SESE rider.',
                                },
                              ),
                            ),
                    style: OutlinedButton.styleFrom(
                      side: BorderSide.none,
                      backgroundColor: Theme.of(context)
                          .colorScheme
                          .surfaceContainerHighest,
                    ),
                  ),
                ),
              ] else ...[
                Expanded(
                  child: FilledButton.icon(
                    key: const Key('trip_chat_open_button'),
                    icon: const Icon(Icons.chat_bubble_outline),
                    label: const Text('Chat in app'),
                    onPressed: () => _openTripChat(context),
                  ),
                ),
              ],
            ],
          ),
          if (!_hidePhones) ...[
            const SizedBox(height: 8),
            SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                key: const Key('trip_chat_open_button'),
                icon: const Icon(Icons.chat_bubble_outline),
                label: const Text('Chat in app'),
                onPressed: () => _openTripChat(context),
                style: OutlinedButton.styleFrom(
                  side: BorderSide.none,
                  backgroundColor:
                      Theme.of(context).colorScheme.surfaceContainerHighest,
                ),
              ),
            ),
          ] else ...[
            const SizedBox(height: 6),
            Text(
              'Phone numbers hidden — coordinate in the trip chat.',
              textAlign: TextAlign.center,
              style: TextStyle(
                  fontSize: 11,
                  color: Theme.of(context).colorScheme.onSurfaceVariant),
            ),
          ],
        ],
      ),
    );
  }
}

// ── Terminal / error placeholder ──────────────────────────────────────────────

/// Terminal / error placeholder with a way back.
class _MessageState extends StatelessWidget {
  final IconData icon;
  final Color? iconColor;
  final String title;
  final String body;
  final VoidCallback onClose;

  const _MessageState({
    required this.icon,
    required this.title,
    required this.body,
    required this.onClose,
    this.iconColor,
  });

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 56, color: iconColor ?? Colors.grey),
            const SizedBox(height: 12),
            Text(
              title,
              style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 8),
            Text(body, textAlign: TextAlign.center),
            const SizedBox(height: 20),
            FilledButton(onPressed: onClose, child: const Text('Done')),
          ],
        ),
      ),
    );
  }
}
