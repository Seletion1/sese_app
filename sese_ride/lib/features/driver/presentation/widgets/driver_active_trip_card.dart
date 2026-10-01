import 'package:flutter/material.dart';
import 'package:sese_core/sese_core.dart';

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

  /// Test seam: inject a fake proximity service (skips device GPS).
  final ProximityTriggerService Function({
    required void Function() onArrive,
    required void Function() onAutoStart,
    required void Function() onPaymentBlock,
  })? proximityFactory;

  const DriverActiveTripCard({
    super.key,
    required this.trip,
    required this.streakService,
    this.waitThresholdMinutes = 10,
    this.driverId = '',
    this.proximityFactory,
  });

  @override
  State<DriverActiveTripCard> createState() => _DriverActiveTripCardState();
}

class _DriverActiveTripCardState extends State<DriverActiveTripCard> {
  bool _busy = false;
  bool _autoBusy = false;
  bool _paymentDialogOpen = false;
  bool _hidePhones = false;
  ProximityTriggerService? _proximity;
  ProximityUpdate? _prox;

  @override
  void initState() {
    super.initState();
    PrivacyMasking.hidePhonesEnabled().then((v) {
      if (mounted) setState(() => _hidePhones = v);
    });
    _proximity = (widget.proximityFactory ??
            ({
              required void Function() onArrive,
              required void Function() onAutoStart,
              required void Function() onPaymentBlock,
            }) =>
                ProximityTriggerService(
                  onArrive: onArrive,
                  onAutoStart: onAutoStart,
                  onPaymentBlock: onPaymentBlock,
                ))(
      onArrive: _handleAutoArrive,
      onAutoStart: _handleAutoStart,
      onPaymentBlock: _handlePaymentBlock,
    );
    _proximity!.updates.listen((u) {
      if (mounted) setState(() => _prox = u);
    });
    _proximity!.start(trip: widget.trip, streakService: widget.streakService);
  }

  @override
  void didUpdateWidget(DriverActiveTripCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    _proximity?.noteTrip(widget.trip);
  }

  @override
  void dispose() {
    _proximity?.dispose();
    _proximity = null;
    super.dispose();
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

  /// Advances the trip, or asks for the delivery PIN when completing a
  /// delivery. Deliveries complete ONLY through `verifyDeliveryPin` — the
  /// recipient's 4-digit code is the proof of handover, and the plain
  /// "Complete Trip" path must never bypass it.
  Future<void> _advanceOrPin(ActiveTrip trip, String next) async {
    if (next == 'COMPLETED' && trip.serviceType != 'ride') {
      await _askDeliveryPin(trip);
      return;
    }
    await _run(
      () => widget.streakService.advanceTripStatus(trip.tripId, next),
      'Could not update trip status.',
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

  String get _statusLabel {
    switch (widget.trip.status) {
      case TripStatus.driverAccepted:
        return 'Accepted — head to pickup';
      case TripStatus.driverArriving:
        return 'En route to pickup';
      case TripStatus.driverArrived:
        return 'Arrived — waiting for customer';
      case TripStatus.waitingForAcceptance:
        return 'Awaiting your decision';
      case TripStatus.searchingDriver:
        return 'Finding you a trip…';
      case TripStatus.inProgress:
        return 'Trip in progress';
      default:
        return widget.trip.status.wireValue;
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

  @override
  Widget build(BuildContext context) {
    final trip = widget.trip;
    final scheme = Theme.of(context).colorScheme;
    final arrived = trip.status == TripStatus.driverArrived ||
        trip.arrivedAt != null;
    final next = _nextStatus;
    final mockDetected = _prox?.isMocked == true;
    final countingDown =
        (_prox?.zone == ProximityZone.arrivalCountdown) || _autoBusy;

    return Container(
      key: const Key('driver_active_trip_card'),
      margin: const EdgeInsets.fromLTRB(12, 8, 12, 0),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(14),
        boxShadow: [
          BoxShadow(
              color: scheme.shadow.withValues(alpha: 0.15),
              blurRadius: 8,
              offset: const Offset(0, 2)),
        ],
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Icon(Icons.directions_car_filled, color: scheme.primary),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  _statusLabel,
                  style: Theme.of(context)
                      .textTheme
                      .titleSmall
                      ?.copyWith(
                        color: scheme.onSurface,
                        fontWeight: FontWeight.bold,
                      ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            'Pickup: ${trip.pickupAddress.isEmpty ? 'see map' : trip.pickupAddress}',
            style: Theme.of(context)
                .textTheme
                .bodySmall
                ?.copyWith(color: scheme.onSurfaceVariant),
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
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
          if (countingDown && !arrived) ...[
            const SizedBox(height: 8),
            Container(
              key: const Key('auto_arrival_banner'),
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: Colors.amber.shade50,
                borderRadius: BorderRadius.circular(8),
              ),
              child: const Row(
                children: [
                  SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                  SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'Auto-arriving at pickup...',
                      style: TextStyle(
                          color: Colors.brown,
                          fontSize: 12,
                          fontWeight: FontWeight.w600),
                    ),
                  ),
                ],
              ),
            ),
          ],
          if (arrived) ...[
            const SizedBox(height: 4),
            Text(
              'Wait at least ${widget.waitThresholdMinutes} min after Arrived — '
              'a no-show cancel after that keeps your streak.',
              style: Theme.of(context)
                  .textTheme
                  .bodySmall
                  ?.copyWith(color: scheme.onTertiaryContainer),
            ),
          ] else ...[
            const SizedBox(height: 4),
            const Text(
              'Cancelling before arrival breaks your streak.',
              style: TextStyle(fontSize: 11, color: Colors.redAccent),
            ),
          ],
          const SizedBox(height: 8),
          Row(
            children: [
              if (next != null)
                Expanded(
                  flex: 2,
                  child: FilledButton(
                    onPressed: _busy
                        ? null
                        : () => _advanceOrPin(trip, next),
                    child: Text(_busy ? 'Working…' : _nextLabel),
                  ),
                ),
              if (next != null) const SizedBox(width: 8),
              Expanded(
                child: OutlinedButton(
                  style: OutlinedButton.styleFrom(
                      foregroundColor: Colors.red,
                      side: BorderSide.none,
                      backgroundColor:
                          Colors.red.withValues(alpha: 0.08)),
                  onPressed: _busy
                      ? null
                      : () => _run(
                          () =>
                              widget.streakService.cancelTrip(trip.tripId),
                          'Could not cancel trip.'),
                  child: const Text('Cancel'),
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          SizedBox(
            width: double.infinity,
            child: TextButton.icon(
              key: const Key('trip_chat_open_button'),
              icon: const Icon(Icons.chat_bubble_outline, size: 18),
              label: const Text('Chat with customer'),
              onPressed: () {
                final myId = widget.driverId.isNotEmpty
                    ? widget.driverId
                    : (trip.driver?.driverId ?? '');
                Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) => TripChatScreen(
                      tripId: trip.tripId,
                      currentUid: myId,
                      senderRole: 'driver',
                      peerName: 'Customer',
                      peerPhone: trip.pickupPhone,
                      hidePhones: _hidePhones,
                    ),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}
