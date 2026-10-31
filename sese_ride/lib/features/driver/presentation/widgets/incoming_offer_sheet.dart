import 'dart:async';

import 'package:flutter/material.dart';
import 'package:latlong2/latlong.dart';
import 'package:sese_core/sese_core.dart';

import '../../../../core/services/remote_config_service.dart';
import '../../../../widgets/map_provider.dart';
import '../../../customer/services/location_service.dart';
import '../../../trips/models/trip_models.dart';
import '../../services/driver_streak_service.dart';
import '../../../../widgets/verified_badge.dart';
import 'low_balance_dialog.dart';
import 'verified_customer_badge.dart';

/// Full-screen incoming offer, Bolt-style: route preview from
/// pickup (A) to drop-off (B) with the driver's leg, address labels,
/// distance/time pills, the live streak commission tag, and a single
/// Accept CTA for the trip fare.
///
/// Skipping (or backing out and letting the ping expire) breaks the daily
/// streak — the sheet says so explicitly. There is no counter-fare flow:
/// the backend settles the verified trip fare only.
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
      ..forward();
    _loadRoutes();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _mapController.fitPoints(_pickup, _dropoff, padding: 72);
    });
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

  String get _fareLabel {
    if (widget.trip.fareFormatted.isNotEmpty) return widget.trip.fareFormatted;
    return '${widget.currencySymbol}${_withSeparators(widget.trip.fareAmount)}';
  }

  String get _perKmLabel {
    final dist = widget.trip.distanceKm;
    if (dist <= 0) return '';
    final perKm = widget.trip.fareAmount / dist;
    return '${widget.currencySymbol}${_withSeparators(perKm)}/km ~${dist.toStringAsFixed(1)} km';
  }

  String get _timeDistanceLabel {
    final mins = widget.trip.durationMins;
    final km = widget.trip.distanceKm;
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
    setState(() {
      _busy = true;
      _accepting = true;
    });
    // Stop urgent loop immediately (honors min 6s internally).
    // ignore: discarded_futures
    AppSoundService.instance.stopIncomingOrderAlert();
    try {
      await widget.streakService.acceptTrip(widget.trip.tripId);
      if (mounted) Navigator.of(context).pop();
    } on DriverStreakException catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _accepting = false;
      });
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
    }
  }

  Future<void> _skip() async {
    if (_busy) return;
    setState(() => _busy = true);
    // Stop urgent loop immediately.
    // ignore: discarded_futures
    AppSoundService.instance.stopIncomingOrderAlert();
    try {
      await widget.streakService.declineTrip(widget.trip.tripId);
      if (mounted) Navigator.of(context).pop();
    } on DriverStreakException catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(e.userMessage)));
      setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final trip = widget.trip;
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
                if (_timeDistanceLabel.isNotEmpty)
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
                            _timeDistanceLabel,
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
                        ),
                        if (trip.isVerifiedCustomer) ...[
                          const SizedBox(height: 8),
                          const Align(
                            alignment: Alignment.centerLeft,
                            child: VerifiedCustomerBadge(),
                          ),
                        ],
                        const SizedBox(height: 8),
                        _AddressRow(
                          dotColor: Colors.green,
                          badge: 'B',
                          label: 'Drop-off',
                          value: trip.dropoffAddress.isEmpty
                              ? 'Drop-off location (see map)'
                              : trip.dropoffAddress,
                        ),
                        const SizedBox(height: 8),
                        Row(
                          children: [
                            Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                UserAvatar(
                                  // Use the real customer first name so the
                                  // avatar initials match the actual person
                                  // rather than the generic 'RI' placeholder.
                                  displayName: trip.customerName.isNotEmpty
                                      ? trip.customerName.trim().split(RegExp(r'\s+')).first
                                      : 'Customer',
                                  radius: 20,
                                ),
                                if (trip.isVerifiedCustomer) ...[
                                  const SizedBox(height: 2),
                                  const VerifiedBadge(
                                      variant: VerifiedBadgeVariant.customer),
                                ],
                              ],
                            ),
                            const SizedBox(width: 10),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    _fareLabel,
                                    style: const TextStyle(
                                        fontWeight: FontWeight.bold,
                                        fontSize: 18),
                                  ),
                                  if (_perKmLabel.isNotEmpty)
                                    Text(
                                      _perKmLabel,
                                      style: const TextStyle(
                                          color: Colors.grey, fontSize: 12),
                                    ),
                                ],
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
                        const SizedBox(height: 8),
                        _buildPaymentBreakdownBanner(trip),
                        const SizedBox(height: 8),
                        const Text(
                          'Skipping, or letting this expire, breaks your daily streak.',
                          textAlign: TextAlign.center,
                          style:
                              TextStyle(fontSize: 12, color: Colors.redAccent),
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
                            : Text('Accept for $_fareLabel'),
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
  }
  Widget _buildPaymentBreakdownBanner(ActiveTrip trip) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final wallet = trip.walletCoverageAmount;
    final cash = trip.cashToCollect;
    final fare = trip.fareAmount;

    if (wallet > 0 && cash > 0) {
      return Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: isDark
              ? const Color(0xFF78350F).withValues(alpha: 0.25)
              : const Color(0xFFFEF3C7),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(
            color: isDark
                ? const Color(0xFFF59E0B).withValues(alpha: 0.4)
                : const Color(0xFFFDE68A),
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  Icons.payments_outlined,
                  size: 16,
                  color: isDark ? const Color(0xFFFBBF24) : const Color(0xFFD97706),
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    'Collect ₦${cash.toStringAsFixed(0)} cash | ₦${wallet.toStringAsFixed(0)} credited to wallet upon completion',
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.bold,
                      color: isDark ? const Color(0xFFFDE68A) : const Color(0xFF92400E),
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 2),
            Text(
              trip.collectAt == 'dropoff'
                  ? 'Collect cash from Receiver at drop-off.'
                  : (trip.collectAt == 'both'
                      ? 'Collect partial cash at pickup & drop-off.'
                      : 'Collect cash from Sender at pickup. Do not collect at drop-off.'),
              style: TextStyle(
                fontSize: 11,
                color: isDark ? const Color(0xFFFCD34D) : const Color(0xFFB45309),
              ),
            ),
          ],
        ),
      );
    } else if (wallet > 0 && cash == 0) {
      return Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: isDark
              ? const Color(0xFF064E3B).withValues(alpha: 0.3)
              : const Color(0xFFD1FAE5),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(
            color: isDark
                ? const Color(0xFF10B981).withValues(alpha: 0.4)
                : const Color(0xFFA7F3D0),
          ),
        ),
        child: Row(
          children: [
            Icon(
              Icons.account_balance_wallet,
              size: 16,
              color: isDark ? const Color(0xFF34D399) : const Color(0xFF059669),
            ),
            const SizedBox(width: 6),
            Expanded(
              child: Text(
                '100% Wallet Prepaid (₦${fare.toStringAsFixed(0)}) • Collect ₦0 cash',
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.bold,
                  color: isDark ? const Color(0xFFA7F3D0) : const Color(0xFF065F46),
                ),
              ),
            ),
          ],
        ),
      );
    } else if (trip.paymentMode == 'receiver_pays') {
      return Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: isDark
              ? const Color(0xFF1E3A8A).withValues(alpha: 0.3)
              : const Color(0xFFEFF6FF),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(
            color: isDark
                ? const Color(0xFF3B82F6).withValues(alpha: 0.4)
                : const Color(0xFFBFDBFE),
          ),
        ),
        child: Row(
          children: [
            Icon(
              Icons.money_rounded,
              size: 16,
              color: isDark ? const Color(0xFF60A5FA) : const Color(0xFF2563EB),
            ),
            const SizedBox(width: 6),
            Expanded(
              child: Text(
                'Collect ₦${(cash > 0 ? cash : fare).toStringAsFixed(0)} CASH from Receiver at drop-off',
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.bold,
                  color: isDark ? const Color(0xFFBFDBFE) : const Color(0xFF1E40AF),
                ),
              ),
            ),
          ],
        ),
      );
    } else {
      return Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: isDark ? const Color(0xFF252530) : const Color(0xFFF3F4F6),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(
            color: isDark ? const Color(0xFF3A3A46) : const Color(0xFFE5E7EB),
          ),
        ),
        child: Row(
          children: [
            Icon(
              Icons.payments_outlined,
              size: 16,
              color: isDark ? Colors.grey.shade400 : const Color(0xFF4B5563),
            ),
            const SizedBox(width: 6),
            Expanded(
              child: Text(
                'Collect ₦${(cash > 0 ? cash : fare).toStringAsFixed(0)} CASH from Sender at pickup',
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.bold,
                  color: isDark ? Colors.white : const Color(0xFF1F2937),
                ),
              ),
            ),
          ],
        ),
      );
    }
  }
}

class _AddressRow extends StatelessWidget {
  final Color dotColor;
  final String badge;
  final String label;
  final String value;

  const _AddressRow({
    required this.dotColor,
    required this.badge,
    required this.label,
    required this.value,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          width: 26,
          height: 26,
          decoration: BoxDecoration(color: dotColor, shape: BoxShape.circle),
          alignment: Alignment.center,
          child: Text(
            badge,
            style: const TextStyle(
                color: Colors.white,
                fontWeight: FontWeight.bold,
                fontSize: 13),
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(label,
                  style:
                      const TextStyle(fontSize: 11, color: Colors.grey)),
              Text(value,
                  style: const TextStyle(
                      fontSize: 14, fontWeight: FontWeight.w600)),
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

/// Visible 6s offer countdown bar, synced to the chime loop.
///
/// Drains green → amber → red as the window closes. Purely informational:
/// the server sweep enforces the real expiry, so a late tap still resolves
/// through accept/reject instead of the sheet vanishing.
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
