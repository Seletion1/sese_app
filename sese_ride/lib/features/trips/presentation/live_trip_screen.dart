import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:latlong2/latlong.dart';
import 'package:sese_core/sese_core.dart';

import '../../../core/services/call_service.dart';
import '../../../widgets/map_provider.dart';
import '../../customer/services/location_service.dart';
import '../models/bid_models.dart';
import '../models/trip_models.dart';
import '../services/trip_service.dart';
import 'cancel_trip_dialog.dart';
import 'mutual_profile_modal.dart';
import 'trip_chat_screen.dart';
import 'trip_rating_dialog.dart';
import '../services/trip_rating_service.dart';
import '../../customer/presentation/customer_dispatch_screen.dart';

/// Navigates back to the booking review screen or pops if already stacked.
///
/// If [CustomerDispatchScreen] pushed this screen, popping restores the exact
/// in-memory state (controllers, addresses, vehicle choices, and payment modes).
/// If opened directly (app relaunch / notification), reconstructs [CustomerDispatchScreen]
/// seeded with all details from [trip] on step 2 (Review & Confirm).
void _navigateBackToBookingOrPop(
  BuildContext context,
  ActiveTrip trip, {
  bool isPushedFromDispatch = false,
}) {
  if (isPushedFromDispatch && Navigator.of(context).canPop()) {
    Navigator.of(context).pop('cancelled');
    return;
  }
  final pickupLoc = trip.pickupLat != 0 && trip.pickupLng != 0
      ? LatLng(trip.pickupLat, trip.pickupLng)
      : null;
  final dropoffLoc = trip.dropoffLat != 0 && trip.dropoffLng != 0
      ? LatLng(trip.dropoffLat, trip.dropoffLng)
      : null;

  final isRide = trip.serviceType == 'ride';
  final isReceive = trip.serviceType == 'receive_item';
  final category = trip.vehicleCategory.isNotEmpty
      ? trip.vehicleCategory
      : (trip.tierIds.isNotEmpty ? trip.tierIds.first : null);

  Navigator.of(context).pushReplacement(
    MaterialPageRoute(
      builder: (_) => CustomerDispatchScreen(
        initialModeIndex: isRide ? 1 : 0,
        isReceiving: isReceive,
        initialPickupAddress:
            trip.pickupAddress.isNotEmpty ? trip.pickupAddress : null,
        initialPickupLatLng: pickupLoc,
        initialDropoffAddress:
            trip.dropoffAddress.isNotEmpty ? trip.dropoffAddress : null,
        initialDropoffLatLng: dropoffLoc,
        initialPickupPhone:
            trip.pickupPhone.isNotEmpty ? trip.pickupPhone : null,
        initialDropoffPhone:
            trip.dropoffPhone.isNotEmpty ? trip.dropoffPhone : null,
        initialPickupName:
            trip.pickupName.isNotEmpty ? trip.pickupName : null,
        initialDropoffName:
            trip.dropoffName.isNotEmpty ? trip.dropoffName : null,
        initialPaymentMode:
            trip.paymentMode.isNotEmpty ? trip.paymentMode : null,
        initialCategory: category,
        initialStep: 2,
      ),
    ),
  );
}

/// Live dispatch tracker for one trip.
///
/// Fully server-driven: renders snapshots from [TripRepository.tripStream]
/// (status banner, driver sheet, live OpenStreetMap driver marker). The backend owns
/// every transition — matchmaking, ping timeouts, re-broadcasts — so the
/// customer may close the app and restore this screen later from Trips.
class LiveTripScreen extends StatelessWidget {
  final String tripId;
  final TripRepository repository;
  final bool isPushedFromDispatch;

  const LiveTripScreen({
    super.key,
    required this.tripId,
    required this.repository,
    this.isPushedFromDispatch = false,
  });

  void _handleBackPress(BuildContext context) {
    if (isPushedFromDispatch && Navigator.of(context).canPop()) {
      Navigator.of(context).pop('minimize_to_home');
    } else if (Navigator.of(context).canPop()) {
      Navigator.of(context).pop();
    }
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        _handleBackPress(context);
      },
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Live Trip'),
          leading: IconButton(
            icon: const Icon(Icons.arrow_back),
            onPressed: () => _handleBackPress(context),
          ),
        ),
        body: StreamBuilder<ActiveTrip?>(
          stream: repository.tripStream(tripId),
          builder: (context, snapshot) {
            if (snapshot.connectionState == ConnectionState.waiting && !snapshot.hasData) {
              return const SeseDetailSkeleton();
            }
            if (snapshot.hasError) {
              return _MessageState(
                icon: Icons.error_outline,
                title: 'Could not load this trip',
                body: 'Check your connection and try again.',
                onClose: () => _handleBackPress(context),
              );
            }
            final trip = snapshot.data;
            if (trip == null) {
              return _MessageState(
                icon: Icons.search_off,
                title: 'Trip no longer available',
                body: 'It may have been cancelled or removed.',
                onClose: () => _handleBackPress(context),
              );
            }
            if (trip.status == TripStatus.completed) {
              return _CompletedTripView(trip: trip);
            }
            if (trip.status == TripStatus.cancelled ||
                trip.status == TripStatus.cancelledWaitingCashSettlement) {
              final isCashWaiting =
                  trip.status == TripStatus.cancelledWaitingCashSettlement;
              final fee = trip.pendingCashFee > 0
                  ? trip.pendingCashFee
                  : trip.paidWaitingFee;
              final feeText = fee > 0 ? '₦${fee.toStringAsFixed(0)}' : '';
              final reason = isCashWaiting
                  ? (feeText.isNotEmpty
                      ? 'Trip cancelled during waiting period. Please pay $feeText cash directly to your driver.'
                      : 'Trip cancelled during waiting period. Please pay the cash waiting fee to your driver.')
                  : (trip.cancellationSource == 'driver'
                      ? 'This trip was cancelled by the driver.'
                      : trip.cancellationSource == 'customer'
                          ? 'You cancelled this trip.'
                          : 'This request is no longer active.');
              return _MessageState(
                icon: isCashWaiting
                    ? Icons.payments_outlined
                    : Icons.cancel_outlined,
                iconColor: isCashWaiting
                    ? const Color(0xFFFFB800)
                    : Colors.redAccent,
                title: isCashWaiting ? 'Cash Payment Due' : 'Trip cancelled',
                body: reason,
                onClose: () => _navigateBackToBookingOrPop(
                  context,
                  trip,
                  isPushedFromDispatch: isPushedFromDispatch,
                ),
              );
            }
            // Special state: auto-reassignment exhausted — prompt fare boost.
            if (trip.status == TripStatus.needsCustomerAction) {
              return _NeedsActionBody(
                trip: trip,
                repository: repository,
                isPushedFromDispatch: isPushedFromDispatch,
              );
            }
            return _LiveTripBody(
              trip: trip,
              repository: repository,
              isPushedFromDispatch: isPushedFromDispatch,
            );
          },
        ),
      ),
    );
  }
}

// ── NeedsCustomerAction prompt ────────────────────────────────────────────────

/// Shown when auto-reassignment has failed 3 times. The customer must raise
/// the fare (or cancel) to get a driver.
class _NeedsActionBody extends StatefulWidget {
  final ActiveTrip trip;
  final TripRepository repository;
  final bool isPushedFromDispatch;

  const _NeedsActionBody({
    required this.trip,
    required this.repository,
    this.isPushedFromDispatch = false,
  });

  @override
  State<_NeedsActionBody> createState() => _NeedsActionBodyState();
}

class _NeedsActionBodyState extends State<_NeedsActionBody> {
  final _controller = TextEditingController();
  bool _loading = false;
  bool _keepSearchingLoading = false;
  bool _showBoostFields = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    // Pre-fill with current fare so the customer can see what to beat.
    final current = widget.trip.fareAmount;
    if (current > 0) {
      _controller.text = current.toStringAsFixed(0);
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _keepSearching() async {
    setState(() {
      _keepSearchingLoading = true;
      _error = null;
    });
    try {
      await widget.repository.keepSearchingTrip(widget.trip.tripId);
      // Stream updates to SEARCHING_DRIVER automatically.
    } on TripException catch (e) {
      if (mounted) setState(() => _error = e.userMessage);
    } catch (e) {
      debugPrint('LiveTripScreen keepSearching error: $e');
      if (mounted) {
        setState(() =>
            _error = 'Unable to search for drivers right now. Please try again.');
      }
    } finally {
      if (mounted) setState(() => _keepSearchingLoading = false);
    }
  }

  Future<void> _boostFare() async {
    final val = double.tryParse(_controller.text.replaceAll(',', ''));
    final maxAllowedFare = _calculateMaxAllowedFare(widget.trip);
    if (val == null || val <= widget.trip.fareAmount) {
      setState(
        () => _error =
            'Enter an amount higher than the current fare (${widget.trip.fareFormatted})',
      );
      return;
    }
    if (val > maxAllowedFare) {
      final maxFormatted = '₦${maxAllowedFare.toInt().toString().replaceAllMapped(RegExp(r'(\d{1,3})(?=(\d{3})+(?!\d))'), (m) => '${m[1]},')}';
      setState(
        () => _error =
            'Offer boost cannot exceed 100% above original base fare (max $maxFormatted).',
      );
      return;
    }
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      await widget.repository.increaseTripFare(widget.trip.tripId, val);
      // Backend resets to SEARCHING_DRIVER — the StreamBuilder will rebuild.
    } on TripException catch (e) {
      if (mounted) setState(() => _error = e.userMessage);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _cancel() async {
    // Reason-first: the dialog returns null on dismiss, committing nothing.
    final result =
        await CancelTripDialog.show(context, isDriver: false);
    if (result == null || !mounted) return;
    try {
      await widget.repository.cancelTrip(
        widget.trip.tripId,
        reason: result.reason,
        useCashSettlement: result.useCashSettlement,
      );
      // Show optional post-cancel feedback sheet before navigating away.
      if (mounted) {
        await CancelTripDialog.showPostCancelFeedback(
          context,
          tripId: widget.trip.tripId,
          userId: widget.trip.customerId,
          role: 'customer',
          isDriver: false,
        );
      }
      if (mounted) {
        _navigateBackToBookingOrPop(
          context,
          widget.trip,
          isPushedFromDispatch: widget.isPushedFromDispatch,
        );
      }
    } on TripException catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(e.userMessage)));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final cardBg = isDark ? const Color(0xFF252530) : Colors.white;
    final borderColor = isDark ? const Color(0xFF3A3A46) : Colors.grey.shade300;

    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Container(
          padding: const EdgeInsets.all(24),
          decoration: BoxDecoration(
            color: cardBg,
            borderRadius: BorderRadius.circular(20),
            border: Border.all(color: borderColor),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: isDark ? 0.3 : 0.08),
                blurRadius: 16,
                offset: const Offset(0, 6),
              ),
            ],
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 64,
                height: 64,
                decoration: BoxDecoration(
                  color: const Color(0xFFF59E0B).withValues(alpha: 0.15),
                  shape: BoxShape.circle,
                ),
                child: const Icon(
                  Icons.access_time_filled_rounded,
                  size: 36,
                  color: Color(0xFFF59E0B),
                ),
              ),
              const SizedBox(height: 16),
              Text(
                'Do you still want to order?',
                style: Theme.of(context).textTheme.titleLarge?.copyWith(
                      fontWeight: FontWeight.bold,
                      color: isDark ? Colors.white : Colors.black87,
                    ),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 8),
              Text(
                'All drivers are busy right now. Keep searching or wait?',
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 14,
                  color: isDark ? Colors.grey.shade400 : Colors.grey.shade700,
                ),
              ),
              if (_error != null) ...[
                const SizedBox(height: 12),
                Text(
                  _error!,
                  style: const TextStyle(color: Colors.red, fontSize: 13),
                  textAlign: TextAlign.center,
                ),
              ],
              const SizedBox(height: 24),
              // Action 1: Keep Searching
              SizedBox(
                width: double.infinity,
                child: FilledButton.icon(
                  icon: _keepSearchingLoading
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: Colors.black87,
                          ),
                        )
                      : const Icon(Icons.search_rounded, color: Colors.black87),
                  label: Text(
                    _keepSearchingLoading ? 'Searching...' : 'Keep Searching',
                    style: const TextStyle(
                      color: Colors.black87,
                      fontWeight: FontWeight.bold,
                      fontSize: 15,
                    ),
                  ),
                  onPressed: (_keepSearchingLoading || _loading)
                      ? null
                      : _keepSearching,
                  style: FilledButton.styleFrom(
                    backgroundColor: const Color(0xFFF59E0B),
                    minimumSize: const Size.fromHeight(50),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 12),
              // Action 2: Boost Fare (Toggleable)
              if (!_showBoostFields)
                SizedBox(
                  width: double.infinity,
                  child: OutlinedButton.icon(
                    icon: const Icon(Icons.bolt, color: Color(0xFFF59E0B)),
                    label: const Text('Boost Offer Fare (Optional)'),
                    onPressed: () => setState(() => _showBoostFields = true),
                    style: OutlinedButton.styleFrom(
                      minimumSize: const Size.fromHeight(46),
                      side: BorderSide(color: borderColor),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                    ),
                  ),
                )
              else ...[
                Wrap(
                  alignment: WrapAlignment.center,
                  spacing: 8,
                  children: [5, 10, 20].map((pct) {
                    final boosted = _calculateBoostedFareAmount(widget.trip, pct);
                    return OutlinedButton(
                      onPressed: _loading
                          ? null
                          : () => setState(() {
                                _controller.text = boosted.toString();
                                _error = null;
                              }),
                      child: Text('+$pct%'),
                    );
                  }).toList(),
                ),
                const SizedBox(height: 8),
                TextField(
                  controller: _controller,
                  keyboardType:
                      const TextInputType.numberWithOptions(decimal: true),
                  inputFormatters: [
                    FilteringTextInputFormatter.allow(RegExp(r'[\d,.]')),
                  ],
                  decoration: InputDecoration(
                    labelText: 'New fare amount',
                    prefixText: '₦ ',
                    errorText: _error,
                    helperText:
                        'Current: ${widget.trip.fareFormatted.isNotEmpty ? widget.trip.fareFormatted : "₦${widget.trip.fareAmount.toStringAsFixed(0)}"}',
                  ),
                ),
                const SizedBox(height: 10),
                SizedBox(
                  width: double.infinity,
                  child: FilledButton.icon(
                    icon: _loading
                        ? const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: Colors.white,
                            ),
                          )
                        : const Icon(Icons.bolt),
                    label:
                        Text(_loading ? 'Boosting...' : 'Submit Boost & Search'),
                    onPressed: _loading ? null : _boostFare,
                    style: FilledButton.styleFrom(
                      minimumSize: const Size.fromHeight(46),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                    ),
                  ),
                ),
              ],
              const SizedBox(height: 12),
              // Action 3: Cancel & Return to Booking
              SizedBox(
                width: double.infinity,
                child: TextButton.icon(
                  icon: const Icon(Icons.close, color: Colors.redAccent),
                  label: const Text(
                    'Cancel & Return to Booking',
                    style: TextStyle(
                      color: Colors.redAccent,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  onPressed: _cancel,
                  style: TextButton.styleFrom(
                    minimumSize: const Size.fromHeight(44),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ── Active (non-terminal) tracking view ───────────────────────────────────────

/// Represents a live nearby driver within the 15km coverage circle.
class _NearbyDriverMarker {
  final String id;
  final LatLng position;
  final String category;

  const _NearbyDriverMarker({
    required this.id,
    required this.position,
    required this.category,
  });
}

/// Active (non-terminal) tracking view: edge-to-edge animated map +
/// draggable bottom sheet with status, offer fare, and privacy-protected cancellation.
class _LiveTripBody extends StatefulWidget {
  final ActiveTrip trip;
  final TripRepository repository;
  final bool isPushedFromDispatch;

  const _LiveTripBody({
    required this.trip,
    required this.repository,
    this.isPushedFromDispatch = false,
  });

  @override
  State<_LiveTripBody> createState() => _LiveTripBodyState();
}

class _LiveTripBodyState extends State<_LiveTripBody> {
  final SeSeMapController _mapController = SeSeMapController();

  /// Road-network route (OSRM / Google Directions).
  List<LatLng> _routePoints = [];

  /// Real-time assigned driver position fix from `driver_status/{driverId}` stream.
  LatLng? _assignedDriverFix;
  StreamSubscription? _assignedDriverSub;

  /// Cache for distance-throttled polyline calculation.
  LatLng? _lastRoutedOrigin;
  TripStatus? _lastTripStatus;

  /// Dynamic map camera animation loop timer.
  Timer? _cameraLoopTimer;
  Timer? _cameraLoopInitTimer;

  /// Dynamic dispatch tuning & map camera animation settings from Firestore `system_settings/dispatch`.
  DispatchTuning _dispatchTuning = const DispatchTuning();
  StreamSubscription? _dispatchTuningSub;

  /// Nearby drivers within the active dispatch stage radius belonging to the trip's vehicle category.
  List<_NearbyDriverMarker> _nearbyDrivers = [];
  StreamSubscription? _nearbyDriversSub;

  /// Resolves the driver search radius (in kilometers) for the active dispatch stage.
  double get _activeStageRadiusKm =>
      _dispatchTuning.radiusForTier(widget.trip.dispatchTier);

  LatLng? get _effectiveDriverPos {
    if (_assignedDriverFix != null) return _assignedDriverFix;
    if (widget.trip.driverLat != null && widget.trip.driverLng != null) {
      return LatLng(widget.trip.driverLat!, widget.trip.driverLng!);
    }
    return null;
  }

  bool get _isDriverEnRouteToPickup =>
      widget.trip.status == TripStatus.driverAccepted ||
      widget.trip.status == TripStatus.driverArriving ||
      widget.trip.status == TripStatus.driverArrived;

  LatLng get _currentRouteOrigin {
    if (_isDriverEnRouteToPickup) {
      return _effectiveDriverPos ?? _pickup;
    }
    return _pickup;
  }

  LatLng get _currentRouteDest {
    if (_isDriverEnRouteToPickup) {
      return _pickup;
    }
    return _dropoff;
  }

  void _initAssignedDriverListener() {
    final driverId = widget.trip.driver?.driverId ?? '';
    if (driverId.isEmpty) {
      _assignedDriverSub?.cancel();
      _assignedDriverSub = null;
      _assignedDriverFix = null;
      return;
    }
    _assignedDriverSub?.cancel();
    try {
      _assignedDriverSub = FirebaseFirestore.instance
          .collection('driver_status')
          .doc(driverId)
          .snapshots()
          .listen(
        (doc) {
          if (!mounted || !doc.exists || doc.data() == null) return;
          final data = doc.data()!;
          final fix = data['lastFix'] as Map<String, dynamic>?;
          final lat = safeNum(fix?['latitude'])?.toDouble() ??
              safeNum(data['lat'])?.toDouble();
          final lng = safeNum(fix?['longitude'])?.toDouble() ??
              safeNum(data['lng'])?.toDouble();
          if (lat == null || lng == null) return;
          final newFix = LatLng(lat, lng);

          final prevDriverPos = _assignedDriverFix;
          setState(() => _assignedDriverFix = newFix);

          if (_isDriverEnRouteToPickup) {
            final distanceMoved = prevDriverPos == null
                ? 999.0
                : const Distance().as(LengthUnit.Meter, prevDriverPos, newFix);
            if (distanceMoved > 15) {
              _loadRoadRoute();
            }
          }
        },
        onError: (err) {
          debugPrint('LiveTripScreen assignedDriver stream error: $err');
        },
      );
    } catch (e) {
      debugPrint('LiveTripScreen initAssignedDriverListener error: $e');
    }
  }

  @override
  void initState() {
    super.initState();
    _initAssignedDriverListener();
    _fitRoute();
    _loadRoadRoute();
    _initDispatchTuning();
    _initNearbyDrivers();
    if (_isSearching) {
      // Delay slightly after initial layout so the camera loop smoothly engages
      _cameraLoopInitTimer = Timer(const Duration(milliseconds: 1500), () {
        if (mounted && _isSearching) {
          _startCameraLoop();
        }
      });
    }
  }

  @override
  void didUpdateWidget(covariant _LiveTripBody oldWidget) {
    super.didUpdateWidget(oldWidget);
    final oldDriverId = oldWidget.trip.driver?.driverId ?? '';
    final newDriverId = widget.trip.driver?.driverId ?? '';
    if (oldDriverId != newDriverId) {
      _initAssignedDriverListener();
    }

    final statusChanged = oldWidget.trip.status != widget.trip.status;
    final coordsChanged = oldWidget.trip.pickupLat != widget.trip.pickupLat ||
        oldWidget.trip.pickupLng != widget.trip.pickupLng ||
        oldWidget.trip.dropoffLat != widget.trip.dropoffLat ||
        oldWidget.trip.dropoffLng != widget.trip.dropoffLng ||
        oldWidget.trip.driverLat != widget.trip.driverLat ||
        oldWidget.trip.driverLng != widget.trip.driverLng;

    if (coordsChanged || statusChanged) {
      _fitRoute();

      bool driverMovedSignificantly = false;
      if (_isDriverEnRouteToPickup && _effectiveDriverPos != null) {
        final lastOrigin = _lastRoutedOrigin;
        if (lastOrigin == null) {
          driverMovedSignificantly = true;
        } else {
          final dist = const Distance()
              .as(LengthUnit.Meter, lastOrigin, _effectiveDriverPos!);
          if (dist > 15) driverMovedSignificantly = true;
        }
      }

      if (statusChanged || driverMovedSignificantly || _lastTripStatus != widget.trip.status) {
        _loadRoadRoute();
      }
      _initNearbyDrivers();
    }

    // Refresh nearby drivers if the dispatch tier / stage changes
    if (oldWidget.trip.dispatchTier != widget.trip.dispatchTier) {
      _initNearbyDrivers();
    }

    // Toggle camera animation loop when searching state transitions
    if (_isSearching && _cameraLoopTimer == null) {
      _startCameraLoop();
    } else if (!_isSearching && _cameraLoopTimer != null) {
      _stopCameraLoop();
      _fitRoute();
    }
  }

  @override
  void dispose() {
    _cameraLoopInitTimer?.cancel();
    _stopCameraLoop();
    _nearbyDriversSub?.cancel();
    _dispatchTuningSub?.cancel();
    _assignedDriverSub?.cancel();
    super.dispose();
  }

  void _initDispatchTuning() {
    _dispatchTuningSub?.cancel();
    try {
      _dispatchTuningSub = FirebaseFirestore.instance
          .collection('system_settings')
          .doc('dispatch')
          .snapshots()
          .listen(
        (doc) {
          if (!mounted) return;
          if (doc.exists && doc.data() != null) {
            setState(() {
              _dispatchTuning = DispatchTuning.fromMap(doc.data());
            });
            _initNearbyDrivers();
          }
        },
        onError: (_) {},
      );
    } catch (_) {}
  }

  LatLng get _pickup => LatLng(widget.trip.pickupLat, widget.trip.pickupLng);
  LatLng get _dropoff => LatLng(widget.trip.dropoffLat, widget.trip.dropoffLng);

  void _fitRoute() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (_isDriverEnRouteToPickup && _effectiveDriverPos != null) {
        _mapController.fitPoints(_effectiveDriverPos!, _pickup, padding: 72);
      } else {
        _mapController.fitPoints(_pickup, _dropoff, padding: 72);
      }
    });
  }

  /// Fetches the drivable road geometry based on the active trip stage.
  Future<void> _loadRoadRoute() async {
    if (SeSeMapView.debugTileProviderOverride != null) return;
    final origin = _currentRouteOrigin;
    final dest = _currentRouteDest;

    _lastRoutedOrigin = origin;
    _lastTripStatus = widget.trip.status;

    final points = await LocationService.fetchRoutePolyline(origin, dest);
    if (!mounted || points.isEmpty) return;
    setState(() => _routePoints = points);
  }

  bool get _showBids =>
      widget.trip.status == TripStatus.bidding ||
      widget.trip.status == TripStatus.marketplaceOpen ||
      widget.trip.status == TripStatus.marketplaceList ||
      widget.trip.status == TripStatus.searchingDriver;

  /// True while searching / broadcasting / pinging for a driver.
  bool get _isSearching =>
      _showBids ||
      widget.trip.status == TripStatus.waitingForAcceptance ||
      widget.trip.status == TripStatus.driverPinged;

  // ── Dynamic Map Camera Animation Loop (Hub Configurable) ──────────────────

  /// Automated camera loop while searching:
  /// Step 1: Center & zoom on pickup (15.5), show nearby drivers within active stage radius. Hold for Hub-configured pickup dwell.
  /// Step 2: Smoothly pan & zoom camera along route to drop-off.
  /// Step 3: Hold at drop-off for Hub-configured dropoff dwell, then pan back to pickup. Repeat.
  void _startCameraLoop() {
    _cameraLoopTimer?.cancel();
    if (!_isSearching || !mounted) return;

    // Step 1: Center on pickup
    _mapController.move(_pickup, 15.5);

    // Hold at pickup for configured duration from Hub (default 5s)
    final pickupDwell = Duration(
      seconds: _dispatchTuning.cameraPickupDwellSec.clamp(2, 30),
    );
    _cameraLoopTimer = Timer(pickupDwell, () {
      if (!_isSearching || !mounted) return;

      // Step 2: Smoothly pan and zoom along route to drop-off
      _mapController.move(_dropoff, 15.5);

      // Step 3: Hold at drop-off for configured duration from Hub (default 2s)
      final dropoffDwell = Duration(
        seconds: _dispatchTuning.cameraDropoffDwellSec.clamp(1, 15),
      );
      _cameraLoopTimer = Timer(dropoffDwell, () {
        if (!_isSearching || !mounted) return;

        // Pan back to pickup
        _mapController.move(_pickup, 15.5);

        // Continue loop gracefully
        _startCameraLoop();
      });
    });
  }

  void _stopCameraLoop() {
    _cameraLoopTimer?.cancel();
    _cameraLoopTimer = null;
  }

  void _pauseCameraLoopForUser() {
    _cameraLoopTimer?.cancel();
    // Resume after 12 seconds if still searching
    _cameraLoopTimer = Timer(const Duration(seconds: 12), () {
      if (_isSearching && mounted) {
        _startCameraLoop();
      }
    });
  }

  // ── Active Stage Radius Nearby Drivers Stream ─────────────────────────────

  void _initNearbyDrivers() {
    _nearbyDriversSub?.cancel();
    try {
      _nearbyDriversSub = FirebaseFirestore.instance
          .collection('driver_status')
          .where('isOnline', isEqualTo: true)
          .snapshots()
          .listen(
        (snapshot) {
          if (!mounted) return;
          final list = <_NearbyDriverMarker>[];
          final stageRadius = _activeStageRadiusKm;
          for (final doc in snapshot.docs) {
            final data = doc.data();
            final fix = data['lastFix'] as Map<String, dynamic>?;
            final lat = safeNum(fix?['latitude'])?.toDouble() ??
                safeNum(data['lat'])?.toDouble();
            final lng = safeNum(fix?['longitude'])?.toDouble() ??
                safeNum(data['lng'])?.toDouble();
            if (lat == null || lng == null) continue;
            final pos = LatLng(lat, lng);

            // Distance gate matching active dispatch stage radius (e.g. Stage 1: 0-3km, Stage 3: Order Pool radius)
            final distKm =
                const Distance().as(LengthUnit.Kilometer, _pickup, pos);
            if (distKm > stageRadius) continue;

            final driverCat = (data['activeVehicleCategory'] ??
                    data['vehicleCategory'] ??
                    '')
                .toString()
                .toLowerCase();
            final tripCat = widget.trip.vehicleCategory.toLowerCase();
            if (tripCat.isNotEmpty &&
                driverCat.isNotEmpty &&
                driverCat != tripCat) {
              continue;
            }

            list.add(_NearbyDriverMarker(
              id: doc.id,
              position: pos,
              category: driverCat.isNotEmpty ? driverCat : tripCat,
            ));
          }

          // Strictly live server markers from Firestore
          setState(() => _nearbyDrivers = list);
        },
        onError: (err) {
          debugPrint('LiveTripScreen nearbyDrivers stream error: $err');
          if (mounted) {
            setState(() {
              _nearbyDrivers = const [];
            });
          }
        },
      );
    } catch (e) {
      debugPrint('LiveTripScreen initNearbyDrivers error: $e');
      if (mounted) {
        setState(() {
          _nearbyDrivers = const [];
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final trip = widget.trip;
    final pickup = _pickup;
    final dropoff = _dropoff;
    final driverPos = _effectiveDriverPos;
    final hasDriverFix = driverPos != null;

    final focus = _isDriverEnRouteToPickup && hasDriverFix
        ? driverPos
        : hasDriverFix
            ? driverPos
            : LatLng(
                (pickup.latitude + dropoff.latitude) / 2,
                (pickup.longitude + dropoff.longitude) / 2,
              );

    final fallbackPolylinePoints = _isDriverEnRouteToPickup
        ? [driverPos ?? pickup, pickup]
        : [pickup, dropoff];

    final vehicleCat = widget.trip.vehicleCategory.toLowerCase();
    final serviceCat = widget.trip.serviceType.toLowerCase();
    final isDriverBike = vehicleCat == 'bike' ||
        vehicleCat == 'delivery' ||
        vehicleCat == 'courier' ||
        vehicleCat == 'keke' ||
        vehicleCat == 'motorcycle' ||
        serviceCat == 'delivery' ||
        serviceCat == 'courier';

    final markers = [
      SeSeMapView.pin(
        point: pickup,
        color: const Color(0xFF10B981),
        label: 'CUSTOMER',
        avatarUrl: widget.trip.customerPhotoUrl,
      ),
      SeSeMapView.pin(point: dropoff, color: Colors.red, label: 'B'),
      if (hasDriverFix)
        SeSeMapView.pin(
          point: driverPos,
          color: Colors.blue,
          label: isDriverBike ? 'BIKE' : 'CAR',
        ),
      // Real-time nearby drivers within active dispatch stage radius
      if (_isSearching)
        ..._nearbyDrivers.map(
          (d) {
            final cat = d.category.toLowerCase();
            final serviceType = widget.trip.serviceType.toLowerCase();
            final vehicleCat = widget.trip.vehicleCategory.toLowerCase();

            final isBike = cat == 'bike' ||
                cat == 'delivery' ||
                cat == 'courier' ||
                cat == 'keke' ||
                cat == 'motorcycle' ||
                serviceType == 'delivery' ||
                serviceType == 'courier' ||
                vehicleCat == 'bike' ||
                vehicleCat == 'courier' ||
                vehicleCat == 'keke';

            return MapPin(
              id: 'driver_${d.id}',
              point: d.position,
              color: AppColors.seseGold,
              label: isBike ? 'BIKE' : 'CAR',
            );
          },
        ),
    ];

    final polylines = [
      SeSeMapView.route(
        points: _routePoints.isNotEmpty ? _routePoints : fallbackPolylinePoints,
      ),
    ];

    return Stack(
      children: [
        // 1. Edge-to-edge Live Map View (zero top status banners or floating pills)
        Positioned.fill(
          child: SeSeMapView(
            mapContext: MapContext.realtimeTracking,
            mapController: _mapController,
            initialCenter: focus,
            initialZoom: 15.0,
            showMyLocation: true,
            markers: markers,
            polylines: polylines,
          ),
        ),

        // 2. Map Recenter FAB (anchored above bottom sheet)
        Positioned(
          right: 16,
          bottom: _isSearching ? 240 : 160,
          child: MapRecenterButton(
            key: const Key('live_trip_recenter'),
            icon: Icons.fit_screen,
            onTap: () {
              _pauseCameraLoopForUser();
              _fitRoute();
            },
          ),
        ),

        // 3. Draggable Bottom Sheet for Searching & Matchmaking
        if (_isSearching)
          _LiveTripSearchingSheet(
            trip: trip,
            repository: widget.repository,
            nearbyDriversCount: _nearbyDrivers.length,
            stageRadius: _activeStageRadiusKm,
            onCancel: () => _cancel(context),
            dispatchTuning: _dispatchTuning,
          )
        // Accepted driver sheet (when a driver accepts)
        else if (trip.driver != null &&
            (trip.status == TripStatus.driverAccepted ||
                trip.status == TripStatus.driverArriving ||
                trip.status == TripStatus.driverArrived ||
                trip.status == TripStatus.inProgress))
          _AcceptedDriverSheet(
            driver: trip.driver!,
            trip: trip,
            repository: widget.repository,
            driverPosOverride: driverPos,
            onCancel: () => _cancel(context),
            onNavigateAway: () => _navigateBackToBookingOrPop(
              context,
              trip,
              isPushedFromDispatch: widget.isPushedFromDispatch,
            ),
          ),
      ],
    );
  }

  Future<void> _cancel(BuildContext context) async {
    // Reason-first: the dialog returns null on dismiss, committing nothing.
    final result =
        await CancelTripDialog.show(context, isDriver: false);
    if (result == null) return;
    try {
      await widget.repository.cancelTrip(
        widget.trip.tripId,
        reason: result.reason,
        useCashSettlement: result.useCashSettlement,
      );
      // Show optional post-cancel feedback sheet before navigating away.
      if (context.mounted) {
        await CancelTripDialog.showPostCancelFeedback(
          context,
          tripId: widget.trip.tripId,
          userId: widget.trip.customerId,
          role: 'customer',
          isDriver: false,
        );
      }
      if (context.mounted) {
        _navigateBackToBookingOrPop(
          context,
          widget.trip,
          isPushedFromDispatch: widget.isPushedFromDispatch,
        );
      }
    } on TripException catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(e.userMessage)));
      }
    }
  }
}

// ── Bid carousel & queue manager ──────────────────────────────────────────────

/// Multi-driver bidding list manager (default max 5 visible, Sese Hub configurable).
/// Automatically triggers bottom sheet expansion animation when a new bid arrives
/// while the sheet is minimized.
class _BidCarousel extends StatefulWidget {
  final ActiveTrip trip;
  final TripRepository repository;
  final int maxConcurrentBids;
  final DraggableScrollableController? sheetController;

  const _BidCarousel({
    required this.trip,
    required this.repository,
    this.maxConcurrentBids = 5,
    this.sheetController,
  });

  @override
  State<_BidCarousel> createState() => _BidCarouselState();
}

class _BidCarouselState extends State<_BidCarousel> {
  int _previousPendingCount = 0;

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<List<BidModel>>(
      stream: widget.repository.bidsStream(widget.trip.tripId),
      builder: (context, snapshot) {
        final allPendingBids = snapshot.data
                ?.where((b) => b.status == BidStatus.pending)
                .toList() ??
            const [];

        // Requirement 1: Auto-expanding bottom sheet on incoming bid
        if (allPendingBids.length > _previousPendingCount) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (widget.sheetController != null &&
                widget.sheetController!.isAttached &&
                widget.sheetController!.size <= 0.40) {
              widget.sheetController!.animateTo(
                0.68,
                duration: const Duration(milliseconds: 350),
                curve: Curves.easeOutCubic,
              );
            }
          });
        }
        _previousPendingCount = allPendingBids.length;

        // Requirement 3: Cap visible bids to maxConcurrentBids (default 5 or Sese Hub setting)
        final visibleBids =
            allPendingBids.take(widget.maxConcurrentBids).toList();

        if (visibleBids.isEmpty) return const SizedBox.shrink();

        return Container(
          margin: const EdgeInsets.symmetric(vertical: 4),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Text(
                  '${allPendingBids.length} driver${allPendingBids.length == 1 ? '' : 's'} offered a fare',
                  style: Theme.of(context).textTheme.labelMedium?.copyWith(
                        fontWeight: FontWeight.bold,
                        color: AppColors.seseGold,
                      ),
                ),
              ),
              ListView.builder(
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                itemCount: visibleBids.length,
                itemBuilder: (ctx, i) {
                  final bid = visibleBids[i];
                  return _BidCard(
                    bid: bid,
                    onAccept: () => _accept(ctx, bid.driverId),
                    onReject: () => _reject(ctx, bid.driverId),
                  );
                },
              ),
            ],
          ),
        );
      },
    );
  }

  Future<void> _accept(BuildContext context, String driverId) async {
    try {
      await widget.repository.acceptBid(widget.trip.tripId, driverId);
    } on TripException catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(e.userMessage)));
      }
    }
  }

  Future<void> _reject(BuildContext context, String driverId) async {
    try {
      await widget.repository.rejectBid(widget.trip.tripId, driverId);
    } on TripException catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(e.userMessage)));
      }
    }
  }
}

/// Compact multi-bid row item card (Requirement 2 & Screenshot reference).
class _BidCard extends StatelessWidget {
  final BidModel bid;
  final VoidCallback onAccept;
  final VoidCallback onReject;

  const _BidCard({
    required this.bid,
    required this.onAccept,
    required this.onReject,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final fareLabel = bid.fareFormatted.isNotEmpty
        ? bid.fareFormatted
        : '₦${bid.offeredFare.toStringAsFixed(0)}';

    final vehicleDetails = [
      if (bid.etaMinutes != null) '~${bid.etaMinutes} min away',
      bid.vehicleModel,
      bid.plateNumber,
    ].where((s) => s.trim().isNotEmpty).join(' · ');

    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      elevation: 0,
      color: cs.surfaceContainerHighest.withValues(alpha: 0.5),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: cs.outline.withValues(alpha: 0.15)),
      ),
      child: Padding(
        padding: const EdgeInsets.all(10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            // Row 1: Avatar + Driver Name + Bid Price directly alongside
            Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                UserAvatar(
                  displayName: bid.driverName,
                  photoUrl: bid.photoUrl,
                  radius: 16,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Flexible(
                        child: Row(
                          children: [
                            Flexible(
                              child: Text(
                                bid.driverName,
                                style: const TextStyle(
                                  fontWeight: FontWeight.bold,
                                  fontSize: 13,
                                ),
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                            if (bid.isVerifiedDriver) ...[
                              const SizedBox(width: 4),
                              const Icon(
                                Icons.verified,
                                size: 14,
                                color: AppColors.seseGold,
                              ),
                            ],
                          ],
                        ),
                      ),
                      const SizedBox(width: 8),
                      Text(
                        fareLabel,
                        style: const TextStyle(
                          fontWeight: FontWeight.bold,
                          fontSize: 16,
                          color: AppColors.seseGold,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 4),

            // Row 2: Distance, Vehicle Model & Plate details on bottom secondary line
            Row(
              children: [
                if (bid.rating > 0) ...[
                  const Icon(Icons.star, size: 12, color: Colors.amber),
                  const SizedBox(width: 2),
                  Text(
                    bid.rating.toStringAsFixed(1),
                    style: const TextStyle(fontSize: 11, fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(width: 6),
                  Text('·', style: TextStyle(color: cs.onSurfaceVariant)),
                  const SizedBox(width: 6),
                ],
                Expanded(
                  child: Text(
                    vehicleDetails.isNotEmpty
                        ? vehicleDetails
                        : 'Vehicle details available',
                    style: TextStyle(
                      fontSize: 11,
                      color: cs.onSurfaceVariant,
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),

            // Row 3: Compact inline Accept and Reject buttons
            Row(
              children: [
                Expanded(
                  child: FilledButton.icon(
                    onPressed: onAccept,
                    style: FilledButton.styleFrom(
                      backgroundColor: Colors.green.shade700,
                      foregroundColor: Colors.white,
                      padding: EdgeInsets.zero,
                      minimumSize: const Size(0, 32),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(8),
                      ),
                    ),
                    icon: const Icon(Icons.check, size: 14),
                    label: const Text('Accept', style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold)),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: onReject,
                    style: OutlinedButton.styleFrom(
                      padding: EdgeInsets.zero,
                      minimumSize: const Size(0, 32),
                      side: BorderSide.none,
                      backgroundColor: cs.surfaceContainerHighest,
                      foregroundColor: cs.onSurface,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(8),
                      ),
                    ),
                    icon: const Icon(Icons.close, size: 14),
                    label: const Text('Reject', style: TextStyle(fontSize: 12)),
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

Stream<DocumentSnapshot<Map<String, dynamic>>> _deliveryPinStream(String tripId) {
  try {
    return FirebaseFirestore.instance
        .collection('delivery_pins')
        .doc(tripId)
        .snapshots();
  } catch (_) {
    return const Stream.empty();
  }
}

// ── Delivery PIN banner ────────────────────────────────────────────────────────

/// Prominently surfaces the 4-digit delivery security PIN to the customer
/// so they can share it with the driver at drop-off.
class _DeliveryPinBanner extends StatelessWidget {
  final String pin;

  const _DeliveryPinBanner({required this.pin});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      key: const Key('delivery_pin_banner'),
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      color: Colors.amber.shade700,
      // Trailing hint is Flexible (not a fixed Text) so the 24px PIN with
      // wide letter-spacing never squeezes on narrow phones.
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          const Icon(Icons.lock_outline, color: Colors.white, size: 20),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text(
                  'Delivery Security PIN',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                    letterSpacing: 0.5,
                  ),
                  softWrap: true,
                ),
                Text(
                  pin,
                  key: const Key('delivery_pin_value'),
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 24,
                    fontWeight: FontWeight.bold,
                    letterSpacing: 8,
                  ),
                  softWrap: false,
                  overflow: TextOverflow.visible,
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          Flexible(
            child: Text(
              'Share with\ndriver at drop-off',
              style: TextStyle(
                color: cs.onError.withValues(alpha: 0.85),
                fontSize: 10,
              ),
              textAlign: TextAlign.right,
              softWrap: true,
            ),
          ),
        ],
      ),
    );
  }
}

// ── Live Trip Searching Draggable Bottom Sheet ──────────────────────────────

/// Full-width draggable bottom sheet for trip searching and matchmaking.
///
/// Houses the live matchmaking status indicator, real-time nearby drivers count,
/// fare boost pencil and split fare actions, pending bids carousel, route summary,
/// and privacy-protected cancellation option revealed by dragging upwards.
class _LiveTripSearchingSheet extends StatefulWidget {
  final ActiveTrip trip;
  final TripRepository repository;
  final int nearbyDriversCount;
  final double stageRadius;
  final VoidCallback onCancel;
  final DispatchTuning dispatchTuning;

  const _LiveTripSearchingSheet({
    required this.trip,
    required this.repository,
    required this.nearbyDriversCount,
    required this.stageRadius,
    required this.onCancel,
    this.dispatchTuning = const DispatchTuning(),
  });

  @override
  State<_LiveTripSearchingSheet> createState() =>
      _LiveTripSearchingSheetState();
}

class _LiveTripSearchingSheetState extends State<_LiveTripSearchingSheet> {
  late final DraggableScrollableController _sheetController =
      DraggableScrollableController();

  @override
  void dispose() {
    _sheetController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;

    final String message;
    switch (widget.trip.status) {
      case TripStatus.searchingDriver:
      case TripStatus.unknown:
        message = widget.trip.reassignmentCount > 0
            ? 'Driver had to cancel. Finding you another nearby driver...'
            : (widget.trip.declineCount > 0
                ? "First driver didn't accept... Looking for available drivers"
                : 'Searching for nearby available drivers...');
      case TripStatus.waitingForAcceptance:
      case TripStatus.driverPinged:
        message = 'Driver connected... Waiting for driver to accept';
      case TripStatus.marketplaceOpen:
      case TripStatus.marketplaceList:
        message = 'Broadcasting to nearby drivers...';
      case TripStatus.bidding:
        message = 'Drivers are submitting bids — choose the best offer below';
      case TripStatus.driverAccepted:
      case TripStatus.driverArriving:
        final name = widget.trip.driver?.fullName ?? 'Your driver';
        message = '$name is on the way to pickup';
      case TripStatus.driverArrived:
        message = 'Your driver has arrived at the pickup point';
      case TripStatus.inProgress:
        message = 'Trip in progress — sit back and relax';
      case TripStatus.needsCustomerAction:
      case TripStatus.completed:
      case TripStatus.cancelled:
      case TripStatus.cancelledWaitingCashSettlement:
      case TripStatus.rejected:
      case TripStatus.ignored:
        message = '';
    }

    final fareStr = widget.trip.fareFormatted.isNotEmpty
        ? widget.trip.fareFormatted
        : '₦${widget.trip.fareAmount.toStringAsFixed(0)}';

    return DraggableScrollableSheet(
      controller: _sheetController,
      initialChildSize: 0.38,
      minChildSize: 0.28,
      maxChildSize: 0.88,
      snap: true,
      snapSizes: const [0.28, 0.38, 0.88],
      builder: (context, scrollController) {
        return Container(
          decoration: BoxDecoration(
            color: cs.surface,
            borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
            boxShadow: const [
              BoxShadow(
                color: Colors.black12,
                blurRadius: 10,
                offset: Offset(0, -3),
              ),
            ],
          ),
          child: ListView(
            controller: scrollController,
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            children: [
              // Drag handle
              Center(
                child: Container(
                  width: 36,
                  height: 4,
                  margin: const EdgeInsets.only(bottom: 12),
                  decoration: BoxDecoration(
                    color: Colors.grey.shade400,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),

              // Matchmaking status container
              Container(
                key: const Key('live_trip_status'),
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                decoration: BoxDecoration(
                  color: AppColors.seseGold,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Row(
                  children: [
                    const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: Colors.black,
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        message,
                        style: const TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w700,
                          color: Colors.black,
                        ),
                      ),
                    ),
                    if (widget.nearbyDriversCount > 0) ...[
                      const SizedBox(width: 8),
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 8, vertical: 4),
                        decoration: BoxDecoration(
                          color: Colors.black,
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Text(
                          '${widget.nearbyDriversCount} nearby (${widget.stageRadius.toStringAsFixed(widget.stageRadius % 1 == 0 ? 0 : 1)}km)',
                          style: const TextStyle(
                            fontSize: 10,
                            fontWeight: FontWeight.bold,
                            color: AppColors.seseGold,
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
              ),

              const SizedBox(height: 14),

              // Offer Fare row & actions
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        'OFFER FARE',
                        style: TextStyle(
                          fontSize: 10,
                          fontWeight: FontWeight.bold,
                          color: Colors.grey,
                          letterSpacing: 0.5,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Row(
                        children: [
                          Text(
                            fareStr,
                            style: TextStyle(
                              fontSize: 22,
                              fontWeight: FontWeight.bold,
                              color: cs.onSurface,
                            ),
                          ),
                          const SizedBox(width: 6),
                          IconButton(
                            key: const Key('boost_fare_pencil_button'),
                            icon: const Icon(
                              Icons.edit_note_rounded,
                              color: AppColors.seseGold,
                              size: 22,
                            ),
                            tooltip: 'Boost Offer Fare',
                            visualDensity: VisualDensity.compact,
                            onPressed: () =>
                                _showBoostFareDialog(context, widget.trip, widget.repository),
                          ),
                        ],
                      ),
                    ],
                  ),
                ],
              ),

              if (widget.trip.deliveryPinRequired && !widget.trip.deliveryPinVerified) ...[
                const SizedBox(height: 12),
                StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
                  stream: _deliveryPinStream(widget.trip.tripId),
                  builder: (context, snapshot) {
                    if (!snapshot.hasData || snapshot.data?.data() == null) {
                      return const SizedBox.shrink();
                    }
                    final pin = (snapshot.data!.data()?['pin'] ?? '').toString();
                    if (pin.isEmpty) return const SizedBox.shrink();
                    return _DeliveryPinBanner(pin: pin);
                  },
                ),
              ],

              // Pending driver bids carousel
              const SizedBox(height: 12),
              _BidCarousel(
                trip: widget.trip,
                repository: widget.repository,
                maxConcurrentBids: widget.dispatchTuning.maxConcurrentBids,
                sheetController: _sheetController,
              ),

              const SizedBox(height: 16),
              const Divider(height: 1),
              const SizedBox(height: 14),

              // Route summary (Pickup and Dropoff)
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Column(
                    children: [
                      const Icon(Icons.circle, color: Colors.green, size: 12),
                      Container(
                        width: 2,
                        height: 24,
                        color: Colors.grey.shade300,
                      ),
                      const Icon(Icons.square, color: Colors.red, size: 12),
                    ],
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          widget.trip.pickupAddress,
                          style: const TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w500,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        const SizedBox(height: 16),
                        Text(
                          widget.trip.dropoffAddress,
                          style: const TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w500,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ],
                    ),
                  ),
                ],
              ),

              // Privacy Cancellation Option: Positioned lower down so user must scroll/drag upwards to reveal
              const SizedBox(height: 28),
              Center(
                child: Text(
                  'Need to change plans?',
                  style: TextStyle(
                    fontSize: 11,
                    color: Colors.grey.shade500,
                  ),
                ),
              ),
              const SizedBox(height: 6),
              Center(
                child: TextButton(
                  style: TextButton.styleFrom(
                    foregroundColor: cs.error,
                    padding: const EdgeInsets.symmetric(
                        horizontal: 16, vertical: 8),
                  ),
                  onPressed: widget.onCancel,
                  child: const Text(
                    'Cancel trip',
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      decoration: TextDecoration.underline,
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 16),
            ],
          ),
        );
      },
    );
  }
}

// ── Accepted-driver sheet ─────────────────────────────────────────────────────

/// Accepted-driver sheet: photo, name, rating, vehicle/payment, 3 round action
/// buttons (Direct Call, In-App VoIP Call, Trip Chat), and the full route details
/// container (PICKUP & DROPOFF), matching the driver active trip view layout
/// while excluding driver state advancement controls.
class _AcceptedDriverSheet extends StatefulWidget {
  final DriverInfo driver;
  final ActiveTrip trip;
  final VoidCallback? onCancel;

  /// Repository reference used to invoke the waiting-fee cancel path directly
  /// from within the sheet (avoids routing a multi-arg cancel through a
  /// single [VoidCallback]).
  final TripRepository repository;

  /// Called after a successful waiting-fee cancel to navigate the customer
  /// back to the booking screen. Distinct from [onCancel] which opens the
  /// cancel dialog; this skips the dialog and goes straight to navigation.
  final VoidCallback? onNavigateAway;

  /// Optional live assigned driver position override (from real-time stream).
  final LatLng? driverPosOverride;

  const _AcceptedDriverSheet({
    required this.driver,
    required this.trip,
    required this.repository,
    this.onCancel,
    this.onNavigateAway,
    this.driverPosOverride,
  });

  @override
  State<_AcceptedDriverSheet> createState() => _AcceptedDriverSheetState();
}

class _AcceptedDriverSheetState extends State<_AcceptedDriverSheet> {
  bool _hidePhones = false;
  late final DraggableScrollableController _sheetController =
      DraggableScrollableController();

  @override
  void dispose() {
    _sheetController.dispose();
    super.dispose();
  }

  @override
  void initState() {
    super.initState();
    PrivacyMasking.hidePhonesEnabled().then((v) {
      if (mounted) setState(() => _hidePhones = v);
    });
  }

  String _firstName(String fullName) {
    final trimmed = fullName.trim();
    if (trimmed.isEmpty) return 'Driver';
    return trimmed.split(RegExp(r'\s+')).first;
  }

  /// Displays the waiting-fee settlement bottom sheet when the customer wants
  /// to cancel after the 10-minute free-wait window has expired.
  ///
  /// The computed fee is a display-only estimate. The server recomputes the
  /// authoritative amount and performs the actual wallet deduction or rejects
  /// with `INSUFFICIENT_FUNDS` if the wallet is short. This method routes
  /// the outcome through the parent's [widget.onCancel] callback on success
  /// so that navigation and post-cancel feedback run through the same path.
  Future<void> _showWaitingFeeSettlementSheet(
      BuildContext context, ActiveTrip trip) async {
    // Estimate the waiting fee for display. The server recomputes authoritatively.
    final arrivedAt = trip.arrivedAt;
    const freeWaitMinutes = 10;
    const ratePerMin = 20.0; // fallback display rate in ₦; server uses timeRatePerMinute
    double estimatedFee = 0.0;
    if (arrivedAt != null) {
      final elapsed = DateTime.now().difference(arrivedAt);
      final billableMin =
          (elapsed.inSeconds / 60 - freeWaitMinutes).clamp(0.0, double.infinity);
      estimatedFee = (billableMin * ratePerMin).ceilToDouble();
    }
    final feeStr = '₦${estimatedFee.toStringAsFixed(0)}';

    final result = await showModalBottomSheet<_WaitingCancelChoice>(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) =>
          _WaitingFeeSettlementSheet(estimatedFee: estimatedFee, feeStr: feeStr),
    );
    if (result == null || !context.mounted) return;

    try {
      await widget.repository.cancelTrip(
        trip.tripId,
        reason: 'waiting_fee',
        useCashSettlement: result == _WaitingCancelChoice.cashSettlement,
      );
      if (context.mounted) {
        await CancelTripDialog.showPostCancelFeedback(
          context,
          tripId: trip.tripId,
          userId: trip.customerId,
          role: 'customer',
          isDriver: false,
        );
      }
      if (context.mounted && widget.onNavigateAway != null) {
        widget.onNavigateAway!();
      } else if (context.mounted && widget.onCancel != null) {
        // Fallback: onCancel will re-check trip status (now cancelled) and route.
        widget.onCancel!();
      }
    } on TripException catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(e.userMessage)));
      }
    } catch (_) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
              content: Text('Unable to cancel right now. Please try again.')),
        );
      }
    }
  }

  /// Returns the single consolidated status string shown in the top status box.
  ///
  /// When a live driver ETA fix is available ([ActiveTrip.driverLat]/[driverLng]),
  /// this message is embedded inside [_DriverEtaCard] which replaces the plain
  /// status box entirely — so only ONE status banner is ever visible at once.
  String _customerStatusMessage(TripStatus status, String driverName) {
    final firstName = _firstName(driverName);
    switch (status) {
      case TripStatus.driverAccepted:
      case TripStatus.driverArriving:
        return '$firstName is on the way to pickup';
      case TripStatus.driverArrived:
        return '$firstName arrived at pickup • Waiting...';
      case TripStatus.inProgress:
        return 'Trip in progress • En route to drop-off';
      default:
        return 'Driver assigned to your trip';
    }
  }


  Widget? _buildCustomerPaymentBreakdown(ActiveTrip trip) {
    final mode = trip.paymentMode.toLowerCase();
    final hasWallet = trip.walletCoverageAmount > 0;
    final hasCash = trip.cashToCollect > 0;
    final isDark = Theme.of(context).brightness == Brightness.dark;

    if (mode == 'receiver_pays') {
      return Container(
        margin: const EdgeInsets.only(bottom: 12),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: isDark
              ? const Color(0xFF1E3A8A).withValues(alpha: 0.3)
              : Colors.blue.shade50,
          borderRadius: BorderRadius.circular(10),
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
              size: 16,
              color: isDark ? const Color(0xFF93C5FD) : Colors.blue.shade800,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                'Receiver Pays Cash: The receiver will pay ₦${trip.fareAmount.toStringAsFixed(0)} cash at drop-off.',
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: isDark ? const Color(0xFFBFDBFE) : Colors.blue.shade900,
                ),
              ),
            ),
          ],
        ),
      );
    } else if (hasWallet && hasCash) {
      return Container(
        margin: const EdgeInsets.only(bottom: 12),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: isDark
              ? const Color(0xFF78350F).withValues(alpha: 0.3)
              : const Color(0xFFFEF3C7),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(
            color: const Color(0xFFF59E0B).withValues(alpha: 0.4),
          ),
        ),
        child: Row(
          children: [
            Icon(
              Icons.account_balance_wallet_outlined,
              size: 16,
              color: isDark ? const Color(0xFFFBBF24) : const Color(0xFF92400E),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '₦${trip.walletCoverageAmount.toStringAsFixed(0)} locked from wallet in escrow.',
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.bold,
                      color: isDark ? const Color(0xFFFDE68A) : const Color(0xFF92400E),
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    'Please give ₦${trip.cashToCollect.toStringAsFixed(0)} cash to the driver at pickup.',
                    style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w500,
                      color: isDark
                          ? const Color(0xFFFDE68A).withValues(alpha: 0.85)
                          : const Color(0xFF92400E),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      );
    } else if (hasWallet && !hasCash) {
      return Container(
        margin: const EdgeInsets.only(bottom: 12),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: isDark
              ? const Color(0xFF065F46).withValues(alpha: 0.3)
              : Colors.green.shade50,
          borderRadius: BorderRadius.circular(10),
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
              size: 16,
              color: isDark ? const Color(0xFF6EE7B7) : Colors.green.shade800,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                '100% Wallet Prepaid — No cash required. Do not pay any cash.',
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: isDark ? const Color(0xFFA7F3D0) : Colors.green.shade900,
                ),
              ),
            ),
          ],
        ),
      );
    }
    return null;
  }

  bool _isCallableNumber(String raw) {
    final v = raw.trim();
    if (v.isEmpty) return false;
    if (v.contains('*') || v.contains('•')) return false;
    return true;
  }

  Future<void> _makeDirectPhoneCall(BuildContext context) async {
    final phone = widget.driver.phone;
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
          content: Text('Driver phone number is masked or unavailable.'),
        ),
      );
    }
  }

  void _startInAppCall(BuildContext context) {
    final callId =
        'call_${widget.trip.tripId}_${DateTime.now().millisecondsSinceEpoch}';
    InAppCallScreen.start(
      context: context,
      callId: callId,
      targetUserId: widget.driver.driverId,
      targetUserName: widget.driver.fullName.isNotEmpty
          ? widget.driver.fullName
          : 'Driver',
      targetUserAvatar: widget.driver.photoUrl,
      metadata: {
        'tripId': widget.trip.tripId,
        'callerRole': 'customer',
      },
    );
  }

  void _openTripChat(BuildContext context) {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => TripChatScreen(
          tripId: widget.trip.tripId,
          currentUid: widget.trip.customerId,
          senderRole: 'customer',
          peerName: widget.driver.fullName.isEmpty
              ? 'Driver'
              : widget.driver.fullName,
          peerPhone: widget.driver.phone,
          hidePhones: _hidePhones,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final driver = widget.driver;
    final trip = widget.trip;
    final scheme = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return DraggableScrollableSheet(
      controller: _sheetController,
      initialChildSize: 0.38,
      minChildSize: 0.18,
      maxChildSize: 0.88,
      snap: true,
      snapSizes: const [0.18, 0.38, 0.88],
      builder: (context, scrollController) {
        return Container(
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
          // so dragging/sliding from the top handle, status banner, or driver profile card expands/collapses the sheet smoothly.
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
                  onTap: () {
                    if (_sheetController.isAttached) {
                      final current = _sheetController.size;
                      final target = current > 0.35 ? 0.18 : 0.65;
                      _sheetController.animateTo(
                        target,
                        duration: const Duration(milliseconds: 250),
                        curve: Curves.easeOutCubic,
                      );
                    }
                  },
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

                // a. Unified status banner:
                //    • When a live driver GPS fix exists → show the ETA card
                //      which already embeds a rich status line ("Driver
                //      arriving in 3 min • 120 m away" or "In progress …").
                //    • When no fix yet → show the plain amber status box as
                //      the sole banner so there is never two status lines.
                if (widget.driverPosOverride != null ||
                    (trip.driverLat != null && trip.driverLng != null)) ...[
                  _DriverEtaCard(
                    trip: trip,
                    driverPosOverride: widget.driverPosOverride,
                  ),
                  const SizedBox(height: 8),
                ] else ...[
                  // b. Plain status container — only shown when no GPS fix.
                  Container(
                    key: const Key('customer_active_status_container'),
                    width: double.infinity,
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
                    decoration: BoxDecoration(
                      color: isDark
                          ? const Color(0xFF78350F).withValues(alpha: 0.3)
                          : const Color(0xFFFEF3C7),
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(
                        color: isDark
                            ? const Color(0xFFF59E0B).withValues(alpha: 0.4)
                            : const Color(0xFFF59E0B).withValues(alpha: 0.3),
                      ),
                    ),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(
                          Icons.directions_car_filled_rounded,
                          color: isDark ? const Color(0xFFFBBF24) : const Color(0xFFD97706),
                          size: 20,
                        ),
                        const SizedBox(width: 8),
                        Flexible(
                          child: Text(
                            _customerStatusMessage(trip.status, driver.fullName),
                            style: TextStyle(
                              fontSize: 14,
                              fontWeight: FontWeight.bold,
                              color: isDark ? const Color(0xFFFBBF24) : const Color(0xFF92400E),
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 8),
                ],

                // b. Identity Row (Mutual Driver Profile Card)
                InkWell(
                  key: const Key('customer_driver_profile_card'),
                  borderRadius: BorderRadius.circular(14),
                  onTap: () {
                    MutualProfileModal.show(
                      context,
                      userId: driver.driverId,
                      fallbackName: driver.fullName,
                      fallbackPhotoUrl: driver.photoUrl,
                      fallbackRating: driver.rating > 0 ? driver.rating : 5.0,
                      roleLabel: 'Driver',
                      vehicleInfo: driver.vehicleLabel,
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
                        UserAvatar(
                          displayName: driver.fullName,
                          photoUrl: driver.photoUrl,
                          radius: 24,
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              // Primary line: bold fare amount
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
                                      driver.vehicleLabel.isNotEmpty
                                          ? driver.vehicleLabel
                                          : 'Vehicle',
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
                              // Secondary line: driver name + rating + plate
                              Row(
                                children: [
                                  Flexible(
                                    child: Text(
                                      driver.fullName.isNotEmpty
                                          ? _firstName(driver.fullName)
                                          : 'Driver',
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
                                  Text(
                                    ' ${(driver.rating > 0 ? driver.rating : 5.0).toStringAsFixed(1)}',
                                    style: TextStyle(
                                      fontWeight: FontWeight.bold,
                                      fontSize: 12,
                                      color: isDark ? Colors.grey.shade300 : Colors.grey.shade700,
                                    ),
                                  ),
                                  if (driver.plateNumber.isNotEmpty) ...[
                                    Text(
                                      '  ·  ${driver.plateNumber}',
                                      style: TextStyle(
                                        fontSize: 12,
                                        color: isDark ? Colors.grey.shade400 : Colors.grey.shade600,
                                        fontWeight: FontWeight.w500,
                                      ),
                                    ),
                                  ],
                                ],
                              ),
                            ],
                          ),
                        ),
                        const Icon(Icons.chevron_right, color: Colors.grey, size: 22),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 12),

                // c. Communication Action Row
                Row(
                  children: [
                    Expanded(
                      child: _CommunicationButton(
                        key: const Key('customer_direct_call_icon'),
                        icon: Icons.phone_outlined,
                        label: 'Direct Call',
                        color: const Color(0xFF10B981),
                        bgColor: const Color(0xFF10B981).withValues(alpha: 0.12),
                        onTap: () => _makeDirectPhoneCall(context),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: _CommunicationButton(
                        key: const Key('customer_inapp_call_icon'),
                        icon: Icons.phone_in_talk_outlined,
                        label: 'In-App Call',
                        color: isDark ? const Color(0xFFFBBF24) : const Color(0xFFD97706),
                        bgColor: isDark
                            ? const Color(0xFF78350F).withValues(alpha: 0.25)
                            : const Color(0xFFFEF3C7),
                        onTap: () => _startInAppCall(context),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: _CommunicationButton(
                        key: const Key('customer_chat_icon'),
                        icon: Icons.chat_bubble_outline,
                        label: 'Chat',
                        color: isDark ? Colors.white : Colors.black87,
                        bgColor: isDark ? const Color(0xFF252530) : Colors.grey.shade100,
                        onTap: () => _openTripChat(context),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),

                // Payment Breakdown Banner
                if (_buildCustomerPaymentBreakdown(trip) != null) ...[
                  _buildCustomerPaymentBreakdown(trip)!,
                  const SizedBox(height: 8),
                ],

                // Delivery Security PIN Banner
                if (trip.deliveryPinRequired && !trip.deliveryPinVerified) ...[
                  StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
                    stream: _deliveryPinStream(trip.tripId),
                    builder: (context, snapshot) {
                      if (!snapshot.hasData || snapshot.data?.data() == null) {
                        return const SizedBox.shrink();
                      }
                      final pin = (snapshot.data!.data()?['pin'] ?? '').toString();
                      if (pin.isEmpty) return const SizedBox.shrink();
                      return _DeliveryPinBanner(pin: pin);
                    },
                  ),
                  const SizedBox(height: 8),
                ],

                // d. Route Details
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
                  ),
                ),

                // e. Cancellation Option — gated by trip status and waiting time.
                //
                // Rules (per spec):
                //   - SEARCHING / DRIVER_ACCEPTED / DRIVER_ARRIVING: show normal cancel.
                //   - DRIVER_ARRIVED < 10 min: show normal cancel (free window).
                //   - DRIVER_ARRIVED ≥ 10 min: show "Settle & Cancel" — waiting fee applies.
                //   - IN_PROGRESS: hide cancel button entirely.
                //   - COMPLETED / any closed status: hide.
                if (widget.onCancel != null &&
                    trip.status != TripStatus.completed &&
                    trip.status != TripStatus.inProgress) ...[
                  const SizedBox(height: 12),
                  Builder(builder: (context) {
                    // Determine if the 10-minute free-wait window has elapsed.
                    final arrivedAt = trip.arrivedAt;
                    final waitThresh = 10; // 10-minute free waiting window (matches backend default)
                    final isDriverArrived =
                        trip.status == TripStatus.driverArrived;
                    final waitExpired = isDriverArrived &&
                        arrivedAt != null &&
                        DateTime.now().difference(arrivedAt).inMinutes >=
                            waitThresh;

                    if (waitExpired) {
                      // Waiting fee applies — show the settle-and-cancel prompt.
                      return Center(
                        child: TextButton.icon(
                          key: const Key('customer_settle_cancel_button'),
                          icon: Icon(Icons.access_time_filled,
                              size: 14, color: Colors.orange.shade700),
                          label: Text(
                            'Settle Waiting Fee & Cancel',
                            style: TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.w700,
                              color: Colors.orange.shade700,
                              decoration: TextDecoration.underline,
                            ),
                          ),
                          onPressed: () =>
                              _showWaitingFeeSettlementSheet(context, trip),
                        ),
                      );
                    }

                    // Free-cancel window: plain text button.
                    return Center(
                      child: TextButton(
                        onPressed: widget.onCancel,
                        style: TextButton.styleFrom(
                          foregroundColor: Colors.red.shade600,
                          padding: const EdgeInsets.symmetric(
                              horizontal: 16, vertical: 8),
                        ),
                        child: const Text(
                          'Cancel ride',
                          style: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                            decoration: TextDecoration.underline,
                          ),
                        ),
                      ),
                    );
                  }),
                  const SizedBox(height: 8),
                ] else ...[
                  const SizedBox(height: 8),
                ],
              ],
            ),
          ),
        );
      },
    );
  }
}

/// Clean horizontal communication button with icon and label for clear touch targets.
///
/// Sized generously (vertical padding 14, font 14 bold) so the tap area is
/// comfortable for both customer and driver one-handed use while in-trip.
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

// ── Terminal / error placeholder ──────────────────────────────────────────────

/// Terminal / error placeholder with a way back.
class _MessageState extends StatelessWidget {
  final IconData icon;
  final Color? iconColor;
  final String title;
  final String body;
  final VoidCallback onClose;

  const _MessageState({
    required this.icon,
    required this.title,
    required this.body,
    required this.onClose,
    this.iconColor,
  });

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 56, color: iconColor ?? Colors.grey),
            const SizedBox(height: 12),
            Text(
              title,
              style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 8),
            Text(body, textAlign: TextAlign.center),
            const SizedBox(height: 20),
            FilledButton(onPressed: onClose, child: const Text('Done')),
          ],
        ),
      ),
    );
  }
}

/// Post-trip completion view that triggers the interactive 1-5 star review dialog for the driver.
class _CompletedTripView extends StatefulWidget {
  final ActiveTrip trip;

  const _CompletedTripView({required this.trip});

  @override
  State<_CompletedTripView> createState() => _CompletedTripViewState();
}

class _CompletedTripViewState extends State<_CompletedTripView> {
  bool _prompted = false;

  @override
  void initState() {
    super.initState();
    _cacheCompletedLocations();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _promptRating();
    });
  }

  /// Automatically caches pickup and drop-off addresses locally and syncs to user records on trip completion.
  void _cacheCompletedLocations() {
    final trip = widget.trip;
    final repo = RecentLocationsRepository();
    final uid = trip.customerId.isNotEmpty ? trip.customerId : null;
    if (trip.pickupAddress.isNotEmpty &&
        (trip.pickupLat != 0 || trip.pickupLng != 0)) {
      repo.saveLocation(
        address: trip.pickupAddress,
        lat: trip.pickupLat,
        lng: trip.pickupLng,
        uid: uid,
      );
    }
    if (trip.dropoffAddress.isNotEmpty &&
        (trip.dropoffLat != 0 || trip.dropoffLng != 0)) {
      repo.saveLocation(
        address: trip.dropoffAddress,
        lat: trip.dropoffLat,
        lng: trip.dropoffLng,
        uid: uid,
      );
    }
  }

  Future<void> _promptRating() async {
    if (_prompted || !mounted) return;
    _prompted = true;

    final driverId = widget.trip.driver?.driverId ?? '';
    final driverName = widget.trip.driver?.fullName ?? 'Driver';
    final customerId = widget.trip.customerId;

    if (driverId.isEmpty || customerId.isEmpty) return;

    final ratingService = TripRatingService();
    final alreadyRated =
        await ratingService.hasRated(widget.trip.tripId, customerId);
    if (alreadyRated || !mounted) return;

    await TripRatingDialog.show(
      context,
      tripId: widget.trip.tripId,
      raterId: customerId,
      ratedUserId: driverId,
      ratedUserName: driverName,
      isRatedUserDriver: true,
      ratingService: ratingService,
    );
  }

  @override
  Widget build(BuildContext context) {
    return _MessageState(
      icon: Icons.check_circle,
      iconColor: Colors.green,
      title: 'Trip completed',
      body: 'Thanks for riding with SESE.',
      onClose: () => Navigator.of(context).pop('completed'),
    );
  }
}

/// Calculates the maximum allowed offer fare for a trip based on its baseline fare and max boost percentage (default: 100%).
double _calculateMaxAllowedFare(ActiveTrip trip, {double maxBoostPct = 100.0}) {
  final originalBase = (trip.baselineFare > 0)
      ? trip.baselineFare
      : (trip.fareAmount > 0 ? trip.fareAmount : 1.0);
  return (originalBase * (1.0 + (maxBoostPct / 100.0))).roundToDouble();
}

/// Calculates the incremented fare for a percentage boost option (+5%, +10%, +20%),
/// calculated relative to original base fare and clamped to the maximum allowed fare.
int _calculateBoostedFareAmount(ActiveTrip trip, int percentage, {double maxBoostPct = 100.0}) {
  final originalBase = (trip.baselineFare > 0)
      ? trip.baselineFare
      : (trip.fareAmount > 0 ? trip.fareAmount : 1.0);
  final maxAllowed = _calculateMaxAllowedFare(trip, maxBoostPct: maxBoostPct);
  final step = (originalBase * percentage / 100.0).roundToDouble();
  final target = trip.fareAmount + step;
  return target > maxAllowed ? maxAllowed.round() : target.round();
}

/// Opens the fare boost dialog allowing the customer to increase their offer fare during searching.
void _showBoostFareDialog(
  BuildContext context,
  ActiveTrip trip,
  TripRepository repository,
) {
  final controller = TextEditingController(
    text: trip.fareAmount > 0 ? trip.fareAmount.toStringAsFixed(0) : '',
  );
  String? error;
  bool loading = false;
  final maxAllowedFare = _calculateMaxAllowedFare(trip);
  final maxFormatted = '₦${maxAllowedFare.toInt().toString().replaceAllMapped(RegExp(r'(\d{1,3})(?=(\d{3})+(?!\d))'), (m) => '${m[1]},')}';

  showDialog<void>(
    context: context,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setDlg) => AlertDialog(
        key: const Key('boost_fare_dialog'),
        title: const Row(
          children: [
            Icon(Icons.edit_note_rounded, color: AppColors.seseGold),
            SizedBox(width: 8),
            Text('Boost Offer Fare'),
          ],
        ),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Increase your offer to attract nearby drivers faster. Maximum allowed offer is 100% above original base fare ($maxFormatted). Decreases below current fare are prohibited.',
                style: const TextStyle(fontSize: 12, color: Colors.grey),
              ),
              const SizedBox(height: 12),
              Wrap(
                spacing: 8,
                children: [5, 10, 20].map((pct) {
                  final boosted = _calculateBoostedFareAmount(trip, pct);
                  return OutlinedButton(
                    onPressed: loading
                        ? null
                        : () => setDlg(() {
                              controller.text = boosted.toString();
                              error = null;
                            }),
                    child: Text('+$pct%'),
                  );
                }).toList(),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: controller,
                keyboardType:
                    const TextInputType.numberWithOptions(decimal: true),
                inputFormatters: [
                  FilteringTextInputFormatter.allow(RegExp(r'[\d,.]')),
                ],
                decoration: InputDecoration(
                  labelText: 'New Offer Amount (₦)',
                  prefixText: '₦ ',
                  border: const OutlineInputBorder(),
                  errorText: error,
                  errorMaxLines: 2,
                ),
                onChanged: (_) {
                  if (error != null) setDlg(() => error = null);
                },
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('Cancel'),
          ),
          FilledButton(
            key: const Key('boost_fare_submit_button'),
            style: FilledButton.styleFrom(
              backgroundColor: AppColors.seseGold,
              foregroundColor: Colors.black87,
            ),
            onPressed: loading
                ? null
                : () async {
                    final val = double.tryParse(
                      controller.text.replaceAll(',', ''),
                    );
                    if (val == null || val <= trip.fareAmount) {
                      setDlg(() => error = 'Enter an amount higher than current fare.');
                      return;
                    }
                    if (val > maxAllowedFare) {
                      setDlg(() => error =
                          'Offer boost cannot exceed 100% above original base fare (max $maxFormatted).');
                      return;
                    }
                    setDlg(() => loading = true);
                    try {
                      await repository.increaseTripFare(trip.tripId, val);
                      if (ctx.mounted) Navigator.of(ctx).pop();
                    } on TripException catch (e) {
                      if (ctx.mounted) {
                        setDlg(() {
                          error = e.userMessage;
                          loading = false;
                        });
                      }
                    } catch (e) {
                      if (ctx.mounted) {
                        setDlg(() {
                          error = 'Unable to increase fare. Please try again.';
                          loading = false;
                        });
                      }
                    }
                  },
            child: const Text('Confirm Increase'),
          ),
        ],
      ),
    ),
  );
}

/// Live ETA card shown on the customer active trip sheet.
///
/// Reads [ActiveTrip.driverLat] / [ActiveTrip.driverLng] which the driver's
/// device publishes every ~10 s via the `updateDriverLocation` callable.
/// Because the outer [StreamBuilder] that owns the trip object rebuilds on
/// every Firestore update, this card updates automatically in near real-time
/// without its own timer or stream.
///
/// Destination logic:
/// - Pre-trip ([driverAccepted] / [driverArriving] / [driverArrived]):
///   measures distance to **pickup** so the customer sees "Driver arriving in
///   X min • Y m away".
/// - Active trip ([inProgress]): measures distance to **dropoff** so the
///   customer sees "In progress • X min to dropoff".
class _DriverEtaCard extends StatelessWidget {
  final ActiveTrip trip;
  final LatLng? driverPosOverride;

  const _DriverEtaCard({required this.trip, this.driverPosOverride});

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final driverPos = driverPosOverride ??
        (trip.driverLat != null && trip.driverLng != null
            ? LatLng(trip.driverLat!, trip.driverLng!)
            : null);
    if (driverPos == null) return const SizedBox.shrink();

    final isInProgress = trip.status == TripStatus.inProgress;

    // Choose the relevant destination based on trip stage.
    final destLat = isInProgress ? trip.dropoffLat : trip.pickupLat;
    final destLng = isInProgress ? trip.dropoffLng : trip.pickupLng;

    // Guard: skip if destination coords are unset.
    if (destLat == 0.0 && destLng == 0.0) return const SizedBox.shrink();

    final destPos = LatLng(destLat, destLng);
    final distM = const Distance().as(LengthUnit.Meter, driverPos, destPos);
    final distKm = distM / 1000.0;

    // Same 30 km/h urban average used in the driver navigation cockpit.
    final etaMin = (distKm / 30.0 * 60).ceil().clamp(1, 999);
    final distLabel =
        distM < 1000 ? '${distM.round()} m' : '${distKm.toStringAsFixed(1)} km';

    final cardBg = isDark
        ? const Color(0xFF78350F).withValues(alpha: 0.35)
        : const Color(0xFFFEF3C7);
    final borderColor = isDark
        ? const Color(0xFFF59E0B).withValues(alpha: 0.4)
        : const Color(0xFFF59E0B).withValues(alpha: 0.5);
    final iconColor =
        isDark ? const Color(0xFFFBBF24) : const Color(0xFFD97706);
    final textColor =
        isDark ? const Color(0xFFFDE68A) : const Color(0xFF92400E);

    final label = isInProgress
        ? 'In progress  •  $etaMin min to drop-off  •  $distLabel'
        : trip.status == TripStatus.driverArrived
            ? 'Driver arrived at pickup  •  $distLabel away'
            : 'Driver arriving in $etaMin min  •  $distLabel away';

    return Container(
      key: const Key('customer_driver_eta_card'),
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
      decoration: BoxDecoration(
        color: cardBg,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: borderColor),
      ),
      child: Row(
        children: [
          Icon(Icons.directions_car_filled_rounded, color: iconColor, size: 22),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              label,
              style: TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w700,
                color: textColor,
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }
}



// ── Waiting Fee Settlement ─────────────────────────────────────────────────

/// Enumerates the two ways a customer can resolve a waiting-fee cancel.
enum _WaitingCancelChoice {
  /// Deduct the fee from the customer's wallet automatically.
  walletDeduction,

  /// Acknowledge cash settlement (driver collects cash; server records it).
  cashSettlement,
}

/// Bottom sheet shown when the customer cancels after the 10-minute free-wait
/// window has elapsed and a waiting fee applies.
///
/// Presents two resolution paths:
///  1. **Auto-Deduct from Wallet** — server deducts [estimatedFee] from the
///     customer's wallet and transfers it to the driver. Requires sufficient
///     wallet balance.
///  2. **Cash Settlement** — driver collects cash on-site. Server sets trip to
///     `CANCELLED_WAITING_CASH_SETTLEMENT` and notifies the driver.
///
/// The displayed fee is a client-side estimate for UX only; the server
/// recomputes the authoritative amount and rejects the call if the wallet is
/// insufficient (returning `INSUFFICIENT_FUNDS` which surfaces as a snackbar).
class _WaitingFeeSettlementSheet extends StatelessWidget {
  final double estimatedFee;
  final String feeStr;

  const _WaitingFeeSettlementSheet({
    required this.estimatedFee,
    required this.feeStr,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;

    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 20, 20, 28),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Handle
            Center(
              child: Container(
                width: 36,
                height: 4,
                margin: const EdgeInsets.only(bottom: 16),
                decoration: BoxDecoration(
                  color: Colors.grey.shade400,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),

            // Title
            Row(
              children: [
                Icon(Icons.access_time_filled,
                    color: Colors.orange.shade700, size: 22),
                const SizedBox(width: 10),
                const Text(
                  'Waiting Fee Applies',
                  style: TextStyle(fontSize: 17, fontWeight: FontWeight.bold),
                ),
              ],
            ),
            const SizedBox(height: 12),

            // Fee explanation
            Container(
              padding:
                  const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
              decoration: BoxDecoration(
                color: isDark
                    ? const Color(0xFF78350F).withValues(alpha: 0.25)
                    : const Color(0xFFFEF3C7),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(
                  color: const Color(0xFFF59E0B).withValues(alpha: 0.5),
                ),
              ),
              child: Text(
                'The driver has been waiting more than 10 minutes. A waiting '
                'fee of approximately $feeStr applies to this cancellation.',
                style: TextStyle(
                  fontSize: 13,
                  color: isDark
                      ? const Color(0xFFFDE68A)
                      : const Color(0xFF92400E),
                  fontWeight: FontWeight.w500,
                ),
              ),
            ),
            const SizedBox(height: 20),

            // Option 1: Wallet auto-deduction
            SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                key: const Key('wallet_settle_cancel_button'),
                icon: const Icon(Icons.account_balance_wallet_outlined,
                    size: 18),
                label: Text('Deduct $feeStr from Wallet & Cancel'),
                style: FilledButton.styleFrom(
                  backgroundColor: Colors.deepOrange,
                  padding: const EdgeInsets.symmetric(vertical: 14),
                ),
                onPressed: () => Navigator.of(context)
                    .pop(_WaitingCancelChoice.walletDeduction),
              ),
            ),
            const SizedBox(height: 10),

            // Option 2: Cash settlement
            SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                key: const Key('cash_settle_cancel_button'),
                icon: const Icon(Icons.payments_outlined, size: 18),
                label: Text('Pay $feeStr Cash to Driver & Cancel'),
                style: OutlinedButton.styleFrom(
                  foregroundColor:
                      isDark ? Colors.amber.shade300 : Colors.deepOrange,
                  side: BorderSide(
                    color: isDark
                        ? Colors.amber.shade700
                        : Colors.deepOrange.shade300,
                  ),
                  padding: const EdgeInsets.symmetric(vertical: 14),
                ),
                onPressed: () => Navigator.of(context)
                    .pop(_WaitingCancelChoice.cashSettlement),
              ),
            ),
            const SizedBox(height: 10),

            // Dismiss
            Center(
              child: TextButton(
                onPressed: () => Navigator.of(context).pop(),
                child: const Text('Go Back'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
