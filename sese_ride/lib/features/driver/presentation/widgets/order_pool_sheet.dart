import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:latlong2/latlong.dart';
import 'package:sese_core/sese_core.dart';

import '../../../customer/services/location_service.dart';
import '../../../trips/models/trip_models.dart';
import '../../../trips/services/trip_service.dart';
import '../../services/driver_streak_service.dart';
import '../../../../widgets/map_provider.dart';
import 'order_feed.dart';


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

  const OrderPoolSheet({
    super.key,
    required this.streakService,
    required this.driverPosition,
    required this.currencySymbol,
  });

  @override
  State<OrderPoolSheet> createState() => _OrderPoolSheetState();
}

class _OrderPoolSheetState extends State<OrderPoolSheet>
    with SingleTickerProviderStateMixin {
  /// Breathing animation controller for the empty-state radar indicator.
  /// Runs only while the sheet is rendered; automatically freed on dispose.
  late final AnimationController _breathe;

  @override
  void initState() {
    super.initState();
    _breathe = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1600),
    )..repeat(reverse: true);
  }

  @override
  void dispose() {
    _breathe.dispose();
    super.dispose();
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

  void _openDetails(ActiveTrip trip) {
    showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) => _PoolOrderDetailSheet(
        trip: trip,
        driverPosition: widget.driverPosition,
        currencySymbol: widget.currencySymbol,
        streakService: widget.streakService,
        onAccepted: (tripId) {
          Navigator.of(ctx).pop(tripId);
          Navigator.of(context).pop(tripId);
        },
      ),
    );
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
          stream: widget.streakService.marketplaceStream(),
          builder: (context, snap) {
            final trips = (snap.data ?? const <ActiveTrip>[])
                .where((t) => OrderFeedState.withinPoolRadius(
                    t, widget.driverPosition))
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
                        padding: const EdgeInsets.fromLTRB(12, 4, 12, 16),
                        itemCount: trips.length,
                        separatorBuilder: (_, _) =>
                            const SizedBox(height: 8),
                        itemBuilder: (context, i) =>
                            _PoolRow(
                          trip: trips[i],
                          fareLabel: _fareLabel(trips[i]),
                          typeLabel: _typeLabel(trips[i]),
                          ageText: _ageText(trips[i]),
                          driverPosition: widget.driverPosition,
                          onTap: () => _openDetails(trips[i]),
                        ),
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
                  Text(
                    fareLabel,
                    style: TextStyle(
                      fontWeight: FontWeight.w900,
                      fontSize: 17,
                      color: scheme.primary,
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
                    Text(
                      'Pickup: ${pickupKm.toStringAsFixed(1)} km (~$pickupEtaMins min)',
                      style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w500,
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                    const Spacer(),
                    Icon(Icons.route_outlined,
                        size: 14, color: scheme.onSurfaceVariant),
                    const SizedBox(width: 4),
                    Text(
                      'Trip: ${trip.distanceKm.toStringAsFixed(1)} km (~$tripDurationMins min)',
                      style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w500,
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 6),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  Text(
                    'Tap to view route & make offer',
                    style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                      color: scheme.primary,
                    ),
                  ),
                  const SizedBox(width: 2),
                  Icon(Icons.arrow_forward_ios,
                      size: 10, color: scheme.primary),
                ],
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
class _PoolOrderDetailSheet extends StatefulWidget {
  final ActiveTrip trip;
  final LatLng driverPosition;
  final String currencySymbol;
  final DriverStreakService streakService;
  final ValueChanged<String> onAccepted;

  const _PoolOrderDetailSheet({
    required this.trip,
    required this.driverPosition,
    required this.currencySymbol,
    required this.streakService,
    required this.onAccepted,
  });

  @override
  State<_PoolOrderDetailSheet> createState() => _PoolOrderDetailSheetState();
}

class _PoolOrderDetailSheetState extends State<_PoolOrderDetailSheet> {
  final SeSeMapController _mapController = SeSeMapController();
  List<LatLng> _routePoints = [];
  List<LatLng> _driverLegPoints = [];
  late final TextEditingController _bidCtrl;
  bool _accepting = false;
  bool _submittingBid = false;
  int? _selectedSuggestionPct;
  String? _bidError;

  LatLng get _pickup => LatLng(widget.trip.pickupLat, widget.trip.pickupLng);
  LatLng get _dropoff => LatLng(widget.trip.dropoffLat, widget.trip.dropoffLng);

  @override
  void initState() {
    super.initState();
    final baseline = widget.trip.fareAmount;
    final initialBid = (baseline * 1.05).round();
    _bidCtrl = TextEditingController(text: initialBid.toString());
    _selectedSuggestionPct = 5;
    _loadRoutes();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _mapController.fitPoints(_pickup, _dropoff, padding: 48);
    });
  }

  @override
  void dispose() {
    _bidCtrl.dispose();
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
    _mapController.fitPoints(_pickup, _dropoff, padding: 48);
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

  void _applySuggestion(int pct, double val) {
    setState(() {
      _selectedSuggestionPct = pct;
      _bidCtrl.text = val.round().toString();
      _bidError = null;
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

  Future<void> _acceptNow() async {
    if (_accepting) return;
    setState(() => _accepting = true);
    try {
      await widget.streakService.acceptTrip(widget.trip.tripId);
      if (!mounted) return;
      widget.onAccepted(widget.trip.tripId);
    } on DriverStreakException catch (e) {
      if (!mounted) return;
      setState(() => _accepting = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(e.userMessage)),
      );
    } catch (_) {
      if (!mounted) return;
      setState(() => _accepting = false);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
            content: Text('Could not accept this order. Try another.')),
      );
    }
  }

  Future<void> _submitBid() async {
    final val = double.tryParse(_bidCtrl.text.trim());
    final baseline = widget.trip.fareAmount;
    if (val == null || val < baseline) {
      setState(() {
        _bidError =
            'Must be \u2265 ${widget.currencySymbol}${_formatAmount(baseline)}';
      });
      return;
    }
    setState(() => _submittingBid = true);
    try {
      final repo = FirestoreTripRepository();
      const distanceCalc = Distance();
      final pickupKm = distanceCalc.as(
          LengthUnit.Kilometer, widget.driverPosition, _pickup);
      final etaMins = ((pickupKm / 30.0) * 60).round().clamp(1, 120);

      await repo.submitBid(widget.trip.tripId, val, etaMinutes: etaMins);
      if (!mounted) return;
      Navigator.of(context).pop();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
              'Counter-offer of ${widget.currencySymbol}${_formatAmount(val)} submitted! Sender has been notified.'),
          backgroundColor: Colors.green.shade800,
        ),
      );
    } on TripException catch (e) {
      if (!mounted) return;
      setState(() => _submittingBid = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(e.userMessage)),
      );
    } catch (e) {
      if (!mounted) return;
      setState(() => _submittingBid = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not submit bid: $e')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final trip = widget.trip;
    final baseline = trip.fareAmount;
    final plus5Val = (baseline * 1.05).roundToDouble();
    final plus10Val = (baseline * 1.10).roundToDouble();

    const distanceCalc = Distance();
    final pickupKm =
        distanceCalc.as(LengthUnit.Kilometer, widget.driverPosition, _pickup);
    final pickupEtaMins = ((pickupKm / 30.0) * 60).round().clamp(1, 120);
    final tripDurationMins = trip.durationMins > 0
        ? trip.durationMins
        : ((trip.distanceKm / 30.0) * 60).round().clamp(2, 240);

    final senderName =
        trip.customerName.isNotEmpty ? trip.customerName : 'Sender';
    final fareLabel = trip.fareFormatted.isNotEmpty
        ? trip.fareFormatted
        : '${widget.currencySymbol}${_formatAmount(baseline)}';

    return Container(
      constraints: BoxConstraints(
        maxHeight: MediaQuery.of(context).size.height * 0.90,
      ),
      decoration: BoxDecoration(
        color: Theme.of(context).scaffoldBackgroundColor,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.25),
            blurRadius: 20,
            offset: const Offset(0, -6),
          ),
        ],
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const SizedBox(height: 8),
          Container(
            width: 44,
            height: 4,
            decoration: BoxDecoration(
              color: scheme.onSurfaceVariant.withValues(alpha: 0.4),
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 8, 4),
            child: Row(
              children: [
                UserAvatar(displayName: senderName, radius: 20),
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
                                  fontWeight: FontWeight.bold, fontSize: 16),
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                          if (trip.isVerifiedCustomer) ...[
                            const SizedBox(width: 4),
                            const Icon(Icons.verified,
                                size: 16, color: AppColors.seseGold),
                          ],
                        ],
                      ),
                      Text(
                        '${trip.serviceType == 'ride' ? 'Ride' : 'Delivery'} • ${trip.distanceKm.toStringAsFixed(1)} km trip',
                        style: TextStyle(
                            fontSize: 12, color: scheme.onSurfaceVariant),
                      ),
                    ],
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.close),
                  tooltip: 'Close',
                  onPressed: () => Navigator.of(context).pop(),
                ),
              ],
            ),
          ),
          const Divider(height: 1),
          Flexible(
            child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  // Prominent price display & Direct tap-to-accept
                  Container(
                    padding: const EdgeInsets.all(14),
                    decoration: BoxDecoration(
                      color:
                          scheme.surfaceContainerHighest.withValues(alpha: 0.6),
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(
                          color: scheme.outlineVariant.withValues(alpha: 0.5)),
                    ),
                    child: Column(
                      children: [
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  'Current Fare',
                                  style: TextStyle(
                                    fontSize: 12,
                                    fontWeight: FontWeight.w600,
                                    color: scheme.onSurfaceVariant,
                                  ),
                                ),
                                const SizedBox(height: 2),
                                Text(
                                  fareLabel,
                                  style: TextStyle(
                                    fontSize: 26,
                                    fontWeight: FontWeight.w900,
                                    color: scheme.primary,
                                  ),
                                ),
                              ],
                            ),
                            FilledButton.icon(
                              key: Key(
                                  'expanded_instant_accept_${trip.tripId}'),
                              style: FilledButton.styleFrom(
                                backgroundColor: AppColors.seseGold,
                                foregroundColor: Colors.black,
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 16, vertical: 12),
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(12),
                                ),
                              ),
                              onPressed: _accepting ? null : _acceptNow,
                              icon: _accepting
                                  ? const SizedBox(
                                      width: 18,
                                      height: 18,
                                      child: CircularProgressIndicator(
                                        strokeWidth: 2,
                                        color: Colors.black,
                                      ),
                                    )
                                  : const Icon(Icons.flash_on, size: 20),
                              label: Text(
                                _accepting ? 'Claiming...' : 'Tap to Accept',
                                style: const TextStyle(
                                  fontWeight: FontWeight.bold,
                                  fontSize: 14,
                                ),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 6),
                        Row(
                          children: [
                            Icon(Icons.bolt,
                                size: 14, color: AppColors.seseGold),
                            const SizedBox(width: 4),
                            Expanded(
                              child: Text(
                                'Instant assignment without customer verification.',
                                style: TextStyle(
                                  fontSize: 11,
                                  color: scheme.onSurfaceVariant,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 12),
                  // Interactive Map View
                  ClipRRect(
                    borderRadius: BorderRadius.circular(16),
                    child: SizedBox(
                      height: 210,
                      child: Stack(
                        children: [
                          SeSeMapView(
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
                          // Zoom controls overlay
                          Positioned(
                            right: 8,
                            top: 8,
                            child: Column(
                              children: [
                                _MapMiniButton(
                                  icon: Icons.add,
                                  onTap: () => _mapController.zoomBy(1),
                                ),
                                const SizedBox(height: 4),
                                _MapMiniButton(
                                  icon: Icons.remove,
                                  onTap: () => _mapController.zoomBy(-1),
                                ),
                                const SizedBox(height: 4),
                                _MapMiniButton(
                                  icon: Icons.my_location,
                                  onTap: () => _mapController.fitPoints(
                                      _pickup, _dropoff,
                                      padding: 48),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),
                  // Route Addresses + Distance / Time metrics
                  Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color:
                          scheme.surfaceContainerHighest.withValues(alpha: 0.4),
                      borderRadius: BorderRadius.circular(14),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Padding(
                              padding: EdgeInsets.only(top: 3),
                              child: Icon(Icons.circle,
                                  size: 10, color: Colors.green),
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  const Text(
                                    'Pickup Point',
                                    style: TextStyle(
                                        fontSize: 11,
                                        fontWeight: FontWeight.bold,
                                        color: Colors.green),
                                  ),
                                  Text(
                                    trip.pickupAddress.isEmpty
                                        ? 'Pickup location'
                                        : trip.pickupAddress,
                                    style: const TextStyle(fontSize: 13),
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),
                        const Padding(
                          padding: EdgeInsets.only(left: 4),
                          child: SizedBox(
                            height: 14,
                            child: VerticalDivider(
                                width: 1, thickness: 1, color: Colors.grey),
                          ),
                        ),
                        Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Padding(
                              padding: EdgeInsets.only(top: 3),
                              child: Icon(Icons.location_on,
                                  size: 12, color: Colors.redAccent),
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  const Text(
                                    'Drop-off Destination',
                                    style: TextStyle(
                                        fontSize: 11,
                                        fontWeight: FontWeight.bold,
                                        color: Colors.redAccent),
                                  ),
                                  Text(
                                    trip.dropoffAddress.isEmpty
                                        ? 'Drop-off location'
                                        : trip.dropoffAddress,
                                    style: const TextStyle(fontSize: 13),
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 10),
                        Row(
                          children: [
                            Expanded(
                              child: Container(
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 8, vertical: 6),
                                decoration: BoxDecoration(
                                  color: scheme.surface,
                                  borderRadius: BorderRadius.circular(8),
                                ),
                                child: Row(
                                  children: [
                                    const Icon(Icons.near_me,
                                        size: 14, color: Colors.blue),
                                    const SizedBox(width: 6),
                                    Expanded(
                                      child: Text(
                                        'To Pickup: ${pickupKm.toStringAsFixed(1)} km (~$pickupEtaMins min)',
                                        style: const TextStyle(
                                            fontSize: 11,
                                            fontWeight: FontWeight.w600),
                                        overflow: TextOverflow.ellipsis,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Container(
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 8, vertical: 6),
                                decoration: BoxDecoration(
                                  color: scheme.surface,
                                  borderRadius: BorderRadius.circular(8),
                                ),
                                child: Row(
                                  children: [
                                    const Icon(Icons.alt_route,
                                        size: 14, color: Colors.green),
                                    const SizedBox(width: 6),
                                    Expanded(
                                      child: Text(
                                        'Trip: ${trip.distanceKm.toStringAsFixed(1)} km (~$tripDurationMins min)',
                                        style: const TextStyle(
                                            fontSize: 11,
                                            fontWeight: FontWeight.w600),
                                        overflow: TextOverflow.ellipsis,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 16),
                  // Counter-Offer (Bidding) Section
                  Container(
                    padding: const EdgeInsets.all(14),
                    decoration: BoxDecoration(
                      color: scheme.surface,
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(
                          color: scheme.primary.withValues(alpha: 0.3)),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Icon(Icons.local_offer_outlined,
                                size: 18, color: scheme.primary),
                            const SizedBox(width: 8),
                            const Text(
                              'Propose Counter-Offer',
                              style: TextStyle(
                                fontSize: 15,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 4),
                        Text(
                          'Sender will be prompted to accept or decline your offer in real-time.',
                          style: TextStyle(
                            fontSize: 12,
                            color: scheme.onSurfaceVariant,
                          ),
                        ),
                        const SizedBox(height: 12),
                        // Quick-action price suggestion chips
                        Row(
                          children: [
                            ChoiceChip(
                              label: Text(
                                  '+5% (${widget.currencySymbol}${_formatAmount(plus5Val)})'),
                              selected: _selectedSuggestionPct == 5,
                              onSelected: (_) =>
                                  _applySuggestion(5, plus5Val),
                            ),
                            const SizedBox(width: 8),
                            ChoiceChip(
                              label: Text(
                                  '+10% (${widget.currencySymbol}${_formatAmount(plus10Val)})'),
                              selected: _selectedSuggestionPct == 10,
                              onSelected: (_) =>
                                  _applySuggestion(10, plus10Val),
                            ),
                          ],
                        ),
                        const SizedBox(height: 12),
                        // Custom price textfield with edit pen icon
                        TextField(
                          controller: _bidCtrl,
                          keyboardType:
                              const TextInputType.numberWithOptions(
                                  decimal: false),
                          inputFormatters: [
                            FilteringTextInputFormatter.digitsOnly
                          ],
                          decoration: InputDecoration(
                            labelText: 'Your Offer Price',
                            prefixText: '${widget.currencySymbol} ',
                            suffixIcon: const Icon(Icons.edit, size: 18),
                            errorText: _bidError,
                            border: const OutlineInputBorder(),
                            contentPadding: const EdgeInsets.symmetric(
                                horizontal: 12, vertical: 12),
                          ),
                          onChanged: _onBidChanged,
                        ),
                        const SizedBox(height: 12),
                        SizedBox(
                          width: double.infinity,
                          child: FilledButton.icon(
                            key: Key('submit_counter_offer_${trip.tripId}'),
                            style: FilledButton.styleFrom(
                              padding:
                                  const EdgeInsets.symmetric(vertical: 12),
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(10),
                              ),
                            ),
                            onPressed:
                                (_submittingBid || _bidError != null)
                                    ? null
                                    : _submitBid,
                            icon: _submittingBid
                                ? const SizedBox(
                                    width: 18,
                                    height: 18,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                      color: Colors.white,
                                    ),
                                  )
                                : const Icon(Icons.send_rounded, size: 18),
                            label: Text(
                              _submittingBid
                                  ? 'Submitting...'
                                  : 'Send Counter-Offer to Sender',
                              style:
                                  const TextStyle(fontWeight: FontWeight.bold),
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
        ],
      ),
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
