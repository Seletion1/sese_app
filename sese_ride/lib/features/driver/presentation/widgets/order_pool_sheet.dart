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

/// Persistent session cache for Order Pool dismissals.
/// Once a driver swipes away or hides an order, it stays permanently filtered out
/// for the remainder of the app session, preventing stream refreshes from ghosting it back.
abstract final class OrderPoolSession {
  static final Set<String> _dismissedOrderIds = <String>{};

  static bool isDismissed(String tripId) => _dismissedOrderIds.contains(tripId);

  static void dismiss(String tripId) {
    _dismissedOrderIds.add(tripId);
  }

  static void restore(String tripId) {
    _dismissedOrderIds.remove(tripId);
  }

  static void clear() {
    _dismissedOrderIds.clear();
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
      useSafeArea: false,
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
                .where((t) => !OrderPoolSession.isDismissed(t.tripId))
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
                              OrderPoolSession.dismiss(trip.tripId);
                              ScaffoldMessenger.of(context)
                                  .removeCurrentSnackBar();
                              ScaffoldMessenger.of(context).showSnackBar(
                                SnackBar(
                                  content: const Text(
                                      'Order hidden for this session.'),
                                  duration: const Duration(seconds: 3),
                                  action: SnackBarAction(
                                    label: 'Undo',
                                    textColor: AppColors.seseGold,
                                    onPressed: () {
                                      OrderPoolSession.restore(trip.tripId);
                                      setState(() {});
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
  final FocusNode _bidFocusNode = FocusNode();
  bool _accepting = false;
  bool _submittingBid = false;
  int? _selectedSuggestionPct;
  bool _isCustomBidActive = false;
  String? _bidError;

  LatLng get _pickup => LatLng(widget.trip.pickupLat, widget.trip.pickupLng);
  LatLng get _dropoff => LatLng(widget.trip.dropoffLat, widget.trip.dropoffLng);

  @override
  void initState() {
    super.initState();
    final baseline = widget.trip.fareAmount;
    _bidCtrl = TextEditingController(text: baseline.round().toString());
    _selectedSuggestionPct = null;
    _loadRoutes();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _mapController.fitPoints(_pickup, _dropoff, padding: 88);
    });
  }

  @override
  void dispose() {
    _bidCtrl.dispose();
    _bidFocusNode.dispose();
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

  void _applySuggestion(int? pct, double val) {
    setState(() {
      _selectedSuggestionPct = pct;
      _isCustomBidActive = false;
      _bidCtrl.text = val.round().toString();
      _bidError = null;
    });
  }

  void _toggleCustomBid() {
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
    if (_selectedSuggestionPct != null) return true;
    if (_isCustomBidActive) {
      final val = double.tryParse(_bidCtrl.text.trim()) ?? 0;
      return val > widget.trip.fareAmount;
    }
    return false;
  }

  double get _currentBidAmount {
    return double.tryParse(_bidCtrl.text.trim()) ?? widget.trip.fareAmount;
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
      debugPrint('OrderPoolSheet submitBid error: $e');
      setState(() => _submittingBid = false);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Unable to submit offer right now. Please try again.'),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final trip = widget.trip;
    final baseline = trip.fareAmount;
    final plus5Val = _roundTo100(baseline * 1.05);
    final plus10Val = _roundTo100(baseline * 1.10);

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

    return SizedBox(
      height: MediaQuery.of(context).size.height,
      width: MediaQuery.of(context).size.width,
      child: Stack(
        children: [
          // ── Layer 0: Full-Screen Interactive Map ──
          Positioned.fill(
            child: SeSeMapView(
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

          // ── Layer 1: Top Navigation Controls (Back & Zoom) ──
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: SafeArea(
              child: Padding(
                padding:
                    const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    CircleAvatar(
                      backgroundColor:
                          scheme.surface.withValues(alpha: 0.95),
                      child: IconButton(
                        icon: const Icon(Icons.arrow_back),
                        tooltip: 'Back to pool',
                        onPressed: () => Navigator.of(context).pop(),
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
          DraggableScrollableSheet(
            initialChildSize: 0.50,
            minChildSize: 0.28,
            maxChildSize: 0.90,
            snap: true,
            snapSizes: const [0.28, 0.50, 0.90],
            builder: (context, scrollController) {
              return Container(
                decoration: BoxDecoration(
                  color: Theme.of(context).scaffoldBackgroundColor,
                  borderRadius:
                      const BorderRadius.vertical(top: Radius.circular(24)),
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
                    // Sheet drag handle
                    Center(
                      child: Container(
                        width: 44,
                        height: 4,
                        decoration: BoxDecoration(
                          color:
                              scheme.onSurfaceVariant.withValues(alpha: 0.4),
                          borderRadius: BorderRadius.circular(2),
                        ),
                      ),
                    ),
                    Expanded(
                      child: SingleChildScrollView(
                        controller: scrollController,
                        padding:
                            const EdgeInsets.fromLTRB(16, 10, 16, 12),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            // Sender Profile Header & Prominent Fare
                            Row(
                              children: [
                                UserAvatar(
                                    displayName: senderName, radius: 22),
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
                                                fontWeight: FontWeight.bold,
                                                fontSize: 16,
                                              ),
                                              overflow: TextOverflow.ellipsis,
                                            ),
                                          ),
                                          if (trip.isVerifiedCustomer) ...[
                                            const SizedBox(width: 4),
                                            const Icon(Icons.verified,
                                                size: 16,
                                                color: AppColors.seseGold),
                                          ],
                                        ],
                                      ),
                                      const SizedBox(height: 2),
                                      Text(
                                        '${trip.serviceType == 'ride' ? 'Ride' : 'Delivery'} • ${trip.distanceKm.toStringAsFixed(1)} km trip',
                                        style: TextStyle(
                                          fontSize: 12,
                                          color: scheme.onSurfaceVariant,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                                Column(
                                  crossAxisAlignment: CrossAxisAlignment.end,
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
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Row(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      const Padding(
                                        padding: EdgeInsets.only(top: 3),
                                        child: Icon(Icons.circle,
                                            size: 10, color: Colors.green),
                                      ),
                                      const SizedBox(width: 8),
                                      Expanded(
                                        child: Text(
                                          trip.pickupAddress.isEmpty
                                              ? 'Pickup location'
                                              : trip.pickupAddress,
                                          style: const TextStyle(
                                              fontSize: 13,
                                              fontWeight: FontWeight.w500),
                                        ),
                                      ),
                                    ],
                                  ),
                                  const Padding(
                                    padding: EdgeInsets.only(left: 4, top: 2, bottom: 2),
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
                                        padding: EdgeInsets.only(top: 2),
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
                                              fontWeight: FontWeight.w500),
                                        ),
                                      ),
                                    ],
                                  ),
                                ],
                              ),
                            ),
                            const SizedBox(height: 10),

                            // Distance & Time Metrics
                            Row(
                              children: [
                                Expanded(
                                  child: Container(
                                    padding: const EdgeInsets.symmetric(
                                        horizontal: 10, vertical: 8),
                                    decoration: BoxDecoration(
                                      color: scheme.surface,
                                      borderRadius: BorderRadius.circular(10),
                                      border: Border.all(
                                        color: scheme.outlineVariant
                                            .withValues(alpha: 0.4),
                                      ),
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
                                              fontWeight: FontWeight.w600,
                                            ),
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
                                        horizontal: 10, vertical: 8),
                                    decoration: BoxDecoration(
                                      color: scheme.surface,
                                      borderRadius: BorderRadius.circular(10),
                                      border: Border.all(
                                        color: scheme.outlineVariant
                                            .withValues(alpha: 0.4),
                                      ),
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
                                              fontWeight: FontWeight.w600,
                                            ),
                                            overflow: TextOverflow.ellipsis,
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 16),

                            // ── Counter-Offer Suggestion Pills + Edit Pen Icon ──
                            // Stacked directly above the unified accept button
                            Row(
                              children: [
                                // Edit pen icon neatly in front of suggestion options
                                Tooltip(
                                  message: 'Enter custom counter-offer',
                                  child: Material(
                                    color: _isCustomBidActive
                                        ? AppColors.seseGold
                                        : scheme.surfaceContainerHighest,
                                    shape: const CircleBorder(),
                                    child: InkWell(
                                      customBorder: const CircleBorder(),
                                      onTap: _toggleCustomBid,
                                      child: Padding(
                                        padding: const EdgeInsets.all(8),
                                        child: Icon(
                                          Icons.edit,
                                          size: 18,
                                          color: _isCustomBidActive
                                              ? Colors.black87
                                              : scheme.onSurfaceVariant,
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
                                          selected: _selectedSuggestionPct ==
                                                  null &&
                                              !_isCustomBidActive,
                                          selectedColor: AppColors.seseGold,
                                          labelStyle: TextStyle(
                                            color: (_selectedSuggestionPct ==
                                                        null &&
                                                    !_isCustomBidActive)
                                                ? Colors.black87
                                                : scheme.onSurface,
                                            fontWeight: FontWeight.bold,
                                            fontSize: 12,
                                          ),
                                          onSelected: (_) =>
                                              _applySuggestion(null, baseline),
                                        ),
                                        const SizedBox(width: 8),
                                        ChoiceChip(
                                          label: Text(
                                              '+5% (${widget.currencySymbol}${_formatAmount(plus5Val)})'),
                                          selected:
                                              _selectedSuggestionPct == 5,
                                          selectedColor: AppColors.seseGold,
                                          labelStyle: TextStyle(
                                            color: _selectedSuggestionPct == 5
                                                ? Colors.black87
                                                : scheme.onSurface,
                                            fontWeight: FontWeight.bold,
                                            fontSize: 12,
                                          ),
                                          onSelected: (_) =>
                                              _applySuggestion(5, plus5Val),
                                        ),
                                        const SizedBox(width: 8),
                                        ChoiceChip(
                                          label: Text(
                                              '+10% (${widget.currencySymbol}${_formatAmount(plus10Val)})'),
                                          selected:
                                              _selectedSuggestionPct == 10,
                                          selectedColor: AppColors.seseGold,
                                          labelStyle: TextStyle(
                                            color: _selectedSuggestionPct == 10
                                                ? Colors.black87
                                                : scheme.onSurface,
                                            fontWeight: FontWeight.bold,
                                            fontSize: 12,
                                          ),
                                          onSelected: (_) =>
                                              _applySuggestion(10, plus10Val),
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
                                keyboardType:
                                    const TextInputType.numberWithOptions(
                                        decimal: false),
                                inputFormatters: [
                                  FilteringTextInputFormatter.digitsOnly
                                ],
                                decoration: InputDecoration(
                                  labelText: 'Custom Offer Amount',
                                  prefixText: '${widget.currencySymbol} ',
                                  errorText: _bidError,
                                  border: OutlineInputBorder(
                                    borderRadius: BorderRadius.circular(10),
                                  ),
                                  contentPadding: const EdgeInsets.symmetric(
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
                          color: Theme.of(context).scaffoldBackgroundColor,
                          boxShadow: [
                            BoxShadow(
                              color: Colors.black.withValues(alpha: 0.08),
                              offset: const Offset(0, -3),
                              blurRadius: 8,
                            ),
                          ],
                        ),
                        child: SizedBox(
                          width: double.infinity,
                          child: FilledButton.icon(
                            key: Key(
                                'pool_primary_action_${trip.tripId}'),
                            style: FilledButton.styleFrom(
                              backgroundColor: _isCounterOffer
                                  ? scheme.primary
                                  : AppColors.seseGold,
                              foregroundColor: Colors.black87,
                              padding: const EdgeInsets.symmetric(
                                  vertical: 14),
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(12),
                              ),
                            ),
                            onPressed: _isCounterOffer
                                ? ((_submittingBid || _bidError != null)
                                    ? null
                                    : _submitBid)
                                : (_accepting ? null : _acceptNow),
                            icon: (_accepting || _submittingBid)
                                ? const SizedBox(
                                    width: 18,
                                    height: 18,
                                    child: CircularProgressIndicator(
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
