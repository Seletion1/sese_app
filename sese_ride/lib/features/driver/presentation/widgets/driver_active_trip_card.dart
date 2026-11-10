import 'dart:async';

import 'package:flutter/material.dart';
import 'package:latlong2/latlong.dart';
import 'package:sese_core/sese_core.dart';

import '../../../../core/services/call_service.dart';
import '../../../customer/services/location_service.dart';
import '../../../trips/models/trip_models.dart';
import '../../../trips/presentation/mutual_profile_modal.dart';
import '../../../trips/presentation/trip_chat_screen.dart';
import '../../../trips/presentation/trip_rating_dialog.dart';
import '../../../trips/services/trip_rating_service.dart';
import '../../services/driver_streak_service.dart';
import '../../services/proximity_trigger_service.dart';

/// Compact driver-side action card for the assigned live trip.
///
/// Buttons follow the server chain (DRIVER_ACCEPTED → DRIVER_ARRIVING →
/// DRIVER_ARRIVED → IN_PROGRESS → COMPLETED). Cancelling before arrival
/// breaks the streak; cancelling after the no-show wait threshold is
/// streak-protected (server-enforced).
///
/// Live proximity triggers ([ProximityTriggerService], OSRM-refined GPS):
/// - Auto-arrival (100m–500m): entering the arrival radius starts a 5s
///   countdown banner ("Auto-arriving at pickup...") that advances to
///   DRIVER_ARRIVED automatically (server fans out the customer FCM alert).
/// - Departure protection (500m–1km): leaving the pickup area after
///   arrival auto-starts pre-paid trips (IN_PROGRESS), but blocks
///   cash/split trips with a siren + payment-confirmation dialog.
/// - Mock Location Guard: spoofed fixes are flagged in-UI and withheld
///   from telemetry (the server callable rejects them independently).
class DriverActiveTripCard extends StatefulWidget {
  final ActiveTrip trip;
  final DriverStreakService streakService;
  final int waitThresholdMinutes;

  /// Signed-in driver id (chat sender identity). Defaults to the assigned
  /// driver on the trip when empty.
  final String driverId;

  /// Last known driver GPS fix (seeds in-app navigation instantly; the
  /// cockpit refines from the live stream when this is absent).
  final LatLng? driverPosition;

  /// Road-accurate navigation polyline points for calculating real-time remaining distance and ETA.
  final List<LatLng> routePoints;

  /// Real-time vehicle speed in km/h derived from device GPS updates.
  final double currentSpeedKmh;

  /// Test seam: inject a fake proximity service (skips device GPS).
  final ProximityTriggerService Function({
    required void Function() onArrive,
    required void Function() onAutoStart,
    required void Function() onPaymentBlock,
  })? proximityFactory;

  /// Whether proximity auto-arrival is enabled from Hub settings.
  final bool autoArrivalEnabled;

  /// Duration in seconds for the auto-arrival countdown (default 5s).
  final int autoArrivalCountdownSeconds;

  /// Optional sheet controller if driven by DraggableScrollableSheet.
  final DraggableScrollableController? sheetController;

  /// Optional scroll controller from a parent DraggableScrollableSheet builder.
  final ScrollController? scrollController;

  /// Optional callback when driver taps the drag handle to toggle collapse/expand.
  final VoidCallback? onToggleCollapse;

  const DriverActiveTripCard({
    super.key,
    required this.trip,
    required this.streakService,
    this.waitThresholdMinutes = 10,
    this.driverId = '',
    this.driverPosition,
    this.routePoints = const [],
    this.currentSpeedKmh = 0.0,
    this.proximityFactory,
    this.autoArrivalEnabled = true,
    this.autoArrivalCountdownSeconds = 5,
    this.sheetController,
    this.scrollController,
    this.onToggleCollapse,
  });

  @override
  State<DriverActiveTripCard> createState() => _DriverActiveTripCardState();
}

class _DriverActiveTripCardState extends State<DriverActiveTripCard> {
  bool _busy = false;
  bool _autoBusy = false;
  bool _paymentDialogOpen = false;
  bool _autoArrivalDismissed = false;
  int _countdownSecondsRemaining = 5;
  Timer? _countdownTicker;
  Timer? _arrivalWaitingTicker;
  DateTime? _localDropoffArrivedAt;
  ProximityTriggerService? _proximity;
  StreamSubscription<ProximityUpdate>? _proximitySub;
  ProximityUpdate? _prox;
  late final DraggableScrollableController _internalSheetController;

  @override
  void initState() {
    super.initState();
    _internalSheetController = DraggableScrollableController();
    _countdownSecondsRemaining = widget.autoArrivalCountdownSeconds;
    _proximity = (widget.proximityFactory ??
            ({
              required void Function() onArrive,
              required void Function() onAutoStart,
              required void Function() onPaymentBlock,
            }) =>
                ProximityTriggerService(
                  autoArrivalEnabled: widget.autoArrivalEnabled,
                  arrivalCountdown: Duration(
                      seconds: widget.autoArrivalCountdownSeconds),
                  onArrive: onArrive,
                  onArriveDropoff: _handleAutoArriveDropoff,
                  onAutoStart: onAutoStart,
                  onPaymentBlock: onPaymentBlock,
                ))(
      onArrive: _handleAutoArrive,
      onAutoStart: _handleAutoStart,
      onPaymentBlock: _handlePaymentBlock,
    );
    _proximitySub = _proximity!.updates.listen((u) {
      if (mounted) {
        setState(() {
          _prox = u;
          _updateCountdownTicker(u);
          if (widget.trip.status == TripStatus.inProgress &&
              (u.distanceM <= 100 || u.zone == ProximityZone.arrivalCountdown) &&
              _localDropoffArrivedAt == null &&
              widget.trip.dropoffArrivedAt == null) {
            _localDropoffArrivedAt = DateTime.now();
            unawaited(widget.streakService.recordDropoffArrival(widget.trip.tripId));
          }
        });
      }
    });
    _proximity!.start(trip: widget.trip, streakService: widget.streakService);
    _startArrivalWaitingTicker();
  }

  void _startArrivalWaitingTicker() {
    _arrivalWaitingTicker?.cancel();
    final inTest = WidgetsBinding.instance.runtimeType
        .toString()
        .contains('TestWidgetsFlutterBinding');
    if (inTest) return;
    _arrivalWaitingTicker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  void _updateCountdownTicker(ProximityUpdate u) {
    if (u.zone == ProximityZone.arrivalCountdown &&
        widget.autoArrivalEnabled &&
        !_autoArrivalDismissed) {
      if (_countdownTicker == null) {
        _countdownSecondsRemaining = widget.autoArrivalCountdownSeconds;
        _countdownTicker = Timer.periodic(const Duration(seconds: 1), (timer) {
          if (!mounted) {
            timer.cancel();
            return;
          }
          if (_countdownSecondsRemaining > 1) {
            setState(() => _countdownSecondsRemaining--);
          } else {
            timer.cancel();
            _countdownTicker = null;
          }
        });
      }
    } else {
      _countdownTicker?.cancel();
      _countdownTicker = null;
      if (u.zone != ProximityZone.arrivalCountdown) {
        _autoArrivalDismissed = false;
      }
    }
  }

  void _cancelAutoArrival() {
    _countdownTicker?.cancel();
    _countdownTicker = null;
    _proximity?.cancelCountdown();
    setState(() => _autoArrivalDismissed = true);
  }

  @override
  void didUpdateWidget(DriverActiveTripCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    _proximity?.noteTrip(widget.trip);
    if (widget.trip.dropoffArrivedAt != null && _localDropoffArrivedAt == null) {
      _localDropoffArrivedAt = widget.trip.dropoffArrivedAt;
    }
  }

  @override
  void dispose() {
    _countdownTicker?.cancel();
    _countdownTicker = null;
    _arrivalWaitingTicker?.cancel();
    _arrivalWaitingTicker = null;
    _proximitySub?.cancel();
    _proximitySub = null;
    _proximity?.dispose();
    _proximity = null;
    _internalSheetController.dispose();
    super.dispose();
  }

  /// Active arrival timestamp for pickup or drop-off waiting.
  DateTime? get _currentArrivalTimestamp {
    final trip = widget.trip;
    if (trip.status == TripStatus.driverArrived) {
      return trip.arrivedAt ?? DateTime.now();
    }
    if (trip.status == TripStatus.inProgress) {
      return trip.dropoffArrivedAt ?? _localDropoffArrivedAt;
    }
    return null;
  }

  /// True when the driver has waited at least [widget.waitThresholdMinutes] after arriving.
  bool get _hasWaitTimeExpired {
    final arrivedAt = _currentArrivalTimestamp;
    if (arrivedAt == null) return false;
    final waited = DateTime.now().difference(arrivedAt);
    return waited >= Duration(minutes: widget.waitThresholdMinutes);
  }

  /// Confirmation dialog before cancelling a trip due to customer no-show.
  /// Cancelling after the wait threshold protects the driver's streak and rating.
  Future<void> _confirmNoShowCancel(ActiveTrip trip) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Cancel Trip (Customer No-Show)'),
        content: Text(
          'You have waited over ${widget.waitThresholdMinutes} minutes after arriving. '
          'Cancelling now is streak-protected and will not penalize your streak or driver rating. '
          'Note: Driver no-show cancellations forfeit waiting fee payouts, but allow you to exit immediately.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Keep Waiting'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Colors.red),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Cancel as No-Show'),
          ),
        ],
      ),
    );
    if (confirmed == true && mounted) {
      await _run(
        () => widget.streakService.cancelTrip(trip.tripId, reason: 'customer_no_show'),
        'Could not cancel trip.',
      );
    }
  }

  Future<bool> _run(Future<void> Function() action, String failFallback) async {
    if (_busy) return false;
    setState(() => _busy = true);
    try {
      await action();
      return true;
    } on DriverStreakException catch (e) {
      if (!mounted) return false;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(e.userMessage)));
      return false;
    } catch (_) {
      if (!mounted) return false;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(failFallback)));
      return false;
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _promptPostTripRating(ActiveTrip trip) {
    if (!mounted) return;
    final customerId =
        trip.customerId.isNotEmpty ? trip.customerId : 'customer';
    final customerName =
        trip.customerName.isNotEmpty ? trip.customerName : 'Customer';

    unawaited(
      TripRatingDialog.show(
        context,
        tripId: trip.tripId,
        raterId: widget.driverId,
        ratedUserId: customerId,
        ratedUserName: customerName,
        isRatedUserDriver: false,
        ratingService: TripRatingService(),
      ),
    );
  }

  /// Advances the trip, running role-based payment collection checks at pickup
  /// and drop-off, and requiring the delivery PIN for completion.
  Future<void> _advanceOrPin(ActiveTrip trip, String next) async {
    if (next == 'CONFIRM_CASH_SETTLEMENT') {
      await _confirmCashSettlement(trip);
      return;
    }

    if (next == 'IN_PROGRESS') {
      // Step 1: Pickup Stage Collection Check
      // Check if cash is actually due from the sender at pickup.
      // If payment split dictates cash from receiver at drop-off or sender's share
      // is covered by wallet/escrow, do not show any cash collection prompt at pickup.
      if (trip.hasCashDueAtPickup) {
        final confirmed = await _showPickupCashCheckDialog(trip);
        if (confirmed != true) return;
      }
    }

    if (next == 'COMPLETED') {
      // Step 2: Drop-Off Stage Collection Check
      // Only prompt if cash is actually due from the receiver at drop-off.
      if (trip.hasCashDueAtDropoff) {
        final confirmed = await _showDropoffCashCheckDialog(trip);
        if (confirmed != true) return;
      }

      if (trip.serviceType != 'ride' && trip.deliveryPinRequired) {
        await _askDeliveryPin(trip);
        return;
      }
    }

    final success = await _run(
      () => widget.streakService.advanceTripStatus(trip.tripId, next),
      'Could not update trip status.',
    );
    if (success) {
      if (next == 'IN_PROGRESS') {
        widget.onToggleCollapse?.call();
      } else if (next == 'COMPLETED') {
        _promptPostTripRating(trip);
      }
    }
  }

  /// Confirms cash settlement or handles unpaid cash dispute for a customer-cancelled trip.
  Future<void> _confirmCashSettlement(ActiveTrip trip) async {
    final fee = trip.pendingCashFee > 0
        ? trip.pendingCashFee
        : trip.paidWaitingFee;
    final feeStr = fee > 0 ? '₦${fee.toStringAsFixed(0)}' : 'cash waiting fee';

    final choice = await showDialog<bool?>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        title: const Row(
          children: [
            Icon(Icons.payments_outlined, color: Color(0xFFD97706)),
            SizedBox(width: 8),
            Text('Cash Waiting Fee'),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Did you collect the $feeStr cash waiting fee directly from the customer?',
              style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 10),
            Text(
              'If cash was not received, select "Cash Not Collected". The unpaid fee will be automatically debited from the customer\'s account balance while protecting your driver earnings.',
              style: TextStyle(
                fontSize: 12,
                color: Theme.of(ctx).brightness == Brightness.dark
                    ? Colors.grey.shade400
                    : Colors.grey.shade600,
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(null),
            child: const Text('Go Back'),
          ),
          OutlinedButton(
            key: const Key('cash_not_collected_button'),
            style: OutlinedButton.styleFrom(
              foregroundColor: Colors.deepOrange,
            ),
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cash Not Collected'),
          ),
          FilledButton(
            key: const Key('confirm_cash_received_button'),
            style: FilledButton.styleFrom(
              backgroundColor: const Color(0xFFE5A93C),
              foregroundColor: Colors.black87,
            ),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Confirm Cash Collected'),
          ),
        ],
      ),
    );

    if (choice == null || !mounted) return;

    final isCollected = choice == true;
    final success = await _run(
      () => widget.streakService.confirmCashCancellation(
        trip.tripId,
        cashCollected: isCollected,
      ),
      'Could not process cash settlement.',
    );

    if (success && mounted) {
      final msg = isCollected
          ? 'Cash settlement of $feeStr confirmed. Trip closed.'
          : 'Unpaid fee of $feeStr debited to customer account. Driver earnings credited.';
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(msg),
          backgroundColor: isCollected ? Colors.green.shade700 : Colors.amber.shade900,
        ),
      );
    }
  }

  Future<bool?> _showPickupCashCheckDialog(ActiveTrip trip) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final hasWallet = trip.walletCoverageAmount > 0;
    final cashAmountAtPickup = trip.cashDueAtPickup;

    final cashStr = '₦${cashAmountAtPickup.toStringAsFixed(0)}';
    final walletStr = '₦${trip.walletCoverageAmount.toStringAsFixed(0)}';

    return showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        title: const Row(
          children: [
            Icon(Icons.payments, color: Colors.green),
            SizedBox(width: 8),
            Text('Pickup Cash Check'),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Kindly collect $cashStr cash payment from the sender before departure.',
              style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
            ),
            if (hasWallet) ...[
              const SizedBox(height: 10),
              Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: isDark
                      ? const Color(0xFF78350F).withValues(alpha: 0.3)
                      : const Color(0xFFFEF3C7),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(
                    color: isDark
                        ? const Color(0xFFF59E0B).withValues(alpha: 0.4)
                        : const Color(0xFFF59E0B).withValues(alpha: 0.3),
                  ),
                ),
                child: Text(
                  'Wallet portion of $walletStr is locked in escrow and will be credited to your driver wallet upon completion.',
                  style: TextStyle(
                    fontSize: 12,
                    color: isDark ? const Color(0xFFFDE68A) : const Color(0xFF92400E),
                  ),
                ),
              ),
            ],
            if (trip.isSplitTrip && trip.hasCashDueAtDropoff) ...[
              const SizedBox(height: 10),
              Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: isDark
                      ? const Color(0xFF1E293B)
                      : const Color(0xFFF1F5F9),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(
                    color: isDark
                        ? const Color(0xFF475569)
                        : const Color(0xFFCBD5E1),
                  ),
                ),
                child: Text(
                  'Receiver\'s share (₦${trip.cashDueAtDropoff.toStringAsFixed(0)}) will be collected at drop-off.',
                  style: TextStyle(
                    fontSize: 12,
                    color: isDark ? const Color(0xFF94A3B8) : const Color(0xFF475569),
                  ),
                ),
              ),
            ],
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: const Color(0xFF10B981),
            ),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Confirm Cash Collected'),
          ),
        ],
      ),
    );
  }

  Future<bool?> _showDropoffCashCheckDialog(ActiveTrip trip) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final cashAmountAtDropoff = trip.cashDueAtDropoff;
    final cashStr = '₦${cashAmountAtDropoff.toStringAsFixed(0)}';
    final walletStr = '₦${trip.walletCoverageAmount.toStringAsFixed(0)}';

    return showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        title: const Row(
          children: [
            Icon(Icons.payments, color: Colors.amber),
            SizedBox(width: 8),
            Text('Drop-off Cash Check'),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              trip.serviceType == 'ride'
                  ? 'Collect $cashStr cash from passenger before ending ride.'
                  : 'Collect $cashStr cash from receiver before completing delivery.',
              style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
            ),
            if (trip.walletCoverageAmount > 0) ...[
              const SizedBox(height: 10),
              Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: isDark
                      ? const Color(0xFF065F46).withValues(alpha: 0.3)
                      : const Color(0xFFECFDF5),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(
                    color: isDark
                        ? const Color(0xFF10B981).withValues(alpha: 0.4)
                        : const Color(0xFFA7F3D0),
                  ),
                ),
                child: Text(
                  'Sender portion of $walletStr is prepaid and locked in escrow. It will be credited to your driver wallet upon completion.',
                  style: TextStyle(
                    fontSize: 12,
                    color: isDark ? const Color(0xFFA7F3D0) : const Color(0xFF065F46),
                  ),
                ),
              ),
            ],
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: const Color(0xFFF59E0B),
            ),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Confirm Cash Collected'),
          ),
        ],
      ),
    );
  }

  Future<void> _askDeliveryPin(ActiveTrip trip) async {
    final pin = await showDialog<String>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => _DeliveryPinDialog(
        trip: trip,
        onSkipOtp: _canSkipDeliveryPin(trip)
            ? () => Navigator.of(ctx).pop('__skip__')
            : null,
      ),
    );
    if (pin == null || !mounted) return;

    if (pin == '__skip__') {
      // Driver tapped Skip OTP — show mandatory liability warning dialog before
      // calling the server. This is a UX gate only; the server also time-gates.
      final confirmed = await showDialog<bool>(
        context: context,
        barrierDismissible: false,
        builder: (ctx) => AlertDialog(
          key: const Key('skip_otp_liability_dialog'),
          title: const Row(
            children: [
              Icon(Icons.warning_amber_rounded, color: Colors.deepOrange),
              SizedBox(width: 8),
              Text('Liability Warning'),
            ],
          ),
          content: const Text(
            'If you skip the code and report an issue, you will be 100% '
            'responsible for the item.\n\n'
            'Only proceed if you have genuinely been unable to reach the '
            'recipient after waiting at least 10 minutes.',
            style: TextStyle(fontSize: 13),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: const Text('Go Back'),
            ),
            FilledButton(
              key: const Key('skip_otp_confirm_button'),
              style: FilledButton.styleFrom(
                backgroundColor: Colors.deepOrange,
              ),
              onPressed: () => Navigator.of(ctx).pop(true),
              child: const Text('I Accept — Skip OTP'),
            ),
          ],
        ),
      );
      if (confirmed != true || !mounted) return;
      final skipSuccess = await _run(
        () => widget.streakService.skipDeliveryPin(trip.tripId),
        'Unable to skip the delivery PIN. Please try again.',
      );
      if (skipSuccess) {
        _promptPostTripRating(trip);
      }
      return;
    }

    final verifySuccess = await _run(
      () => widget.streakService.verifyDeliveryPin(trip.tripId, pin),
      'Could not complete delivery.',
    );
    if (verifySuccess) {
      _promptPostTripRating(trip);
    }
  }

  /// Returns true when enough time has elapsed in IN_PROGRESS for the driver
  /// to legitimately skip the delivery PIN (≥ 10 min since [trip.arrivedAt]).
  ///
  /// Uses [trip.arrivedAt] as a proxy for when the trip reached the drop-off
  /// phase since `startedAt` may not be populated in all versions. The server
  /// enforces the same gate independently and is idempotent if already handled.
  bool _canSkipDeliveryPin(ActiveTrip trip) {
    if (!trip.deliveryPinRequired) return false;
    // Delivery trips use arrivedAt as the start of the drop-off wait window.
    final arrivedAt = trip.arrivedAt;
    if (arrivedAt == null) return false;
    final elapsed = DateTime.now().difference(arrivedAt);
    return elapsed.inMinutes >= (widget.waitThresholdMinutes);
  }

  /// Auto-arrival expiry: advance to DRIVER_ARRIVED (server alerts customer).
  Future<void> _handleAutoArrive() async {
    if (_autoBusy || !mounted) return;
    if (widget.trip.status != TripStatus.driverAccepted &&
        widget.trip.status != TripStatus.driverArriving) {
      return;
    }
    setState(() => _autoBusy = true);
    try {
      await widget.streakService
          .advanceTripStatus(widget.trip.tripId, 'DRIVER_ARRIVED');
    } on DriverStreakException catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(e.userMessage)));
      }
    } finally {
      if (mounted) setState(() => _autoBusy = false);
    }
  }

  /// Auto-arrival at drop-off expiry: note arrival timestamp and notify backend.
  Future<void> _handleAutoArriveDropoff() async {
    if (_autoBusy || !mounted) return;
    if (widget.trip.status != TripStatus.inProgress) return;
    if (_localDropoffArrivedAt == null && widget.trip.dropoffArrivedAt == null) {
      setState(() {
        _localDropoffArrivedAt = DateTime.now();
      });
      unawaited(widget.streakService.recordDropoffArrival(widget.trip.tripId));
    }
  }

  /// Departure auto-start for pre-paid trips.
  Future<void> _handleAutoStart() async {
    if (_autoBusy || !mounted) return;
    if (widget.trip.status != TripStatus.driverArrived) return;
    setState(() => _autoBusy = true);
    try {
      await widget.streakService
          .advanceTripStatus(widget.trip.tripId, 'IN_PROGRESS');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
              content: Text('Pre-paid trip auto-started. Drive safe!')),
        );
      }
    } on DriverStreakException catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(e.userMessage)));
      }
    } finally {
      if (mounted) setState(() => _autoBusy = false);
    }
  }

  /// Departure on cash/split: siren + payment confirmation gate.
  /// Auto-start stays BLOCKED until the driver explicitly confirms.
  Future<void> _handlePaymentBlock() async {
    if (!mounted || _paymentDialogOpen) return;
    if (widget.trip.status != TripStatus.driverArrived) return;
    _paymentDialogOpen = true;
    // ignore: discarded_futures
    AppSoundService.instance.playSirenAlert();
    try {
      final confirmed = await showDialog<bool>(
        context: context,
        barrierDismissible: false,
        builder: (ctx) => AlertDialog(
          title: const Row(
            children: [
              Icon(Icons.payments_outlined, color: Colors.red),
              SizedBox(width: 8),
              Text('Payment Confirmation'),
            ],
          ),
          content: const Text(
            'This is a cash or split-payment order and cannot auto-start.\n\n'
            'Please confirm you have collected (or verified) payment '
            'before starting the ride.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Confirm & Start Ride'),
            ),
          ],
        ),
      );
      if (!mounted) return;
      if (confirmed == true) {
        await _handleAutoStart();
      }
    } finally {
      // ignore: discarded_futures
      AppSoundService.instance.stopSirenAlert();
      _paymentDialogOpen = false;
    }
  }

  /// Next server transition for the current status, if the driver drives it.
  String? get _nextStatus {
    switch (widget.trip.status) {
      case TripStatus.driverAccepted:
        return 'DRIVER_ARRIVING';
      case TripStatus.driverArriving:
        return 'DRIVER_ARRIVED';
      case TripStatus.driverArrived:
        return 'IN_PROGRESS';
      case TripStatus.inProgress:
        return 'COMPLETED';
      case TripStatus.cancelledWaitingCashSettlement:
        return 'CONFIRM_CASH_SETTLEMENT';
      default:
        return null;
    }
  }

  /// Label for the slide-to-action button — direct action verbs only,
  /// no "Slide to" prefix (the animated arrow thumb already conveys the gesture).
  String get _nextLabel {
    switch (_nextStatus) {
      case 'DRIVER_ARRIVING':
        return 'On My Way';
      case 'DRIVER_ARRIVED':
        return 'Arrived at Pickup';
      case 'IN_PROGRESS':
        return 'Start Ride';
      case 'COMPLETED':
        return 'Complete Trip >';
      case 'CONFIRM_CASH_SETTLEMENT':
        final fee = widget.trip.pendingCashFee > 0
            ? widget.trip.pendingCashFee
            : widget.trip.paidWaitingFee;
        final feeStr = fee > 0 ? '₦${fee.toStringAsFixed(0)}' : 'Cash';
        return 'Confirm $feeStr Collected';
      default:
        return 'Confirm';
    }
  }

  String _paymentLabel(ActiveTrip trip) {
    final mode = trip.paymentMode.toLowerCase();
    final hasWallet = trip.walletCoverageAmount > 0;
    final hasCash = trip.cashToCollect > 0;

    if (mode == 'receiver_pays') {
      return 'RECEIVER PAYS (CASH)';
    } else if (mode == 'split' ||
        trip.splitEnabled ||
        trip.paymentMethod.toLowerCase() == 'split') {
      if (hasWallet && hasCash) {
        return 'SPLIT (WALLET + CASH)';
      }
      return 'SPLIT PAYMENT';
    } else if (hasWallet && hasCash) {
      return 'SPLIT (WALLET + CASH)';
    } else if (trip.paymentMethod.toLowerCase() == 'wallet' ||
        (hasWallet && !hasCash)) {
      return '100% WALLET PREPAID';
    } else if (mode == 'sender_pays') {
      return 'SENDER PAYS (CASH)';
    }
    return trip.paymentMethod.toUpperCase();
  }

  /// Compact one-line subtitle shown beneath the customer name in the
  /// identity row.  Full payment instructions are in [_PaymentCollectionCard]
  /// below, so this line shows only the fare + a short mode label to avoid
  /// conflicting or duplicate cash-amount text.
  String _formatTripPaymentSubtitle(ActiveTrip trip) {
    // 1. While en route to pickup:
    if (trip.status == TripStatus.driverAccepted ||
        trip.status == TripStatus.driverArriving) {
      if (trip.paymentMode.toLowerCase() == 'receiver_pays') {
        return 'Receiver Pays at Drop-off';
      }
      if (trip.isSplitTrip) {
        return 'Split Payment';
      }
      if (trip.isPrepaidTrip || (trip.walletCoverageAmount > 0 && trip.cashToCollect <= 0)) {
        return '100% Wallet Prepaid';
      }
      return 'Cash Payment';
    }

    // 2. Arrived at pickup:
    if (trip.status == TripStatus.driverArrived) {
      if (trip.paymentMode.toLowerCase() == 'receiver_pays') {
        return 'Receiver Pays at Drop-off';
      }
      if (trip.hasCashDueAtPickup) {
        return 'Collect ₦${trip.cashDueAtPickup.toStringAsFixed(0)} Cash';
      } else {
        return 'No Cash Due at Pickup';
      }
    }

    // 3. In Progress (Heading to Drop-off):
    if (trip.status == TripStatus.inProgress) {
      if (trip.hasCashDueAtDropoff) {
        return 'Collect ₦${trip.cashDueAtDropoff.toStringAsFixed(0)} Cash at Drop-off';
      } else {
        return 'All Payments Settled';
      }
    }

    if (trip.paymentMode.toLowerCase() == 'receiver_pays') {
      return 'Receiver Pays at Drop-off';
    }

    if (trip.walletCoverageAmount > 0 && trip.cashToCollect > 0) {
      return 'Wallet + ₦${trip.cashToCollect.toStringAsFixed(0)} Cash';
    } else if (trip.walletCoverageAmount > 0 && trip.cashToCollect <= 0) {
      return '100% Wallet Prepaid';
    } else if (trip.cashToCollect > 0) {
      return 'Cash Payment';
    }

    return _paymentLabel(trip);
  }

  /// Booker lifeline: the account holder who ordered and paid.
  ///
  /// `customerPhone` is minted raw server-side and never masked, so this
  /// number renders VERBATIM — deliberately bypassing [_hidePhones], which
  /// only governs the secondary pickup/drop-off contacts below. Falls back
  /// to the pickup contact on trips minted before the field existed; when
  /// even that is empty/masked, in-app chat (always available) is the line.
  String _bookerPhone(ActiveTrip trip) => trip.customerPhone.isNotEmpty
      ? trip.customerPhone
      : trip.pickupPhone;



  /// True when [raw] can be directly dialed via mobile carrier:
  /// non-empty and not a server/client masking placeholder (`080****5678`, `••••••`).
  bool _isCallableNumber(String raw) {
    final v = raw.trim();
    if (v.isEmpty) return false;
    if (v.contains('*') || v.contains('•')) return false;
    return true;
  }

  String _firstName(String fullName) {
    final trimmed = fullName.trim();
    if (trimmed.isEmpty) return '';
    return trimmed.split(RegExp(r'\s+')).first;
  }

  // _cancelTripWithDialog removed: per spec, drivers cannot cancel while
  // en-route to pickup (driverAccepted / driverArriving). The only driver
  // cancel path is _confirmNoShowCancel after the 10-minute no-show wait.


  Future<void> _makeDirectPhoneCall(BuildContext context, ActiveTrip trip) async {
    final phone = _bookerPhone(trip);
    if (_isCallableNumber(phone) && AppCallService.isDialable(phone)) {
      final ok = await AppCallService.makeCall(phone);
      if (!ok && context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Could not open phone dialer.')),
        );
      }
    } else if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
            content: Text('Direct phone number is masked or unavailable.')),
      );
    }
  }

  void _openChat(BuildContext context, ActiveTrip trip) {
    final myId = widget.driverId.isNotEmpty
        ? widget.driverId
        : (trip.driver?.driverId ?? '');
    final receiverPhone = (trip.dropoffPhone.isNotEmpty &&
            trip.dropoffPhone != _bookerPhone(trip))
        ? trip.dropoffPhone
        : '';
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => TripChatScreen(
          tripId: trip.tripId,
          currentUid: myId,
          senderRole: 'driver',
          peerName: _firstName(
              trip.customerName.isEmpty ? 'Customer' : trip.customerName),
          peerPhone: _bookerPhone(trip),
          hidePhones: false,
          receiverName: receiverPhone.isNotEmpty
              ? _firstName(
                  trip.dropoffName.isNotEmpty ? trip.dropoffName : 'Receiver')
              : '',
          receiverPhone: receiverPhone,
        ),
      ),
    );
  }

  /// Dynamically computes the call contact targets based on who placed the order and current trip phase.
  ///
  /// Conforms strictly to dynamic 1 or 2 option rules:
  /// - Rule A (Sender is Pickup): 1 option — Call the Pickup/Sender.
  /// - Rule B (Sender is Drop-off / Third-Party Booking):
  ///   - Pickup stage: 2 options (Sender who booked, Pickup Contact).
  ///   - Drop-off stage: 2 options (Sender who booked, Receiver / Drop-off Contact).
  List<_CallContactTarget> _buildCallTargets(ActiveTrip trip) {
    final isDropoffStage = trip.status == TripStatus.inProgress;
    final rawBooker = trip.customerName.trim().isNotEmpty
        ? trip.customerName.trim()
        : 'Customer';
    final bookerName = _firstName(rawBooker);
    final bookerPhone = _bookerPhone(trip);
    final bookerId = trip.customerId.isNotEmpty ? trip.customerId : null;

    final rawPickup = trip.pickupName.trim();
    final pickupName = _firstName(rawPickup);
    final pickupPhone = trip.pickupPhone.trim();

    final rawDropoff = trip.dropoffName.trim();
    final dropoffName = _firstName(rawDropoff);
    final dropoffPhone = trip.dropoffPhone.trim();

    final bool isPickupDifferent = (rawPickup.isNotEmpty &&
            rawPickup.toLowerCase() != rawBooker.toLowerCase()) ||
        (pickupPhone.isNotEmpty &&
            bookerPhone.isNotEmpty &&
            pickupPhone != bookerPhone);

    final bool isDropoffDifferent = dropoffPhone.isNotEmpty &&
        ((rawDropoff.isNotEmpty &&
                rawDropoff.toLowerCase() != rawBooker.toLowerCase()) ||
            (bookerPhone.isNotEmpty && dropoffPhone != bookerPhone));

    if (!isDropoffStage) {
      if (isPickupDifferent) {
        return [
          _CallContactTarget(
            title: 'Call Sender ($bookerName)',
            contactName: bookerName,
            contactPhone: bookerPhone,
            targetUserId: bookerId,
            role: 'booker',
            subtitle: '$bookerName • In-App Voice Call',
          ),
          _CallContactTarget(
            title:
                'Call Pickup (${pickupName.isNotEmpty ? pickupName : 'Pickup'})',
            contactName: pickupName.isNotEmpty ? pickupName : 'Pickup Contact',
            contactPhone: pickupPhone,
            targetUserId: null,
            role: 'pickup',
            subtitle:
                '${pickupName.isNotEmpty ? pickupName : 'Pickup Contact'} • On-site Contact',
          ),
        ];
      } else {
        return [
          _CallContactTarget(
            title: 'Call Pickup / Sender ($bookerName)',
            contactName: bookerName,
            contactPhone: bookerPhone,
            targetUserId: bookerId,
            role: 'sender',
            subtitle: '$bookerName • In-App Voice Call',
          ),
        ];
      }
    } else {
      if (isDropoffDifferent) {
        return [
          _CallContactTarget(
            title: 'Call Sender ($bookerName)',
            contactName: bookerName,
            contactPhone: bookerPhone,
            targetUserId: bookerId,
            role: 'booker',
            subtitle: '$bookerName • In-App Voice Call',
          ),
          _CallContactTarget(
            title:
                'Call Receiver (${dropoffName.isNotEmpty ? dropoffName : 'Receiver'})',
            contactName: dropoffName.isNotEmpty ? dropoffName : 'Receiver',
            contactPhone: dropoffPhone,
            targetUserId: null,
            role: 'receiver',
            subtitle:
                '${dropoffName.isNotEmpty ? dropoffName : 'Receiver'} • Drop-off Contact',
          ),
        ];
      } else {
        return [
          _CallContactTarget(
            title: 'Call Pickup / Sender ($bookerName)',
            contactName: bookerName,
            contactPhone: bookerPhone,
            targetUserId: bookerId,
            role: 'customer',
            subtitle: '$bookerName • In-App Voice Call',
          ),
        ];
      }
    }
  }

  /// Displays the clean secondary bottom sheet presenting strictly 1 or 2 contextual call options.
  void _showCallContactSheet(BuildContext context, ActiveTrip trip) {
    final targets = _buildCallTargets(trip);
    if (targets.isEmpty) return;

    final scheme = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;

    showModalBottomSheet<void>(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (ctx) => Container(
        decoration: BoxDecoration(
          color: scheme.surface,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.15),
              blurRadius: 16,
              offset: const Offset(0, -4),
            ),
          ],
        ),
        padding: const EdgeInsets.fromLTRB(20, 12, 20, 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Center(
              child: Container(
                width: 40,
                height: 4,
                decoration: BoxDecoration(
                  color: Colors.grey.withValues(alpha: 0.35),
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            const SizedBox(height: 16),
            for (int i = 0; i < targets.length; i++) ...[
              if (i > 0) const SizedBox(height: 10),
              _CallTargetTile(
                key: Key('call_target_option_$i'),
                target: targets[i],
                isDark: isDark,
                onTap: () {
                  Navigator.of(ctx).pop();
                  _handleCallTarget(context, trip, targets[i]);
                },
              ),
            ],
          ],
        ),
      ),
    );
  }

  /// Seamlessly connects the driver to the selected party via secure In-App VoIP
  /// or appropriate carrier dialing based on user privacy rules.
  void _handleCallTarget(
    BuildContext context,
    ActiveTrip trip,
    _CallContactTarget target,
  ) async {
    // 1. If targeting the registered account holder (order booker / sender):
    // Trigger the secure in-app VoIP audio call (WebRTC / Zego)
    if (target.targetUserId != null && target.targetUserId!.isNotEmpty) {
      final callId =
          'call_${trip.tripId}_${DateTime.now().millisecondsSinceEpoch}';
      InAppCallScreen.start(
        context: context,
        callId: callId,
        targetUserId: target.targetUserId!,
        targetUserName: target.contactName,
        metadata: {
          'tripId': trip.tripId,
          'callerRole': 'driver',
          'contactRole': target.role,
        },
      );
      return;
    }

    // 2. If targeting a third-party contact with an unmasked dialable carrier number:
    if (_isCallableNumber(target.contactPhone) &&
        AppCallService.isDialable(target.contactPhone)) {
      final ok = await AppCallService.makeCall(target.contactPhone);
      if (!ok && context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Could not open phone dialer.')),
        );
      }
      return;
    }

    // 3. If target number is masked, securely route in-app VoIP to the order booker
    if (trip.customerId.isNotEmpty) {
      final callId =
          'call_${trip.tripId}_${DateTime.now().millisecondsSinceEpoch}';
      InAppCallScreen.start(
        context: context,
        callId: callId,
        targetUserId: trip.customerId,
        targetUserName:
            trip.customerName.isNotEmpty ? trip.customerName : 'Customer',
        metadata: {
          'tripId': trip.tripId,
          'callerRole': 'driver',
          'note': '${target.contactName} number masked; routed to trip booker',
        },
      );
      return;
    }

    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
              'Phone number is masked. Please coordinate securely via In-App Chat.'),
        ),
      );
    }
  }

  /// Stage-aware contact block.
  ///
  String _statusHeaderTitle(ActiveTrip trip) {
    switch (trip.status) {
      case TripStatus.driverAccepted:
      case TripStatus.driverArriving:
        return 'Sender notified';
      case TripStatus.driverArrived:
        return 'Arrived at pickup';
      case TripStatus.inProgress:
        if (_currentArrivalTimestamp != null) {
          return 'Arrived at drop-off';
        }
        return 'Trip in progress';
      case TripStatus.cancelledWaitingCashSettlement:
        return 'Customer Cancelled';
      default:
        return 'Active Trip';
    }
  }

  String _statusHeaderSubtitle(ActiveTrip trip) {
    switch (trip.status) {
      case TripStatus.driverAccepted:
      case TripStatus.driverArriving:
        return 'Drive closer to the pickup location to start the waiting timer';
      case TripStatus.driverArrived:
        if (_hasWaitTimeExpired) {
          return 'Paid waiting active • Customer billed for wait time';
        }
        return 'Waiting at pickup location for customer/package';
      case TripStatus.inProgress:
        if (_currentArrivalTimestamp != null) {
          if (_hasWaitTimeExpired) {
            return 'Paid waiting active • Customer billed for wait time';
          }
          return 'Waiting at drop-off location for receiver';
        }
        return 'Head toward destination address';
      case TripStatus.cancelledWaitingCashSettlement:
        final fee = trip.pendingCashFee > 0
            ? trip.pendingCashFee
            : trip.paidWaitingFee;
        final feeStr = fee > 0 ? '₦${fee.toStringAsFixed(0)}' : 'waiting fee';
        return 'Collect $feeStr cash waiting fee from customer';
      default:
        return '';
    }
  }

  static const double _sheetCollapsedSize = 0.18;
  static const double _sheetStandardSize = 0.44;
  static const double _sheetExpandedSize = 0.88;

  void _toggleInternalSheet() {
    final ctrl = widget.sheetController ?? _internalSheetController;
    if (!ctrl.isAttached) return;
    try {
      final current = ctrl.size;
      final target = current <= 0.22 ? _sheetStandardSize : _sheetCollapsedSize;
      ctrl.animateTo(
        target,
        duration: const Duration(milliseconds: 300),
        curve: Curves.easeInOut,
      );
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    if (widget.scrollController != null) {
      return _buildSheetContent(context, widget.scrollController!);
    }

    final controller = widget.sheetController ?? _internalSheetController;
    final initialSize =
        widget.sheetController != null ? _sheetCollapsedSize : _sheetExpandedSize;

    return DraggableScrollableSheet(
      controller: controller,
      initialChildSize: initialSize,
      minChildSize: _sheetCollapsedSize,
      maxChildSize: _sheetExpandedSize,
      snap: true,
      snapSizes: const [_sheetCollapsedSize, _sheetStandardSize, _sheetExpandedSize],
      builder: (context, scrollCtrl) {
        return _buildSheetContent(context, scrollCtrl);
      },
    );
  }

  String _calculateEtaLabel(ActiveTrip trip) {
    final driverPos = widget.driverPosition;
    final isDropoff = trip.status == TripStatus.inProgress;
    final destLat = isDropoff ? trip.dropoffLat : trip.pickupLat;
    final destLng = isDropoff ? trip.dropoffLng : trip.pickupLng;

    if (driverPos == null || driverPos.latitude == 0 || destLat == 0.0) {
      if (trip.durationMins > 0) return '${trip.durationMins.round()} min';
      return '— min';
    }

    double distKm;
    if (widget.routePoints.isNotEmpty) {
      final distM = LocationService.calculateRemainingRouteDistanceM(
        driverPos,
        widget.routePoints,
        fallbackDestination: LatLng(destLat, destLng),
      );
      distKm = distM / 1000.0;
    } else {
      final distM = const Distance().as(
        LengthUnit.Meter,
        driverPos,
        LatLng(destLat, destLng),
      );
      distKm = distM / 1000.0;
    }

    // Dynamic ETA derived from live vehicle speed when in motion (>15 km/h),
    // otherwise falling back to realistic city traffic transit speed (25 km/h).
    final effectiveSpeed = (widget.currentSpeedKmh > 15.0)
        ? widget.currentSpeedKmh
        : 25.0;
    final etaMin = (distKm / effectiveSpeed * 60).ceil().clamp(1, 999);
    return '$etaMin min';
  }

  String _calculateDistanceLabel(ActiveTrip trip) {
    final driverPos = widget.driverPosition;
    final isDropoff = trip.status == TripStatus.inProgress;
    final destLat = isDropoff ? trip.dropoffLat : trip.pickupLat;
    final destLng = isDropoff ? trip.dropoffLng : trip.pickupLng;

    if (driverPos == null || driverPos.latitude == 0 || destLat == 0.0) {
      if (trip.distanceKm > 0) return '${trip.distanceKm.toStringAsFixed(1)} km';
      return '— km';
    }

    double distKm;
    double distM;
    if (widget.routePoints.isNotEmpty) {
      distM = LocationService.calculateRemainingRouteDistanceM(
        driverPos,
        widget.routePoints,
        fallbackDestination: LatLng(destLat, destLng),
      );
      distKm = distM / 1000.0;
    } else {
      distM = const Distance().as(
        LengthUnit.Meter,
        driverPos,
        LatLng(destLat, destLng),
      );
      distKm = distM / 1000.0;
    }

    if (distKm < 1.0) {
      return '${distM.round()} m';
    }
    return '${distKm.toStringAsFixed(1)} km';
  }

  String _calculateArrivalTimeLabel(ActiveTrip trip) {
    final driverPos = widget.driverPosition;
    final isDropoff = trip.status == TripStatus.inProgress;
    final destLat = isDropoff ? trip.dropoffLat : trip.pickupLat;
    final destLng = isDropoff ? trip.dropoffLng : trip.pickupLng;

    int etaMin = trip.durationMins > 0 ? trip.durationMins.round() : 5;
    if (driverPos != null && driverPos.latitude != 0 && destLat != 0.0) {
      double distKm;
      if (widget.routePoints.isNotEmpty) {
        final distM = LocationService.calculateRemainingRouteDistanceM(
          driverPos,
          widget.routePoints,
          fallbackDestination: LatLng(destLat, destLng),
        );
        distKm = distM / 1000.0;
      } else {
        final distM = const Distance().as(
          LengthUnit.Meter,
          driverPos,
          LatLng(destLat, destLng),
        );
        distKm = distM / 1000.0;
      }
      final effectiveSpeed = (widget.currentSpeedKmh > 15.0)
          ? widget.currentSpeedKmh
          : 25.0;
      etaMin = (distKm / effectiveSpeed * 60).ceil().clamp(1, 999);
    }
    final arrivalTime = DateTime.now().add(Duration(minutes: etaMin));
    final h = arrivalTime.hour.toString().padLeft(2, '0');
    final m = arrivalTime.minute.toString().padLeft(2, '0');
    return '$h:$m';
  }

  Widget _buildTelemetryStrip(ActiveTrip trip, bool isDark) {
    final eta = _calculateEtaLabel(trip);
    final dist = _calculateDistanceLabel(trip);
    final arrival = _calculateArrivalTimeLabel(trip);

    return Padding(
      key: const Key('hud_bottom_telemetry_strip'),
      padding: const EdgeInsets.only(bottom: 8, top: 2),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            Icons.directions_car_rounded,
            size: 18,
            color: isDark ? Colors.white70 : Colors.black54,
          ),
          const SizedBox(width: 6),
          Text(
            eta,
            style: TextStyle(
              fontSize: 15,
              fontWeight: FontWeight.bold,
              color: isDark ? Colors.white : Colors.black87,
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: Text(
              '•',
              style: TextStyle(
                color: isDark ? Colors.white38 : Colors.grey.shade400,
                fontSize: 14,
              ),
            ),
          ),
          Text(
            dist,
            style: TextStyle(
              fontSize: 15,
              fontWeight: FontWeight.bold,
              color: isDark ? Colors.white : Colors.black87,
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: Text(
              '•',
              style: TextStyle(
                color: isDark ? Colors.white38 : Colors.grey.shade400,
                fontSize: 14,
              ),
            ),
          ),
          Icon(
            Icons.access_time_rounded,
            size: 17,
            color: isDark ? Colors.white70 : Colors.black54,
          ),
          const SizedBox(width: 6),
          Text(
            arrival,
            style: TextStyle(
              fontSize: 15,
              fontWeight: FontWeight.bold,
              color: isDark ? Colors.white : Colors.black87,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildArrivalWaitingTimer(BuildContext context, bool isDark) {
    final arrivedAt = _currentArrivalTimestamp;
    if (arrivedAt == null) return const SizedBox.shrink();

    final now = DateTime.now();
    final elapsed = now.difference(arrivedAt);
    final isExpired = elapsed.inMinutes >= widget.waitThresholdMinutes;

    if (!isExpired) {
      final totalWaitSeconds = widget.waitThresholdMinutes * 60;
      final remainingSeconds =
          (totalWaitSeconds - elapsed.inSeconds).clamp(0, totalWaitSeconds);
      final mins = remainingSeconds ~/ 60;
      final secs = remainingSeconds % 60;
      final timeStr = '$mins:${secs.toString().padLeft(2, '0')}';

      final bg = isDark
          ? const Color(0xFF78350F).withValues(alpha: 0.35)
          : const Color(0xFFFEF3C7);
      final border = const Color(0xFFF59E0B).withValues(alpha: 0.5);
      final textColor =
          isDark ? const Color(0xFFFDE68A) : const Color(0xFF92400E);

      return Container(
        key: const Key('driver_arrival_countdown_badge'),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        decoration: BoxDecoration(
          color: bg,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: border, width: 1.2),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.timer_outlined,
              size: 15,
              color: textColor,
            ),
            const SizedBox(width: 4),
            Text(
              timeStr,
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.bold,
                fontFeatures: const [FontFeature.tabularFigures()],
                color: textColor,
              ),
            ),
          ],
        ),
      );
    } else {
      final paidSeconds =
          elapsed.inSeconds - (widget.waitThresholdMinutes * 60);
      final paidMins = paidSeconds ~/ 60;
      final paidSecs = paidSeconds % 60;
      final timeStr = '+$paidMins:${paidSecs.toString().padLeft(2, '0')}';

      final ratePerMin = 20.0;
      final estimatedFee = ((paidSeconds / 60.0) * ratePerMin).ceil();
      final feeStr = '₦$estimatedFee';

      final bg = isDark
          ? const Color(0xFF991B1B).withValues(alpha: 0.3)
          : const Color(0xFFFEE2E2);
      final border = const Color(0xFFEF4444).withValues(alpha: 0.6);
      final textColor =
          isDark ? const Color(0xFFFCA5A5) : const Color(0xFFB91C1C);

      return Container(
        key: const Key('driver_paid_waiting_badge'),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        decoration: BoxDecoration(
          color: bg,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: border, width: 1.2),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.access_time_filled_rounded,
              size: 14,
              color: textColor,
            ),
            const SizedBox(width: 4),
            Text(
              'Paid Wait $timeStr ($feeStr)',
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.bold,
                fontFeatures: const [FontFeature.tabularFigures()],
                color: textColor,
              ),
            ),
          ],
        ),
      );
    }
  }

  Widget _buildSheetContent(
      BuildContext context, ScrollController scrollController) {
    final trip = widget.trip;
    final scheme = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final isAtPickupWait = trip.status == TripStatus.driverArrived;
    final next = _nextStatus;
    final mockDetected = _prox?.isMocked == true;
    final countingDown = widget.autoArrivalEnabled &&
        !_autoArrivalDismissed &&
        ((_prox?.zone == ProximityZone.arrivalCountdown) || _autoBusy);

    return Container(
      key: const Key('driver_active_trip_card'),
      margin: EdgeInsets.zero,
      decoration: BoxDecoration(
        color: scheme.surface,
        borderRadius: const BorderRadius.only(
          topLeft: Radius.circular(24),
          topRight: Radius.circular(24),
        ),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.12),
            blurRadius: 16,
            offset: const Offset(0, -4),
          ),
        ],
      ),
      // Single scrollable view attached to scrollController starting from the top edge
      // so dragging/sliding from the top handle, action slider, or identity card expands/collapses the sheet smoothly.
      child: SingleChildScrollView(
        controller: scrollController,
        physics: const ClampingScrollPhysics(),
        padding: EdgeInsets.fromLTRB(
          16,
          6,
          16,
          16 + MediaQuery.of(context).padding.bottom,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Full-width grabbable header touch handle area
            GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: widget.onToggleCollapse ?? _toggleInternalSheet,
              child: Container(
                width: double.infinity,
                padding: const EdgeInsets.symmetric(vertical: 2),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Center(
                      child: Container(
                        width: 48,
                        height: 5,
                        margin: const EdgeInsets.only(top: 2, bottom: 6),
                        decoration: BoxDecoration(
                          color: isDark ? const Color(0xFF3A3A46) : Colors.grey.shade300,
                          borderRadius: BorderRadius.circular(3),
                        ),
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Row(
                            children: [
                              Expanded(
                                child: Text(
                                  _statusHeaderTitle(trip),
                                  style: TextStyle(
                                    fontWeight: FontWeight.bold,
                                    fontSize: 18,
                                    color: isDark ? Colors.white : Colors.black87,
                                  ),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                              _buildArrivalWaitingTimer(context, isDark),
                            ],
                          ),
                          if (_statusHeaderSubtitle(trip).isNotEmpty) ...[
                            const SizedBox(height: 4),
                            Text(
                              _statusHeaderSubtitle(trip),
                              style: TextStyle(
                                fontSize: 12,
                                color: isDark ? Colors.grey.shade400 : Colors.grey.shade600,
                              ),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ],
                          if (trip.status == TripStatus.inProgress ||
                              trip.status == TripStatus.driverArriving ||
                              trip.status == TripStatus.driverAccepted) ...[
                            const SizedBox(height: 6),
                            _buildTelemetryStrip(trip, isDark),
                          ],
                        ],
                      ),
                    ),
                    const SizedBox(height: 6),
                  ],
                ),
              ),
            ),

            // a. Action Container (Primary Action Slider)
            _SlideToActionButton(
              key: const Key('driver_slide_action_button'),
              label: _nextLabel,
              busy: _busy,
              enabled: next != null,
              onSlideComplete: () {
                if (next != null) {
                  _advanceOrPin(trip, next);
                }
              },
            ),
            const SizedBox(height: 8),

            // b. Identity Row (Mutual Customer Profile Card)
            InkWell(
              key: const Key('driver_customer_profile_card'),
              borderRadius: BorderRadius.circular(14),
              onTap: () {
                MutualProfileModal.show(
                  context,
                  userId: trip.customerId,
                  fallbackName: trip.customerName.isEmpty ? 'Customer' : trip.customerName,
                  roleLabel: 'Customer',
                );
              },
              child: Container(
                padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 12),
                decoration: BoxDecoration(
                  color: isDark ? const Color(0xFF252530) : Colors.grey.shade50,
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(
                    color: isDark ? const Color(0xFF3A3A46) : Colors.grey.shade200,
                  ),
                ),
                child: Row(
                  children: [
                    Container(
                      width: 48,
                      height: 48,
                      decoration: BoxDecoration(
                        color: isDark
                            ? const Color(0xFF78350F).withValues(alpha: 0.3)
                            : const Color(0xFFFEF3C7),
                        shape: BoxShape.circle,
                      ),
                      child: const Center(
                        child: Icon(
                          Icons.person,
                          color: Color(0xFFD97706),
                          size: 28,
                        ),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          // Primary line: bold fare + vehicle category
                          Row(
                            crossAxisAlignment: CrossAxisAlignment.center,
                            children: [
                              Text(
                                trip.fareFormatted.isNotEmpty
                                    ? trip.fareFormatted
                                    : '₦${trip.fareAmount.toStringAsFixed(0)}',
                                style: TextStyle(
                                  fontWeight: FontWeight.w900,
                                  fontSize: 20,
                                  color: isDark
                                      ? const Color(0xFFFBBF24)
                                      : const Color(0xFF92400E),
                                  letterSpacing: -0.3,
                                ),
                              ),
                              const SizedBox(width: 8),
                              Flexible(
                                child: Text(
                                  trip.vehicleCategory.isNotEmpty
                                      ? trip.vehicleCategory
                                      : 'Ride',
                                  style: TextStyle(
                                    fontWeight: FontWeight.bold,
                                    fontSize: 15,
                                    color: isDark ? Colors.white : Colors.black87,
                                  ),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 3),
                          // Secondary line: customer name + rating + payment mode
                          Row(
                            children: [
                              Flexible(
                                child: Text(
                                  _firstName(trip.customerName.isEmpty
                                      ? 'Customer'
                                      : trip.customerName),
                                  style: TextStyle(
                                    fontWeight: FontWeight.w600,
                                    fontSize: 13,
                                    color: isDark ? Colors.grey.shade300 : Colors.grey.shade700,
                                  ),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                              const Icon(Icons.verified, color: Colors.blue, size: 14),
                              const SizedBox(width: 4),
                              const Icon(Icons.star_rounded, color: Colors.amber, size: 14),
                              const Text(
                                ' 5.0',
                                style: TextStyle(
                                  fontWeight: FontWeight.bold,
                                  fontSize: 12,
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 2),
                          // Tertiary: payment subtitle
                          Text(
                            _formatTripPaymentSubtitle(trip),
                            style: TextStyle(
                              fontSize: 12,
                              color: isDark ? Colors.grey.shade400 : Colors.grey.shade600,
                              fontWeight: FontWeight.w500,
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ],
                      ),
                    ),
                    const Icon(Icons.chevron_right, color: Colors.grey, size: 22),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 8),

            // c. Communication Action Row (Direct Call, In-App Call, Chat on same horizontal line)
                  Row(
                    children: [
                      Expanded(
                        child: _CommunicationButton(
                          key: const Key('driver_direct_call_icon'),
                          icon: Icons.phone_outlined,
                          label: 'Direct Call',
                          color: const Color(0xFF10B981),
                          bgColor: const Color(0xFF10B981).withValues(alpha: 0.12),
                          onTap: () => _makeDirectPhoneCall(context, trip),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: _CommunicationButton(
                          key: const Key('driver_inapp_call_icon'),
                          icon: Icons.phone_in_talk_outlined,
                          label: 'In-App Call',
                          color: const Color(0xFFD97706),
                          bgColor: isDark
                              ? const Color(0xFF78350F).withValues(alpha: 0.25)
                              : const Color(0xFFFEF3C7),
                          onTap: () => _showCallContactSheet(context, trip),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: _CommunicationButton(
                          key: const Key('driver_chat_icon'),
                          icon: Icons.chat_bubble_outline,
                          label: 'Chat',
                          color: isDark ? Colors.white : Colors.black87,
                          bgColor: isDark ? const Color(0xFF252530) : Colors.grey.shade100,
                          onTap: () => _openChat(context, trip),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),

            // Payment Breakdown & Collection Instructions
            _PaymentCollectionCard(trip: trip),

            // 4. Route Details Box (PICKUP & DROPOFF)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              decoration: BoxDecoration(
                color: isDark ? const Color(0xFF252530) : Colors.grey.shade50,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(
                  color: isDark ? const Color(0xFF3A3A46) : Colors.grey.shade200,
                ),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Pickup row
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Padding(
                        padding: const EdgeInsets.only(top: 3),
                        child: Container(
                          width: 10,
                          height: 10,
                          decoration: const BoxDecoration(
                            color: Color(0xFF10B981),
                            shape: BoxShape.circle,
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Text(
                              'PICKUP',
                              style: TextStyle(
                                fontSize: 10,
                                fontWeight: FontWeight.bold,
                                color: Color(0xFF10B981),
                                letterSpacing: 0.5,
                              ),
                            ),
                            const SizedBox(height: 2),
                            Text(
                              trip.pickupAddress.isEmpty
                                  ? 'Pickup location on map'
                                  : trip.pickupAddress,
                              style: TextStyle(
                                fontSize: 13,
                                fontWeight: FontWeight.w600,
                                color: isDark ? Colors.white : Colors.black87,
                              ),
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                  if (trip.status == TripStatus.inProgress) ...[
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 6),
                      child: Divider(
                        height: 1,
                        color: isDark ? const Color(0xFF3A3A46) : null,
                      ),
                    ),
                    // Dropoff row
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Padding(
                          padding: const EdgeInsets.only(top: 3),
                          child: Container(
                            width: 10,
                            height: 10,
                            decoration: const BoxDecoration(
                              color: Color(0xFFEF4444),
                              shape: BoxShape.circle,
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const Text(
                                'DROPOFF',
                                style: TextStyle(
                                  fontSize: 10,
                                  fontWeight: FontWeight.bold,
                                  color: Color(0xFFEF4444),
                                  letterSpacing: 0.5,
                                ),
                              ),
                              const SizedBox(height: 2),
                              Text(
                                trip.dropoffAddress.isEmpty
                                    ? 'Drop-off location on map'
                                    : trip.dropoffAddress,
                                style: TextStyle(
                                  fontSize: 13,
                                  fontWeight: FontWeight.w600,
                                  color: isDark ? Colors.white : Colors.black87,
                                ),
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ],
                ],
              ),
            ),

            if (mockDetected) ...[
              const SizedBox(height: 8),
              Container(
                key: const Key('mock_location_warning'),
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: Colors.red.shade50,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Row(
                  children: [
                    const Icon(Icons.location_off,
                        color: Colors.red, size: 18),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        'Mock location detected — disable mock locations. '
                        'Telemetry is paused while spoofing.',
                        style: TextStyle(
                            color: Colors.red.shade800, fontSize: 12),
                      ),
                    ),
                  ],
                ),
              ),
            ],

            if (countingDown && !isAtPickupWait) ...[
              const SizedBox(height: 8),
              Container(
                key: const Key('auto_arrival_banner'),
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                decoration: BoxDecoration(
                  color: Colors.amber.shade50,
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: Colors.amber.shade300, width: 1.2),
                ),
                child: Row(
                  children: [
                    Stack(
                      alignment: Alignment.center,
                      children: [
                        SizedBox(
                          width: 32,
                          height: 32,
                          child: CircularProgressIndicator(
                            value: widget.autoArrivalCountdownSeconds > 0
                                ? _countdownSecondsRemaining /
                                    widget.autoArrivalCountdownSeconds
                                : 1.0,
                            strokeWidth: 3,
                            backgroundColor: Colors.amber.shade200,
                            color: Colors.amber.shade800,
                          ),
                        ),
                        Text(
                          '$_countdownSecondsRemaining',
                          style: TextStyle(
                            color: Colors.amber.shade900,
                            fontWeight: FontWeight.bold,
                            fontSize: 13,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            trip.status == TripStatus.inProgress
                                ? 'Auto-arriving at drop-off in ${_countdownSecondsRemaining}s...'
                                : 'Auto-arriving at pickup in ${_countdownSecondsRemaining}s...',
                            style: const TextStyle(
                              color: Colors.brown,
                              fontSize: 13,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            'Arriving automatically · Tap cancel to pause',
                            style: TextStyle(
                              color: Colors.brown.shade700,
                              fontSize: 11,
                            ),
                          ),
                        ],
                      ),
                    ),
                    TextButton(
                      key: const Key('cancel_auto_arrival_button'),
                      onPressed: _cancelAutoArrival,
                      style: TextButton.styleFrom(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 8, vertical: 4),
                        minimumSize: Size.zero,
                        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                        foregroundColor: Colors.brown.shade800,
                      ),
                      child: const Text(
                        'Cancel',
                        style: TextStyle(
                            fontWeight: FontWeight.bold, fontSize: 12),
                      ),
                    ),
                  ],
                ),
              ),
            ],



            // Cancellation option — visible after scrolling, with generous bottom clearance.
            // Per spec: no cancel button while en-route to pickup (DRIVER_ACCEPTED /
            // DRIVER_ARRIVING). Only DRIVER_ARRIVED exposes the cancel after the 10-minute
            // no-show wait elapses. IN_PROGRESS hides the button entirely — the driver
            // must complete the trip.
            if (trip.status == TripStatus.driverArrived && _hasWaitTimeExpired) ...{
              const SizedBox(height: 24),
              Center(
                child: TextButton.icon(
                  key: const Key('driver_cancel_trip_button'),
                  icon: const Icon(Icons.cancel_outlined, size: 16, color: Colors.grey),
                  label: Text(
                    'Cancel Trip (Customer No-Show)',
                    style: TextStyle(
                      color: Colors.grey.shade600,
                      fontSize: 12,
                      fontWeight: FontWeight.w500,
                      decoration: TextDecoration.underline,
                    ),
                  ),
                  onPressed: _busy ? null : () => _confirmNoShowCancel(trip),
                ),
              ),
              const SizedBox(height: 8),
            } else if (trip.status == TripStatus.driverArrived && !_hasWaitTimeExpired) ...{
              // Wait notice: driver must wait for the 10-minute threshold before cancelling.
              const SizedBox(height: 8),
            } else ...{
              // driverAccepted / driverArriving / inProgress: no cancel button.
              const SizedBox(height: 8),
            },
          ],
        ),
      ),
    );
  }
}

/// Contextual call target model containing identity, role, and connectivity details.
class _CallContactTarget {
  final String title;
  final String contactName;
  final String contactPhone;
  final String? targetUserId;
  final String role;
  final String subtitle;

  const _CallContactTarget({
    required this.title,
    required this.contactName,
    required this.contactPhone,
    this.targetUserId,
    required this.role,
    required this.subtitle,
  });
}

/// A clean, modern call option tile rendered in the secondary call bottom sheet.
class _CallTargetTile extends StatelessWidget {
  final _CallContactTarget target;
  final bool isDark;
  final VoidCallback onTap;

  const _CallTargetTile({
    super.key,
    required this.target,
    required this.isDark,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final fill = isDark ? const Color(0xFF282832) : const Color(0xFFF9FAFB);
    final borderColor =
        isDark ? const Color(0xFF383844) : const Color(0xFFE5E7EB);

    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(16),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        decoration: BoxDecoration(
          color: fill,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: borderColor, width: 1),
        ),
        child: Row(
          children: [
            Container(
              width: 44,
              height: 44,
              decoration: BoxDecoration(
                color: const Color(0xFF10B981).withValues(alpha: 0.12),
                shape: BoxShape.circle,
              ),
              child: const Icon(
                Icons.phone_rounded,
                color: Color(0xFF059669),
                size: 22,
              ),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    target.title,
                    style: const TextStyle(
                      fontWeight: FontWeight.w700,
                      fontSize: 14,
                    ),
                  ),
                  const SizedBox(height: 3),
                  Text(
                    target.subtitle,
                    style: TextStyle(
                      fontSize: 12,
                      color: Colors.grey.shade600,
                      fontWeight: FontWeight.w500,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              decoration: BoxDecoration(
                color: const Color(0xFF10B981),
                borderRadius: BorderRadius.circular(20),
              ),
              child: const Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.call, color: Colors.white, size: 14),
                  SizedBox(width: 4),
                  Text(
                    'Call',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 12,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Clean horizontal communication button with icon and label for clear touch targets.
class _CommunicationButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final Color color;
  final Color bgColor;
  final VoidCallback onTap;

  const _CommunicationButton({
    super.key,
    required this.icon,
    required this.label,
    required this.color,
    required this.bgColor,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(14),
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 10),
          decoration: BoxDecoration(
            color: bgColor,
            borderRadius: BorderRadius.circular(14),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(icon, color: color, size: 21),
              const SizedBox(width: 7),
              Flexible(
                child: Text(
                  label,
                  style: TextStyle(
                    color: color,
                    fontWeight: FontWeight.w700,
                    fontSize: 14,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Slide-to-Action button widget used across all active trip stages.
class _SlideToActionButton extends StatefulWidget {
  final String label;
  final bool busy;
  final bool enabled;
  final VoidCallback onSlideComplete;

  const _SlideToActionButton({
    super.key,
    required this.label,
    required this.busy,
    required this.enabled,
    required this.onSlideComplete,
  });

  @override
  State<_SlideToActionButton> createState() => _SlideToActionButtonState();
}

class _SlideToActionButtonState extends State<_SlideToActionButton> {
  double _dragDistance = 0;
  bool _isDragging = false;

  static const double _trackHeight = 54;
  static const double _thumbSize = 46;
  static const double _completionFraction = 0.80;

  void _reset() {
    if (mounted) {
      setState(() {
        _dragDistance = 0;
        _isDragging = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final maxSlide = (constraints.maxWidth - _thumbSize - 8)
            .clamp(0.0, double.infinity);

        return GestureDetector(
          key: const Key('slide_to_action_track'),
          onHorizontalDragUpdate: (widget.enabled && !widget.busy)
              ? (details) {
                  _isDragging = true;
                  setState(() {
                    _dragDistance = (_dragDistance + details.delta.dx)
                        .clamp(0.0, maxSlide);
                  });
                }
              : null,
          onHorizontalDragEnd: (widget.enabled && !widget.busy)
              ? (_) {
                  final completed = _isDragging &&
                      maxSlide > 0 &&
                      _dragDistance >= maxSlide * _completionFraction;
                  _reset();
                  if (completed) {
                    widget.onSlideComplete();
                  }
                }
              : null,
          child: Container(
            height: _trackHeight,
            decoration: BoxDecoration(
              color: const Color(0xFFF59E0B),
              borderRadius: BorderRadius.circular(16),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.08),
                  blurRadius: 8,
                  offset: const Offset(0, 2),
                ),
              ],
            ),
            child: Stack(
              alignment: Alignment.centerLeft,
              children: [
                Center(
                  child: Text(
                    widget.busy ? 'Working…' : widget.label,
                    style: const TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.bold,
                      color: Colors.black87,
                      letterSpacing: 0.2,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                Transform.translate(
                  offset: Offset(4 + _dragDistance, 0),
                  child: Container(
                    width: _thumbSize,
                    height: _thumbSize,
                    decoration: BoxDecoration(
                      color: const Color(0xFFD97706),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    alignment: Alignment.center,
                    child: const Icon(
                      Icons.chevron_right,
                      color: Colors.white,
                      size: 28,
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

/// Delivery PIN confirmation dialog widget. Keeps controller alive during pop transitions.
/// Dialog prompting the driver to enter the 4-digit delivery PIN given by the
/// recipient. When [onSkipOtp] is provided (i.e., the 10-minute wait has
/// elapsed), a "Skip OTP" escape-hatch button is shown that triggers the
/// liability warning flow before calling the server.
class _DeliveryPinDialog extends StatefulWidget {
  final ActiveTrip trip;

  /// Called when the driver taps "Skip OTP". Non-null only after the 10-minute
  /// wait threshold has elapsed. Pops the dialog with the sentinel `'__skip__'`
  /// string so the parent can handle the liability warning flow.
  final VoidCallback? onSkipOtp;

  const _DeliveryPinDialog({required this.trip, this.onSkipOtp});

  @override
  State<_DeliveryPinDialog> createState() => _DeliveryPinDialogState();
}

class _DeliveryPinDialogState extends State<_DeliveryPinDialog> {
  late final TextEditingController _ctrl;
  String? _error;

  @override
  void initState() {
    super.initState();
    _ctrl = TextEditingController();
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      key: const Key('delivery_pin_dialog'),
      title: const Text('Delivery PIN'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Ask the recipient for the 4-digit code sent to them at '
            'booking. The delivery completes only with the right code.',
            style: TextStyle(fontSize: 13),
          ),
          const SizedBox(height: 12),
          TextField(
            key: const Key('delivery_pin_field'),
            controller: _ctrl,
            keyboardType: TextInputType.number,
            maxLength: 4,
            decoration: InputDecoration(
              labelText: '4-digit PIN',
              border: const OutlineInputBorder(),
              errorText: _error,
            ),
            onChanged: (_) {
              if (_error != null) setState(() => _error = null);
            },
          ),
        ],
      ),
      actions: [
        // Skip OTP escape-hatch: only visible after the 10-minute wait has
        // elapsed AND the parent determined it is eligible. Positioned as
        // the leftmost action so it is not accidentally tapped.
        if (widget.onSkipOtp != null)
          TextButton(
            key: const Key('skip_otp_button'),
            style: TextButton.styleFrom(
              foregroundColor: Colors.deepOrange,
            ),
            onPressed: widget.onSkipOtp,
            child: const Text('Skip OTP'),
          ),
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          key: const Key('delivery_pin_submit'),
          onPressed: () {
            if (!RegExp(r'^\d{4}$').hasMatch(_ctrl.text.trim())) {
              setState(() => _error = 'Enter the 4-digit code.');
              return;
            }
            Navigator.of(context).pop(_ctrl.text.trim());
          },
          child: const Text('Complete Delivery'),
        ),
      ],
    );
  }
}

class _PaymentCollectionCard extends StatelessWidget {
  final ActiveTrip trip;

  const _PaymentCollectionCard({required this.trip});

  static String _formatCurrency(num amount) {
    final whole = amount.round().toString();
    return '₦${whole.replaceAllMapped(RegExp(r'(\d{1,3})(?=(\d{3})+(?!\d))'), (m) => '${m[1]},')}';
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final status = trip.status;

    // 1. En Route to Pickup:
    // Completely hide any specific cash collection breakdown or escrow notes.
    if (status == TripStatus.driverAccepted ||
        status == TripStatus.driverArriving) {
      return const SizedBox.shrink();
    }

    // 2. Arrived at Pickup:
    // Check if cash is actually due from the sender at pickup.
    // If no cash is due (receiver pays at drop-off or sender's share is 100% wallet/escrow),
    // do not show any cash collection prompt at pickup.
    if (status == TripStatus.driverArrived) {
      if (!trip.hasCashDueAtPickup) {
        return const SizedBox.shrink();
      }

      final cashAmount = trip.cashDueAtPickup;
      final hasWallet = trip.walletCoverageAmount > 0;
      final walletAmount = trip.walletCoverageAmount;

      final cardBg = isDark
          ? const Color(0xFF78350F).withValues(alpha: 0.25)
          : const Color(0xFFFEF3C7);
      final borderColor = const Color(0xFFF59E0B).withValues(alpha: 0.4);
      final accentColor =
          isDark ? const Color(0xFFFBBF24) : const Color(0xFF92400E);
      final textColor = isDark ? Colors.white : const Color(0xFF92400E);

      return Container(
        margin: const EdgeInsets.only(bottom: 12),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          color: cardBg,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: borderColor, width: 1.2),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.payments_outlined, size: 16, color: accentColor),
                const SizedBox(width: 6),
                Text(
                  trip.isSplitTrip
                      ? 'SPLIT PAYMENT (WALLET + CASH)'
                      : 'CASH PAYMENT AT PICKUP',
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.bold,
                    letterSpacing: 0.5,
                    color: accentColor,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 6),
            Text(
              'Kindly collect ${_formatCurrency(cashAmount)} cash payment from the sender before departure.',
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.bold,
                color: textColor,
              ),
            ),
            if (hasWallet) ...[
              const SizedBox(height: 3),
              Text(
                '₦${walletAmount.toStringAsFixed(0)} wallet portion locked in escrow, credited upon completion.',
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w500,
                  color: isDark
                      ? Colors.grey.shade400
                      : accentColor.withValues(alpha: 0.85),
                ),
              ),
            ],
          ],
        ),
      );
    }

    // 3. In Progress (Heading to Drop-off / At Drop-off):
    if (status == TripStatus.inProgress) {
      if (!trip.hasCashDueAtDropoff) {
        return const SizedBox.shrink();
      }

      final cashAmount = trip.cashDueAtDropoff;
      final isReceiverPays = trip.paymentMode.toLowerCase() == 'receiver_pays';

      final cardBg = isDark
          ? const Color(0xFF1E3A8A).withValues(alpha: 0.25)
          : const Color(0xFFEFF6FF);
      final borderColor = isDark
          ? const Color(0xFF3B82F6).withValues(alpha: 0.4)
          : const Color(0xFF93C5FD);
      final accentColor =
          isDark ? const Color(0xFF93C5FD) : const Color(0xFF1D4ED8);
      final textColor = isDark ? Colors.white : const Color(0xFF1E40AF);

      return Container(
        margin: const EdgeInsets.only(bottom: 12),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          color: cardBg,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: borderColor, width: 1.2),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.call_received_rounded, size: 16, color: accentColor),
                const SizedBox(width: 6),
                Text(
                  isReceiverPays
                      ? 'RECEIVER PAYS (CASH ONLY)'
                      : 'SPLIT PAYMENT (RECEIVER SHARE)',
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.bold,
                    letterSpacing: 0.5,
                    color: accentColor,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 6),
            Text(
              trip.serviceType == 'ride'
                  ? 'Collect ₦${cashAmount.toStringAsFixed(0)} cash from passenger before ending ride.'
                  : 'Collect ₦${cashAmount.toStringAsFixed(0)} cash from receiver before completing delivery.',
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.bold,
                color: textColor,
              ),
            ),
            const SizedBox(height: 3),
            Text(
              'Collect cash from receiver at drop-off before releasing package or completing ride.',
              style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w500,
                color: isDark
                    ? Colors.grey.shade400
                    : accentColor.withValues(alpha: 0.85),
              ),
            ),
          ],
        ),
      );
    }

    return const SizedBox.shrink();
  }
}



