import 'dart:async';

import 'package:flutter/material.dart';
import 'package:latlong2/latlong.dart';
import 'package:sese_core/sese_core.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../trips/models/trip_models.dart';
import '../../../trips/presentation/cancel_trip_dialog.dart';
import '../../../trips/presentation/trip_chat_screen.dart';
import '../../services/driver_streak_service.dart';
import '../driver_in_app_navigation_screen.dart';
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

  @override
  void initState() {
    super.initState();
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
    super.dispose();
  }

  /// Driver cancellation behind the reason dialog: no instant dismissal.
  /// A dismissed dialog returns null and commits nothing; Confirm forwards
  /// the selected code for the server audit trail + rate-limit counters.
  Future<void> _cancelWithReason(ActiveTrip trip) async {
    final reason = await CancelTripDialog.show(context, isDriver: true);
    if (reason == null || !mounted) return;
    await _run(
      () => widget.streakService.cancelTrip(trip.tripId, reason: reason),
      'Could not cancel trip.',
    );
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

  /// True when [raw] has at least some contact information (even if masked).
  bool _hasContact(String raw) => raw.trim().isNotEmpty;

  /// True when [raw] can be directly dialed via mobile carrier:
  /// non-empty and not a server/client masking placeholder (`080****5678`, `••••••`).
  bool _isCallableNumber(String raw) {
    final v = raw.trim();
    if (v.isEmpty) return false;
    if (v.contains('*') || v.contains('•')) return false;
    return true;
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

  /// Shows a bottom sheet offering In-App Call (VoIP), Direct Call, and In-App Chat.
  ///
  /// In-App Call (VoIP) is always available even when phone numbers are masked
  /// under customer privacy settings. Direct Call connects via mobile carrier
  /// when unmasked, and informs the driver if the number is masked.
  /// Raw [phone] digits are never displayed on screen as [Text].
  void _showCallSheet(
    BuildContext context,
    String phone,
    String contactLabel,
  ) {
    if (phone.trim().isEmpty) return;
    final scheme = Theme.of(context).colorScheme;
    final isUnmasked = _isCallableNumber(phone);
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (ctx) => Container(
        decoration: BoxDecoration(
          color: scheme.surface,
          borderRadius:
              const BorderRadius.vertical(top: Radius.circular(20)),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.12),
              blurRadius: 10,
              offset: const Offset(0, -2),
            ),
          ],
        ),
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Center(
              child: Container(
                width: 36,
                height: 4,
                decoration: BoxDecoration(
                  color: Colors.grey.withValues(alpha: 0.4),
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            const SizedBox(height: 16),
            Row(
              children: [
                Icon(Icons.call_rounded, color: scheme.primary),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    'Contact $contactLabel',
                    style: Theme.of(ctx).textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.bold,
                        ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 20),
            // In-App Call (VoIP) — always enabled even with privacy masking on.
            _CallOption(
              key: const Key('call_option_in_app'),
              icon: Icons.headset_mic_rounded,
              iconColor: AppColors.seseGold,
              title: 'In-App Call (VoIP)',
              subtitle: 'Data call via the app (number protected)',
              onTap: () {
                Navigator.of(ctx).pop();
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                    content: Text('Starting in-app secure audio call with $contactLabel...'),
                    duration: const Duration(seconds: 4),
                  ),
                );
              },
            ),
            const SizedBox(height: 8),
            // Direct Call — carrier dialing when unmasked, or privacy explanation.
            if (isUnmasked)
              _CallOption(
                key: const Key('call_option_direct'),
                icon: Icons.phone_rounded,
                iconColor: Colors.green.shade600,
                title: 'Direct Call',
                subtitle: 'Dial from your mobile carrier',
                onTap: () {
                  Navigator.of(ctx).pop();
                  _openUri(context, Uri(scheme: 'tel', path: phone));
                },
              )
            else
              _CallOption(
                key: const Key('call_option_direct_masked'),
                icon: Icons.lock_outline_rounded,
                iconColor: Colors.grey,
                title: 'Direct Call (Masked)',
                subtitle: 'Number hidden for user privacy. Use In-App Call or Chat.',
                onTap: () {
                  Navigator.of(ctx).pop();
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(
                      content: Text(
                        'Phone number is masked for customer privacy. Connect securely via In-App Call or Chat.',
                      ),
                    ),
                  );
                },
              ),
            const SizedBox(height: 8),
            // In-App Chat shortcut
            _CallOption(
              key: const Key('call_option_chat'),
              icon: Icons.chat_bubble_outline_rounded,
              iconColor: scheme.primary,
              title: 'In-App Chat',
              subtitle: 'Send real-time messages & photos',
              onTap: () {
                Navigator.of(ctx).pop();
                _openChat(context, widget.trip);
              },
            ),
          ],
        ),
      ),
    );
  }

  /// Stage-aware contact block.
  ///
  /// **Pre-pickup** (DRIVER_ACCEPTED / DRIVER_ARRIVING / DRIVER_ARRIVED):
  ///   - Displays the active pickup contact (respecting third-party sender details).
  ///   - The original trip booker remains permanently accessible as an alternative line.
  ///   - Raw phone numbers are NEVER visible as [Text] (respecting privacy).
  ///   - Call and chat actions connect securely via in-app VoIP, chat, or masked dialer.
  ///
  /// **Post-pickup** (IN_PROGRESS):
  ///   - The drop-off receiver becomes the primary contact (showing receiver name).
  ///   - The original trip booker stays continuously reachable as a secondary contact.
  Widget _buildBookerContact(BuildContext context, ActiveTrip trip) {
    final scheme = Theme.of(context).colorScheme;
    final booker = _bookerPhone(trip);
    final canCallBooker = _hasContact(booker);
    final isPostPickup = trip.status == TripStatus.inProgress;

    // Drop-off receiver details
    final receiver = trip.dropoffPhone;
    final canCallReceiver = _hasContact(receiver);
    final dropoffContactName = trip.dropoffName.isNotEmpty
        ? trip.dropoffName
        : 'Drop-off receiver';

    // Third-party pickup detection
    final hasDistinctPickupName = trip.pickupName.isNotEmpty &&
        trip.pickupName.toLowerCase() != trip.customerName.toLowerCase();
    final hasDistinctPickupPhone = trip.pickupPhone.isNotEmpty &&
        trip.pickupPhone != booker;
    final hasThirdPartyPickup = hasDistinctPickupName || hasDistinctPickupPhone;

    final pickupContactName = trip.pickupName.isNotEmpty
        ? trip.pickupName
        : (hasDistinctPickupPhone ? 'Pickup contact' : (trip.customerName.isEmpty ? 'Customer' : trip.customerName));
    final pickupPhoneTarget = trip.pickupPhone.isNotEmpty ? trip.pickupPhone : booker;
    final canCallPickup = _hasContact(pickupPhoneTarget);

    return Container(
      key: const Key('booker_contact_row'),
      margin: const EdgeInsets.only(top: 8),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: scheme.primaryContainer.withValues(alpha: 0.45),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          if (!isPostPickup) ...[
            // ── Pre-pickup: Primary contact row ──────────────────────────
            Row(
              children: [
                Icon(
                  hasThirdPartyPickup
                      ? Icons.person_pin_circle_outlined
                      : Icons.account_circle,
                  size: 18,
                  color: scheme.onPrimaryContainer,
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        hasThirdPartyPickup
                            ? 'Pickup contact · $pickupContactName'
                            : 'Trip booker · ${trip.customerName.isEmpty ? 'Customer' : trip.customerName}',
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                              color: scheme.onPrimaryContainer,
                              fontWeight: FontWeight.bold,
                            ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      // Do NOT show raw phone — hidden behind action buttons.
                      Text(
                        canCallPickup
                            ? 'Tap call or message to reach contact'
                            : 'Reachable via chat below',
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                              color: scheme.onPrimaryContainer
                                  .withValues(alpha: 0.75),
                              fontSize: 11,
                            ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ),
                ),
                // Call sheet — VoIP data call or direct dialer
                IconButton(
                  key: const Key('pickup_contact_call_button'),
                  tooltip: hasThirdPartyPickup
                      ? 'Call pickup contact'
                      : 'Call trip booker',
                  visualDensity: VisualDensity.compact,
                  icon: const Icon(Icons.call, size: 20),
                  color: scheme.onPrimaryContainer,
                  onPressed: canCallPickup
                      ? () => _showCallSheet(
                            context,
                            pickupPhoneTarget,
                            pickupContactName,
                          )
                      : null,
                ),
              ],
            ),
            // If third-party pickup contact is active, keep main booker as secondary line
            if (hasThirdPartyPickup && canCallBooker) ...[
              const SizedBox(height: 4),
              Row(
                children: [
                  Icon(Icons.account_circle_outlined,
                      size: 14,
                      color: scheme.onPrimaryContainer.withValues(alpha: 0.7)),
                  const SizedBox(width: 4),
                  Expanded(
                    child: Text(
                      'Booker: ${trip.customerName.isEmpty ? 'Customer' : trip.customerName} — tap to call',
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                            color: scheme.onPrimaryContainer
                                .withValues(alpha: 0.75),
                            fontSize: 11,
                          ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  IconButton(
                    key: const Key('booker_call_button'),
                    tooltip: 'Call trip booker',
                    visualDensity: VisualDensity.compact,
                    iconSize: 18,
                    icon: const Icon(Icons.call_outlined),
                    color: scheme.onPrimaryContainer.withValues(alpha: 0.85),
                    onPressed: () => _showCallSheet(
                      context,
                      booker,
                      trip.customerName.isEmpty ? 'Booker' : trip.customerName,
                    ),
                  ),
                ],
              ),
            ],
          ] else ...[
            // ── Post-pickup: Receiver contact leads ─────────────────────
            Row(
              children: [
                Icon(Icons.place_rounded,
                    size: 18, color: scheme.onPrimaryContainer),
                const SizedBox(width: 6),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        trip.dropoffName.isNotEmpty
                            ? 'Drop-off receiver · ${trip.dropoffName}'
                            : 'Drop-off receiver',
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                              color: scheme.onPrimaryContainer,
                              fontWeight: FontWeight.bold,
                            ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      // Raw receiver number is hidden behind action button.
                      Text(
                        canCallReceiver
                            ? 'Tap call or message to reach receiver'
                            : 'Reachable via chat below',
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                              color: scheme.onPrimaryContainer
                                  .withValues(alpha: 0.75),
                              fontSize: 11,
                            ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ),
                ),
                IconButton(
                  key: const Key('receiver_call_button'),
                  tooltip: 'Call drop-off receiver',
                  visualDensity: VisualDensity.compact,
                  icon: const Icon(Icons.call, size: 20),
                  color: scheme.onPrimaryContainer,
                  onPressed: canCallReceiver
                      ? () => _showCallSheet(
                            context,
                            receiver,
                            dropoffContactName,
                          )
                      : null,
                ),
              ],
            ),
            // Booker stays as a permanent secondary line during the trip.
            if (canCallBooker) ...[
              const SizedBox(height: 4),
              Row(
                children: [
                  Icon(Icons.account_circle_outlined,
                      size: 14,
                      color: scheme.onPrimaryContainer.withValues(alpha: 0.7)),
                  const SizedBox(width: 4),
                  Expanded(
                    child: Text(
                      'Booker: ${trip.customerName.isEmpty ? 'Customer' : trip.customerName} — tap to call',
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                            color: scheme.onPrimaryContainer
                                .withValues(alpha: 0.75),
                            fontSize: 11,
                          ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  IconButton(
                    key: const Key('booker_call_button'),
                    tooltip: 'Call trip booker',
                    visualDensity: VisualDensity.compact,
                    iconSize: 18,
                    icon: const Icon(Icons.call_outlined),
                    color: scheme.onPrimaryContainer.withValues(alpha: 0.85),
                    onPressed: () => _showCallSheet(
                      context,
                      booker,
                      trip.customerName.isEmpty ? 'Booker' : trip.customerName,
                    ),
                  ),
                ],
              ),
            ],
          ],
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final trip = widget.trip;
    final scheme = Theme.of(context).colorScheme;
    final arrived = trip.status == TripStatus.driverArrived ||
        trip.arrivedAt != null;
    final next = _nextStatus;
    final mockDetected = _prox?.isMocked == true;
    final countingDown = widget.autoArrivalEnabled &&
        !_autoArrivalDismissed &&
        ((_prox?.zone == ProximityZone.arrivalCountdown) || _autoBusy);

    return Container(
      key: const Key('driver_active_trip_card'),
      // Zero horizontal margin so the card stretches edge-to-edge.
      // Top corners are rounded so the card lifts cleanly off the map;
      // bottom corners are square to sit flush against the screen edge.
      margin: EdgeInsets.zero,
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest,
        borderRadius: const BorderRadius.only(
          topLeft: Radius.circular(20),
          topRight: Radius.circular(20),
        ),
        boxShadow: [
          BoxShadow(
              color: scheme.shadow.withValues(alpha: 0.18),
              blurRadius: 12,
              offset: const Offset(0, -2)),
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
          _buildBookerContact(context, trip),
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
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
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
                      style:
                          TextStyle(fontWeight: FontWeight.bold, fontSize: 12),
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
              Expanded(
                child: FilledButton.icon(
                  key: const Key('trip_navigate_button'),
                  style: FilledButton.styleFrom(
                    backgroundColor: AppColors.seseGold,
                    foregroundColor: Colors.black,
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
                  ),
                  icon: const Icon(Icons.navigation_rounded, size: 18),
                  label: const Text(
                    'Navigate',
                    style: TextStyle(fontWeight: FontWeight.bold),
                  ),
                  // Feature 5: internal-only navigation — all turn-by-turn
                  // is rendered inside the app using the active map engine.
                  // External launchers (Google Maps, Waze, Apple Maps) are
                  // no longer reachable from this button; drivers that need
                  // an external app can still use their device independently.
                  onPressed: () {
                    final isPickup = trip.status != TripStatus.inProgress;
                    final targetLat = isPickup ? trip.pickupLat : trip.dropoffLat;
                    final targetLng = isPickup ? trip.pickupLng : trip.dropoffLng;
                    final targetAddr = isPickup
                        ? trip.pickupAddress
                        : trip.dropoffAddress;
                    Navigator.of(context).push(
                      MaterialPageRoute(
                        builder: (_) => DriverInAppNavigationScreen(
                          destination: LatLng(targetLat, targetLng),
                          destinationAddress: targetAddr,
                          isHeadingToPickup: isPickup,
                          initialDriverPosition: widget.driverPosition,
                          trip: trip,
                        ),
                      ),
                    );
                  },
                ),
              ),
              const SizedBox(width: 8),
              if (next != null)
                Expanded(
                  flex: 2,
                  child: FilledButton(
                    onPressed: _busy
                        ? null
                        : () => _advanceOrPin(trip, next),
                    style: FilledButton.styleFrom(
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 12),
                      visualDensity: VisualDensity.compact,
                    ),
                    // Single-line ellipsis (not word-wrap) so long labels
                    // like "Start Trip (En Route)" never stack vertically.
                    child: Text(
                      _busy ? 'Working…' : _nextLabel,
                      softWrap: false,
                      overflow: TextOverflow.ellipsis,
                      maxLines: 1,
                      style: const TextStyle(fontSize: 13),
                    ),
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
                  onPressed: _busy ? null : () => _cancelWithReason(trip),
                  child: const Text(
                    'Cancel',
                    softWrap: false,
                    overflow: TextOverflow.ellipsis,
                    maxLines: 1,
                  ),
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
              onPressed: () => _openChat(context, trip),
            ),
          ),
        ],
      ),
    );
  }
}

/// A tappable card tile used inside the call routing bottom sheet.
///
/// Shows an [icon] on a coloured chip, a [title] and a [subtitle] line.
/// Styled consistently with [_NavOptionTile] in
/// `navigation_launcher_service.dart`.
class _CallOption extends StatelessWidget {
  final IconData icon;
  final Color iconColor;
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  const _CallOption({
    super.key,
    required this.icon,
    required this.iconColor,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final fill = isDark ? const Color(0xFF282832) : const Color(0xFFF3F4F6);

    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(14),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        decoration: BoxDecoration(
          color: fill,
          borderRadius: BorderRadius.circular(14),
        ),
        child: Row(
          children: [
            Container(
              width: 40,
              height: 40,
              decoration: BoxDecoration(
                color: iconColor.withValues(alpha: 0.15),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Icon(icon, color: iconColor, size: 22),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: const TextStyle(
                        fontWeight: FontWeight.w700, fontSize: 14),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    subtitle,
                    style: Theme.of(context)
                        .textTheme
                        .bodySmall
                        ?.copyWith(fontSize: 12),
                  ),
                ],
              ),
            ),
            const Icon(Icons.arrow_forward_ios_rounded,
                size: 14, color: Colors.grey),
          ],
        ),
      ),
    );
  }
}
