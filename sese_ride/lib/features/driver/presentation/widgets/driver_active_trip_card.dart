import 'dart:async';

import 'package:flutter/material.dart';
import 'package:latlong2/latlong.dart';
import 'package:sese_core/sese_core.dart';

import '../../../../core/services/call_service.dart';
import '../../../trips/models/trip_models.dart';
import '../../../trips/presentation/cancel_trip_dialog.dart';
import '../../../trips/presentation/mutual_profile_modal.dart';
import '../../../trips/presentation/trip_chat_screen.dart';
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
  ProximityTriggerService? _proximity;
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
    _proximity!.updates.listen((u) {
      if (mounted) {
        setState(() {
          _prox = u;
          _updateCountdownTicker(u);
        });
      }
    });
    _proximity!.start(trip: widget.trip, streakService: widget.streakService);
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
  }

  @override
  void dispose() {
    _countdownTicker?.cancel();
    _countdownTicker = null;
    _proximity?.dispose();
    _proximity = null;
    _internalSheetController.dispose();
    super.dispose();
  }

  /// True when the driver has waited at least [widget.waitThresholdMinutes] after arriving.
  bool get _hasWaitTimeExpired {
    final arrivedAt = widget.trip.arrivedAt;
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

  Future<void> _run(Future<void> Function() action, String failFallback) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await action();
    } on DriverStreakException catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(e.userMessage)));
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(failFallback)));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// Advances the trip, running role-based payment collection checks at pickup
  /// and drop-off, and requiring the delivery PIN for completion.
  Future<void> _advanceOrPin(ActiveTrip trip, String next) async {
    final mode = trip.paymentMode.toLowerCase();
    final isReceiverPays = mode == 'receiver_pays';
    final hasWallet = trip.walletCoverageAmount > 0;
    final hasCash = trip.cashToCollect > 0;
    final is100Prepaid = trip.isPrepaidTrip || (hasWallet && !hasCash);

    if (next == 'IN_PROGRESS' && !is100Prepaid) {
      // Step 1: Pickup Stage Collection Check
      // - Sender Pays (Cash or Split): Prompt cash collection at pickup
      // - Receiver Pays: 0 collection prompt at pickup (strictly at drop-off)
      if (!isReceiverPays && (hasCash || (!hasWallet && !trip.isPrepaidTrip))) {
        final confirmed = await _showPickupCashCheckDialog(trip);
        if (confirmed != true) return;
      }
    }

    if (next == 'COMPLETED') {
      if (!is100Prepaid) {
        // Step 2: Drop-Off Stage Collection Check
        // - Receiver Pays: Prompt full fare collection in cash from receiver
        // - Split Payment where collectAt == 'dropoff': Prompt cash collection from receiver
        // - Sender Pays: 0 collection prompt at drop-off (already collected at pickup)
        if (isReceiverPays || (trip.collectAt == 'dropoff' && hasCash)) {
          final confirmed = await _showDropoffCashCheckDialog(trip);
          if (confirmed != true) return;
        }
      }

      if (trip.serviceType != 'ride' && trip.deliveryPinRequired) {
        await _askDeliveryPin(trip);
        return;
      }
    }

    await _run(
      () => widget.streakService.advanceTripStatus(trip.tripId, next),
      'Could not update trip status.',
    );
  }

  Future<bool?> _showPickupCashCheckDialog(ActiveTrip trip) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final cashAmount =
        trip.cashToCollect > 0 ? trip.cashToCollect : trip.fareAmount;
    final cashStr = '₦${cashAmount.toStringAsFixed(0)}';
    final hasWallet = trip.walletCoverageAmount > 0;
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
              trip.serviceType == 'ride'
                  ? 'Collect $cashStr CASH from Booker/Sender before starting ride.'
                  : 'Collect $cashStr CASH from Sender before taking package.',
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
    final cashAmount =
        trip.cashToCollect > 0 ? trip.cashToCollect : trip.fareAmount;
    final cashStr = '₦${cashAmount.toStringAsFixed(0)}';
    final hasWallet = trip.walletCoverageAmount > 0;
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
                  ? 'Collect $cashStr CASH from Rider/Receiver before ending ride.'
                  : 'Collect $cashStr CASH from Receiver before releasing package.',
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
      builder: (ctx) => const _DeliveryPinDialog(),
    );
    if (pin == null || !mounted) return;
    await _run(
      () => widget.streakService.verifyDeliveryPin(trip.tripId, pin),
      'Could not complete delivery.',
    );
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

  /// Auto-arrival at drop-off expiry: prompt or advance completion.
  Future<void> _handleAutoArriveDropoff() async {
    if (_autoBusy || !mounted) return;
    if (widget.trip.status != TripStatus.inProgress) return;
    await _advanceOrPin(widget.trip, 'COMPLETED');
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
      default:
        return null;
    }
  }

  String get _nextLabel {
    switch (_nextStatus) {
      case 'DRIVER_ARRIVING':
        return 'Slide to Start Trip';
      case 'DRIVER_ARRIVED':
        return "Slide to confirm Arrived";
      case 'IN_PROGRESS':
        return 'Slide to Start Ride';
      case 'COMPLETED':
        return 'Slide to Complete Trip';
      default:
        return 'Slide to Confirm';
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
    final fareStr = trip.fareFormatted.isNotEmpty
        ? trip.fareFormatted
        : '₦${trip.fareAmount.toStringAsFixed(0)}';

    if (trip.paymentMode.toLowerCase() == 'receiver_pays') {
      return '$fareStr • Receiver Pays at Drop-off';
    }

    if (trip.walletCoverageAmount > 0 && trip.cashToCollect > 0) {
      // Split: show wallet + cash portions without repeating the collection instruction.
      return '$fareStr • Wallet + ₦${trip.cashToCollect.toStringAsFixed(0)} Cash';
    } else if (trip.walletCoverageAmount > 0 && trip.cashToCollect <= 0) {
      return '$fareStr • 100% Wallet Prepaid';
    } else if (trip.cashToCollect > 0) {
      return '$fareStr • Cash Payment';
    }

    return '$fareStr • ${_paymentLabel(trip)}';
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

  Future<void> _cancelTripWithDialog(ActiveTrip trip) async {
    final result = await CancelTripDialog.show(context, isDriver: true);
    if (result != null && mounted) {
      await _run(
        () => widget.streakService.cancelTrip(trip.tripId, reason: result.reason),
        'Could not cancel trip.',
      );
      // Show optional post-cancel feedback sheet after the cancellation succeeds.
      if (mounted) {
        await CancelTripDialog.showPostCancelFeedback(
          context,
          tripId: trip.tripId,
          userId: widget.driverId,
          role: 'driver',
          isDriver: true,
        );
      }
    }
  }

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
  void _toggleInternalSheet() {
    final ctrl = widget.sheetController ?? _internalSheetController;
    if (!ctrl.isAttached) return;
    try {
      final current = ctrl.size;
      final target = current <= 0.25 ? 0.42 : 0.18;
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
    final isTripStarted = widget.trip.status == TripStatus.inProgress;
    final initialSize = isTripStarted ? 0.18 : 0.42;

    return DraggableScrollableSheet(
      controller: controller,
      initialChildSize: initialSize,
      minChildSize: 0.18,
      maxChildSize: 0.88,
      snap: true,
      snapSizes: const [0.18, 0.42, 0.88],
      builder: (context, scrollCtrl) {
        return _buildSheetContent(context, scrollCtrl);
      },
    );
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
                child: Center(
                  child: Container(
                    width: 48,
                    height: 5,
                    margin: const EdgeInsets.only(top: 2, bottom: 8),
                    decoration: BoxDecoration(
                      color: isDark ? const Color(0xFF3A3A46) : Colors.grey.shade300,
                      borderRadius: BorderRadius.circular(3),
                    ),
                  ),
                ),
              ),
            ),

            // Compact live ETA telemetry pill — visible only while the trip
            // is IN_PROGRESS and the sheet is collapsed to the 0.18 stub,
            // giving the driver at-a-glance remaining time + distance without
            // expanding the sheet or entering the navigation cockpit.
            if (trip.status == TripStatus.inProgress &&
                widget.driverPosition != null &&
                trip.dropoffLat != 0.0 &&
                trip.dropoffLng != 0.0)
              _ActiveTripEtaPill(
                driverPosition: widget.driverPosition!,
                dropoffLat: trip.dropoffLat,
                dropoffLng: trip.dropoffLng,
              ),
            if (trip.status == TripStatus.inProgress &&
                widget.driverPosition != null &&
                trip.dropoffLat != 0.0 &&
                trip.dropoffLng != 0.0)
              const SizedBox(height: 8),

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
              borderRadius: BorderRadius.circular(12),
              onTap: () {
                MutualProfileModal.show(
                  context,
                  userId: trip.customerId,
                  fallbackName: trip.customerName.isEmpty ? 'Customer' : trip.customerName,
                  roleLabel: 'Customer',
                );
              },
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 4),
                child: Row(
                  children: [
                    Container(
                      width: 44,
                      height: 44,
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
                          size: 26,
                        ),
                      ),
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
                                  _firstName(trip.customerName.isEmpty
                                      ? 'Customer'
                                      : trip.customerName),
                                  style: const TextStyle(
                                    fontWeight: FontWeight.bold,
                                    fontSize: 17,
                                  ),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                              const SizedBox(width: 4),
                              const Icon(
                                Icons.verified,
                                color: Colors.blue,
                                size: 17,
                              ),
                              const SizedBox(width: 6),
                              const Icon(
                                Icons.star_rounded,
                                color: Colors.amber,
                                size: 16,
                              ),
                              const Text(
                                ' 5.0',
                                style: TextStyle(
                                  fontWeight: FontWeight.bold,
                                  fontSize: 13,
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 2),
                          Text(
                            _formatTripPaymentSubtitle(trip),
                            style: TextStyle(
                              fontSize: 13,
                              color: isDark ? Colors.grey.shade400 : Colors.grey.shade700,
                              fontWeight: FontWeight.w600,
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
                        child: trip.status == TripStatus.inProgress
                            ? Container(
                                width: 10,
                                height: 10,
                                decoration: const BoxDecoration(
                                  color: Color(0xFFEF4444),
                                  shape: BoxShape.circle,
                                ),
                              )
                            : const Icon(
                                Icons.lock_outline,
                                size: 14,
                                color: Colors.grey,
                              ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: trip.status == TripStatus.inProgress
                            ? Column(
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
                              )
                            : Text(
                                'Drop-off revealed once ride starts',
                                style: TextStyle(
                                  fontSize: 12,
                                  color: isDark ? Colors.grey.shade400 : Colors.grey.shade600,
                                  fontStyle: FontStyle.italic,
                                ),
                              ),
                      ),
                    ],
                  ),
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

            // Informative wait notice: STRICTLY only when arrived at pickup AND wait hasn't expired.
            if (isAtPickupWait && !_hasWaitTimeExpired) ...[
              const SizedBox(height: 8),
              Text(
                'Wait at least ${widget.waitThresholdMinutes} min after Arrived — '
                'a no-show cancel after that keeps your streak.',
                style: Theme.of(context)
                    .textTheme
                    .bodySmall
                    ?.copyWith(color: scheme.onTertiaryContainer),
              ),
            ],

            // Cancellation option — visible after scrolling, with generous bottom clearance
            const SizedBox(height: 24),
            Center(
              child: TextButton.icon(
                key: const Key('driver_cancel_trip_button'),
                icon: const Icon(Icons.cancel_outlined, size: 16, color: Colors.grey),
                label: Text(
                  isAtPickupWait && _hasWaitTimeExpired
                      ? 'Cancel Trip (Customer No-Show)'
                      : 'Cancel Trip',
                  style: TextStyle(
                    color: Colors.grey.shade600,
                    fontSize: 12,
                    fontWeight: FontWeight.w500,
                    decoration: TextDecoration.underline,
                  ),
                ),
                onPressed: _busy
                    ? null
                    : () {
                        if (isAtPickupWait && _hasWaitTimeExpired) {
                          _confirmNoShowCancel(trip);
                        } else {
                          _cancelTripWithDialog(trip);
                        }
                      },
              ),
            ),
            const SizedBox(height: 8),
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
        borderRadius: BorderRadius.circular(12),
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 8),
          decoration: BoxDecoration(
            color: bgColor,
            borderRadius: BorderRadius.circular(12),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(icon, color: color, size: 19),
              const SizedBox(width: 6),
              Flexible(
                child: Text(
                  label,
                  style: TextStyle(
                    color: color,
                    fontWeight: FontWeight.bold,
                    fontSize: 13,
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
class _DeliveryPinDialog extends StatefulWidget {
  const _DeliveryPinDialog();

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

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final mode = trip.paymentMode.toLowerCase();
    final hasWallet = trip.walletCoverageAmount > 0;
    final hasCash = trip.cashToCollect > 0;
    final cashAmount =
        hasCash ? trip.cashToCollect : (hasWallet ? 0.0 : trip.fareAmount);
    final walletAmount = trip.walletCoverageAmount;
    final isReceiverPays = mode == 'receiver_pays';

    Color cardBg;
    Color borderColor;
    Color accentColor;
    Color textColor;
    IconData icon;
    String title;
    String collectionText;
    String settlementText;

    if (isReceiverPays) {
      cardBg = isDark
          ? const Color(0xFF1E3A8A).withValues(alpha: 0.25)
          : const Color(0xFFEFF6FF);
      borderColor = isDark
          ? const Color(0xFF3B82F6).withValues(alpha: 0.4)
          : const Color(0xFF93C5FD);
      accentColor = isDark ? const Color(0xFF93C5FD) : const Color(0xFF1D4ED8);
      textColor = isDark ? Colors.white : const Color(0xFF1E40AF);
      icon = Icons.call_received_rounded;
      title = 'RECEIVER PAYS (CASH ONLY)';
      collectionText =
          'Collect ₦${trip.fareAmount.toStringAsFixed(0)} cash from Receiver at drop-off.';
      settlementText = 'Do not collect any payment at pickup.';
    } else if (hasWallet && hasCash) {
      cardBg = isDark
          ? const Color(0xFF78350F).withValues(alpha: 0.25)
          : const Color(0xFFFEF3C7);
      borderColor = isDark
          ? const Color(0xFFF59E0B).withValues(alpha: 0.4)
          : const Color(0xFFF59E0B).withValues(alpha: 0.4);
      accentColor = isDark ? const Color(0xFFFBBF24) : const Color(0xFF92400E);
      textColor = isDark ? Colors.white : const Color(0xFF92400E);
      icon = Icons.payments_outlined;
      title = 'SPLIT PAYMENT (WALLET + CASH)';
      collectionText =
          'Collect ₦${cashAmount.toStringAsFixed(0)} cash at pickup from sender.';
      settlementText =
          '₦${walletAmount.toStringAsFixed(0)} credited to your wallet upon completion.';
    } else if (hasWallet && !hasCash) {
      cardBg = isDark
          ? const Color(0xFF065F46).withValues(alpha: 0.25)
          : const Color(0xFFECFDF5);
      borderColor = isDark
          ? const Color(0xFF10B981).withValues(alpha: 0.4)
          : const Color(0xFFA7F3D0);
      accentColor = isDark ? const Color(0xFF6EE7B7) : const Color(0xFF065F46);
      textColor = isDark ? Colors.white : const Color(0xFF065F46);
      icon = Icons.account_balance_wallet_outlined;
      title = '100% WALLET PREPAID';
      collectionText = '₦0 cash to collect — do not ask customer for cash.';
      settlementText =
          '₦${walletAmount.toStringAsFixed(0)} credited to your wallet upon completion.';
    } else {
      cardBg = isDark ? const Color(0xFF252530) : const Color(0xFFF9FAFB);
      borderColor = isDark ? const Color(0xFF3A3A46) : const Color(0xFFE5E7EB);
      accentColor = isDark ? AppColors.seseGold : Colors.black87;
      textColor = isDark ? Colors.white : Colors.black87;
      icon = Icons.money_rounded;
      title = 'CASH PAYMENT';
      // Use the server-computed cashToCollect when available; fall back to
      // the full fare only when no partial escrow is set, preventing a
      // mismatch where the subtitle shows a different figure than the card.
      final cashDisplay = hasCash ? trip.cashToCollect : trip.fareAmount;
      collectionText =
          'Collect ₦${cashDisplay.toStringAsFixed(0)} cash at pickup from sender.';
      settlementText = 'Keep 100% of collected cash.';
    }

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
              Icon(icon, size: 16, color: accentColor),
              const SizedBox(width: 6),
              Text(
                title,
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
          Row(
            children: [
              Expanded(
                child: Text(
                  collectionText,
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.bold,
                    color: textColor,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 3),
          Text(
            settlementText,
            style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w500,
              color: isDark ? Colors.grey.shade400 : accentColor.withValues(alpha: 0.85),
            ),
          ),
        ],
      ),
    );
  }
}

/// Compact telemetry pill shown above the slide-to-action button when the
/// trip is [TripStatus.inProgress] and the sheet is collapsed to its 0.18
/// stub.  Gives the driver at-a-glance remaining ETA + distance to the
/// dropoff without requiring them to expand the sheet or open the cockpit.
///
/// ETA is estimated at 30 km/h average urban speed (same formula as the
/// in-app navigation screen); this is a display-only, non-money calculation
/// so client-side computation is acceptable per server-authoritative rules.
class _ActiveTripEtaPill extends StatelessWidget {
  final LatLng driverPosition;
  final double dropoffLat;
  final double dropoffLng;

  const _ActiveTripEtaPill({
    required this.driverPosition,
    required this.dropoffLat,
    required this.dropoffLng,
  });

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final dropoff = LatLng(dropoffLat, dropoffLng);
    final distM = const Distance().as(
      LengthUnit.Meter,
      driverPosition,
      dropoff,
    );
    final distKm = distM / 1000.0;
    final etaMin = (distKm / 30.0 * 60).ceil().clamp(1, 999);
    final distLabel = distM < 1000
        ? '${distM.round()} m'
        : '${distKm.toStringAsFixed(1)} km';

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      decoration: BoxDecoration(
        color: AppColors.seseGold,
        borderRadius: BorderRadius.circular(14),
        boxShadow: [
          BoxShadow(
            color: AppColors.seseGold.withValues(
              alpha: isDark ? 0.25 : 0.35,
            ),
            blurRadius: 8,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Icon(Icons.timer_outlined, color: Colors.black, size: 18),
          const SizedBox(width: 8),
          Text(
            '$etaMin min  •  $distLabel to dropoff',
            style: const TextStyle(
              fontSize: 15,
              fontWeight: FontWeight.w800,
              color: Colors.black,
              letterSpacing: -0.1,
            ),
          ),
        ],
      ),
    );
  }
}



