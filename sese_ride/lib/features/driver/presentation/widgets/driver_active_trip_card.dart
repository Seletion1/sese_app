import 'dart:async';

import 'package:flutter/material.dart';
import 'package:latlong2/latlong.dart';
import 'package:sese_core/sese_core.dart';

import '../../../../core/services/call_service.dart';
import '../../../trips/models/trip_models.dart';
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
          'Cancelling now is streak-protected and will not penalize your streak or driver rating.',
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

  /// Advances the trip, running mandatory cash collection checks at pickup
  /// and drop-off, and requiring the delivery PIN for completion.
  Future<void> _advanceOrPin(ActiveTrip trip, String next) async {
    if (next == 'IN_PROGRESS') {
      // Step 1: Pickup Cash Check (Sender Cash Portion)
      if (trip.paymentMethod == 'cash' || trip.paymentMethod == 'split') {
        final confirmed = await _showPickupCashCheckDialog(trip);
        if (confirmed != true) return;
      }
    }
    if (next == 'COMPLETED') {
      // Step 2: Drop-Off Cash Check (Receiver Cash Portion)
      if (trip.paymentMethod == 'cash' || trip.paymentMethod == 'split') {
        final confirmed = await _showDropoffCashCheckDialog(trip);
        if (confirmed != true) return;
      }
      if (trip.serviceType != 'ride') {
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
    final fareStr = trip.fareFormatted.isNotEmpty
        ? trip.fareFormatted
        : '₦${trip.fareAmount.toStringAsFixed(0)}';
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
        content: Text(
          'Collect $fareStr CASH from Sender before taking package.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Confirm Cash Collected'),
          ),
        ],
      ),
    );
  }

  Future<bool?> _showDropoffCashCheckDialog(ActiveTrip trip) {
    final fareStr = trip.fareFormatted.isNotEmpty
        ? trip.fareFormatted
        : '₦${trip.fareAmount.toStringAsFixed(0)}';
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
        content: Text(
          'Collect $fareStr CASH from Receiver before releasing package.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Confirm Cash Collected'),
          ),
        ],
      ),
    );
  }

  Future<void> _askDeliveryPin(ActiveTrip trip) async {
    final ctrl = TextEditingController();
    String? error;
    final pin = await showDialog<String>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDlg) => AlertDialog(
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
                controller: ctrl,
                keyboardType: TextInputType.number,
                maxLength: 4,
                decoration: InputDecoration(
                  labelText: '4-digit PIN',
                  border: const OutlineInputBorder(),
                  errorText: error,
                ),
                onChanged: (_) {
                  if (error != null) setDlg(() => error = null);
                },
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: const Text('Cancel'),
            ),
            FilledButton(
              key: const Key('delivery_pin_submit'),
              onPressed: () {
                if (!RegExp(r'^\d{4}$').hasMatch(ctrl.text.trim())) {
                  setDlg(() => error = 'Enter the 4-digit code.');
                  return;
                }
                Navigator.of(ctx).pop(ctrl.text.trim());
              },
              child: const Text('Complete Delivery'),
            ),
          ],
        ),
      ),
    );
    ctrl.dispose();
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
        return 'Start Trip (En Route)';
      case 'DRIVER_ARRIVED':
        return "I've Arrived";
      case 'IN_PROGRESS':
        return 'Start Ride';
      case 'COMPLETED':
        return 'Complete Trip';
      default:
        return 'Advance';
    }
  }

  String _categoryLabel(ActiveTrip trip) {
    if (trip.serviceType.toLowerCase() == 'delivery') {
      return 'Courier';
    }
    if (trip.vehicleCategory.isNotEmpty) {
      final cat = trip.vehicleCategory.trim();
      return cat[0].toUpperCase() + cat.substring(1).toLowerCase();
    }
    return 'Ride';
  }

  String _paymentLabel(ActiveTrip trip) {
    final method = trip.paymentMethod.toLowerCase();
    if (method == 'cash') {
      return trip.splitEnabled ? 'SPLIT (SENDER)' : 'SENDER P...';
    } else if (method == 'split') {
      return 'SPLIT PAYMENT';
    } else if (method == 'wallet') {
      return 'WALLET PREPAID';
    }
    return trip.paymentMethod.toUpperCase();
  }

  String _statusBadgeText(TripStatus status) {
    switch (status) {
      case TripStatus.driverAccepted:
        return 'Accepted';
      case TripStatus.driverArriving:
        return 'En Route';
      case TripStatus.driverArrived:
        return 'Arrived';
      case TripStatus.inProgress:
        return 'In Progress';
      default:
        return 'Active';
    }
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
          peerName: trip.customerName.isEmpty ? 'Customer' : trip.customerName,
          peerPhone: _bookerPhone(trip),
          hidePhones: false,
          receiverName: receiverPhone.isNotEmpty
              ? (trip.dropoffName.isNotEmpty ? trip.dropoffName : 'Drop-off Receiver')
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
    final bookerName =
        trip.customerName.trim().isNotEmpty ? trip.customerName.trim() : 'Customer';
    final bookerPhone = _bookerPhone(trip);
    final bookerId = trip.customerId.isNotEmpty ? trip.customerId : null;

    final pickupName = trip.pickupName.trim();
    final pickupPhone = trip.pickupPhone.trim();

    final dropoffName = trip.dropoffName.trim();
    final dropoffPhone = trip.dropoffPhone.trim();

    // Check if pickup contact is distinct from the person who booked
    final bool isPickupDifferent = (pickupName.isNotEmpty &&
            pickupName.toLowerCase() != bookerName.toLowerCase()) ||
        (pickupPhone.isNotEmpty &&
            bookerPhone.isNotEmpty &&
            pickupPhone != bookerPhone);

    // Check if drop-off contact is distinct from the person who booked
    final bool isDropoffDifferent = dropoffPhone.isNotEmpty &&
        ((dropoffName.isNotEmpty &&
                dropoffName.toLowerCase() != bookerName.toLowerCase()) ||
            (bookerPhone.isNotEmpty && dropoffPhone != bookerPhone));

    if (!isDropoffStage) {
      // ── PICKUP STAGE ──
      if (isPickupDifferent) {
        // Rule B (Pickup Stage): 2 options
        return [
          _CallContactTarget(
            title: 'Call the Sender (Person who booked)',
            contactName: bookerName,
            contactPhone: bookerPhone,
            targetUserId: bookerId,
            role: 'booker',
            subtitle: '$bookerName • In-App Voice Call',
          ),
          _CallContactTarget(
            title: 'Call the Pickup Contact',
            contactName: pickupName.isNotEmpty ? pickupName : 'Pickup Contact',
            contactPhone: pickupPhone,
            targetUserId: null,
            role: 'pickup',
            subtitle:
                '${pickupName.isNotEmpty ? pickupName : 'Pickup Contact'} • On-site Contact',
          ),
        ];
      } else {
        // Rule A (Sender is Pickup): 1 option
        return [
          _CallContactTarget(
            title: 'Call the Pickup / Sender',
            contactName: bookerName,
            contactPhone: bookerPhone,
            targetUserId: bookerId,
            role: 'sender',
            subtitle: '$bookerName • In-App Voice Call',
          ),
        ];
      }
    } else {
      // ── DROP-OFF STAGE ──
      if (isDropoffDifferent) {
        // Rule B (Drop-off Stage): 2 options
        return [
          _CallContactTarget(
            title: 'Call the Sender (Person who booked)',
            contactName: bookerName,
            contactPhone: bookerPhone,
            targetUserId: bookerId,
            role: 'booker',
            subtitle: '$bookerName • In-App Voice Call',
          ),
          _CallContactTarget(
            title: 'Call the Receiver / Drop-off Contact',
            contactName: dropoffName.isNotEmpty ? dropoffName : 'Receiver',
            contactPhone: dropoffPhone,
            targetUserId: null,
            role: 'receiver',
            subtitle:
                '${dropoffName.isNotEmpty ? dropoffName : 'Receiver'} • Drop-off Contact',
          ),
        ];
      } else {
        // Passenger ride or booker is recipient: 1 option
        return [
          _CallContactTarget(
            title: 'Call the Pickup / Sender',
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
        padding: const EdgeInsets.fromLTRB(20, 12, 20, 32),
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
            const SizedBox(height: 18),
            Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: const Color(0xFFF59E0B).withValues(alpha: 0.15),
                    shape: BoxShape.circle,
                  ),
                  child: const Icon(
                    Icons.phone_in_talk_rounded,
                    color: Color(0xFFD97706),
                    size: 20,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Call Contact',
                        style: Theme.of(ctx).textTheme.titleMedium?.copyWith(
                              fontWeight: FontWeight.bold,
                            ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        targets.length == 1
                            ? 'Tap to connect with contact'
                            : 'Select which contact to call',
                        style: TextStyle(
                          fontSize: 12,
                          color: Colors.grey.shade600,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
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
      maxChildSize: 0.85,
      snap: true,
      snapSizes: const [0.18, 0.42, 0.85],
      builder: (context, scrollCtrl) {
        return _buildSheetContent(context, scrollCtrl);
      },
    );
  }

  Widget _buildSheetContent(
      BuildContext context, ScrollController scrollController) {
    final trip = widget.trip;
    final scheme = Theme.of(context).colorScheme;
    // STRICT RULE: Only consider waiting at pickup when status is strictly driverArrived.
    // When In-Progress / Drop-off, pickup wait is over and cancellation is completely hidden.
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
      child: SingleChildScrollView(
        controller: scrollController,
        physics: const ClampingScrollPhysics(),
        padding: const EdgeInsets.fromLTRB(16, 6, 16, 20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // 1. Tappable / Draggable Centered handle bar
            GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: widget.onToggleCollapse ?? _toggleInternalSheet,
              child: Center(
                child: Container(
                  width: 44,
                  height: 5,
                  margin: const EdgeInsets.only(top: 4, bottom: 8),
                  decoration: BoxDecoration(
                    color: Colors.grey.shade300,
                    borderRadius: BorderRadius.circular(3),
                  ),
                ),
              ),
            ),

            // 2. Customer Header Row: Avatar, Name, Category/Fare/Payment, Status Badge
            Row(
              children: [
                Container(
                  width: 44,
                  height: 44,
                  decoration: const BoxDecoration(
                    color: Color(0xFFFEF3C7),
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
                              trip.customerName.isEmpty
                                  ? 'Customer'
                                  : trip.customerName,
                              style: const TextStyle(
                                fontWeight: FontWeight.bold,
                                fontSize: 16,
                              ),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                          const SizedBox(width: 4),
                          const Icon(
                            Icons.verified,
                            color: Colors.blue,
                            size: 16,
                          ),
                        ],
                      ),
                      const SizedBox(height: 2),
                      Text(
                        '${_categoryLabel(trip)} • ₦${trip.fareAmount.toStringAsFixed(0)} • ${_paymentLabel(trip)}',
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
                  padding:
                      const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                  decoration: BoxDecoration(
                    color: const Color(0xFFFEF3C7),
                    borderRadius: BorderRadius.circular(16),
                  ),
                  child: Text(
                    _statusBadgeText(trip.status),
                    style: const TextStyle(
                      color: Color(0xFFB45309),
                      fontWeight: FontWeight.bold,
                      fontSize: 12,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),

            // 3. Primary Action Button (Slide / Tap)
            // Positioned right under the header so it remains instantly accessible
            // even when the sheet is minimized.
            Material(
              color: const Color(0xFFF59E0B),
              borderRadius: BorderRadius.circular(16),
              child: InkWell(
                onTap: (_busy || next == null)
                    ? null
                    : () => _advanceOrPin(trip, next),
                borderRadius: BorderRadius.circular(16),
                child: Container(
                  height: 52,
                  padding: const EdgeInsets.symmetric(horizontal: 6),
                  child: Row(
                    children: [
                      Container(
                        width: 40,
                        height: 40,
                        decoration: BoxDecoration(
                          color: const Color(0xFFD97706),
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: const Center(
                          child: Icon(
                            Icons.chevron_right,
                            color: Colors.white,
                            size: 26,
                          ),
                        ),
                      ),
                      Expanded(
                        child: Center(
                          child: Text(
                            _busy ? 'Working…' : _nextLabel,
                            style: const TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.bold,
                              color: Colors.black87,
                              letterSpacing: 0.2,
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ),
                      const SizedBox(width: 40),
                    ],
                  ),
                ),
              ),
            ),
            const SizedBox(height: 12),

            // 4. Action Buttons: Call & Message
            Row(
              children: [
                Expanded(
                  child: SizedBox(
                    height: 42,
                    child: OutlinedButton.icon(
                      key: const Key('driver_call_button'),
                      icon: const Icon(Icons.phone_outlined, size: 18),
                      label: const Text(
                        'Call',
                        style: TextStyle(
                            fontWeight: FontWeight.bold, fontSize: 14),
                      ),
                      style: OutlinedButton.styleFrom(
                        foregroundColor: const Color(0xFFD97706),
                        side: const BorderSide(
                            color: Color(0xFFF59E0B), width: 1.5),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                        padding: EdgeInsets.zero,
                      ),
                      onPressed: () => _showCallContactSheet(context, trip),
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: SizedBox(
                    height: 42,
                    child: FilledButton.icon(
                      key: const Key('driver_message_button'),
                      icon: const Icon(Icons.chat_bubble_outline, size: 18),
                      label: const Text(
                        'Message',
                        style: TextStyle(
                            fontWeight: FontWeight.bold, fontSize: 14),
                      ),
                      style: FilledButton.styleFrom(
                        backgroundColor: const Color(0xFFF59E0B),
                        foregroundColor: Colors.black87,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                        padding: EdgeInsets.zero,
                      ),
                      onPressed: () => _openChat(context, trip),
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),

            // 5. Route Details Box (PICKUP & DROPOFF)
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Colors.grey.shade50,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: Colors.grey.shade200),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Pickup row
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Padding(
                        padding: const EdgeInsets.only(top: 4),
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
                              style: const TextStyle(
                                fontSize: 13,
                                fontWeight: FontWeight.w600,
                                color: Colors.black87,
                              ),
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                  const Padding(
                    padding: EdgeInsets.symmetric(vertical: 8),
                    child: Divider(height: 1),
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
                                    style: const TextStyle(
                                      fontSize: 13,
                                      fontWeight: FontWeight.w600,
                                      color: Colors.black87,
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
                                  color: Colors.grey.shade600,
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
            // Never rendered when in-progress.
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

            // Customer No-Show cancel link: STRICTLY only when arrived at pickup AND >= 10 mins wait.
            // When trip is In-Progress / Drop-off ("Complete Trip"), all cancellation options are completely hidden/deleted.
            if (isAtPickupWait && _hasWaitTimeExpired) ...[
              const SizedBox(height: 10),
              Center(
                child: TextButton(
                  onPressed: _busy ? null : () => _confirmNoShowCancel(trip),
                  style: TextButton.styleFrom(
                    foregroundColor: Colors.grey.shade600,
                    padding: const EdgeInsets.symmetric(
                        horizontal: 16, vertical: 4),
                    minimumSize: Size.zero,
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                  child: const Text(
                    'Cancel Trip (Customer No-Show)',
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w400,
                      decoration: TextDecoration.underline,
                    ),
                  ),
                ),
              ),
            ],
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
