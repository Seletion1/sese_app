import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import 'package:latlong2/latlong.dart';
import 'package:sese_core/sese_core.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../../../core/services/remote_config_service.dart';
import '../../customer/services/location_service.dart';
import '../../notifications/notification_inbox_screen.dart';
import '../../trips/models/trip_models.dart';
import '../../trips/presentation/trip_rating_dialog.dart';
import '../../trips/services/trip_rating_service.dart';
import '../../../widgets/map_provider.dart';
import '../services/driver_fleet_service.dart';
import '../services/driver_overlay_service.dart';
import '../services/driver_status_service.dart';
import '../services/driver_streak_service.dart';
import '../services/navigation_launcher_service.dart';
import 'driver_fleet_screen.dart';
import 'online_verification_shield_modal.dart';
import 'widgets/driver_active_trip_card.dart';
import 'widgets/incoming_offer_sheet.dart';
import 'widgets/order_feed.dart';
import 'widgets/order_pool_sheet.dart';
import 'widgets/slide_to_offline.dart';
import 'widgets/streak_celebration_modal.dart';
import 'widgets/streak_progress_banner.dart';
import '../../payments/payment_service.dart';
import '../../wallet/earnings_screen.dart';
import '../../wallet/earnings_service.dart';
import 'widgets/verification_banner.dart';

class DriverDashboardScreen extends StatefulWidget {
  final DriverFleetService fleetService;

  /// Zero-trust availability handshake. Defaults to the production
  /// Cloud Functions backend; inject a fake in tests.
  final DriverStatusService? statusService;

  /// Daily commission streak data + trip actions. Defaults to the
  /// production backend; inject a fake in tests.
  final DriverStreakService? streakService;
  final String driverId;
  final RegionConfig? config;
  final AppUser? user;
  final VoidCallback? onSignOut;

  /// Test seam: seed map position without touching platform location APIs.
  final LatLng? initialPosition;

  const DriverDashboardScreen({
    super.key,
    required this.fleetService,
    this.statusService,
    this.streakService,
    this.driverId = 'current_driver',
    this.config,
    this.user,
    this.onSignOut,
    this.initialPosition,
  });

  @override
  State<DriverDashboardScreen> createState() => _DriverDashboardScreenState();
}

class _DriverDashboardScreenState extends State<DriverDashboardScreen>
    with WidgetsBindingObserver {
  bool _isOnline = false;
  VehicleModel? _activeVehicle;
  List<VehicleModel> _fleet = [];
  bool _loading = true;

  /// Active online session ID returned by backend or generated locally.
  String? _currentSessionId;

  /// True when this device's online session was superseded or taken offline
  /// by another device. Drives the non-intrusive notification banner.
  bool _sessionOverriddenOnOtherDevice = false;

  /// Real-time subscription to driver availability document (`driver_status/{uid}`).
  StreamSubscription<DriverStatusSnapshot>? _statusSubscription;
  bool _hasReceivedInitialStatusSnapshot = false;

  /// Listener callback for silent FCM data messages indicating session termination.
  VoidCallback? _pushSessionListener;

  /// True while the activity is backgrounded (overlay bubble owns the UI).
  bool _appPaused = false;

  /// True when the driver mutes spoken audio turn navigation in active trip view.
  bool _audioGuidanceMuted = false;

  // ── Driver Resting Break (Module 4) ────────────────────────────────────────
  /// True while the driver is on a deliberate rest break. Auto-push pings
  /// (Stage 1 exclusive offers) are suppressed but the Quick-Order
  /// pool badge stays visible so the driver can manually accept pool orders.
  bool _isOnBreak = false;

  /// Seconds remaining on the current break countdown.
  int _breakRemainingSeconds = 0;

  /// Ticks every second to decrement [_breakRemainingSeconds] and auto-resume
  /// when the break expires.
  Timer? _breakTimer;

  /// Camera for the home map canvas. Created once; positions move through
  /// it (never recreated — OsmMapView applies the initial center only).
  final SeSeMapController _mapController = SeSeMapController();

  /// Live GPS position stream subscription for continuous tracking & movement detection.
  StreamSubscription<Position>? _livePositionSubscription;

  /// Sheet controller for the full-width draggable active trip bottom sheet.
  final DraggableScrollableController _activeTripSheetController =
      DraggableScrollableController();

  /// Service calculating live completed trip earnings and daily net profit.
  late final EarningsService _earningsService = EarningsService();

  /// State tracking for auto-collapsing the active trip card on movement.
  ActiveTrip? _currentActiveTrip;
  ActiveTrip? _lastActiveTripForRating;
  String? _trackedTripId;
  TripStatus? _lastTrackedStatus;
  LatLng? _tripStartLocation;
  LatLng? _panOriginPosition;
  bool _hasAutoCollapsedForTrip = false;
  bool _isFollowingUser = true;

  /// Unified controller for immersive map interaction, UI autohide, and snap-to-edge sheet collapse.
  late final MapInteractionController _mapInteractionController =
      MapInteractionController(
    inactivityDuration: const Duration(milliseconds: 2000),
    sheetCollapsedExtent: _sheetCollapsedSize,
    sheetStandardExtent: _sheetStandardSize,
    sheetController: _activeTripSheetController,
    onRecenter: _recenterMap,
    onImmersiveChanged: (val) {
      if (mounted) setState(() {});
    },
  );

  bool get _isMapInteracting => _mapInteractionController.isImmersive;
  DateTime? _lastPanTime;
  List<LatLng> _activeRoutePoints = [];
  List<RouteStep> _activeRouteSteps = [];
  RouteStep? _currentGuidanceStep;
  double _currentSpeedKmh = 0.0;
  DateTime? _lastGpsFixTime;
  LatLng? _lastGpsPosition;
  DateTime? _lastRouteFetchTime;
  final Set<String> _ratedTripDocIds = {};

  void _updateCurrentGuidanceStep(LatLng driverPos) {
    if (_activeRouteSteps.isEmpty || driverPos.latitude == 0) return;
    RouteStep? nextStep;
    double minUpcomingDist = double.infinity;

    // Scan steps along the route for the immediate upcoming maneuver ahead
    for (int i = 0; i < _activeRouteSteps.length; i++) {
      final step = _activeRouteSteps[i];
      final distM = const Distance().as(LengthUnit.Meter, driverPos, step.location);
      if (distM < minUpcomingDist && distM >= 10.0) {
        minUpcomingDist = distM;
        nextStep = step;
        break;
      }
    }

    // If past all intermediate turns, lock to the final destination arrival step
    if (nextStep == null && _activeRouteSteps.isNotEmpty) {
      nextStep = _activeRouteSteps.last;
    }

    if (nextStep != null) {
      _currentGuidanceStep = nextStep;
    }
  }

  void _handleMapGestureStarted() {
    _mapInteractionController.notifyInteractionStarted(
      currentLat: _driverPosition.latitude,
      currentLng: _driverPosition.longitude,
    );
  }

  void _checkAndShowPostTripRating(ActiveTrip trip) async {
    final ratedDocId = '${trip.tripId}_${widget.driverId}';
    if (_ratedTripDocIds.contains(ratedDocId)) return;
    _ratedTripDocIds.add(ratedDocId);

    final ratingService = TripRatingService();
    final alreadyRated =
        await ratingService.hasRated(trip.tripId, widget.driverId);
    if (alreadyRated || !mounted) return;

    final customerId =
        trip.customerId.isNotEmpty ? trip.customerId : 'customer';
    final customerName =
        trip.customerName.isNotEmpty ? trip.customerName : 'Customer';

    // ignore: unawaited_futures
    TripRatingDialog.show(
      context,
      tripId: trip.tripId,
      raterId: widget.driverId,
      ratedUserId: customerId,
      ratedUserName: customerName,
      isRatedUserDriver: false,
      ratingService: ratingService,
    );
  }

  Future<void> _fetchActiveTripRoute(ActiveTrip active) async {
    if (_driverPosition.latitude == 0.0 && _driverPosition.longitude == 0.0) {
      return;
    }
    final isDropoffStage = active.status == TripStatus.inProgress;
    final destLat = isDropoffStage ? active.dropoffLat : active.pickupLat;
    final destLng = isDropoffStage ? active.dropoffLng : active.pickupLng;
    if (destLat == 0.0 || destLng == 0.0) return;

    final now = DateTime.now();
    if (_lastRouteFetchTime != null &&
        now.difference(_lastRouteFetchTime!) < const Duration(seconds: 8) &&
        _activeRoutePoints.isNotEmpty) {
      return;
    }
    _lastRouteFetchTime = now;

    try {
      final details = await LocationService.fetchRouteDetails(
        _driverPosition,
        LatLng(destLat, destLng),
      );
      if (mounted && details.points.isNotEmpty) {
        _activeRoutePoints = details.points;
        _activeRouteSteps = details.steps;
        _updateCurrentGuidanceStep(_driverPosition);
        setState(() {});
      }
    } catch (_) {}
  }

  /// Opens the Tier-3 pool as a bottom sheet. Accepting inside calls the
  /// zero-trust `acceptTrip` callable (atomic first-wins + verified +
  /// approved-vehicle); there is deliberately no separate `claimPoolOrder`
  /// endpoint — a second entry point to the same transaction would be a
  /// duplicate, not a feature.
  Future<void> _openPoolSheet() async {
    final accepted = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: Colors.transparent,
      builder: (_) => OrderPoolSheet(
        streakService: _streaks,
        driverPosition: _driverPosition,
        currencySymbol: _currencySymbol,
        driverId: widget.driverId,
      ),
    );
    if (accepted != null && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Order accepted — head to pickup.')),
      );
    }
  }

  /// Guards the server handshake so the UI can never self-assert status
  /// while a grant is in flight.
  bool _syncing = false;

  /// Driver's current coordinates. Defaults to Lagos; refined from the
  /// platform location fix when available. Centers the home map canvas and
  /// feeds the signed online payload plus the incoming-offer route preview.
  late LatLng _driverPosition;

  late final DriverStatusService _status =
      widget.statusService ?? DriverStatusService();

  /// Streak streams/actions. Constructing never touches Firebase.
  late final DriverStreakService _streaks =
      widget.streakService ?? DriverStreakService(driverId: widget.driverId);

  String get _currencySymbol => widget.config?.currencySymbol ?? '₦';

  @override
  void initState() {
    super.initState();
    _streaks.driverId ??= widget.driverId;
    WidgetsBinding.instance.addObserver(this);
    _driverPosition =
        widget.initialPosition ?? const LatLng(6.5244, 3.3792); // Lagos
    _loadFleet();
    _resolvePosition();
    _startLivePositionTracking();
    _initSessionControl();
    _mapController.onFollowingChanged = () {
      if (mounted) {
        setState(() {
          _isFollowingUser = _mapController.isFollowingUser;
          if (!_isFollowingUser) {
            _lastPanTime = DateTime.now();
            _panOriginPosition = _driverPosition;
            _handleMapGestureStarted();
          }
        });
      }
    };
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _mapController.move(_driverPosition, 15.0);
    });
    // Overlay → app actions (bubble tap, overlay accept/reject/expired).
    DriverOverlayService.instance.listenActions(_handleOverlayAction);
  }

  void _initSessionControl() {
    _statusSubscription =
        _status.driverStatusStream(widget.driverId).listen((snapshot) {
      if (!mounted) return;
      if (!_hasReceivedInitialStatusSnapshot) {
        _hasReceivedInitialStatusSnapshot = true;
        unawaited(_restoreOnlineSession(snapshot));
      }
      // If we are currently online on this device, check if our session was revoked:
      if (_isOnline) {
        final sessionRevoked = (_currentSessionId != null &&
                snapshot.activeSessionId != null &&
                snapshot.activeSessionId != _currentSessionId) ||
            (!snapshot.isOnline);

        if (sessionRevoked) {
          _handleRemoteSessionTermination();
        }
      }
    });

    _pushSessionListener = () {
      final event = PushNotificationService.driverSessionTerminatedEvents.value;
      if (event == null || !mounted) return;
      final termSession = event['terminatedSessionId']?.toString();
      if (_isOnline &&
          (termSession == null ||
              termSession == _currentSessionId ||
              _currentSessionId == null)) {
        _handleRemoteSessionTermination();
      }
    };
    PushNotificationService.driverSessionTerminatedEvents
        .addListener(_pushSessionListener!);
  }

  Future<void> _restoreOnlineSession(DriverStatusSnapshot snapshot) async {
    SharedPreferences prefs;
    try {
      prefs = await SharedPreferences.getInstance();
    } catch (e) {
      debugPrint('DriverDashboard: could not restore online session: $e');
      return;
    }
    final savedSessionId = prefs.getString('driver_online_session');

    if (!snapshot.isOnline) return;

    final activeSessionId = snapshot.activeSessionId;
    if (activeSessionId == null || savedSessionId != activeSessionId) {
      if (savedSessionId != null) {
        await prefs.remove('driver_online_session');
      }
      if (mounted) {
        setState(() => _sessionOverriddenOnOtherDevice = true);
      }
      return;
    }

    if (!mounted || _isOnline) return;
    setState(() {
      _isOnline = true;
      _currentSessionId = activeSessionId;
      _streaks.activeSessionId = activeSessionId;
      _sessionOverriddenOnOtherDevice = false;
    });
    DriverOverlayService.instance.isOnline = true;
    // Re-establish the visible online signal after process recreation. The
    // dashboard GPS stream is already started in initState and remains alive
    // while the Android foreground overlay service keeps the app process up.
    unawaited(PushNotificationService.showOngoingOnlineAlert());
    unawaited(PushNotificationService.subscribe('driver_${widget.driverId}'));
    unawaited(MediaPermissionService.ensureBackgroundLocation());
    if (WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed) {
      unawaited(DriverOverlayService.instance.closeOverlayWidget());
    } else {
      unawaited(DriverOverlayService.instance.showOverlayWidget());
    }
  }

  Future<void> _persistOnlineSession(String? sessionId) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      const key = 'driver_online_session';
      if (sessionId == null || sessionId.isEmpty) {
        await prefs.remove(key);
      } else {
        await prefs.setString(key, sessionId);
      }
    } catch (e) {
      debugPrint('DriverDashboard: online session persistence failed: $e');
    }
  }

  void _handleRemoteSessionTermination() {
    if (!_isOnline && !_sessionOverriddenOnOtherDevice) return;
    setState(() {
      _isOnline = false;
      _currentSessionId = null;
      _streaks.activeSessionId = null;
      _sessionOverriddenOnOtherDevice = true;
    });
    DriverOverlayService.instance.isOnline = false;

    // Cleanup background and foreground services on this device
    // ignore: discarded_futures
    AppSoundService.instance.playOfflineSound();
    // ignore: discarded_futures
    DriverOverlayService.instance.hide();
    // ignore: discarded_futures
    PushNotificationService.cancelOnlineAlert();
    // ignore: discarded_futures
    PushNotificationService.unsubscribe('driver_${widget.driverId}');
    unawaited(_persistOnlineSession(null));
  }

  @override
  void dispose() {
    _mapInteractionController.dispose();
    WidgetsBinding.instance.removeObserver(this);
    _statusSubscription?.cancel();
    _livePositionSubscription?.cancel();
    _activeTripSheetController.dispose();
    if (_pushSessionListener != null) {
      PushNotificationService.driverSessionTerminatedEvents
          .removeListener(_pushSessionListener!);
    }
    _breakTimer?.cancel();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // `inactive` fires on brief focus losses (call overlays, notification shade
    // pull-down, task-switcher peek). We should NOT treat these as a full
    // background event — doing so would incorrectly toggle the bubble and
    // could mislead the online/offline state.
    //
    // `paused`, `detached`, and `hidden` count as genuinely backgrounded
    // for the purposes of the floating bubble.
    final backgrounded =
        state == AppLifecycleState.paused ||
        state == AppLifecycleState.detached ||
        state == AppLifecycleState.hidden;
    final foreground = state == AppLifecycleState.resumed;

    if (!foreground && !backgrounded) return; // inactive — ignore

    final nowPaused = backgrounded;
    if (nowPaused == _appPaused) return;
    setState(() => _appPaused = nowPaused);
    if (!mounted) return;
    if (nowPaused) {
      // Minimized while ONLINE: the floating SeSe bubble owns the screen
      // and the single unified "SeSe Driver Active" notification holds the
      // OS foreground signal. The driver is NOT taken offline — GPS fixes
      // and dispatch offers keep flowing until an explicit go-offline.
      if (_isOnline) {
        // ignore: discarded_futures
        DriverOverlayService.instance.showOverlayWidget();
      }
    } else {
      // Back in foreground: overlay yields to the in-app UI.
      // ignore: discarded_futures
      DriverOverlayService.instance.closeOverlayWidget();
    }
  }

  /// Overlay isolate actions: bubble tap (foreground request) and overlay
  /// accept/reject/expired outcomes for background order popups.
  Future<void> _handleOverlayAction(String action, String tripId) async {
    switch (action) {
      case 'open_app':
      case 'foreground':
        // Bubble tapped while minimized: dismiss the bubble and bring
        // sese_ride directly to the foreground via
        // Intent.FLAG_ACTIVITY_REORDER_TO_FRONT without data loss.
        await DriverOverlayService.instance.closeOverlayWidget();
        if (!mounted) return;
        await DriverOverlayService.instance.bringToForeground();
        break;
      case 'accepted':
      case 'rejected':
        // Overlay order was accepted or rejected: dismiss the overlay popup and
        // immediately restore the full app to the foreground per Rule 3.
        await DriverOverlayService.instance.closeOverlayWidget();
        if (!mounted) return;
        await DriverOverlayService.instance.bringToForeground();
        setState(() {});
        break;
      case 'expired':
        // Offer expired in the background overlay: restore floating bubble if still paused.
        if (_appPaused && _isOnline) {
          await DriverOverlayService.instance.showOverlayWidget();
        } else {
          await DriverOverlayService.instance.closeOverlayWidget();
        }
        if (!mounted) return;
        setState(() {});
        break;
    }
  }

  /// Best-effort platform fix for the signed online payload and the
  /// incoming-offer route preview. Never throws: falls back to the seeded
  /// default when location is unavailable (denied, disabled, test env).
  Future<void> _resolvePosition() async {
    try {
      final enabled = await Geolocator.isLocationServiceEnabled();
      if (!enabled) return;
      var permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        // Step 1 — foreground disclosure (ACCESS_FINE_LOCATION).
        if (mounted) {
          final agreedFg =
              await ProminentLocationDisclosureDialog.showForeground(
            context,
            userId: widget.driverId,
          );
          if (!agreedFg) return;
        }
        permission = await Geolocator.requestPermission();
      }
      if (permission == LocationPermission.denied ||
          permission == LocationPermission.deniedForever) {
        return;
      }
      // Step 2 — background disclosure (ACCESS_BACKGROUND_LOCATION) only
      // when foreground was just granted and background is not yet granted.
      // Drivers need background GPS for dispatch even when the app is closed.
      if (permission == LocationPermission.whileInUse && mounted) {
        final agreedBg = await ProminentLocationDisclosureDialog.show(
          context,
          userId: widget.driverId,
        );
        if (agreedBg) {
          // Re-request so the OS can escalate to Always-Allow.
          permission = await Geolocator.requestPermission();
        }
      }
      if (permission == LocationPermission.denied ||
          permission == LocationPermission.deniedForever) {
        return;
      }
      final pos = await Geolocator.getCurrentPosition();
      if (!mounted) return;
      setState(() {
        _driverPosition = LatLng(pos.latitude, pos.longitude);
      });
      // Keep the home map centered as the fix refines.
      // ignore: discarded_futures
      _mapController.move(_driverPosition, 15.0);
    } catch (_) {
      // No platform location (e.g. widget tests) or native location stack
      // unavailable — keep seeded default. Plain catch handles both
      // Exceptions and Errors (e.g. DynamicLibraryLoadError).
    }
  }

  void _recenterMap() {
    final active = _currentActiveTrip;
    if (active != null && active.status == TripStatus.inProgress) {
      _mapController.recenterToBottomCenter(_driverPosition, zoom: 17.0);
    } else {
      _mapController.recenterTo(_driverPosition, 16.5);
    }
    _mapInteractionController.restoreUI();
    if (mounted) {
      setState(() {
        _isFollowingUser = true;
      });
    }
  }

  void _checkAutoResumeTracking(Position pos, LatLng newPos) {
    if (_isFollowingUser) {
      if (_isMapInteracting) {
        _mapInteractionController.restoreUI();
      }
      return;
    }
    final now = DateTime.now();
    if (_lastPanTime == null) return;

    final secondsSincePan = now.difference(_lastPanTime!).inSeconds;
    // Allow driver a quiet window (at least 4s) so manual panning isn't interrupted mid-interaction
    if (secondsSincePan < 4) return;

    // Movement detection: vehicle moving (speed > 1.2 m/s ~ 4.3 km/h) or moved > 10m from pan origin
    bool isMoving = pos.speed > 1.2;
    if (!isMoving && _panOriginPosition != null) {
      final movedM = const Distance().as(
        LengthUnit.Meter,
        _panOriginPosition!,
        newPos,
      );
      if (movedM > 10.0) {
        isMoving = true;
      }
    }

    // Auto-resume tracking if movement progresses or idle timeout reaches 15s
    if (isMoving || secondsSincePan >= 15) {
      _recenterMap();
      // Restore standard trip sheet state when movement resumes navigation
      if (_currentActiveTrip != null && isMoving) {
        _expandActiveTripSheetToStandard();
      }
    }
  }

  /// Continuously follows live GPS movement during active trips and idle positioning.
  /// Detects actual vehicle movement to auto-collapse the bottom action sheet.
  void _startLivePositionTracking() {
    _livePositionSubscription?.cancel();
    try {
      _livePositionSubscription = Geolocator.getPositionStream(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.bestForNavigation,
          distanceFilter: 8,
        ),
      ).listen(
        (pos) {
          if (!mounted) return;
          final newPos = LatLng(pos.latitude, pos.longitude);
          final now = DateTime.now();
          double speedKmh = 0.0;
          if (pos.speed > 0) {
            speedKmh = (pos.speed * 3.6).clamp(0.0, 200.0);
          } else if (_lastGpsFixTime != null && _lastGpsPosition != null) {
            final dtSec = now.difference(_lastGpsFixTime!).inMilliseconds / 1000.0;
            if (dtSec > 0.4 && dtSec < 8.0) {
              final distM = const Distance().as(LengthUnit.Meter, _lastGpsPosition!, newPos);
              speedKmh = ((distM / dtSec) * 3.6).clamp(0.0, 200.0);
            }
          }
          _lastGpsFixTime = now;
          _lastGpsPosition = newPos;

          _updateCurrentGuidanceStep(newPos);
          _mapInteractionController.onLocationUpdate(
            pos.latitude,
            pos.longitude,
            speed: pos.speed,
          );

          setState(() {
            _driverPosition = newPos;
            _currentSpeedKmh = speedKmh;
          });

          // Live map camera follow during active trip or when set to follow
          if (_isFollowingUser) {
            final active = _currentActiveTrip;
            if (active != null && active.status == TripStatus.inProgress) {
              _mapController.followToBottomCenter(newPos, zoom: 17.0);
            } else {
              _mapController.followTo(newPos);
            }
          } else {
            _checkAutoResumeTracking(pos, newPos);
          }

          // Evaluate vehicle movement to auto-collapse the bottom sheet
          _checkMovementAndAutoCollapse(pos);
        },
        onError: (e) {
          debugPrint('DriverDashboard live position stream error: $e');
        },
      );
    } catch (e) {
      debugPrint('Could not start live position tracking: $e');
    }
  }

  void _checkMovementAndAutoCollapse(Position pos) {
    final trip = _currentActiveTrip;
    if (trip == null) return;

    if (trip.tripId != _trackedTripId || trip.status != _lastTrackedStatus) {
      if (trip.status == TripStatus.inProgress &&
          _lastTrackedStatus != TripStatus.inProgress) {
        _hasAutoCollapsedForTrip = false;
        _tripStartLocation = LatLng(pos.latitude, pos.longitude);
      }
      _trackedTripId = trip.tripId;
      _lastTrackedStatus = trip.status;
    }

    if (trip.status != TripStatus.inProgress || _hasAutoCollapsedForTrip) {
      return;
    }

    // Vehicle movement detection:
    // Speed threshold: speed > 1.2 m/s (~4.3 km/h, clear vehicle driving movement)
    // Distance threshold: moved > 15m from trip start location
    bool isMoving = pos.speed > 1.2;
    if (!isMoving && _tripStartLocation != null) {
      final movedM = const Distance().as(
        LengthUnit.Meter,
        _tripStartLocation!,
        LatLng(pos.latitude, pos.longitude),
      );
      if (movedM > 15.0) {
        isMoving = true;
      }
    }

    if (isMoving) {
      _hasAutoCollapsedForTrip = true;
      _collapseActiveTripSheet();
    }
  }

  static const double _sheetCollapsedSize = 0.18;
  static const double _sheetStandardSize = 0.44;

  void _collapseActiveTripSheet() {
    if (!_activeTripSheetController.isAttached) return;
    try {
      _activeTripSheetController.animateTo(
        _sheetCollapsedSize,
        duration: const Duration(milliseconds: 320),
        curve: Curves.easeOutCubic,
      );
    } catch (_) {}
  }

  void _expandActiveTripSheetToStandard() {
    if (!_activeTripSheetController.isAttached) return;
    try {
      _activeTripSheetController.animateTo(
        _sheetStandardSize,
        duration: const Duration(milliseconds: 320),
        curve: Curves.easeOutCubic,
      );
    } catch (_) {}
  }

  void _toggleActiveTripSheet() {
    if (!_activeTripSheetController.isAttached) return;
    try {
      final current = _activeTripSheetController.size;
      final target = current <= 0.22 ? _sheetStandardSize : _sheetCollapsedSize;
      _activeTripSheetController.animateTo(
        target,
        duration: const Duration(milliseconds: 300),
        curve: Curves.easeOutCubic,
      );
    } catch (_) {}
  }

  void _autoCollapseSheetOnActiveTrip() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _collapseActiveTripSheet();
    });
  }


  /// Collects the signed GPS fix for the zero-trust online handshake.
  /// Falls back to the last known position with unknown accuracy so the
  /// server — never the client — decides.
  Future<DriverGpsFix> _collectGpsFix() async {
    try {
      final pos = await Geolocator.getCurrentPosition();
      return DriverGpsFix(
        latitude: pos.latitude,
        longitude: pos.longitude,
        accuracyMeters: pos.accuracy,
        timestamp: DateTime.now(),
        isMocked: pos.isMocked,
      );
    } catch (_) {
      // Platform location unavailable: fall back to the last known position
      // with unknown accuracy so the server — never the client — decides.
      // Plain catch also covers native-load Errors (DynamicLibraryLoadError).
      return DriverGpsFix(
        latitude: _driverPosition.latitude,
        longitude: _driverPosition.longitude,
        accuracyMeters: 9999,
        timestamp: DateTime.now(),
      );
    }
  }

  Future<void> _loadFleet({bool silent = false}) async {
    if (!silent) setState(() => _loading = true);
    try {
      final vehicles =
          await widget.fleetService.getDriverFleet(widget.driverId);
      if (!mounted) return;
      setState(() {
        _fleet = vehicles;
        if (!silent) _loading = false;
        // If there's an active selected vehicle that is verified, keep it ready
        try {
          _activeVehicle =
              vehicles.firstWhere((v) => v.isActiveSelected && v.isApproved);
        } catch (_) {
          _activeVehicle = null;
        }
      });
    } catch (_) {
      // Fleet fetch must never wedge the home tab on a spinner: show the
      // dashboard with an empty fleet instead.
      if (!mounted) return;
      setState(() {
        if (!silent) _loading = false;
        _fleet = [];
        _activeVehicle = null;
      });
    }
  }

  /// One-tap go-online: no confirmation prompt. The strict verification
  /// guard (approved vehicle + live camera shield) and the server grant
  /// still apply — only the "Are you ready?" sheet is skipped.

  /// Server-gated offline transition. The UI flips to offline ONLY on
  /// backend confirmation (which also refuses while a trip is mid-ride).
  Future<void> _goOffline() async {
    if (_syncing) return;
    setState(() => _syncing = true);
    try {
      final decision =
          await _status.requestGoOffline(driverId: widget.driverId);
      if (!mounted) return;
      if (decision.granted) {
        setState(() {
          _isOnline = false;
          _currentSessionId = null;
          _streaks.activeSessionId = null;
          _sessionOverriddenOnOtherDevice = false;
        });
        DriverOverlayService.instance.isOnline = false;
        // Audio feedback: offline double-tone.
        // ignore: discarded_futures
        AppSoundService.instance.playOfflineSound();
        // Bubble/overlay teardown + sticky-signal cancel + driver-topic
        // unsubscribe.
        // ignore: discarded_futures
        DriverOverlayService.instance.hide();
        // ignore: discarded_futures
        PushNotificationService.cancelOnlineAlert();
        // ignore: discarded_futures
        PushNotificationService.unsubscribe('driver_${widget.driverId}');
        unawaited(_persistOnlineSession(null));
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('You are now OFFLINE.')),
        );
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              decision.message.isEmpty
                  ? 'Cannot go offline right now.'
                  : decision.message,
            ),
          ),
        );
      }
    } on DriverStatusException catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(e.message)),
      );
    } finally {
      if (mounted) setState(() => _syncing = false);
    }
  }

  Future<void> _showGoOfflineConfirmation() async {
    final confirm = await showModalBottomSheet<bool>(
      context: context,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(24.0),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Text(
                'Go Offline?',
                style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 12),
              Text(
                _activeVehicle == null
                    ? "You won't receive trip requests or earn bonuses while offline."
                    : 'Online with ${_activeVehicle!.displayTitle}.\n'
                        "You won't receive trip requests or earn bonuses while offline.",
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 24),
              ElevatedButton(
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.redAccent,
                  minimumSize: const Size(double.infinity, 50),
                ),
                onPressed: () => Navigator.pop(ctx, true),
                child: const Text(
                  'Go Offline',
                  style: TextStyle(color: Colors.white),
                ),
              ),
              const SizedBox(height: 10),
              OutlinedButton(
                style: OutlinedButton.styleFrom(
                  minimumSize: const Size(double.infinity, 50),
                ),
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('Stay Online and Keep Earning'),
              ),
            ],
          ),
        ),
      ),
    );
    if (confirm == true && mounted) _goOffline();
  }

  void _goOnlineNow() {
    if (_syncing) return;

    // Hub verification gate: drivers CANNOT go Online until BOTH
    // `isProfileVerified == true` AND an approved vehicle exist
    // (sese_hub admin toggles both flags after document audit).
    // Vehicle upload itself stays non-blocking while pending.
    // A null read (offline / unavailable) falls through to the vehicle
    // guard below; the Cloud Functions `goOnline` handshake remains the
    // authoritative enforcement point.
    _checkProfileVerified().then((profileOk) {
      if (!mounted) return;
      if (profileOk == false) {
        showDialog(
          context: context,
          builder: (ctx) => AlertDialog(
            title: const Row(
              children: [
                Icon(Icons.hourglass_top_outlined, color: Colors.orange),
                SizedBox(width: 8),
                Text('Verification Pending'),
              ],
            ),
            content: const Text(
              'Account pending verification. Our team is reviewing your '
              'submission.\n\nYou cannot go online yet, but you can register '
              'vehicles in Fleet & Vehicles to speed up approval.',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: const Text('Cancel'),
              ),
              FilledButton(
                onPressed: () {
                  Navigator.pop(ctx);
                  _openFleetManagement();
                },
                child: const Text('Fleet & Vehicles'),
              ),
            ],
          ),
        );
        return;
      }
      // Document expiry guard — check after profile passes because a fresh
      // driver without any dates entered (nulls) is allowed through; only
      // hard-expired documents block the flow.
      _checkDocExpiry().then((expiredDoc) {
        if (!mounted) return;
        if (expiredDoc != null) {
          showDialog(
            context: context,
            builder: (ctx) => AlertDialog(
              title: const Row(
                children: [
                  Icon(Icons.warning_amber_rounded, color: Colors.red),
                  SizedBox(width: 8),
                  Text('Document Expired'),
                ],
              ),
              content: Text(
                'Your $expiredDoc has expired. Update the expiry date in '
                'Driver Profile → Document Expiry Dates to go online again.',
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(ctx),
                  child: const Text('Dismiss'),
                ),
              ],
            ),
          );
          return;
        }
        _goOnlineWithVerifiedProfile();
      });
    });
  }

  /// Reads the hub profile flag. Returns null when the read itself is
  /// unavailable (offline / uninitialized) so the caller falls through to
  /// the vehicle guard; the server handshake enforces authoritatively.
  Future<bool?> _checkProfileVerified() async {
    try {
      final doc = await FirebaseFirestore.instance
          .collection('drivers')
          .doc(widget.driverId)
          .get();
      if (!doc.exists) return null;
      return doc.data()?[DriverVerification.fieldProfileVerified] == true;
    } catch (_) {
      return null;
    }
  }

  /// Checks whether any mandatory document (license, inspection, insurance)
  /// is expired. Returns the document label if expired, null otherwise.
  ///
  /// A null field (not yet entered) is treated as *not* expired so a
  /// first-time driver is not wrongly blocked. The Cloud Functions
  /// `goOnline` handshake is the authoritative enforcement point; this
  /// provides the client-side UI signal only.
  Future<String?> _checkDocExpiry() async {
    try {
      final doc = await FirebaseFirestore.instance
          .collection('drivers')
          .doc(widget.driverId)
          .get();
      if (!doc.exists) return null;
      final data = doc.data()!;
      final today = DateTime.now();

      DateTime? parseTs(dynamic v) {
        if (v == null) return null;
        try {
          return (v as dynamic).toDate() as DateTime;
        } catch (_) {
          if (v is String) return DateTime.tryParse(v);
          return null;
        }
      }

      final license = parseTs(data['licenseExpiry']);
      if (license != null && license.isBefore(today)) return "Driver's License";
      final inspection = parseTs(data['inspectionExpiry']);
      if (inspection != null && inspection.isBefore(today)) {
        return 'Vehicle Inspection Certificate';
      }
      final insurance = parseTs(data['insuranceExpiry']);
      if (insurance != null && insurance.isBefore(today)) {
        return 'Vehicle Insurance Policy';
      }
      return null;
    } catch (_) {
      // Offline or unavailable — allow through; server is authoritative.
      return null;
    }
  }

  void _goOnlineWithVerifiedProfile() async {
    // ── Overlay permission gate (Android only) ────────────────────────────
    // The floating SeSe bubble and background order popup both require
    // SYSTEM_ALERT_WINDOW. Without it the driver can go ONLINE but will never
    // see incoming offers in the background — a silent failure that looks like
    // a dispatch problem. Gate here (before the server handshake) so the user
    // can act on the prompt before any state changes.
    //
    // Non-Android (iOS, web, tests) always passes — overlay is Android-only.
    if (Platform.isAndroid) {
      final hasOverlay = await DriverOverlayService.instance
          .ensurePermission(context: context);
      if (!mounted) return;
      if (!hasOverlay) {
        // Permission was explicitly declined or the OS prompt was dismissed.
        // Show a targeted dialog explaining the feature impact and send the
        // driver to Android Settings — the go-online flow is halted here.
        await showDialog<void>(
          context: context,
          builder: (ctx) => AlertDialog(
            icon: const Icon(Icons.layers_outlined,
                size: 36, color: AppColors.seseGold),
            title: const Text('"Display over other apps" Required'),
            content: const Text(
              'To receive incoming trip offers when the app is in the '
              'background, SeSe needs the \'Display over other apps\' '
              'permission.\n\nTap "Open Settings", enable it for SeSe, then '
              'return here and tap GO ONLINE again.',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: const Text('Later'),
              ),
              FilledButton(
                onPressed: () {
                  Navigator.pop(ctx);
                  // FlutterOverlayWindow uses its own settings launcher;
                  // fall back to a SnackBar hint if unsupported.
                  DriverOverlayService.instance
                      .ensurePermission(context: context);
                },
                child: const Text('Open Settings'),
              ),
            ],
          ),
        );
        return; // halt — driver must re-tap GO ONLINE after granting
      }
    }

    // Refresh the fleet right before the guard: the cached list is from
    // screen load, but hub approval may have landed after that — a stale
    // cache would wrongly block a verified driver here while the server
    // (and Fleet screen) already see the APPROVED vehicle.
    if (mounted) setState(() => _syncing = true);
    await _loadFleet(silent: true);
    if (!mounted) return;
    setState(() => _syncing = false);
    // Driver wants to go online -> Strict Verification Guard
    final verifiedVehicles = _fleet.where((v) => v.isApproved).toList();

    if (verifiedVehicles.isEmpty) {
      showDialog(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Account Verification Required'),
          content: const Text(
            'Register and verify your vehicle to go online and receive orders.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () {
                Navigator.pop(ctx);
                _openFleetManagement();
              },
              child: const Text('Manage Fleet'),
            ),
          ],
        ),
      );
      return;
    }

    // Trigger Pre-Online Selection & One-Time Live Camera Snapshot.
    //
    // Snapshot requirement is driven by the `require_multi_vehicle_snapshot`
    // Remote Config flag so support can relax the live plate check without an
    // app release:
    // - Exactly one approved vehicle: auto-selected, snapshot skipped, driver
    //   goes online in one tap regardless of the flag.
    // - Two or more approved vehicles + flag true: the driver picks the session
    //   vehicle inside the shield modal and passes the live plate snapshot.
    // - Two or more approved vehicles + flag false: the snapshot is skipped but
    //   the session vehicle is still chosen explicitly, so dispatch always
    //   resolves to an unambiguous vehicle.
    // The UI goes ONLINE only after the server grants the signed request
    // (see _finalizeGoOnline) — never on client assertion.
    if (verifiedVehicles.length == 1) {
      await _goOnlineWithSessionVehicle(verifiedVehicles.first);
      return;
    }

    if (RemoteConfigService.requireMultiVehicleSnapshot) {
      showDialog(
        context: context,
        barrierDismissible: false,
        builder: (ctx) => OnlineVerificationShieldModal(
          verifiedVehicles: verifiedVehicles,
          fleetService: widget.fleetService,
          driverId: widget.driverId,
          onVerificationPassed: (selectedVehicle) {
            _finalizeGoOnline(selectedVehicle);
          },
        ),
      );
      return;
    }

    final picked = await _pickSessionVehicle(verifiedVehicles);
    if (picked == null || !mounted) return;
    await _goOnlineWithSessionVehicle(picked);
  }

  /// Snapshot-free entry point: persists the chosen session vehicle, then
  /// requests the online grant.
  ///
  /// The persistence is required because `submitLiveVerification` — which lives
  /// inside the shield modal — is what normally sets `isActiveSelected`. Without
  /// it, bypassing the modal would leave no record of which vehicle the driver
  /// is working, so a later launch could not restore the session.
  Future<void> _goOnlineWithSessionVehicle(VehicleModel vehicle) async {
    try {
      await widget.fleetService.setActiveSelectedVehicle(
        driverId: widget.driverId,
        vehicleId: vehicle.id,
      );
    } catch (e) {
      // Non-fatal: going online must not be blocked by an advisory write.
      debugPrint('DriverDashboard: could not persist session vehicle ($e)');
    }
    if (!mounted) return;
    await _finalizeGoOnline(vehicle);
  }

  /// Lightweight session-vehicle chooser requiring manual plate number confirmation.
  /// Returns null when the driver cancels or fails verification.
  Future<VehicleModel?> _pickSessionVehicle(List<VehicleModel> vehicles) {
    return showModalBottomSheet<VehicleModel>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Theme.of(context).colorScheme.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => _SessionVehiclePickerSheet(vehicles: vehicles),
    );
  }

  /// Zero-trust online grant: fires the authenticated `goOnline()` request
  /// (Bearer ID token + signed GPS fix) and transitions the UI to ONLINE
  /// only on success response.
  Future<void> _finalizeGoOnline(VehicleModel selectedVehicle) async {
    if (_syncing) return;
    setState(() => _syncing = true);
    try {
      final fix = await _collectGpsFix();
      final decision = await _status.requestGoOnline(
        driverId: widget.driverId,
        fix: fix,
      );
      if (!mounted) return;
      if (decision.granted) {
        setState(() {
          _activeVehicle = selectedVehicle;
          _isOnline = true;
          _sessionOverriddenOnOtherDevice = false;
          _currentSessionId = decision.sessionId;
          _streaks.activeSessionId = decision.sessionId;
        });
        DriverOverlayService.instance.isOnline = true;
        unawaited(_persistOnlineSession(decision.sessionId));
        // Audio feedback: online chime.
        // ignore: discarded_futures
        AppSoundService.instance.playOnlineSound();
        // Overlay bubble readiness + sticky foreground signal + driver-topic
        // push subscription. Background location is best-effort: foreground
        // fixes work without it, but the OS only keeps delivering fixes
        // while minimized when it is granted.
        // ignore: discarded_futures
        DriverOverlayService.instance.ensurePermission(context: context);
        // ignore: discarded_futures
        MediaPermissionService.ensureBackgroundLocation();
        // ignore: discarded_futures
        PushNotificationService.showOngoingOnlineAlert();
        // ignore: discarded_futures
        PushNotificationService.subscribe('driver_${widget.driverId}');
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              decision.message.isEmpty
                  ? 'Unable to go online right now. Please try again.'
                  : decision.message,
            ),
          ),
        );
      }
    } on DriverStatusException catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(e.message)),
      );
    } finally {
      if (mounted) setState(() => _syncing = false);
    }
  }

  void _openFleetManagement() async {
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => DriverFleetScreen(
          fleetService: widget.fleetService,
          driverId: widget.driverId,
          isOnline: _isOnline,
          config: widget.config,
        ),
      ),
    );
    _loadFleet();
  }

  // ── Module 4: Driver Resting Break ──────────────────────────────────────────

  /// Displays the break-options bottom sheet and starts a countdown when the
  /// driver picks a duration. Duration values come from [RemoteKeysConfig] so
  /// hub admins can tune them without an app release.
  ///
  /// If the break feature is globally disabled via [RemoteKeysConfig.driverBreakEnabled]
  /// the sheet is skipped — the tap is treated as a no-op.
  ///
  /// If the driver is already on break, tapping the slider cancels the break
  /// immediately (sets Firestore `isOnBreak = false` and resets the timer).
  Future<void> _showBreakOptions() async {
    // Cancel an active break on tap while on break.
    if (_isOnBreak) {
      _endBreak();
      return;
    }

    // Fetch remote config for break durations.
    RemoteKeysConfig remoteKeys;
    try {
      remoteKeys = await RemoteKeysService().fetchRemoteKeys();
    } catch (_) {
      remoteKeys = const RemoteKeysConfig();
    }

    if (!remoteKeys.driverBreakEnabled) return; // feature flag off
    if (!mounted) return;

    final option1 = remoteKeys.driverBreakOption1Minutes;
    final option2 = remoteKeys.driverBreakOption2Minutes;

    final chosen = await showModalBottomSheet<int>(
      context: context,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (ctx) => SafeArea(
        // 16px gutters so session-vehicle options span edge-to-edge.
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Container(
                width: 40,
                height: 4,
                margin: const EdgeInsets.only(bottom: 16),
                decoration: BoxDecoration(
                  color: Colors.grey.shade400,
                  borderRadius: BorderRadius.circular(4),
                ),
                alignment: Alignment.center,
              ),
              const Text(
                'Take a Break',
                style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 8),
              const Text(
                'How long do you need? Quick-Order pool stays open during your break.',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 13, color: Colors.grey),
              ),
              const SizedBox(height: 20),
              FilledButton.icon(
                key: const Key('break_option_1'),
                icon: const Icon(Icons.coffee_outlined),
                label: Text('$option1-Minute Break'),
                style: FilledButton.styleFrom(
                  minimumSize: const Size(double.infinity, 52),
                  backgroundColor: AppColors.seseGold,
                  foregroundColor: Colors.black,
                ),
                onPressed: () => Navigator.pop(ctx, option1),
              ),
              const SizedBox(height: 12),
              FilledButton.icon(
                key: const Key('break_option_2'),
                icon: const Icon(Icons.hotel_outlined),
                label: Text('$option2-Minute Break (${option2 == 60 ? '1 Hour' : '$option2 min'})'),
                style: FilledButton.styleFrom(
                  minimumSize: const Size(double.infinity, 52),
                  backgroundColor: AppColors.seseGold,
                  foregroundColor: Colors.black,
                ),
                onPressed: () => Navigator.pop(ctx, option2),
              ),
              const SizedBox(height: 12),
              OutlinedButton(
                onPressed: () => Navigator.pop(ctx),
                style: OutlinedButton.styleFrom(
                  minimumSize: const Size(double.infinity, 48),
                ),
                child: const Text('Stay Online'),
              ),
            ],
          ),
        ),
      ),
    );

    if (chosen == null || !mounted) return;
    _startBreak(chosen * 60);
  }

  /// Starts a break countdown of [durationSeconds]. Updates Firestore
  /// `drivers/{uid}.isOnBreak = true` best-effort (non-blocking).
  void _startBreak(int durationSeconds) {
    _breakTimer?.cancel();
    setState(() {
      _isOnBreak = true;
      _breakRemainingSeconds = durationSeconds;
    });
    // Best-effort Firestore write — never blocks the UI or throws.
    FirebaseFirestore.instance
        .collection('drivers')
        .doc(widget.driverId)
        .set({'isOnBreak': true}, SetOptions(merge: true))
        .catchError((_) {});

    _breakTimer = Timer.periodic(const Duration(seconds: 1), (t) {
      if (!mounted) {
        t.cancel();
        return;
      }
      setState(() {
        _breakRemainingSeconds--;
      });
      if (_breakRemainingSeconds <= 0) {
        t.cancel();
        _endBreak();
      }
    });
  }

  /// Ends the current break: resets state, cancels the timer, and updates
  /// Firestore `drivers/{uid}.isOnBreak = false`.
  void _endBreak() {
    _breakTimer?.cancel();
    _breakTimer = null;
    setState(() {
      _isOnBreak = false;
      _breakRemainingSeconds = 0;
    });
    FirebaseFirestore.instance
        .collection('drivers')
        .doc(widget.driverId)
        .set({'isOnBreak': false}, SetOptions(merge: true))
        .catchError((_) {});
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Break ended — you are back online.')),
      );
    }
  }

  /// Returns the compact timer label shown inside the [SlideToOffline] thumb
  /// during an active break. Shows minutes when > 60s remaining, seconds
  /// otherwise (so the driver can see the final countdown precisely).
  String? _breakThumbText() {
    if (!_isOnBreak) return null;
    if (_breakRemainingSeconds > 60) {
      return '${(_breakRemainingSeconds / 60).ceil()}m';
    }
    return '${_breakRemainingSeconds}s';
  }

  @override
  Widget build(BuildContext context) {
    // Scaffold color comes from AppTheme (light/dark variants) — never a
    // hardcoded hex, so the screen can never diverge from brightness.
    if (_loading) {
      return Scaffold(
        backgroundColor: Theme.of(context).scaffoldBackgroundColor,
        body: const SeseProfileSkeleton(),
      );
    }

    // Full-screen map canvas base adapting to system theme.
    // System back navigation and backgrounding/exit gates are managed by DriverHomeShell.
    return Scaffold(
      backgroundColor: Theme.of(context).scaffoldBackgroundColor,
      body: SizedBox.expand(child: _buildMapStack()),
    );
  }

  /// Home map stack: tile canvas + floating pill, badge, radar, and cards.
  ///
  /// Layout contract —
  /// - map fills the screen, camera on the driver, marker on the driver;
  /// - top floats the GO ONLINE pill / slide control, then the pool badge
  ///   (online only), then the verification banner;
  /// - center shows the radar overlay while online with no live trip and an
  ///   empty pool (the pulsing badge already draws the eye otherwise);
  /// - bottom shows the live-trip card when a trip is active, else the
  ///   streak banner while online, else nothing (offline is just the map —
  ///   there is deliberately no earnings/status overlay card). Tier 1/2
  ///   [_PingListener], never inline — the inline [OrderFeed] list is
  ///   superseded by the pool sheet and is no longer mounted here.
  Widget _buildMapStack() {
    return StreamBuilder<ActiveTrip?>(
      stream: _streaks.activeTripStream(widget.driverId),
      builder: (context, tripSnap) {
        final active = tripSnap.data;
        _currentActiveTrip = active;
        if (active != null) {
          _lastActiveTripForRating = active;
          if (active.status == TripStatus.completed) {
            _checkAndShowPostTripRating(active);
          } else if (active.status == TripStatus.cancelledWaitingCashSettlement) {
            if (_activeRoutePoints.isNotEmpty) {
              _activeRoutePoints = [];
            }
          } else {
            _fetchActiveTripRoute(active);
          }
          if (active.tripId != _trackedTripId || active.status != _lastTrackedStatus) {
            final isNewTrip = active.tripId != _trackedTripId;
            final isJustStarted = active.status == TripStatus.inProgress &&
                _lastTrackedStatus != TripStatus.inProgress;

            if (isNewTrip || isJustStarted) {
              _hasAutoCollapsedForTrip = true;
              _tripStartLocation = _driverPosition;
              _autoCollapseSheetOnActiveTrip();
              if (active.status == TripStatus.inProgress &&
                  _driverPosition.latitude != 0.0) {
                _isFollowingUser = true;
                _mapController.recenterToBottomCenter(_driverPosition, zoom: 17.0);
              }
            } else if (active.status == TripStatus.cancelledWaitingCashSettlement) {
              _expandActiveTripSheetToStandard();
            }
            _trackedTripId = active.tripId;
            _lastTrackedStatus = active.status;
          }
        } else {
          if (_lastActiveTripForRating != null) {
            final tripToRate = _lastActiveTripForRating!;
            _lastActiveTripForRating = null;
            if (tripToRate.status == TripStatus.completed) {
              _checkAndShowPostTripRating(tripToRate);
            }
          }
          if (_activeRoutePoints.isNotEmpty) {
            _activeRoutePoints = [];
          }
        }
        final isDark = Theme.of(context).brightness == Brightness.dark;
        return Stack(
          fit: StackFit.expand,
          children: [
            // 0. Map canvas base wrapped in gesture listener to toggle immersive full-screen map mode.
            Positioned.fill(
              child: Listener(
                onPointerDown: (_) => _handleMapGestureStarted(),
                onPointerMove: (_) => _handleMapGestureStarted(),
                onPointerUp: (_) =>
                    _mapInteractionController.notifyInteractionEnded(),
                onPointerCancel: (_) =>
                    _mapInteractionController.notifyInteractionEnded(),
                child: _buildMapBase(active),
              ),
            ),
            // Zero-size listeners: incoming-offer page + grand-award
            // celebration modal (dialogs driven by Firestore streams).
            Positioned(
              top: 0,
              left: 0,
              width: 0,
              height: 0,
              child: _PingListener(
                service: _streaks,
                driverId: widget.driverId,
                currencySymbol: _currencySymbol,
                driverPosition: _driverPosition,
                isAppPaused: () => _appPaused,
                isOnBreak: () => _isOnBreak,
                user: widget.user,
              ),
            ),
            Positioned(
              top: 0,
              left: 0,
              width: 0,
              height: 0,
              child: _CelebrationListener(
                service: _streaks,
                driverId: widget.driverId,
                currencySymbol: _currencySymbol,
              ),
            ),
            // New pool arrivals chime once while browsing the map.
            Positioned(
              top: 0,
              left: 0,
              width: 0,
              height: 0,
              child: _PoolArrivalChime(
                streakService: _streaks,
                driverPosition: _driverPosition,
                driverId: widget.driverId,
                enabled: _isOnline && active == null,
              ),
            ),
            // Top Header Overlay (Wallet, Status Bar, Bell, Banners)
            Positioned(
              top: 0,
              left: 0,
              right: 0,
              child: AnimatedSlide(
                duration: const Duration(milliseconds: 300),
                curve: Curves.easeInOut,
                offset: _isMapInteracting ? const Offset(0, -0.3) : Offset.zero,
                child: AnimatedOpacity(
                  duration: const Duration(milliseconds: 250),
                  opacity: _isMapInteracting ? 0.0 : 1.0,
                  child: IgnorePointer(
                    ignoring: _isMapInteracting,
                    child: SafeArea(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          if (_sessionOverriddenOnOtherDevice) ...[
                            _buildSessionTerminatedBanner(),
                          ],
                          const SizedBox(height: 8),
                          if (active != null) ...[
                            Padding(
                              padding:
                                  const EdgeInsets.symmetric(horizontal: 16),
                              child: _buildActiveTripTopNavBanner(active),
                            ),
                          ] else ...[
                            Padding(
                              padding:
                                  const EdgeInsets.symmetric(horizontal: 12),
                              child: _buildOnlineHeader(),
                            ),
                            const SizedBox(height: 6),
                            // Notification bell: positioned directly beneath the GO ONLINE / status banner.
                            Padding(
                              padding:
                                  const EdgeInsets.symmetric(horizontal: 16),
                              child: Row(
                                mainAxisAlignment: MainAxisAlignment.end,
                                children: [
                                  Material(
                                    color: Theme.of(context)
                                        .colorScheme
                                        .surface
                                        .withValues(alpha: 0.9),
                                    shape: const CircleBorder(),
                                    elevation: 2,
                                    child: NotificationBellButton(
                                        uid: widget.driverId),
                                  ),
                                ],
                              ),
                            ),
                            const SizedBox(height: 6),
                            Padding(
                              padding:
                                  const EdgeInsets.symmetric(horizontal: 12),
                              child:
                                  VerificationBanner(driverId: widget.driverId),
                            ),
                            _DocExpiryBanner(driverId: widget.driverId),
                          ],
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),

            // Left Speed Limit / Current Speed indicator badge (active in_progress)
            if (active != null && active.status == TripStatus.inProgress)
              Positioned(
                left: 14,
                bottom: MediaQuery.sizeOf(context).height * _sheetCollapsedSize + 16,
                child: Container(
                  key: const Key('hud_speed_limit_badge'),
                  padding:
                      const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                  decoration: BoxDecoration(
                    color: isDark
                        ? const Color(0xFF1E1E24).withValues(alpha: 0.90)
                        : Colors.white.withValues(alpha: 0.90),
                    borderRadius: BorderRadius.circular(16),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withValues(alpha: 0.25),
                        blurRadius: 8,
                        offset: const Offset(0, 2),
                      ),
                    ],
                  ),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Container(
                        width: 36,
                        height: 36,
                        decoration: BoxDecoration(
                          color: isDark
                              ? const Color(0xFF2C2C36)
                              : Colors.grey.shade200,
                          shape: BoxShape.circle,
                        ),
                        child: Center(
                          child: Icon(
                            Icons.location_on_rounded,
                            color: isDark ? Colors.white70 : Colors.black87,
                            size: 20,
                          ),
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        _currentSpeedKmh > 0
                            ? '${_currentSpeedKmh.round()}'
                            : '0',
                        style: TextStyle(
                          fontWeight: FontWeight.w900,
                          fontSize: 18,
                          color: isDark ? Colors.white : Colors.black87,
                        ),
                      ),
                      Text(
                        'km/h',
                        style: TextStyle(
                          fontSize: 10,
                          fontWeight: FontWeight.bold,
                          color: isDark
                              ? Colors.grey.shade400
                              : Colors.grey.shade600,
                        ),
                      ),
                    ],
                  ),
                ),
              ),

            // Right Panel Search Icon (retained exclusively during active turn-by-turn navigation)
            if (active != null && active.status == TripStatus.inProgress)
              Positioned(
                right: 14,
                top: 105,
                child: Container(
                  key: const Key('hud_search_button'),
                  width: 44,
                  height: 44,
                  decoration: BoxDecoration(
                    color: isDark
                        ? const Color(0xFF252530).withValues(alpha: 0.90)
                        : Colors.white.withValues(alpha: 0.90),
                    borderRadius: BorderRadius.circular(12),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withValues(alpha: 0.2),
                        blurRadius: 8,
                        offset: const Offset(0, 2),
                      ),
                    ],
                  ),
                  child: IconButton(
                    icon: Icon(
                      Icons.search_rounded,
                      color: isDark ? Colors.white70 : Colors.black87,
                      size: 22,
                    ),
                    onPressed: () {
                      final isHeadingToPickup =
                          active.status == TripStatus.driverAccepted ||
                          active.status == TripStatus.driverArriving ||
                          active.status == TripStatus.driverArrived;
                      NavigationLauncherService.showNavigationChooser(
                        context: context,
                        destinationLat: isHeadingToPickup
                            ? active.pickupLat
                            : active.dropoffLat,
                        destinationLng: isHeadingToPickup
                            ? active.pickupLng
                            : active.dropoffLng,
                        destinationAddress: isHeadingToPickup
                            ? active.pickupAddress
                            : active.dropoffAddress,
                        isHeadingToPickup: isHeadingToPickup,
                        driverPosition: _driverPosition,
                        trip: active,
                      );
                    },
                  ),
                ),
              ),

            // Primary Floating Recenter Pill Button (bottom-center):
            // The sole, standardized recenter control for optimal thumb accessibility.
            // Retained during map interaction so driver can always snap back.
            if (!_isFollowingUser || _isMapInteracting)
              Positioned(
                left: 0,
                right: 0,
                bottom: active != null ? 84 : 130,
                child: Center(
                  child: Material(
                    key: const Key('driver_recenter_pill_button'),
                    color: isDark ? const Color(0xFF2D2D38) : Colors.white,
                    elevation: 6,
                    shadowColor: Colors.black.withValues(alpha: 0.25),
                    borderRadius: BorderRadius.circular(28),
                    child: InkWell(
                      borderRadius: BorderRadius.circular(28),
                      onTap: _recenterMap,
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 20, vertical: 12),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Transform.rotate(
                              angle: -math.pi / 4,
                              child: Icon(
                                Icons.navigation_rounded,
                                size: 20,
                                color: isDark
                                    ? Colors.white
                                    : const Color(0xFF1E293B),
                              ),
                            ),
                            const SizedBox(width: 8),
                            Text(
                              'Recenter',
                              style: TextStyle(
                                fontWeight: FontWeight.w700,
                                fontSize: 15,
                                color: isDark
                                    ? Colors.white
                                    : const Color(0xFF1E293B),
                                letterSpacing: 0.2,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ),

            // Bottom Area (Active Trip Sheet or Idle Streak Slot + Quick Order Badge)
            if (active != null) ...[
              if (MapProviderPolicy.resolve(MapContext.realtimeTracking) !=
                  MapProvider.googleMaps)
                const Positioned(
                  right: 12,
                  bottom: 180,
                  child: _RasterCredit(),
                ),
              // Full-width draggable bottom action sheet extending directly above the bottom nav bar.
              // Kept visible at its snap-to-edge size during map interaction so driver
              // can easily pull it back up; never hidden or dismissed with opacity 0.
              _buildActiveTripCard(active),
            ] else if (_isOnline) ...[
              Positioned(
                left: 12,
                right: 12,
                bottom: 12,
                child: AnimatedSlide(
                  duration: const Duration(milliseconds: 300),
                  curve: Curves.easeInOut,
                  offset:
                      _isMapInteracting ? const Offset(0, 0.3) : Offset.zero,
                  child: AnimatedOpacity(
                    duration: const Duration(milliseconds: 250),
                    opacity: _isMapInteracting ? 0.0 : 1.0,
                    child: IgnorePointer(
                      ignoring: _isMapInteracting,
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          if (MapProviderPolicy.resolve(
                                  MapContext.idlePositioning) !=
                              MapProvider.googleMaps)
                            const Align(
                              alignment: Alignment.centerRight,
                              child: _RasterCredit(),
                            ),
                          const SizedBox(height: 4),
                          Row(
                            mainAxisAlignment: MainAxisAlignment.end,
                            crossAxisAlignment: CrossAxisAlignment.center,
                            children: [
                              Flexible(child: _buildBottomStreakSlot()),
                              const SizedBox(width: 10),
                              PoolBadge(
                                streakService: _streaks,
                                driverPosition: _driverPosition,
                                driverId: widget.driverId,
                                onTap: _openPoolSheet,
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ],
        );
      },
    );
  }

  /// Tile canvas using the native blue-dot my-location indicator for the
  /// driver's current position. Routed through [SeSeMapView] so the map
  /// provider policy applies: idle positioning may use Google Maps once
  /// provisioned, live-trip tracking stays on OpenStreetMap.
  Widget _buildMapBase([ActiveTrip? activeTrip]) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final hasActiveTrip = activeTrip != null;

    final markers = <MapPin>[];
    final polylines = <MapRoute>[];

    if (hasActiveTrip) {
      final isDropoffStage = activeTrip.status == TripStatus.inProgress;
      final destLat =
          isDropoffStage ? activeTrip.dropoffLat : activeTrip.pickupLat;
      final destLng =
          isDropoffStage ? activeTrip.dropoffLng : activeTrip.pickupLng;

      if (destLat != 0.0 && destLng != 0.0) {
        final destPoint = LatLng(destLat, destLng);
        // Destination Pin Marker (A or B)
        markers.add(
          SeSeMapView.pin(
            point: destPoint,
            color: isDropoffStage
                ? const Color(0xFFEF4444)
                : const Color(0xFF10B981),
            label: isDropoffStage ? 'B' : 'A',
          ),
        );

        // Directional Navigation Arrow Marker at driver's live position
        if (_driverPosition.latitude != 0.0 &&
            _driverPosition.longitude != 0.0) {
          markers.add(
            SeSeMapView.pin(
              point: _driverPosition,
              color: const Color(0xFF2563EB),
              label: 'NAV',
            ),
          );

          // Road-snapped turn-by-turn route polyline path
          final routePoints = _activeRoutePoints.isNotEmpty
              ? _activeRoutePoints
              : [_driverPosition, destPoint];
          polylines.add(
            SeSeMapView.route(
              points: routePoints,
              color: AppColors.seseGold,
              width: 6,
            ),
          );
        }
      }
    }

    return SeSeMapView(
      mapContext: hasActiveTrip
          ? MapContext.realtimeTracking
          : MapContext.idlePositioning,
      mapController: _mapController,
      interactionController: _mapInteractionController,
      onInteractionStarted: _handleMapGestureStarted,
      onInteractionEnded: () => _mapInteractionController.notifyInteractionEnded(),
      initialCenter: _driverPosition,
      initialZoom: hasActiveTrip ? 16.5 : 15.0,
      isDarkOverride: isDark,
      showMyLocation: !hasActiveTrip,
      showRecenterFab: false,
      userLocation: _driverPosition,
      markers: markers,
      polylines: polylines,
    );
  }

  /// Live daily net profit pill; the full earnings view is one tap away.
  Widget _buildBalancePill() {
    return StreamBuilder<DayEarnings>(
      stream: _earningsService.todayEarningsStream(widget.driverId),
      builder: (context, snapshot) {
        final day = snapshot.data;
        final dailyNetTotal = day?.net ?? 0.0;
        final formattedTotal = PaymentService.formatNaira(dailyNetTotal);

        return Material(
          color: Colors.transparent,
          child: InkWell(
            key: const Key('current_balance_pill'),
            borderRadius: BorderRadius.circular(20),
            onTap: () {
              final effectiveUser = widget.user ??
                  AppUser(
                    uid: widget.driverId,
                    fullName: 'Driver',
                    email: '',
                    phoneNumber: '',
                    role: UserRole.driver,
                    createdAt: DateTime.now(),
                  );
              Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (_) => EarningsScreen(user: effectiveUser),
                ),
              );
            },
            child: Padding(
              padding: const EdgeInsets.only(top: 8),
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.surface.withValues(
                        alpha: 0.92,
                      ),
                  borderRadius: BorderRadius.circular(18),
                  border: Border.all(
                    color: AppColors.seseGold.withValues(alpha: 0.7),
                  ),
                  boxShadow: const [
                    BoxShadow(
                      color: Colors.black26,
                      blurRadius: 5,
                      offset: Offset(0, 2),
                    ),
                  ],
                ),
                child: Padding(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
                  child: Text(
                    formattedTotal,
                    style: Theme.of(context).textTheme.labelLarge?.copyWith(
                          fontWeight: FontWeight.w700,
                          letterSpacing: 0.2,
                        ),
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }


  Widget _buildOnlineHeader() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 0),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          _isOnline
              ? SlideToOffline(
                  key: const Key('slide_to_offline'),
                  enabled: !_syncing,
                  onSlideComplete: _showGoOfflineConfirmation,
                  onTapBreak: _showBreakOptions,
                  breakTimerText: _breakThumbText(),
                )
              : GestureDetector(
                  key: const Key('power_toggle'),
                  onTap: _syncing ? null : _goOnlineNow,
                  child: Container(
                    height: 52,
                    decoration: BoxDecoration(
                      color: Theme.of(context).colorScheme.primary,
                      borderRadius: BorderRadius.circular(28),
                      boxShadow: const [
                        BoxShadow(
                          color: Colors.black26,
                          blurRadius: 8,
                          offset: Offset(0, 3),
                        ),
                      ],
                    ),
                    alignment: Alignment.center,
                    child: _syncing
                        ? SizedBox(
                            width: 22,
                            height: 22,
                            child: CircularProgressIndicator(
                                strokeWidth: 2,
                                color: Theme.of(context).colorScheme.onPrimary),
                          )
                        : Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(Icons.power_settings_new,
                                  color: Theme.of(context).colorScheme.onPrimary,
                                  size: 22),
                              const SizedBox(width: 8),
                              Text(
                                'GO ONLINE',
                                style: Theme.of(context)
                                    .textTheme
                                    .titleMedium
                                    ?.copyWith(
                                      color: Theme.of(context).colorScheme.onPrimary,
                                      fontWeight: FontWeight.bold,
                                      letterSpacing: 0.5,
                                    ),
                                overflow: TextOverflow.ellipsis,
                              ),
                            ],
                          ),
                  ),
                ),
          _buildBalancePill(),
        ],
      ),
    );
  }

  Widget _buildSessionTerminatedBanner() {
    return Container(
      key: const ValueKey('session_terminated_banner'),
      margin: const EdgeInsets.fromLTRB(12, 4, 12, 4),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: const Color(0xFF2C2411),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(
          color: const Color(0xFFE5A93C).withValues(alpha: 0.6),
          width: 1.2,
        ),
        boxShadow: const [
          BoxShadow(
            color: Colors.black26,
            blurRadius: 4,
            offset: Offset(0, 2),
          ),
        ],
      ),
      child: Row(
        children: [
          const Icon(
            Icons.devices_other_rounded,
            color: Color(0xFFE5A93C),
            size: 22,
          ),
          const SizedBox(width: 10),
          const Expanded(
            child: Text(
              'You went online on another device. This session is now offline.',
              style: TextStyle(
                color: Colors.white,
                fontSize: 12.5,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          const SizedBox(width: 6),
          IconButton(
            icon: const Icon(Icons.close, size: 18, color: Colors.white70),
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(),
            splashRadius: 16,
            onPressed: () {
              setState(() => _sessionOverriddenOnOtherDevice = false);
            },
          ),
        ],
      ),
    );
  }

  String _formattedGuidanceText(ActiveTrip active) {
    if (_currentGuidanceStep != null &&
        _currentGuidanceStep!.instruction.isNotEmpty) {
      if (_driverPosition.latitude != 0.0) {
        final distM = const Distance().as(
          LengthUnit.Meter,
          _driverPosition,
          _currentGuidanceStep!.location,
        );
        return _currentGuidanceStep!.formatDynamicInstruction(distM);
      }
      return _currentGuidanceStep!.instruction;
    }
    if (_activeRouteSteps.isNotEmpty) {
      final step = _activeRouteSteps.first;
      if (_driverPosition.latitude != 0.0) {
        final distM = const Distance().as(
          LengthUnit.Meter,
          _driverPosition,
          step.location,
        );
        return step.formatDynamicInstruction(distM);
      }
      return step.instruction;
    }
    return active.status == TripStatus.inProgress
        ? 'Continue straight to drop-off'
        : 'Head toward pickup location';
  }

  IconData _guidanceManeuverIcon(ActiveTrip active) {
    if (_currentGuidanceStep != null) {
      return _currentGuidanceStep!.maneuverIconData;
    }
    return active.status == TripStatus.inProgress
        ? Icons.turn_right_rounded
        : Icons.navigation_rounded;
  }

  /// Floating top turn-by-turn banner shown while a driver has an active trip.
  /// Matches top turn navigation indicator spec:
  /// Left turn/navigation icon, title ("Navigation: En Route to Drop-off"),
  /// destination address, and secondary detail line.
  Widget _buildActiveTripTopNavBanner(ActiveTrip active) {
    final isCashSettlement =
        active.status == TripStatus.cancelledWaitingCashSettlement;
    final isDropoff = active.status == TripStatus.inProgress;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final fee = active.pendingCashFee > 0
        ? active.pendingCashFee
        : active.paidWaitingFee;
    final feeStr = fee > 0 ? '₦${fee.toStringAsFixed(0)}' : 'fee';

    return Container(
      decoration: BoxDecoration(
        color: isDark ? const Color(0xFF252530) : Colors.white,
        borderRadius: BorderRadius.circular(16),
        border: isDark
            ? Border.all(
                color: isCashSettlement
                    ? const Color(0xFFF59E0B)
                    : const Color(0xFF3A3A46),
                width: isCashSettlement ? 1.5 : 1.0,
              )
            : (isCashSettlement
                ? Border.all(color: const Color(0xFFF59E0B), width: 1.5)
                : null),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: isDark ? 0.3 : 0.12),
            blurRadius: 10,
            offset: const Offset(0, 3),
          ),
        ],
      ),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      child: Row(
        children: [
          Container(
            width: 42,
            height: 42,
            decoration: BoxDecoration(
              color: isCashSettlement
                  ? const Color(0xFFF59E0B)
                  : (isDropoff ? const Color(0xFF1E293B) : const Color(0xFF10B981)),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Center(
              child: Icon(
                isCashSettlement
                    ? Icons.payments_rounded
                    : _guidanceManeuverIcon(active),
                color: Colors.white,
                size: 24,
              ),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                if (isCashSettlement) ...[
                  Row(
                    children: [
                      Text(
                        'Cancelled',
                        style: TextStyle(
                          fontWeight: FontWeight.bold,
                          fontSize: 13,
                          color: isDark
                              ? const Color(0xFFFCA5A5)
                              : Colors.red.shade700,
                        ),
                      ),
                      const SizedBox(width: 6),
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 6, vertical: 2),
                        decoration: BoxDecoration(
                          color: isDark
                              ? const Color(0xFF78350F).withValues(alpha: 0.3)
                              : const Color(0xFFFEF3C7),
                          borderRadius: BorderRadius.circular(4),
                        ),
                        child: Text(
                          'CASH DUE',
                          style: TextStyle(
                            fontSize: 10,
                            fontWeight: FontWeight.bold,
                            color: isDark
                                ? const Color(0xFFFDE68A)
                                : const Color(0xFF92400E),
                            letterSpacing: 0.5,
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 2),
                  Text(
                    'Collect $feeStr cash waiting fee',
                    style: TextStyle(
                      fontSize: 12,
                      color:
                          isDark ? Colors.grey.shade300 : Colors.grey.shade800,
                      fontWeight: FontWeight.w600,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ] else ...[
                  Text(
                    _formattedGuidanceText(active),
                    style: TextStyle(
                      fontWeight: FontWeight.w800,
                      fontSize: 14.5,
                      color: isDark ? Colors.white : Colors.black87,
                      letterSpacing: -0.2,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 2),
                  Text(
                    isDropoff
                        ? (active.dropoffAddress.isNotEmpty
                            ? active.dropoffAddress
                            : 'Drop-off destination')
                        : (active.pickupAddress.isNotEmpty
                            ? active.pickupAddress
                            : 'Pickup location'),
                    style: TextStyle(
                      fontSize: 12,
                      color:
                          isDark ? Colors.grey.shade300 : Colors.grey.shade700,
                      fontWeight: FontWeight.w500,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 1),
                  Text(
                    'Destination details',
                    style: TextStyle(
                      fontSize: 11,
                      color:
                          isDark ? Colors.grey.shade400 : Colors.grey.shade600,
                    ),
                  ),
                ],
              ],
            ),
          ),
          IconButton(
            tooltip: _audioGuidanceMuted ? 'Unmute guidance' : 'Mute guidance',
            icon: Icon(
              _audioGuidanceMuted
                  ? Icons.volume_off_outlined
                  : Icons.volume_up_outlined,
              color: _audioGuidanceMuted
                  ? Colors.grey
                  : (isDark ? Colors.white : Colors.black87),
            ),
            visualDensity: VisualDensity.compact,
            onPressed: () {
              setState(() {
                _audioGuidanceMuted = !_audioGuidanceMuted;
              });
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(
                  content: Text(
                    _audioGuidanceMuted
                        ? 'Navigation voice guidance muted'
                        : 'Navigation voice guidance enabled',
                  ),
                  duration: const Duration(seconds: 1),
                ),
              );
            },
          ),
        ],
      ),
    );
  }

  /// Live-trip action card for the map bottom slot. Takes the already-resolved
  /// trip (the map stack owns the single `activeTripStream` subscription) —
  /// no nested streams here.
  Widget _buildActiveTripCard(ActiveTrip active) {
    return StreamBuilder<DailyStreakConfig>(
      stream: _streaks.streakConfigStream(),
      builder: (context, cfgSnap) {
        final cfg = cfgSnap.data ?? const DailyStreakConfig();
        return DriverActiveTripCard(
          trip: active,
          streakService: _streaks,
          waitThresholdMinutes: cfg.noShowWaitMinutes,
          driverId: widget.driverId,
          driverPosition: _driverPosition,
          routePoints: _activeRoutePoints,
          currentSpeedKmh: _currentSpeedKmh,
          autoArrivalEnabled: cfg.autoArrivalEnabled,
          autoArrivalCountdownSeconds: cfg.autoArrivalCountdownSeconds,
          sheetController: _activeTripSheetController,
          onToggleCollapse: _toggleActiveTripSheet,
        );
      },
    );
  }

  /// Bottom slot: daily streak banner — starts collapsed as a floating round
  /// badge (tappable to expand). When the driver has arrived at a pickup it
  /// stays expanded so the wait timer is always visible.
  Widget _buildBottomStreakSlot() {
    return StreamBuilder<DailyStreakConfig>(
      stream: _streaks.streakConfigStream(),
      builder: (context, cfgSnap) {
        final cfg = cfgSnap.data ?? const DailyStreakConfig();
        return StreamBuilder<ActiveTrip?>(
          stream: _streaks.activeTripStream(widget.driverId),
          builder: (context, tripSnap) {
            final active = tripSnap.data;
            return StreamBuilder<DriverStreakState>(
              stream: _streaks.streakStream(widget.driverId),
              builder: (context, streakSnap) {
                final streak = streakSnap.data ??
                    DriverStreakState(driverId: widget.driverId);
                return StreakProgressBanner(
                  streak: streak,
                  fareAmount: active?.fareAmount ?? 0,
                  currencySymbol: _currencySymbol,
                  waitThresholdMinutes: cfg.noShowWaitMinutes,
                  arrivedAt: active?.arrivedAt,
                  collapsible: true,
                );
              },
            );
          },
        );
      },
    );
  }

}

/// Raster tile attribution rendered just above the bottom card.
class _RasterCredit extends StatelessWidget {
  const _RasterCredit();

  @override
  Widget build(BuildContext context) {
    final isMapbox = MapConfigController.instance.isMapbox;
    return Text(
      isMapbox ? '© Mapbox © OpenStreetMap' : '© CARTO',
      style: Theme.of(context).textTheme.labelSmall?.copyWith(
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
    );
  }
}


/// One-shot chime on pool-count *increases* past the first snapshot: the
/// initial load never chimes. Gated by [enabled] (online + trip-free) at
/// fire time. Uses the short message chime — the 6s order loop belongs to
/// exclusive pings.
class _PoolArrivalChime extends StatefulWidget {
  final DriverStreakService streakService;
  final LatLng driverPosition;
  final String? driverId;
  final bool enabled;

  const _PoolArrivalChime({
    required this.streakService,
    required this.driverPosition,
    this.driverId,
    required this.enabled,
  });

  @override
  State<_PoolArrivalChime> createState() => _PoolArrivalChimeState();
}

class _PoolArrivalChimeState extends State<_PoolArrivalChime> {
  bool _seenFirst = false;
  int _lastCount = 0;

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<List<ActiveTrip>>(
      stream: widget.streakService.marketplaceStream(driverId: widget.driverId),
      builder: (context, snap) {
        final trips = snap.data ?? const <ActiveTrip>[];
        final count = trips
            .where((t) => widget.driverId == null || widget.driverId!.isEmpty || t.customerId != widget.driverId)
            .where((t) => OrderFeedState.withinPoolRadius(
                t, widget.driverPosition))
            .length;
        if (!_seenFirst) {
          // First snapshot seeds the baseline — never chimes.
          _seenFirst = true;
          _lastCount = count;
        } else if (count != _lastCount) {
          final grew = count > _lastCount;
          _lastCount = count;
          if (grew && widget.enabled) {
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (!mounted) return;
              // ignore: discarded_futures
              AppSoundService.instance.playIncomingMessageSound();
            });
          }
        }
        return const SizedBox.shrink();
      },
    );
  }
}



/// Invisible listener: opens the full-screen incoming offer page
/// ([IncomingOfferSheet]) whenever the backend pings this driver, with the
/// live streak commission tag and the OSM route preview. Exactly one offer
/// per ping; dismissing lets the ping expire (which the backend counts as
/// a streak break — the sheet says so).
class _PingListener extends StatefulWidget {
  final DriverStreakService service;
  final String driverId;
  final String currencySymbol;

  /// Driver's last known position (origin of the route preview leg).
  final LatLng driverPosition;

  /// True while the activity is backgrounded (overlay owns the UI).
  final bool Function() isAppPaused;

  /// True while the driver is on a rest break. When true, Stage 1
  /// exclusive pings are suppressed so the driver is not interrupted. The
  /// Quick-Order pool (Tier 3) remains visible and manually browseable.
  final bool Function() isOnBreak;

  final AppUser? user;

  const _PingListener({
    required this.service,
    required this.driverId,
    required this.currencySymbol,
    required this.driverPosition,
    required this.isAppPaused,
    required this.isOnBreak,
    this.user,
  });

  @override
  State<_PingListener> createState() => _PingListenerState();
}

class _PingListenerState extends State<_PingListener> {
  String? _sheetForTrip;
  bool _sheetOpen = false;

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<DriverStreakState>(
      stream: widget.service.streakStream(widget.driverId),
      builder: (context, streakSnap) {
        final streak =
            streakSnap.data ?? DriverStreakState(driverId: widget.driverId);
        return StreamBuilder<ActiveTrip?>(
          stream: widget.service.pingStream(widget.driverId),
          builder: (context, pingSnap) {
            final ping = pingSnap.data;
            if (ping == null) {
              if (_sheetOpen && mounted) {
                // Ping resolved elsewhere (accepted/expired/cancelled).
                _sheetOpen = false;
                _sheetForTrip = null;
                WidgetsBinding.instance.addPostFrameCallback((_) {
                  if (mounted && Navigator.of(context).canPop()) {
                    Navigator.of(context).pop();
                  }
                });
              } else {
                _sheetForTrip = null;
              }
            } else if (_sheetForTrip != ping.tripId && !_sheetOpen) {
              // Gate: suppress exclusive ping popups while driver is on break.
              // The pool badge (Tier 3 marketplace) remains accessible.
              if (widget.isOnBreak()) {
                // Driver is resting — don't auto-popup the offer sheet.
              } else {
                _sheetForTrip = ping.tripId;
                WidgetsBinding.instance.addPostFrameCallback((_) {
                  if (mounted) _showPing(ping, streak);
                });
              }
            }
            return const SizedBox.shrink();
          },
        );
      },
    );
  }

  Future<void> _showPing(ActiveTrip ping, DriverStreakState streak) async {
    if (_sheetOpen || !mounted) return;
    final fareLabel = ping.fareFormatted.isNotEmpty
        ? ping.fareFormatted
        : '₦${ping.fareAmount.toStringAsFixed(0)}';
    if (widget.isAppPaused()) {
      // Do NOT force app to full screen upon arrival: let driver interact with or view
      // the prompt via the active floating overlay system per Rule 3.
      setState(() => _sheetOpen = true);
      // ignore: discarded_futures
      AppSoundService.instance.playIncomingOrderAlert(
        minDuration: Duration(
          seconds: RemoteConfigService.stage1OfferCountdownSeconds > 0
              ? RemoteConfigService.stage1OfferCountdownSeconds
              : 20,
        ),
      );
      await DriverOverlayService.instance.showOrderOffer(
        tripId: ping.tripId,
        pickup: ping.pickupAddress,
        dropoff: ping.dropoffAddress,
        distanceKm: ping.distanceKm.toStringAsFixed(1),
        fare: fareLabel,
        pickupLat: ping.pickupLat,
        pickupLng: ping.pickupLng,
        dropoffLat: ping.dropoffLat,
        dropoffLng: ping.dropoffLng,
      );
      if (mounted) setState(() => _sheetOpen = false);
      // ignore: discarded_futures
      AppSoundService.instance.stopIncomingOrderAlert();
      return;
    }
    setState(() => _sheetOpen = true);
    // Urgent order alert loop — enforces full configured countdown window.
    // ignore: discarded_futures
    AppSoundService.instance.playIncomingOrderAlert(
      minDuration: Duration(
        seconds: RemoteConfigService.stage1OfferCountdownSeconds > 0
            ? RemoteConfigService.stage1OfferCountdownSeconds
            : 20,
      ),
    );
    await Navigator.of(context).push<void>(
      MaterialPageRoute(
        fullscreenDialog: true,
        builder: (_) => IncomingOfferSheet(
          trip: ping,
          streakTag: (ping.status == TripStatus.marketplaceOpen ||
                  ping.status == TripStatus.marketplaceList)
              ? streak.poolOrderLabel(
                  fareAmount: ping.fareAmount,
                  symbol: widget.currencySymbol,
                )
              : streak.streakLabel(
                  fareAmount: ping.fareAmount,
                  symbol: widget.currencySymbol,
                ),
          currencySymbol: widget.currencySymbol,
          driverPosition: widget.driverPosition,
          streakService: widget.service,
          driverId: widget.driverId,
          user: widget.user,
        ),
      ),
    );
    // Sheet dismissed (accepted / skipped / timed out) — stop alert.
    // ignore: discarded_futures
    AppSoundService.instance.stopIncomingOrderAlert();
    if (mounted) {
      setState(() => _sheetOpen = false);
    }
  }
}

/// Invisible listener: fires the celebratory modal once per day when the
/// backend marks the streak complete (Level 3 Step 6 + grand award paid).
class _CelebrationListener extends StatefulWidget {
  final DriverStreakService service;
  final String driverId;
  final String currencySymbol;

  const _CelebrationListener({
    required this.service,
    required this.driverId,
    required this.currencySymbol,
  });

  @override
  State<_CelebrationListener> createState() => _CelebrationListenerState();
}

class _CelebrationListenerState extends State<_CelebrationListener> {
  String? _celebratedKey;

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<DailyStreakConfig>(
      stream: widget.service.streakConfigStream(),
      builder: (context, cfgSnap) {
        final cfg = cfgSnap.data ?? const DailyStreakConfig();
        return StreamBuilder<DriverStreakState>(
          stream: widget.service.streakStream(widget.driverId),
          builder: (context, streakSnap) {
            final streak = streakSnap.data;
            if (streak != null &&
                streak.dailyStreakCompleted &&
                streak.resetDateLocal.isNotEmpty &&
                _celebratedKey != streak.resetDateLocal) {
              _celebratedKey = streak.resetDateLocal;
              WidgetsBinding.instance.addPostFrameCallback((_) {
                if (mounted) {
                  showStreakCelebration(
                    context,
                    awardAmount: cfg.completionCashAward,
                    currencySymbol: widget.currencySymbol,
                  );
                }
              });
            }
            return const SizedBox.shrink();
          },
        );
      },
    );
  }
}

// ---------------------------------------------------------------------------
// Document Expiry Warning Banner
// ---------------------------------------------------------------------------

/// Streams `drivers/{driverId}` and shows a collapsible amber/red banner when
/// any mandatory document (license, inspection, insurance) is expired or
/// expiring within 7 days. Renders nothing when all dates are in-date or
/// not yet entered.
class _DocExpiryBanner extends StatelessWidget {
  final String driverId;

  const _DocExpiryBanner({required this.driverId});

  /// Null when Firebase isn't initialized (widget tests, offline cold start)
  /// — the builder then renders nothing instead of throwing `[core/no-app]`.
  Stream<DocumentSnapshot<Map<String, dynamic>>>? _driverDocStream() {
    if (driverId.isEmpty) return null;
    try {
      return FirebaseFirestore.instance
          .collection('drivers')
          .doc(driverId)
          .snapshots();
    } catch (_) {
      return null;
    }
  }

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
      stream: _driverDocStream(),
      builder: (context, snap) {
        if (!snap.hasData || snap.data?.data() == null) {
          return const SizedBox.shrink();
        }
        final data = snap.data!.data()!;
        final today = DateTime.now();
        final warnCutoff = today.add(const Duration(days: 7));

        DateTime? parseTs(dynamic v) {
          if (v == null) return null;
          try {
            return (v as dynamic).toDate() as DateTime;
          } catch (_) {
            if (v is String) return DateTime.tryParse(v);
            return null;
          }
        }

        final expiries = {
          "Driver's License": parseTs(data['licenseExpiry']),
          'Vehicle Inspection': parseTs(data['inspectionExpiry']),
          'Vehicle Insurance': parseTs(data['insuranceExpiry']),
        };

        // Find the most critical issue first: expired → expiring soon.
        String? message;
        Color bannerColor = Colors.orange;

        for (final entry in expiries.entries) {
          final d = entry.value;
          if (d == null) continue;
          if (d.isBefore(today)) {
            message =
                '${entry.key} expired. Update in Profile → Document Expiry to go online.';
            bannerColor = Colors.red.shade700;
            break; // expired is the most severe — stop scanning
          }
        }

        if (message == null) {
          for (final entry in expiries.entries) {
            final d = entry.value;
            if (d == null) continue;
            if (d.isBefore(warnCutoff)) {
              final days = d.difference(today).inDays;
              message =
                  '${entry.key} expires in $days day${days == 1 ? '' : 's'}. '
                  'Update soon to avoid account suspension.';
              bannerColor = Colors.orange.shade700;
              break;
            }
          }
        }

        if (message == null) return const SizedBox.shrink();

        return Padding(
          padding: const EdgeInsets.fromLTRB(12, 4, 12, 0),
          child: Material(
            color: bannerColor,
            borderRadius: BorderRadius.circular(10),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              child: Row(
                children: [
                  const Icon(Icons.warning_amber_rounded,
                      color: Colors.white, size: 18),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      message,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

// ============================================================================
// _SessionVehiclePickerSheet — proper StatefulWidget so plateController is
// always disposed when the bottom sheet is dismissed (fixes the TextEditingController
// memory leak that the previous StatefulBuilder approach left unresolved).
// ============================================================================

class _SessionVehiclePickerSheet extends StatefulWidget {
  const _SessionVehiclePickerSheet({required this.vehicles});
  final List<VehicleModel> vehicles;

  @override
  State<_SessionVehiclePickerSheet> createState() =>
      _SessionVehiclePickerSheetState();
}

class _SessionVehiclePickerSheetState
    extends State<_SessionVehiclePickerSheet> {
  late VehicleModel _selected;
  final _plateController = TextEditingController();
  String? _plateError;

  @override
  void initState() {
    super.initState();
    final active = widget.vehicles.firstWhereOrNull((v) => v.isActiveSelected);
    _selected = active ??
        widget.vehicles.firstOrNull ??
        VehicleModel(
          id: '',
          driverId: '',
          category: VehicleCategory.car,
          make: '',
          model: '',
          year: 2020,
          licensePlate: '',
          color: '',
          createdAt: DateTime.now(),
          updatedAt: DateTime.now(),
        );
  }

  @override
  void dispose() {
    _plateController.dispose();
    super.dispose();
  }

  void _onConfirm() {
    final typed = _plateController.text
        .trim()
        .replaceAll(RegExp(r'[\s\-]'), '')
        .toUpperCase();
    final expected = _selected.licensePlate
        .trim()
        .replaceAll(RegExp(r'[\s\-]'), '')
        .toUpperCase();
    if (typed != expected) {
      setState(() {
        _plateError =
            'Plate number does not match (${_selected.licensePlate})';
      });
      return;
    }
    Navigator.pop(context, _selected);
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.fromLTRB(
        20,
        16,
        20,
        MediaQuery.of(context).viewInsets.bottom + 20,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Center(
            child: Container(
              width: 40,
              height: 4,
              margin: const EdgeInsets.only(bottom: 12),
              decoration: BoxDecoration(
                color: Colors.grey.shade400,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ),
          const Text(
            'Select Session Vehicle',
            style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 4),
          const Text(
            'Choose vehicle and type its exact plate number to confirm.',
            style: TextStyle(fontSize: 13, color: Colors.grey),
          ),
          const SizedBox(height: 12),
          Flexible(
            child: SingleChildScrollView(
              child: RadioGroup<VehicleModel>(
                groupValue: _selected,
                onChanged: (val) {
                  if (val != null) {
                    setState(() {
                      _selected = val;
                      _plateError = null;
                    });
                  }
                },
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: widget.vehicles.map((veh) {
                    final isSelected = _selected.id == veh.id;
                    return RadioListTile<VehicleModel>(
                      value: veh,
                      contentPadding: EdgeInsets.zero,
                      title: Text(
                        veh.displayTitle,
                        style: const TextStyle(
                          fontWeight: FontWeight.bold,
                          fontSize: 14,
                        ),
                      ),
                      subtitle: Text(
                        'Category: ${veh.category.displayName} '
                        '${veh.tier != null ? "• ${veh.tier!.defaultDisplayName}" : ""}',
                        style: const TextStyle(fontSize: 12),
                      ),
                      secondary: Icon(
                        veh.category == VehicleCategory.car
                            ? Icons.directions_car
                            : Icons.two_wheeler,
                        color: isSelected
                            ? Theme.of(context).colorScheme.primary
                            : Colors.grey,
                      ),
                    );
                  }).toList(),
                ),
              ),
            ),
          ),
          const SizedBox(height: 12),
          const Text(
            'Confirm Plate Number:',
            style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13),
          ),
          const SizedBox(height: 6),
          TextField(
            key: const Key('plate_verification_input'),
            controller: _plateController,
            autocorrect: false,
            textCapitalization: TextCapitalization.characters,
            decoration: InputDecoration(
              hintText:
                  'Type plate number (e.g. ${_selected.licensePlate})',
              errorText: _plateError,
              border: const OutlineInputBorder(),
              contentPadding:
                  const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            ),
            onChanged: (_) {
              if (_plateError != null) {
                setState(() => _plateError = null);
              }
            },
          ),
          const SizedBox(height: 16),
          Row(
            children: [
              Expanded(
                child: OutlinedButton(
                  onPressed: () => Navigator.pop(context),
                  child: const Text('Cancel'),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: FilledButton(
                  key: const Key('confirm_vehicle_online_button'),
                  onPressed: _onConfirm,
                  child: const Text('Confirm & Go Online'),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

