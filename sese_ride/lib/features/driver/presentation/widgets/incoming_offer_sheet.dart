import 'dart:async';

import 'package:flutter/material.dart';
import 'package:latlong2/latlong.dart';
import 'package:sese_core/sese_core.dart';

import '../../../../core/services/remote_config_service.dart';
import '../../../../widgets/map_provider.dart';
import '../../../customer/services/location_service.dart';
import '../../../trips/models/trip_models.dart';
import '../../../trips/services/trip_service.dart';
import '../../services/driver_streak_service.dart';
import 'low_balance_dialog.dart';

/// Full-screen incoming offer, Bolt-style: route preview from
/// pickup (A) to drop-off (B) with the driver's leg, address labels,
/// distance/time pills, the live streak commission tag, and a single
/// Accept CTA for the trip fare.
///
/// There is no counter-fare flow: the backend settles the verified trip fare only.
class IncomingOfferSheet extends StatefulWidget {
  final ActiveTrip trip;

  /// e.g. "Streak Rate: 12.5% Fee" or "Level 2 Perk: 0% Fee + ₦450 Refund".
  final String streakTag;
  final String currencySymbol;

  /// Driver's last known position (origin of the preview leg).
  final LatLng driverPosition;

  final DriverStreakService streakService;
  final String? driverId;
  final AppUser? user;

  const IncomingOfferSheet({
    super.key,
    required this.trip,
    required this.streakTag,
    required this.currencySymbol,
    required this.driverPosition,
    required this.streakService,
    this.driverId,
    this.user,
  });

  @override
  State<IncomingOfferSheet> createState() => _IncomingOfferSheetState();
}

class _IncomingOfferSheetState extends State<IncomingOfferSheet>
    with SingleTickerProviderStateMixin {
  final SeSeMapController _mapController = SeSeMapController();
  List<LatLng> _routePoints = [];
  List<LatLng> _driverLegPoints = [];
  bool _busy = false;
  bool _accepting = false;

  /// Guards local expiry so the countdown callback can't race a manual
  /// Accept/Skip (which sets [_busy] and manages the route itself).
  bool _expiryHandled = false;

  LatLng get _pickup => LatLng(widget.trip.pickupLat, widget.trip.pickupLng);
  LatLng get _dropoff =>
      LatLng(widget.trip.dropoffLat, widget.trip.dropoffLng);

  /// Dynamic offer countdown window from Hub configuration (defaults to 20 seconds).
  Duration get _offerWindow => Duration(
        seconds: RemoteConfigService.stage1OfferCountdownSeconds > 0
            ? RemoteConfigService.stage1OfferCountdownSeconds
            : 20,
      );
  late final AnimationController _countdown;

  @override
  void initState() {
    super.initState();
    final window = _offerWindow;
    // Fallback alert if sheet is opened outside _PingListener.
    // Loops for the full configured offer countdown window (e.g., 20 seconds).
    // ignore: discarded_futures
    AppSoundService.instance.playIncomingOrderAlert(minDuration: window);
    _countdown = AnimationController(vsync: this, duration: window)
      ..addStatusListener(_handleCountdownStatus)
      ..forward();
    _loadRoutes();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _mapController.fitPoints(_pickup, _dropoff, padding: 72);
    });
  }

  /// Countdown hit zero → tear the sheet down immediately, no server round-trip.
  void _handleCountdownStatus(AnimationStatus status) {
    if (status == AnimationStatus.completed) {
      // Fire-and-forget: the route pop happens synchronously inside.
      // ignore: discarded_futures
      _expireLocally();
    }
  }

  /// Local, zero-server dismissal path for an expired offer.
  ///
  /// Order of operations is deliberate: (1) stop the alert loop, (2) pop the
  /// route so the driver instantly sees the idle/searching surface again,
  /// (3) tell the backend to record the skip so dispatch re-pings the next
  /// Stage-1 driver (or escalates to the Tier-3 marketplace pool). The UI
  /// never waits on the network — expiry is a local decision.
  Future<void> _expireLocally() async {
    if (_expiryHandled || !mounted) return;
    // A manual Accept/Skip in flight owns the route — don't race it.
    if (_busy) return;
    _expiryHandled = true;

    // 1. Stop the urgent alert and countdown timer immediately.
    // ignore: discarded_futures
    AppSoundService.instance.stopIncomingOrderAlert();
    _countdown.stop();

    // 2. Instantly clear the offer card from the driver's screen.
    if (mounted) {
      Navigator.of(context).pop();
      // The embedded StreamBuilder is unmounted with the route, so
      // `tripStream` unsubscribes automatically; `dispose()` tears down
      // the AnimationController and stops the chime loop.
    }

    // 3. Record the skip server-side; dispatch re-matches (Tier 1) or opens
    //    the order pool. Failures here must not resurrect the UI.
    try {
      await widget.streakService.declineTrip(
        widget.trip.tripId,
        action: 'skipped',
      );
    } catch (e) {
      debugPrint('IncomingOfferSheet expiry declineTrip error: $e');
    }
  }

  @override
  void dispose() {
    // Ensure loop stops if sheet is dismissed via back gesture / timeout.
    // ignore: discarded_futures
    AppSoundService.instance.stopIncomingOrderAlert();
    _countdown.dispose();
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
    _mapController.fitPoints(_pickup, _dropoff, padding: 72);
  }

  String _fareLabel(ActiveTrip trip) {
    if (trip.fareFormatted.isNotEmpty) return trip.fareFormatted;
    return '${widget.currencySymbol}${_withSeparators(trip.fareAmount)}';
  }

  String _perKmLabel(ActiveTrip trip) {
    final dist = trip.distanceKm;
    if (dist <= 0) return '';
    final perKm = trip.fareAmount / dist;
    return '${widget.currencySymbol}${_withSeparators(perKm)}/km ~${dist.toStringAsFixed(1)} km';
  }

  String _timeDistanceLabel(ActiveTrip trip) {
    final mins = trip.durationMins;
    final km = trip.distanceKm;
    if (mins <= 0 && km <= 0) return '';
    return '${mins.toStringAsFixed(0)} min · ${km.toStringAsFixed(1)} km';
  }

  static String _withSeparators(double amount) {
    final rounded = amount.round();
    final digits = rounded.toString().split('').reversed.toList();
    final out = <String>[];
    for (var i = 0; i < digits.length; i++) {
      if (i > 0 && i % 3 == 0) out.add(',');
      out.add(digits[i]);
    }
    return out.reversed.join();
  }

  Future<void> _accept() async {
    if (_busy) return;
    _expiryHandled = true;
    setState(() {
      _busy = true;
      _accepting = true;
    });
    // Stop urgent loop immediately (honors min 6s internally).
    // ignore: discarded_futures
    AppSoundService.instance.stopIncomingOrderAlert();
    _countdown.stop();
    try {
      await widget.streakService.acceptTrip(widget.trip.tripId);
      if (mounted) Navigator.of(context).pop();
    } on DriverStreakException catch (e) {
      if (!mounted) return;
      if (e.userMessage.toLowerCase().contains('balance is low') ||
          e.userMessage.toLowerCase().contains('top up')) {
        await showLowBalanceAcceptancePrompt(
          context,
          driverId: widget.driverId ?? widget.user?.uid ?? '',
          user: widget.user,
        );
      } else {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(e.userMessage)));
      }
    } catch (e) {
      debugPrint('IncomingOfferSheet._accept error: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Unable to accept trip. Please try again.'),
          ),
        );
      }
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
          _accepting = false;
        });
      }
    }
  }

  Future<void> _skip() async {
    if (_busy) return;
    _expiryHandled = true;
    setState(() => _busy = true);

    // 1. Stop urgent alert and countdown timer immediately.
    // ignore: discarded_futures
    AppSoundService.instance.stopIncomingOrderAlert();
    _countdown.stop();

    // 2. Instantly pop the offer sheet so the UI transitions back to idle/waiting without lagging.
    if (mounted) {
      Navigator.of(context).pop();
    }

    // 3. Record the skip server-side fire-and-forget; dispatch re-matches or opens pool.
    try {
      await widget.streakService.declineTrip(
        widget.trip.tripId,
        action: 'skipped',
      );
    } catch (e) {
      debugPrint('IncomingOfferSheet._skip error: $e');
    }
  }

  /// Trip poll stream, degrading to an empty stream when Firebase is
  /// unavailable (widget tests / offline host without an app).
  Stream<ActiveTrip?> _tripStream() {
    try {
      return FirestoreTripRepository().tripStream(widget.trip.tripId);
    } catch (e) {
      debugPrint('IncomingOfferSheet tripStream unavailable: $e');
      return const Stream<ActiveTrip?>.empty();
    }
  }

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<ActiveTrip?>(
      stream: _tripStream(),
      builder: (context, snap) {
        final trip = snap.data ?? widget.trip;
        final fareLabel = _fareLabel(trip);
        final perKmLabel = _perKmLabel(trip);
        final timeDistanceLabel = _timeDistanceLabel(trip);

        return Scaffold(
          body: Column(
            children: [
              // Route map (A → B + driver leg) with overlay controls.
              Expanded(
                flex: 5,
                child: Stack(
                  children: [
                    Positioned.fill(
                      child: SeSeMapView(
                        // Offer route preview (pre-accept browsing): Google Maps.
                        mapContext: MapContext.browsing,
                        mapController: _mapController,
                        initialCenter: _pickup,
                        initialZoom: 13.0,
                        showMyLocation: true,
                        markers: [
                          SeSeMapView.pin(
                              point: _pickup, color: Colors.blue, label: 'A'),
                          SeSeMapView.pin(
                              point: _dropoff, color: Colors.green, label: 'B'),
                          SeSeMapView.pin(
                              point: widget.driverPosition, color: Colors.amber),
                        ],
                        polylines: [
                          if (_routePoints.isNotEmpty)
                            SeSeMapView.route(
                              points: _routePoints,
                              color: Colors.green.shade700,
                              width: 5,
                              id: 'offer-route',
                            ),
                          if (_driverLegPoints.isNotEmpty)
                            SeSeMapView.route(
                              points: _driverLegPoints,
                              color: Colors.blue,
                              width: 4,
                              id: 'driver-leg',
                            ),
                        ],
                      ),
                    ),
                    // Top-left: skip this offer.
                    Positioned(
                      top: 12,
                      left: 12,
                      child: SafeArea(
                        bottom: false,
                        child: Material(
                          borderRadius: BorderRadius.circular(24),
                          elevation: 4,
                          child: InkWell(
                            key: const Key('skip_offer_button'),
                            borderRadius: BorderRadius.circular(24),
                            onTap: _busy ? null : _skip,
                            child: const Padding(
                              padding: EdgeInsets.symmetric(
                                  horizontal: 14, vertical: 10),
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Icon(Icons.close, size: 18),
                                  SizedBox(width: 6),
                                  Text('Skip offer',
                                      style:
                                          TextStyle(fontWeight: FontWeight.w600)),
                                ],
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                    // Top-center: trip time/distance pill.
                    if (timeDistanceLabel.isNotEmpty)
                      Positioned(
                        top: 12,
                        left: 0,
                        right: 0,
                        child: SafeArea(
                          bottom: false,
                          child: Center(
                            child: Container(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 12, vertical: 8),
                              decoration: BoxDecoration(
                                color: Colors.green.shade700,
                                borderRadius: BorderRadius.circular(8),
                              ),
                              child: Text(
                                timeDistanceLabel,
                                style: const TextStyle(
                                    color: Colors.white,
                                    fontWeight: FontWeight.bold,
                                    fontSize: 12),
                              ),
                            ),
                          ),
                        ),
                      ),
                    // Right: custom zoom controls (OSM tiles have no SDK buttons).
                    Positioned(
                      right: 12,
                      top: 110,
                      child: Column(
                        children: [
                          _ZoomButton(
                            icon: Icons.add,
                            onTap: () => _mapController.zoomBy(1),
                          ),
                          const SizedBox(height: 8),
                          _ZoomButton(
                            icon: Icons.remove,
                            onTap: () => _mapController.zoomBy(-1),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
              // Offer details + streak tag + Sticky Accept CTA.
              Expanded(
                flex: 4,
                child: Column(
                  children: [
                    Expanded(
                      child: SingleChildScrollView(
                        padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            _OfferCountdown(controller: _countdown),
                            const SizedBox(height: 12),
                            Container(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 10, vertical: 6),
                              decoration: BoxDecoration(
                                color: Theme.of(context).brightness == Brightness.dark
                                    ? const Color(0xFF78350F).withValues(alpha: 0.3)
                                    : AppColors.seseGoldLight,
                                borderRadius: BorderRadius.circular(20),
                              ),
                              child: Text(
                                widget.streakTag,
                                textAlign: TextAlign.center,
                                style: TextStyle(
                                    fontWeight: FontWeight.bold,
                                    fontSize: 13,
                                    color: Theme.of(context).brightness == Brightness.dark
                                        ? const Color(0xFFFBBF24)
                                        : Colors.black87),
                              ),
                            ),
                            const SizedBox(height: 12),
                            _AddressRow(
                              dotColor: Colors.blue,
                              badge: 'A',
                              label: 'Pickup',
                              value: trip.pickupAddress.isEmpty
                                  ? 'Pickup location (see map)'
                                  : trip.pickupAddress,
                              displayName: trip.pickupName.isNotEmpty
                                  ? trip.pickupName
                                  : trip.customerName,
                              photoUrl: trip.customerPhotoUrl,
                              isVerified: trip.isVerifiedCustomer,
                            ),
                            const SizedBox(height: 8),
                            _AddressRow(
                              dotColor: Colors.green,
                              badge: 'B',
                              label: 'Drop-off',
                              value: trip.dropoffAddress.isEmpty
                                  ? 'Drop-off location (see map)'
                                  : trip.dropoffAddress,
                              displayName: trip.dropoffName.isNotEmpty
                                  ? trip.dropoffName
                                  : (trip.pickupName.isNotEmpty
                                      ? 'Recipient'
                                      : trip.customerName),
                              photoUrl: trip.dropoffName.isNotEmpty
                                  ? null
                                  : trip.customerPhotoUrl,
                              isVerified: trip.isVerifiedCustomer,
                            ),
                            const SizedBox(height: 10),
                            Row(
                              mainAxisAlignment: MainAxisAlignment.spaceBetween,
                              children: [
                                if (perKmLabel.isNotEmpty)
                                  Expanded(
                                    child: Text(
                                      perKmLabel,
                                      style: const TextStyle(
                                        color: Colors.grey,
                                        fontSize: 12,
                                        fontWeight: FontWeight.w600,
                                      ),
                                    ),
                                  ),
                                Chip(
                                  label: Text(
                                    trip.serviceType == 'send_item'
                                        ? 'Courier'
                                        : 'Ride',
                                    style: const TextStyle(
                                        color: Colors.white,
                                        fontWeight: FontWeight.bold,
                                        fontSize: 12),
                                  ),
                                  backgroundColor: Colors.blue,
                                  side: BorderSide.none,
                                  visualDensity: VisualDensity.compact,
                                ),
                              ],
                            ),
                          ],
                        ),
                      ),
                    ),
                    // Pinned sticky bottom container with system navigation bar clearance
                    SafeArea(
                      top: false,
                      child: Container(
                        padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
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
                          child: FilledButton(
                            key: const Key('accept_offer_button'),
                            style: FilledButton.styleFrom(
                              backgroundColor: AppColors.seseGold,
                              foregroundColor: Colors.black,
                              minimumSize: const Size.fromHeight(54),
                              textStyle: const TextStyle(
                                  fontSize: 17, fontWeight: FontWeight.bold),
                            ),
                            onPressed: _busy ? null : _accept,
                            child: _accepting
                                ? const SizedBox(
                                    width: 22,
                                    height: 22,
                                    child: CircularProgressIndicator(
                                        strokeWidth: 2, color: Colors.black),
                                  )
                                : Text('Accept for $fareLabel'),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

Widget _buildAvatarWithVerification({
  required String displayName,
  String? photoUrl,
  required bool isVerified,
  double radius = 18,
}) {
  final avatar = UserAvatar(
    displayName: displayName,
    photoUrl: photoUrl,
    radius: radius,
  );
  if (!isVerified) return avatar;
  return Stack(
    clipBehavior: Clip.none,
    children: [
      avatar,
      Positioned(
        right: -2,
        bottom: -2,
        child: Container(
          decoration: const BoxDecoration(
            color: Colors.white,
            shape: BoxShape.circle,
          ),
          padding: const EdgeInsets.all(1),
          child: const Icon(
            Icons.verified,
            size: 13,
            color: AppColors.seseGold,
          ),
        ),
      ),
    ],
  );
}

class _AddressRow extends StatelessWidget {
  final Color dotColor;
  final String badge;
  final String label;
  final String value;
  final String? displayName;
  final String? photoUrl;
  final bool isVerified;

  const _AddressRow({
    required this.dotColor,
    required this.badge,
    required this.label,
    required this.value,
    this.displayName,
    this.photoUrl,
    this.isVerified = false,
  });

  @override
  Widget build(BuildContext context) {
    final name = displayName ?? '';
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _buildAvatarWithVerification(
          displayName: name.isNotEmpty ? name : label,
          photoUrl: photoUrl,
          isVerified: isVerified,
          radius: 14,
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                    decoration: BoxDecoration(
                      color: dotColor.withValues(alpha: 0.15),
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: Text(
                      '$badge · $label',
                      style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.bold,
                        color: dotColor,
                      ),
                    ),
                  ),
                  if (name.isNotEmpty) ...[
                    const SizedBox(width: 6),
                    Flexible(
                      child: Text(
                        name,
                        style: const TextStyle(
                          fontSize: 11,
                          color: Colors.grey,
                          fontWeight: FontWeight.w500,
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                ],
              ),
              const SizedBox(height: 2),
              Text(
                value,
                style: const TextStyle(
                    fontSize: 14, fontWeight: FontWeight.w600),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _ZoomButton extends StatelessWidget {
  final IconData icon;
  final VoidCallback onTap;

  const _ZoomButton({required this.icon, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Material(
      shape: const CircleBorder(),
      elevation: 4,
      color: isDark ? const Color(0xFF252530) : Colors.white,
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(10),
          child: Icon(
            icon,
            size: 22,
            color: isDark ? Colors.white : Colors.black87,
          ),
        ),
      ),
    );
  }
}

/// Visible offer countdown bar, synced to the chime loop.
///
/// Drains green → amber → red as the window closes. The parent sheet
/// detonates automatically when the timer reaches zero (see
/// [_IncomingOfferSheetState._expireLocally]); the server-side ping sweep is
/// only a backstop for app crashes / force-closes.
class _OfferCountdown extends StatelessWidget {
  final AnimationController controller;

  const _OfferCountdown({required this.controller});

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: controller,
      builder: (context, _) {
        final totalSecs = controller.duration?.inSeconds ?? 20;
        final remaining = (1.0 - controller.value) * totalSecs;
        final secs = remaining.ceil().clamp(0, totalSecs);
        final frac = (1.0 - controller.value).clamp(0.0, 1.0);
        final color = secs > (totalSecs ~/ 2)
            ? Colors.green.shade700
            : secs > (totalSecs ~/ 4)
                ? Colors.orange.shade800
                : Colors.red.shade700;
        return Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(Icons.timer_outlined, size: 14, color: color),
                const SizedBox(width: 4),
                Text(
                  secs > 0 ? 'Offer expires in ${secs}s' : 'Offer expiring…',
                  key: const Key('offer_countdown_text'),
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: color,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 4),
            ClipRRect(
              borderRadius: BorderRadius.circular(3),
              child: LinearProgressIndicator(
                value: frac,
                minHeight: 5,
                backgroundColor: color.withValues(alpha: 0.2),
                valueColor: AlwaysStoppedAnimation<Color>(color),
              ),
            ),
          ],
        );
      },
    );
  }
}
