import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:latlong2/latlong.dart';
import 'package:sese_core/sese_core.dart';

import '../../../core/services/call_service.dart';
import '../../../widgets/map_provider.dart';
import '../../../widgets/verified_badge.dart';
import '../../customer/services/location_service.dart';
import '../models/bid_models.dart';
import '../models/trip_models.dart';
import '../services/trip_service.dart';
import 'cancel_trip_dialog.dart';
import 'mutual_profile_modal.dart';
import 'split_request_sheet.dart';
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
void _navigateBackToBookingOrPop(BuildContext context, ActiveTrip trip) {
  if (Navigator.of(context).canPop()) {
    Navigator.of(context).pop(true);
    return;
  }
  final pickupLoc = trip.pickupLat != 0 && trip.pickupLng != 0
      ? LatLng(trip.pickupLat, trip.pickupLng)
      : null;
  final dropoffLoc = trip.dropoffLat != 0 && trip.dropoffLng != 0
      ? LatLng(trip.dropoffLat, trip.dropoffLng)
      : null;

  Navigator.of(context).pushReplacement(
    MaterialPageRoute(
      builder: (_) => CustomerDispatchScreen(
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

  const LiveTripScreen({
    super.key,
    required this.tripId,
    required this.repository,
  });

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Live Trip')),
      body: StreamBuilder<ActiveTrip?>(
        stream: repository.tripStream(tripId),
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.waiting) {
            return const Center(child: CircularProgressIndicator());
          }
          if (snapshot.hasError) {
            return _MessageState(
              icon: Icons.error_outline,
              title: 'Could not load this trip',
              body: 'Check your connection and try again.',
              onClose: () => Navigator.of(context).pop(),
            );
          }
          final trip = snapshot.data;
          if (trip == null) {
            return _MessageState(
              icon: Icons.search_off,
              title: 'Trip no longer available',
              body: 'It may have been cancelled or removed.',
              onClose: () => Navigator.of(context).pop(),
            );
          }
          if (trip.status == TripStatus.completed) {
            return _CompletedTripView(trip: trip);
          }
          if (trip.status == TripStatus.cancelled) {
            final reason = trip.cancellationSource == 'driver'
                ? 'This trip was cancelled by the driver.'
                : trip.cancellationSource == 'customer'
                ? 'You cancelled this trip.'
                : 'This request is no longer active.';
            return _MessageState(
              icon: Icons.cancel_outlined,
              title: 'Trip cancelled',
              body: reason,
              onClose: () => _navigateBackToBookingOrPop(context, trip),
            );
          }
          // Special state: auto-reassignment exhausted — prompt fare boost.
          if (trip.status == TripStatus.needsCustomerAction) {
            return _NeedsActionBody(trip: trip, repository: repository);
          }
          return _LiveTripBody(trip: trip, repository: repository);
        },
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

  const _NeedsActionBody({required this.trip, required this.repository});

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
    if (val == null || val <= widget.trip.fareAmount) {
      setState(
        () => _error =
            'Enter an amount higher than the current fare (${widget.trip.fareFormatted})',
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
      if (mounted) _navigateBackToBookingOrPop(context, widget.trip);
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
                    final base = widget.trip.fareAmount;
                    final boosted = (base * (100 + pct) / 100).round();
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

  const _LiveTripBody({required this.trip, required this.repository});

  @override
  State<_LiveTripBody> createState() => _LiveTripBodyState();
}

class _LiveTripBodyState extends State<_LiveTripBody> {
  final SeSeMapController _mapController = SeSeMapController();

  /// Road-network route (OSRM / Google Directions).
  List<LatLng> _routePoints = [];

  /// Dynamic map camera animation loop timer.
  Timer? _cameraLoopTimer;

  /// Dynamic dispatch tuning & map camera animation settings from Firestore `system_settings/dispatch`.
  DispatchTuning _dispatchTuning = const DispatchTuning();
  StreamSubscription? _dispatchTuningSub;

  /// Nearby drivers within the active dispatch stage radius belonging to the trip's vehicle category.
  List<_NearbyDriverMarker> _nearbyDrivers = [];
  StreamSubscription? _nearbyDriversSub;

  /// Resolves the driver search radius (in kilometers) for the active dispatch stage.
  double get _activeStageRadiusKm =>
      _dispatchTuning.radiusForTier(widget.trip.dispatchTier);

  @override
  void initState() {
    super.initState();
    _fitRoute();
    _loadRoadRoute();
    _initDispatchTuning();
    _initNearbyDrivers();
    if (_isSearching) {
      // Delay slightly after initial layout so the camera loop smoothly engages
      Future.delayed(const Duration(milliseconds: 1500), () {
        if (mounted && _isSearching) {
          _startCameraLoop();
        }
      });
    }
  }

  @override
  void didUpdateWidget(covariant _LiveTripBody oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.trip.pickupLat != widget.trip.pickupLat ||
        oldWidget.trip.pickupLng != widget.trip.pickupLng ||
        oldWidget.trip.dropoffLat != widget.trip.dropoffLat ||
        oldWidget.trip.dropoffLng != widget.trip.dropoffLng) {
      _fitRoute();
      _loadRoadRoute();
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
    _stopCameraLoop();
    _nearbyDriversSub?.cancel();
    _dispatchTuningSub?.cancel();
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
      _mapController.fitPoints(_pickup, _dropoff, padding: 72);
    });
  }

  /// Fetches the drivable road geometry.
  Future<void> _loadRoadRoute() async {
    if (SeSeMapView.debugTileProviderOverride != null) return;
    final points = await LocationService.fetchRoutePolyline(_pickup, _dropoff);
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
            final lat = (fix?['latitude'] as num?)?.toDouble() ??
                (data['lat'] as num?)?.toDouble();
            final lng = (fix?['longitude'] as num?)?.toDouble() ??
                (data['lng'] as num?)?.toDouble();
            if (lat == null || lng == null) continue;
            final pos = LatLng(lat, lng);

            // Distance gate matching active dispatch stage radius (e.g. Stage 1: 0-3km, Stage 2: 0-6km, Stage 3: 0-10km)
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
    final hasDriverFix = trip.driverLat != null && trip.driverLng != null;
    final focus = hasDriverFix
        ? LatLng(trip.driverLat!, trip.driverLng!)
        : LatLng(
            (pickup.latitude + dropoff.latitude) / 2,
            (pickup.longitude + dropoff.longitude) / 2,
          );

    final markers = [
      SeSeMapView.pin(point: pickup, color: Colors.green),
      SeSeMapView.pin(point: dropoff, color: Colors.red),
      if (hasDriverFix)
        SeSeMapView.pin(
          point: LatLng(trip.driverLat!, trip.driverLng!),
          color: Colors.blue,
        ),
      // Real-time nearby drivers within 15km radius circle
      if (_isSearching)
        ..._nearbyDrivers.map(
          (d) => MapPin(
            id: 'driver_${d.id}',
            point: d.position,
            color: AppColors.seseGold,
            label: 'DRIVER',
          ),
        ),
    ];

    final polylines = [
      SeSeMapView.route(
        points: _routePoints.isNotEmpty ? _routePoints : [pickup, dropoff],
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
            onCancel: () => _cancel(context),
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
      if (context.mounted) _navigateBackToBookingOrPop(context, widget.trip);
    } on TripException catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(e.userMessage)));
      }
    }
  }
}

// ── Bid carousel ──────────────────────────────────────────────────────────────

/// Horizontal scrolling carousel of driver bids (max 5 visible).
/// Shown while the trip is in a "still searching" state so the customer
/// can accept the best bid without waiting for the automatic assignment.
class _BidCarousel extends StatelessWidget {
  static const int _maxVisible = 5;

  final ActiveTrip trip;
  final TripRepository repository;

  const _BidCarousel({required this.trip, required this.repository});

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<List<BidModel>>(
      stream: repository.bidsStream(trip.tripId),
      builder: (context, snapshot) {
        final bids =
            snapshot.data
                ?.where((b) => b.status == BidStatus.pending)
                .take(_maxVisible)
                .toList() ??
            const [];
        if (bids.isEmpty) return const SizedBox.shrink();
        return Container(
          color: Theme.of(context).colorScheme.surfaceContainerLow,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 10, 16, 4),
                child: Text(
                  '${bids.length} driver${bids.length == 1 ? '' : 's'} offered a fare',
                  style: Theme.of(context).textTheme.labelMedium
                      ?.copyWith(fontWeight: FontWeight.bold),
                ),
              ),
              SizedBox(
                height: 148,
                child: ListView.separated(
                  scrollDirection: Axis.horizontal,
                  padding: const EdgeInsets.fromLTRB(12, 0, 12, 10),
                  separatorBuilder: (context, index) =>
                      const SizedBox(width: 10),
                  itemCount: bids.length,
                  itemBuilder: (ctx, i) => _BidCard(
                    bid: bids[i],
                    onAccept: () => _accept(ctx, bids[i].driverId),
                    onReject: () => _reject(ctx, bids[i].driverId),
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Future<void> _accept(BuildContext context, String driverId) async {
    try {
      await repository.acceptBid(trip.tripId, driverId);
    } on TripException catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(e.userMessage)));
      }
    }
  }

  Future<void> _reject(BuildContext context, String driverId) async {
    try {
      await repository.rejectBid(trip.tripId, driverId);
    } on TripException catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(e.userMessage)));
      }
    }
  }
}

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
    return Card(
      margin: EdgeInsets.zero,
      child: SizedBox(
        width: 160,
        child: Padding(
          padding: const EdgeInsets.all(10),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      UserAvatar(
                        displayName: bid.driverName,
                        photoUrl: bid.photoUrl,
                        radius: 16,
                      ),
                      if (bid.isVerifiedDriver) ...[
                        const SizedBox(height: 2),
                        const VerifiedBadge(
                          variant: VerifiedBadgeVariant.driver,
                        ),
                      ],
                    ],
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Row(
                      children: [
                        Flexible(
                          child: Text(
                            bid.driverName.split(' ').first,
                            style: const TextStyle(
                              fontWeight: FontWeight.bold,
                              fontSize: 12,
                            ),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        if (bid.isVerifiedDriver) ...[
                          const SizedBox(width: 4),
                          const Icon(
                            Icons.verified,
                            size: 12,
                            color: Colors.blue,
                          ),
                        ],
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 4),
              if (bid.rating > 0)
                Row(
                  children: [
                    const Icon(Icons.star, size: 11, color: Colors.amber),
                    const SizedBox(width: 2),
                    Text(
                      bid.rating.toStringAsFixed(1),
                      style: const TextStyle(fontSize: 10),
                    ),
                    if (bid.etaMinutes != null) ...{
                      const SizedBox(width: 6),
                      Text(
                        '~${bid.etaMinutes} min',
                        style: TextStyle(
                          fontSize: 10,
                          color: cs.onSurfaceVariant,
                        ),
                      ),
                    },
                  ],
                ),
              const Spacer(),
              Text(
                fareLabel,
                style: TextStyle(
                  fontWeight: FontWeight.bold,
                  fontSize: 16,
                  color: cs.primary,
                ),
              ),
              const SizedBox(height: 6),
              Row(
                children: [
                  Expanded(
                    child: FilledButton(
                      onPressed: onAccept,
                      style: FilledButton.styleFrom(
                        backgroundColor: Colors.green.shade700,
                        padding: EdgeInsets.zero,
                        minimumSize: const Size(0, 28),
                        textStyle: const TextStyle(fontSize: 11),
                      ),
                      child: const Text('Accept'),
                    ),
                  ),
                  const SizedBox(width: 4),
                  Expanded(
                    child: OutlinedButton(
                      onPressed: onReject,
                      style: OutlinedButton.styleFrom(
                        padding: EdgeInsets.zero,
                        minimumSize: const Size(0, 28),
                        textStyle: const TextStyle(fontSize: 11),
                        side: BorderSide.none,
                        backgroundColor: Theme.of(context)
                            .colorScheme
                            .surfaceContainerHighest,
                      ),
                      child: const Text('Reject'),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ── Delivery PIN banner ────────────────────────────────────────────────────────

/// Prominently surfaces the 4-digit delivery security PIN to the customer
/// so they can share it with the driver at drop-off.
///
/// Appears only when [ActiveTrip.deliveryPinRequired] is true and the trip
/// has a server-issued [ActiveTrip.deliveryPin]. The server generates this
/// PIN inside `createTrip` when the customer opted-in or when the Hub's
/// `forceDeliveryPinSystemWide` flag is active.
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
class _LiveTripSearchingSheet extends StatelessWidget {
  final ActiveTrip trip;
  final TripRepository repository;
  final int nearbyDriversCount;
  final double stageRadius;
  final VoidCallback onCancel;

  const _LiveTripSearchingSheet({
    required this.trip,
    required this.repository,
    required this.nearbyDriversCount,
    required this.stageRadius,
    required this.onCancel,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;

    final String message;
    switch (trip.status) {
      case TripStatus.searchingDriver:
      case TripStatus.unknown:
        message = trip.reassignmentCount > 0
            ? 'Driver had to cancel. Finding you another nearby driver...'
            : (trip.declineCount > 0
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
        final name = trip.driver?.fullName ?? 'Your driver';
        message = '$name is on the way to pickup';
      case TripStatus.driverArrived:
        message = 'Your driver has arrived at the pickup point';
      case TripStatus.inProgress:
        message = 'Trip in progress — sit back and relax';
      case TripStatus.needsCustomerAction:
      case TripStatus.completed:
      case TripStatus.cancelled:
        message = '';
    }

    final fareStr = trip.fareFormatted.isNotEmpty
        ? trip.fareFormatted
        : '₦${trip.fareAmount.toStringAsFixed(0)}';

    return DraggableScrollableSheet(
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
                  color: cs.primaryContainer.withValues(alpha: 0.5),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Row(
                  children: [
                    SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: cs.primary,
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        message,
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                          color: cs.onSurface,
                        ),
                      ),
                    ),
                    if (nearbyDriversCount > 0) ...[
                      const SizedBox(width: 8),
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 8, vertical: 4),
                        decoration: BoxDecoration(
                          color: cs.primary,
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Text(
                          '$nearbyDriversCount nearby (${stageRadius.toStringAsFixed(stageRadius % 1 == 0 ? 0 : 1)}km)',
                          style: TextStyle(
                            fontSize: 10,
                            fontWeight: FontWeight.bold,
                            color: cs.onPrimary,
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
                            style: const TextStyle(
                              fontSize: 22,
                              fontWeight: FontWeight.bold,
                              color: Colors.black87,
                            ),
                          ),
                          const SizedBox(width: 6),
                          IconButton(
                            key: const Key('boost_fare_pencil_button'),
                            icon: const Icon(
                              Icons.edit_note_rounded,
                              color: Color(0xFFD97706),
                              size: 22,
                            ),
                            tooltip: 'Boost Offer Fare',
                            visualDensity: VisualDensity.compact,
                            onPressed: () =>
                                _showBoostFareDialog(context, trip, repository),
                          ),
                        ],
                      ),
                    ],
                  ),
                  OutlinedButton.icon(
                    key: const Key('split_fare_button'),
                    icon: const Icon(Icons.group_add_outlined, size: 16),
                    label: const Text('Split Fare',
                        style: TextStyle(fontSize: 12)),
                    style: OutlinedButton.styleFrom(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 10, vertical: 6),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                    ),
                    onPressed: () async {
                      final splitId = await SplitRequestSheet.show(
                        context,
                        tripId: trip.tripId,
                      );
                      if (splitId != null && context.mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(
                            content: Text(
                              'Invites sent. The split activates once everyone accepts.',
                            ),
                          ),
                        );
                      }
                    },
                  ),
                ],
              ),

              if (trip.deliveryPinRequired &&
                  trip.deliveryPin != null &&
                  trip.deliveryPin!.trim().isNotEmpty) ...[
                const SizedBox(height: 12),
                _DeliveryPinBanner(pin: trip.deliveryPin!),
              ],

              // Pending driver bids carousel
              const SizedBox(height: 12),
              _BidCarousel(trip: trip, repository: repository),

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
                          trip.pickupAddress,
                          style: const TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w500,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        const SizedBox(height: 16),
                        Text(
                          trip.dropoffAddress,
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
                  onPressed: onCancel,
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

  const _AcceptedDriverSheet({
    required this.driver,
    required this.trip,
    this.onCancel,
  });

  @override
  State<_AcceptedDriverSheet> createState() => _AcceptedDriverSheetState();
}

class _AcceptedDriverSheetState extends State<_AcceptedDriverSheet> {
  bool _hidePhones = false;

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

  String _customerStatusMessage(TripStatus status, String driverName) {
    final firstName = _firstName(driverName);
    switch (status) {
      case TripStatus.driverAccepted:
      case TripStatus.driverArriving:
        return '$firstName is on the way to pickup';
      case TripStatus.driverArrived:
        return '$firstName has arrived at pickup point';
      case TripStatus.inProgress:
        return 'Trip in progress — sit back and relax';
      default:
        return 'Driver assigned to your trip';
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
      return 'SENDER PAYS';
    }
    return trip.paymentMethod.toUpperCase();
  }

  String _formatCustomerPaymentSubtitle(ActiveTrip trip, DriverInfo driver) {
    final fareStr = trip.fareFormatted.isNotEmpty
        ? trip.fareFormatted
        : '₦${trip.fareAmount.toStringAsFixed(0)}';
    final vehicle =
        driver.vehicleLabel.isNotEmpty ? ' • ${driver.vehicleLabel}' : '';

    if (trip.paymentMode.toLowerCase() == 'receiver_pays') {
      return '$fareStr$vehicle • Receiver Pays Cash at Drop-off';
    }

    if (trip.walletCoverageAmount > 0 && trip.cashToCollect > 0) {
      return '$fareStr$vehicle • Pay ₦${trip.cashToCollect.toStringAsFixed(0)} Cash (₦${trip.walletCoverageAmount.toStringAsFixed(0)} Wallet Locked)';
    } else if (trip.walletCoverageAmount > 0 && trip.cashToCollect <= 0) {
      return '$fareStr$vehicle • 100% Wallet (₦0 Cash)';
    } else if (trip.cashToCollect > 0) {
      return '$fareStr$vehicle • Pay ₦${trip.cashToCollect.toStringAsFixed(0)} Cash at Pickup';
    }

    return '$fareStr$vehicle • ${_paymentLabel(trip)}';
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
                  onTap: () {},
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

                // a. Status Container
                Container(
                  key: const Key('customer_active_status_container'),
                  width: double.infinity,
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
                  decoration: BoxDecoration(
                    color: isDark
                        ? const Color(0xFF78350F).withValues(alpha: 0.3)
                        : const Color(0xFFFEF3C7),
                    borderRadius: BorderRadius.circular(24),
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
                        size: 22,
                      ),
                      const SizedBox(width: 8),
                      Flexible(
                        child: Text(
                          _customerStatusMessage(trip.status, driver.fullName),
                          style: TextStyle(
                            fontSize: 15,
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

                // b. Identity Row (Mutual Driver Profile Card)
                InkWell(
                  key: const Key('customer_driver_profile_card'),
                  borderRadius: BorderRadius.circular(12),
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
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 4),
                    child: Row(
                      children: [
                        UserAvatar(
                          displayName: driver.fullName,
                          photoUrl: driver.photoUrl,
                          radius: 22,
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
                                      driver.fullName.isNotEmpty
                                          ? driver.fullName
                                          : 'Driver',
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
                                      Row(
                                        mainAxisSize: MainAxisSize.min,
                                        children: [
                                          const Icon(
                                            Icons.star_rounded,
                                            color: Colors.amber,
                                            size: 16,
                                          ),
                                          Text(
                                            ' ${(driver.rating > 0 ? driver.rating : 5.0).toStringAsFixed(1)}',
                                            style: const TextStyle(
                                              fontWeight: FontWeight.bold,
                                              fontSize: 13,
                                            ),
                                          ),
                                        ],
                                      ),
                                    ],
                                  ),
                                  const SizedBox(height: 2),
                                  Text(
                                    _formatCustomerPaymentSubtitle(trip, driver),
                                    style: TextStyle(
                                      fontSize: 13,
                                      color: isDark ? Colors.grey.shade300 : Colors.grey.shade700,
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

                // e. Cancellation Option
                if (widget.onCancel != null && trip.status != TripStatus.completed) ...[
                  const SizedBox(height: 12),
                  Center(
                    child: TextButton(
                      onPressed: widget.onCancel,
                      style: TextButton.styleFrom(
                        foregroundColor: Colors.red.shade600,
                        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
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
                  ),
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
        borderRadius: BorderRadius.circular(10),
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 8),
          decoration: BoxDecoration(
            color: bgColor,
            borderRadius: BorderRadius.circular(10),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(icon, color: color, size: 18),
              const SizedBox(width: 6),
              Flexible(
                child: Text(
                  label,
                  style: TextStyle(
                    color: color,
                    fontWeight: FontWeight.bold,
                    fontSize: 12,
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
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Increase your offer to attract nearby drivers faster. Decreases below current fare (${trip.fareFormatted.isNotEmpty ? trip.fareFormatted : "₦${trip.fareAmount.toStringAsFixed(0)}"}) are prohibited.',
              style: const TextStyle(fontSize: 12, color: Colors.grey),
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              children: [5, 10, 20].map((pct) {
                final base = trip.fareAmount;
                final boosted = (base * (100 + pct) / 100).round();
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
                    }
                  },
            child: const Text('Confirm Increase'),
          ),
        ],
      ),
    ),
  );
}


