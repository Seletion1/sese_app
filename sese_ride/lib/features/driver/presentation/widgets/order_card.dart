import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:latlong2/latlong.dart';
import 'package:sese_core/sese_core.dart';

import '../../../trips/models/trip_models.dart';
import '../../../trips/services/trip_service.dart';
import '../../services/driver_streak_service.dart';
import '../../../../widgets/verified_badge.dart';
import 'low_balance_dialog.dart';
import 'verified_customer_badge.dart';

/// One incoming ride in the driver home feed.
///
/// Shows the customer name + rating badge, fare/per-km, A/B addresses with
/// live distances from the driver's position, the service tier label, and an
/// Accept CTA (first tap wins atomically — see `acceptTrip` transaction).
/// Also offers a "Bid Custom Fare" action for marketplace trips where the
/// driver wants to propose a different fare.
class OrderCard extends StatefulWidget {
  final ActiveTrip trip;
  final LatLng driverPosition;
  final String currencySymbol;
  final DriverStreakService streakService;

  /// Tag from `[DriverStreakState.streakLabel]` for the driver's current
  /// commission tier, shown as a small badge on the card.
  final String streakTag;

  /// Optional injected repository — defaults to [FirestoreTripRepository].
  final TripRepository? tripRepository;

  const OrderCard({
    super.key,
    required this.trip,
    required this.driverPosition,
    required this.currencySymbol,
    required this.streakService,
    required this.streakTag,
    this.tripRepository,
  });

  @override
  State<OrderCard> createState() => _OrderCardState();
}

class _OrderCardState extends State<OrderCard> {
  double? _pickupKm;
  double? _dropoffKm;
  bool _sending = false;
  bool _bidding = false;

  TripRepository get _repo =>
      widget.tripRepository ?? FirestoreTripRepository();

  @override
  void initState() {
    super.initState();
    _computeDistances();
  }

  @override
  void didUpdateWidget(covariant OrderCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.trip.pickupLat != widget.trip.pickupLat ||
        oldWidget.trip.pickupLng != widget.trip.pickupLng ||
        oldWidget.trip.dropoffLat != widget.trip.dropoffLat ||
        oldWidget.trip.dropoffLng != widget.trip.dropoffLng ||
        oldWidget.driverPosition != widget.driverPosition) {
      _computeDistances();
    }
  }

  Future<void> _computeDistances() async {
    final pickup = LatLng(widget.trip.pickupLat, widget.trip.pickupLng);
    final dropoff = LatLng(widget.trip.dropoffLat, widget.trip.dropoffLng);
    const distanceCalc = Distance();
    final pickupKm =
        distanceCalc.as(LengthUnit.Kilometer, widget.driverPosition, pickup);
    final dropoffKm =
        distanceCalc.as(LengthUnit.Kilometer, widget.driverPosition, dropoff);
    if (mounted) {
      setState(() {
        _pickupKm = pickupKm;
        _dropoffKm = dropoffKm;
      });
    }
  }

  String get _perKm {
    if (widget.trip.distanceKm <= 0 || widget.trip.fareAmount <= 0) return '';
    final rate = widget.trip.fareAmount / widget.trip.distanceKm;
    return '${widget.currencySymbol}${_fmt(rate)}/km';
  }

  String get _categoryLabel {
    final tiers = widget.trip.tierIds;
    if (tiers.isEmpty) {
      return widget.trip.serviceType == 'send_item' ? 'Courier' : 'Ride';
    }
    return tiers.first;
  }

  String _fmt(double amount) {
    final rounded = amount.round();
    final digits = rounded.toString().split('').reversed.toList();
    final out = <String>[];
    for (var i = 0; i < digits.length; i++) {
      if (i > 0 && i % 3 == 0) out.add(',');
      out.add(digits[i]);
    }
    return out.reversed.join();
  }

  Widget? _buildPaymentBadge(ActiveTrip trip) {
    final mode = trip.paymentMode.toLowerCase();
    final hasWallet = trip.walletCoverageAmount > 0;
    final hasCash = trip.cashToCollect > 0;
    final isDark = Theme.of(context).brightness == Brightness.dark;

    if (mode == 'receiver_pays') {
      return Container(
        margin: const EdgeInsets.only(top: 6),
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        decoration: BoxDecoration(
          color: isDark
              ? const Color(0xFF1E3A8A).withValues(alpha: 0.3)
              : Colors.blue.shade50,
          borderRadius: BorderRadius.circular(6),
          border: Border.all(
            color: isDark
                ? const Color(0xFF3B82F6).withValues(alpha: 0.4)
                : Colors.blue.shade200,
          ),
        ),
        child: Row(
          children: [
            Icon(
              Icons.call_received_rounded,
              size: 13,
              color: isDark ? const Color(0xFF93C5FD) : Colors.blue.shade800,
            ),
            const SizedBox(width: 4),
            Expanded(
              child: Text(
                'Receiver Pays Cash at Drop-off (Collect ₦${trip.fareAmount.toStringAsFixed(0)})',
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                  color: isDark ? const Color(0xFFBFDBFE) : Colors.blue.shade800,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
      );
    } else if (hasWallet && hasCash) {
      return Container(
        margin: const EdgeInsets.only(top: 6),
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        decoration: BoxDecoration(
          color: isDark
              ? const Color(0xFF78350F).withValues(alpha: 0.3)
              : const Color(0xFFFEF3C7),
          borderRadius: BorderRadius.circular(6),
          border: Border.all(
            color: const Color(0xFFF59E0B).withValues(alpha: 0.4),
          ),
        ),
        child: Row(
          children: [
            Icon(
              Icons.account_balance_wallet_outlined,
              size: 13,
              color: isDark ? const Color(0xFFFBBF24) : const Color(0xFF92400E),
            ),
            const SizedBox(width: 4),
            Expanded(
              child: Text(
                'Collect ₦${trip.cashToCollect.toStringAsFixed(0)} cash | ₦${trip.walletCoverageAmount.toStringAsFixed(0)} wallet',
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                  color: isDark ? const Color(0xFFFDE68A) : const Color(0xFF92400E),
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
      );
    } else if (hasWallet && !hasCash) {
      return Container(
        margin: const EdgeInsets.only(top: 6),
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        decoration: BoxDecoration(
          color: isDark
              ? const Color(0xFF065F46).withValues(alpha: 0.3)
              : Colors.green.shade50,
          borderRadius: BorderRadius.circular(6),
          border: Border.all(
            color: isDark
                ? const Color(0xFF10B981).withValues(alpha: 0.4)
                : Colors.green.shade200,
          ),
        ),
        child: Row(
          children: [
            Icon(
              Icons.check_circle_outline,
              size: 13,
              color: isDark ? const Color(0xFF6EE7B7) : Colors.green.shade800,
            ),
            const SizedBox(width: 4),
            Expanded(
              child: Text(
                '100% Wallet Prepaid • ₦0 cash to collect',
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                  color: isDark ? const Color(0xFFA7F3D0) : Colors.green.shade800,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
      );
    }
    return null;
  }

  String _distanceLabel(double? km, String fallback) {
    if (km == null) return fallback;
    return '~${km.toStringAsFixed(1)} km';
  }

  Future<void> _accept() async {
    if (_sending) return;
    setState(() => _sending = true);
    try {
      await widget.streakService.acceptTrip(widget.trip.tripId);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Trip accepted — see active trip above.')),
      );
    } on DriverStreakException catch (e) {
      if (!mounted) return;
      if (e.userMessage.toLowerCase().contains('balance is low') ||
          e.userMessage.toLowerCase().contains('top up')) {
        await showLowBalanceAcceptancePrompt(
          context,
          driverId: widget.streakService.driverId ?? '',
        );
      } else {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(e.userMessage)));
      }
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  /// Opens a dialog for the driver to submit a custom fare bid.
  Future<void> _showBidDialog() async {
    final baseline = widget.trip.fareAmount;
    final controller = TextEditingController(
      text: baseline.toStringAsFixed(0),
    );
    String? error;

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSt) => AlertDialog(
          title: const Text('Bid Custom Fare'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                'Listed fare: ${widget.trip.fareFormatted.isNotEmpty ? widget.trip.fareFormatted : '${widget.currencySymbol}${_fmt(baseline)}'}.\n'
                'Your bid must be ≥ the listed fare.',
                style: const TextStyle(fontSize: 12),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: controller,
                autofocus: true,
                keyboardType:
                    const TextInputType.numberWithOptions(decimal: false),
                inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                decoration: InputDecoration(
                  labelText: 'Your bid',
                  prefixText: '${widget.currencySymbol} ',
                  errorText: error,
                ),
                onChanged: (v) {
                  final val = double.tryParse(v);
                  setSt(() {
                    error = (val == null || val < baseline)
                        ? 'Must be ≥ ${widget.trip.fareFormatted.isNotEmpty ? widget.trip.fareFormatted : widget.currencySymbol + _fmt(baseline)}'
                        : null;
                  });
                },
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, null),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: error != null ? null : () => Navigator.pop(ctx, true),
              child: const Text('Submit Bid'),
            ),
          ],
        ),
      ),
    );

    if (confirmed != true) return;
    final val = double.tryParse(controller.text);
    if (val == null || val < baseline) return;

    setState(() => _bidding = true);
    try {
      await _repo.submitBid(widget.trip.tripId, val);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Bid submitted — waiting for customer.')),
      );
    } on TripException catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(e.userMessage)));
    } finally {
      if (mounted) setState(() => _bidding = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final trip = widget.trip;
    final name = trip.driver?.fullName.isNotEmpty == true
        ? trip.driver!.fullName
        : 'Customer';
    // Until the driver claims the trip, `trip.driver` is null — show a
    // generic customer placeholder (no PII is exposed before claim).
    final rating = trip.driver?.rating ?? 0;
    final fareLabel = trip.fareFormatted.isNotEmpty
        ? trip.fareFormatted
        : '${widget.currencySymbol}${_fmt(trip.fareAmount)}';
    return Card(
      key: Key('order_card_${trip.tripId}'),
      margin: const EdgeInsets.only(bottom: 12),
      elevation: 2,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const UserAvatar(displayName: 'C', radius: 18),
                    if (trip.isVerifiedCustomer) ...[
                      const SizedBox(height: 2),
                      const VerifiedBadge(
                          variant: VerifiedBadgeVariant.customer),
                    ],
                  ],
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Flexible(
                            child: Text(
                              name,
                              style: const TextStyle(
                                  fontWeight: FontWeight.bold, fontSize: 14),
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
                      if (rating > 0)
                        Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const Icon(Icons.star, size: 12, color: Colors.amber),
                            const SizedBox(width: 2),
                            Text(rating.toStringAsFixed(1),
                                style: const TextStyle(
                                    fontSize: 11, color: Colors.grey)),
                          ],
                        ),
                    ],
                  ),
                ),
                if (widget.streakTag.isNotEmpty)
                  Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                    decoration: BoxDecoration(
                      color: scheme.primary.withValues(alpha: 0.15),
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: Text(
                      widget.streakTag,
                      style: TextStyle(
                          fontSize: 10,
                          fontWeight: FontWeight.bold,
                          color: scheme.primary),
                    ),
                  ),
              ],
            ),
            if (trip.isVerifiedCustomer) ...[
              const SizedBox(height: 6),
              const VerifiedCustomerBadge(),
            ],
            const SizedBox(height: 8),
            // Fare + badges wrap instead of overflowing on narrow phones:
            // the fare keeps word-safe bounds while badges flow right.
            Row(
              children: [
                Flexible(
                  child: Text(
                    fareLabel,
                    style: const TextStyle(
                        fontWeight: FontWeight.bold, fontSize: 18),
                    softWrap: false,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                if (_perKm.isNotEmpty) ...[
                  const SizedBox(width: 8),
                  Flexible(
                    child: Text(
                      _perKm,
                      style: const TextStyle(color: Colors.grey, fontSize: 12),
                      softWrap: false,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
                const Spacer(),
                if (trip.fareBoosted) ...[
                  Flexible(
                    child: Container(
                      key: const Key('higher_fare_badge'),
                      padding:
                          const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                      decoration: BoxDecoration(
                        color: Colors.green.shade700,
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: Text(
                        trip.boostPercent > 0
                            ? 'HIGHER FARE +${trip.boostPercent}%'
                            : 'HIGHER FARE',
                        style: const TextStyle(
                            color: Colors.white,
                            fontSize: 11,
                            fontWeight: FontWeight.bold),
                        softWrap: false,
                        overflow: TextOverflow.ellipsis,
                        maxLines: 1,
                      ),
                    ),
                  ),
                  const SizedBox(width: 6),
                ],
                Flexible(
                  child: Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                    decoration: BoxDecoration(
                      color: Colors.blue.shade600,
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: Text(
                      _categoryLabel,
                      style: const TextStyle(
                          color: Colors.white,
                          fontSize: 11,
                          fontWeight: FontWeight.bold),
                      softWrap: false,
                      overflow: TextOverflow.ellipsis,
                      maxLines: 1,
                    ),
                  ),
                ),
              ],
            ),
            if (_buildPaymentBadge(trip) != null) ...[
              _buildPaymentBadge(trip)!,
            ],
            const SizedBox(height: 8),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  width: 18,
                  height: 18,
                  decoration: const BoxDecoration(
                      color: Colors.blue, shape: BoxShape.circle),
                  alignment: Alignment.center,
                  child: const Text('A',
                      style: TextStyle(
                          color: Colors.white,
                          fontSize: 11,
                          fontWeight: FontWeight.bold)),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('Pickup',
                          style: TextStyle(
                              fontSize: 10, color: scheme.onSurfaceVariant)),
                      Text(
                        trip.pickupAddress.isEmpty
                            ? 'Pickup location (see map)'
                            : trip.pickupAddress,
                        style:
                            TextStyle(fontSize: 12, color: scheme.onSurface),
                      ),
                    ],
                  ),
                ),
                Text(
                    _distanceLabel(
                        _pickupKm, '~${trip.distanceKm.toStringAsFixed(1)} km'),
                    style: TextStyle(
                        fontSize: 11, color: scheme.onSurfaceVariant)),
              ],
            ),
            const SizedBox(height: 6),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  width: 18,
                  height: 18,
                  decoration: const BoxDecoration(
                      color: Colors.green, shape: BoxShape.circle),
                  alignment: Alignment.center,
                  child: const Text('B',
                      style: TextStyle(
                          color: Colors.white,
                          fontSize: 11,
                          fontWeight: FontWeight.bold)),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('Drop-off',
                          style: TextStyle(
                              fontSize: 10, color: scheme.onSurfaceVariant)),
                      Text(
                        trip.dropoffAddress.isEmpty
                            ? 'Drop-off location (see map)'
                            : trip.dropoffAddress,
                        style:
                            TextStyle(fontSize: 12, color: scheme.onSurface),
                      ),
                    ],
                  ),
                ),
                Text(_distanceLabel(_dropoffKm, ''),
                    style: TextStyle(
                        fontSize: 11, color: scheme.onSurfaceVariant)),
              ],
            ),
            const SizedBox(height: 10),
            // ── CTAs: Accept + Bid Custom Fare ────────────────────────────
            Row(
              children: [
                Expanded(
                  flex: 3,
                  child: FilledButton.icon(
                    icon: _sending
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(
                                strokeWidth: 2, color: Colors.white))
                        : const Icon(Icons.check),
                    label: Text(_sending ? 'Claiming…' : 'Accept'),
                    style: FilledButton.styleFrom(
                      backgroundColor: Colors.green.shade700,
                      minimumSize: const Size.fromHeight(44),
                    ),
                    onPressed: (_sending || _bidding) ? null : _accept,
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  flex: 2,
                  child: OutlinedButton.icon(
                    icon: _bidding
                        ? const SizedBox(
                            width: 14,
                            height: 14,
                            child: CircularProgressIndicator(strokeWidth: 2))
                        : const Icon(Icons.edit_note, size: 18),
                    label: Text(
                      _bidding ? 'Bidding…' : 'Bid Fare',
                      style: const TextStyle(fontSize: 12),
                    ),
                    style: OutlinedButton.styleFrom(
                      minimumSize: const Size.fromHeight(44),
                      side: BorderSide.none,
                      backgroundColor:
                          Theme.of(context).colorScheme.surfaceContainerHighest,
                    ),
                    onPressed: (_sending || _bidding) ? null : _showBidDialog,
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
