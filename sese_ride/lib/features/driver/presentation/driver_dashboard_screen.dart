import 'dart:async';
import 'dart:io';

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
import '../../payments/top_up_sheet.dart';
import '../../wallet/earnings_screen.dart';
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
  /// (Stage 1 & Stage 2 exclusive offers) are suppressed but the Quick-Order
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

  /// State tracking for auto-collapsing the active trip card on movement.
  ActiveTrip? _currentActiveTrip;
  String? _trackedTripId;
  TripStatus? _lastTrackedStatus;
  LatLng? _tripStartLocation;
  bool _hasAutoCollapsedForTrip = false;
  List<LatLng> _activeRoutePoints = [];
  DateTime? _lastRouteFetchTime;
  final Set<String> _ratedTripDocIds = {};

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
      final points = await LocationService.fetchRoutePolyline(
        _driverPosition,
        LatLng(destLat, destLng),
      );
      if (mounted && points.isNotEmpty) {
        setState(() {
          _activeRoutePoints = points;
        });
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
      widget.streakService ?? DriverStreakService();

  String get _currencySymbol => widget.config?.currencySymbol ?? '₦';

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _driverPosition =
        widget.initialPosition ?? const LatLng(6.5244, 3.3792); // Lagos
    _loadFleet();
    _resolvePosition();
    _startLivePositionTracking();
    _initSessionControl();
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
    // Only `paused` (app fully hidden) and `detached` (Flutter engine torn down)
    // count as genuinely backgrounded for the purposes of the bubble.
    final backgrounded =
        state == AppLifecycleState.paused ||
        state == AppLifecycleState.detached;
    final foreground = state == AppLifecycleState.resumed;

    if (!foreground && !backgrounded) return; // inactive / hidden — ignore

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
        // Intent.FLAG_ACTIVITY_REORDER_TO_FRONT.
        await DriverOverlayService.instance.closeOverlayWidget();
        if (!mounted) return;
        await DriverOverlayService.instance.bringToForeground();
        break;
      case 'accepted':
      case 'rejected':
      case 'expired':
        // Overlay already executed/closed the popup; refresh local state so
        // the feed reflects the outcome when the driver returns.
        await DriverOverlayService.instance.closeOverlayWidget();
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

  /// Continuously follows live GPS movement during active trips and idle positioning.
  /// Detects actual vehicle movement to auto-collapse the bottom action sheet.
  void _startLivePositionTracking() {
    _livePositionSubscription?.cancel();
    try {
      _livePositionSubscription = Geolocator.getPositionStream(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.bestForNavigation,
          distanceFilter: 3,
        ),
      ).listen(
        (pos) {
          if (!mounted) return;
          final newPos = LatLng(pos.latitude, pos.longitude);
          setState(() {
            _driverPosition = newPos;
          });

          // Live map camera follow during active trip or when set to follow
          if (_currentActiveTrip != null || _mapController.isFollowingUser) {
            _mapController.followTo(newPos);
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

  void _collapseActiveTripSheet() {
    if (!_activeTripSheetController.isAttached) return;
    try {
      _activeTripSheetController.animateTo(
        0.32,
        duration: const Duration(milliseconds: 300),
        curve: Curves.easeOutCubic,
      );
    } catch (_) {}
  }

  void _toggleActiveTripSheet() {
    if (!_activeTripSheetController.isAttached) return;
    try {
      final current = _activeTripSheetController.size;
      final target = current <= 0.35 ? 0.50 : 0.32;
      _activeTripSheetController.animateTo(
        target,
        duration: const Duration(milliseconds: 300),
        curve: Curves.easeOutCubic,
      );
    } catch (_) {}
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
            'Under security policy, drivers cannot go online or receive orders until vehicle registration and verification are complete.\n\nPlease register a vehicle and upload all required documents to proceed with account verification.',
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
      builder: (ctx) {
        var selected = vehicles.firstWhere(
          (v) => v.isActiveSelected,
          orElse: () => vehicles.first,
        );
        final plateController = TextEditingController();
        String? plateError;

        return StatefulBuilder(
          builder: (ctx, setSheetState) {
            return Padding(
              padding: EdgeInsets.fromLTRB(
                20,
                16,
                20,
                MediaQuery.of(ctx).viewInsets.bottom + 20,
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
                        groupValue: selected,
                        onChanged: (val) {
                          if (val != null) {
                            setSheetState(() {
                              selected = val;
                              plateError = null;
                            });
                          }
                        },
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: vehicles.map((veh) {
                            final isSelected = selected.id == veh.id;
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
                                    ? Theme.of(ctx).colorScheme.primary
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
                    controller: plateController,
                    autocorrect: false,
                    textCapitalization: TextCapitalization.characters,
                    decoration: InputDecoration(
                      hintText: 'Type plate number (e.g. ${selected.licensePlate})',
                      errorText: plateError,
                      border: const OutlineInputBorder(),
                      contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                    ),
                    onChanged: (_) {
                      if (plateError != null) {
                        setSheetState(() => plateError = null);
                      }
                    },
                  ),
                  const SizedBox(height: 16),
                  Row(
                    children: [
                      Expanded(
                        child: OutlinedButton(
                          onPressed: () => Navigator.pop(ctx),
                          child: const Text('Cancel'),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: FilledButton(
                          key: const Key('confirm_vehicle_online_button'),
                          onPressed: () {
                            final typed = plateController.text
                                .trim()
                                .replaceAll(RegExp(r'[\s\-]'), '')
                                .toUpperCase();
                            final expected = selected.licensePlate
                                .trim()
                                .replaceAll(RegExp(r'[\s\-]'), '')
                                .toUpperCase();
                            if (typed != expected) {
                              setSheetState(() {
                                plateError =
                                    'Plate number does not match (${selected.licensePlate})';
                              });
                              return;
                            }
                            Navigator.pop(ctx, selected);
                          },
                          child: const Text('Confirm & Go Online'),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            );
          },
        );
      },
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
        body: const Center(
          child: CircularProgressIndicator(
            color: AppColors.seseGold,
          ),
        ),
      );
    }

    // Full-screen map canvas base adapting to system theme.
    return PopScope(
      canPop: !_isOnline,
      onPopInvokedWithResult: (didPop, _) async {
        if (didPop) return;
        if (_isOnline) {
          // Minimizes app task to background without killing process & spawns floating SeSe logo
          await DriverOverlayService.instance.moveTaskToBack();
          await DriverOverlayService.instance.showOverlayWidget();
        }
      },
      child: Scaffold(
        backgroundColor: Theme.of(context).scaffoldBackgroundColor,
        body: SizedBox.expand(child: _buildMapStack()),
      ),
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
          if (active.status == TripStatus.completed) {
            _checkAndShowPostTripRating(active);
          } else {
            _fetchActiveTripRoute(active);
          }
          if (active.tripId != _trackedTripId || active.status != _lastTrackedStatus) {
            if (active.status == TripStatus.inProgress &&
                _lastTrackedStatus != TripStatus.inProgress) {
              _hasAutoCollapsedForTrip = false;
              _tripStartLocation = _driverPosition;
            }
            _trackedTripId = active.tripId;
            _lastTrackedStatus = active.status;
          }
        } else if (_activeRoutePoints.isNotEmpty) {
          _activeRoutePoints = [];
        }
        return Stack(
          fit: StackFit.expand,
          children: [
            // 0. Map canvas base. Context flips to realtime tracking while
            // a trip is live so the policy pins the OSM renderer even after
            // Google Maps is provisioned for idle browsing.
            Positioned.fill(child: _buildMapBase(active)),
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
                enabled: _isOnline && active == null,
              ),
            ),
            Positioned(
              top: 0,
              left: 0,
              right: 0,
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
                        padding: const EdgeInsets.symmetric(horizontal: 16),
                        child: _buildActiveTripTopNavBanner(active),
                      ),
                    ] else ...[
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 12),
                        child: _buildOnlineHeader(),
                      ),
                      const SizedBox(height: 6),
                      // Notification bell: positioned directly beneath the GO ONLINE / status banner.
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 16),
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
                      _buildLowBalanceBanner(),
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 12),
                        child: VerificationBanner(driverId: widget.driverId),
                      ),
                      _DocExpiryBanner(driverId: widget.driverId),
                    ],
                  ],
                ),
              ),
            ),
            // 1. Recenter FAB (Module 1): bottom-right — above the bottom card
            // while ONLINE, near the edge while OFFLINE (no bottom card).
            // Shown in both states so the driver can always recenter on GPS.
            Positioned(
              right: 16,
              bottom: active != null
                  ? 180
                  : (_isOnline ? 210 : 16),
              child: Material(
                key: const Key('driver_recenter_fab'),
                color: Theme.of(context).colorScheme.surface,
                elevation: 4,
                shape: const CircleBorder(),
                child: InkWell(
                  customBorder: const CircleBorder(),
                  // Re-engages GPS follow AND snaps back (see home map).
                  onTap: () =>
                      _mapController.recenterTo(_driverPosition, 16.0),
                  child: const Padding(
                    padding: EdgeInsets.all(10),
                    child: Icon(Icons.my_location, size: 22, color: Color(0xFF4285F4)),
                  ),
                ),
              ),
            ),
            // 2. (Radar moved into the Order Pool sheet — map stays clean.)
            // 3. Bottom area:
            // When trip is active: full-width DraggableScrollableSheet touching bottom.
            // When idle/online: floating streak banner + pool badge.
            if (active != null) ...[
              if (MapProviderPolicy.resolve(MapContext.realtimeTracking) !=
                  MapProvider.googleMaps)
                const Positioned(
                  right: 12,
                  bottom: 180,
                  child: _RasterCredit(),
                ),
              // Full-width draggable bottom action sheet extending directly above the bottom nav bar
              _buildActiveTripCard(active),
            ] else if (_isOnline) ...[
              Positioned(
                left: 12,
                right: 12,
                bottom: 12,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    if (MapProviderPolicy.resolve(MapContext.idlePositioning) !=
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
                          onTap: _openPoolSheet,
                        ),
                      ],
                    ),
                  ],
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
              color: AppColors.seseGold,
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
      initialCenter: _driverPosition,
      initialZoom: hasActiveTrip ? 16.5 : 15.0,
      isDarkOverride: isDark,
      showMyLocation: true,
      showRecenterFab: false,
      userLocation: _driverPosition,
      markers: markers,
      polylines: polylines,
    );
  }

  /// Small live cash-balance pill; the full earnings view is one tap away.
  Widget _buildBalancePill() {
    return StreamBuilder<DualWallet>(
      stream: const SeseCoinService().walletStream(widget.driverId),
      builder: (context, snapshot) {
        final balance = snapshot.data?.mainWalletBalance ?? 0;

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
                    '$_currencySymbol${balance.toStringAsFixed(2)}',
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

  Widget _buildLowBalanceBanner() {
    return StreamBuilder<DualWallet>(
      stream: const SeseCoinService().walletStream(widget.driverId),
      builder: (context, wSnap) {
        final wallet = wSnap.data ?? const DualWallet();
        return StreamBuilder<FinancialConfig>(
          stream: const FinancialConfigService().configStream(),
          builder: (context, cSnap) {
            final config = cSnap.data ?? const FinancialConfig();
            final lowBalance = wallet.mainWalletBalance < config.minWalletBalanceToOnline;
            if (!_isOnline || !lowBalance) return const SizedBox.shrink();

            return Container(
              margin: const EdgeInsets.fromLTRB(12, 4, 12, 4),
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Colors.amber.shade900,
                borderRadius: BorderRadius.circular(10),
                boxShadow: const [
                  BoxShadow(color: Colors.black26, blurRadius: 4, offset: Offset(0, 2)),
                ],
              ),
              child: Row(
                children: [
                  const Icon(Icons.warning_amber_rounded, color: Colors.white, size: 24),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'Warning: Your wallet balance is below ₦${config.minWalletBalanceToOnline.toStringAsFixed(2)}. '
                      'You are online, but you will not receive trip requests until you top up your wallet.',
                      style: const TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.w500),
                    ),
                  ),
                  const SizedBox(width: 8),
                  ElevatedButton(
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.white,
                      foregroundColor: Colors.amber.shade900,
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                    ),
                    onPressed: () {
                      final u = widget.user ??
                          AppUser(
                            uid: widget.driverId,
                            fullName: 'Driver',
                            email: '',
                            phoneNumber: '',
                            createdAt: DateTime.now(),
                            role: UserRole.driver,
                          );
                      showTopUpSheet(context, PaymentService(), u);
                    },
                    child: const Text('Top Up Now', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12)),
                  ),
                ],
              ),
            );
          },
        );
      },
    );
  }

  /// Floating top banner shown while a driver has an active trip.
  /// Matches the Uber/Lyft/Bolt top navigation indicator:
  /// Left green navigation icon, current stage ("Now PICKUP/DROPOFF"),
  /// guidance instruction, and quick actions to open in-app navigation
  /// cockpit or toggle voice guidance.
  Widget _buildActiveTripTopNavBanner(ActiveTrip active) {
    final isPickup = active.status != TripStatus.inProgress;

    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.12),
            blurRadius: 10,
            offset: const Offset(0, 3),
          ),
        ],
      ),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      child: Row(
        children: [
          Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              color: const Color(0xFF10B981),
              borderRadius: BorderRadius.circular(10),
            ),
            child: const Center(
              child: Icon(
                Icons.navigation,
                color: Colors.white,
                size: 22,
              ),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  children: [
                    const Text(
                      'Now',
                      style: TextStyle(
                        fontWeight: FontWeight.bold,
                        fontSize: 13,
                        color: Colors.black87,
                      ),
                    ),
                    const SizedBox(width: 6),
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 6, vertical: 2),
                      decoration: BoxDecoration(
                        color: const Color(0xFFD1FAE5),
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: Text(
                        isPickup ? 'PICKUP' : 'DROPOFF',
                        style: const TextStyle(
                          fontSize: 10,
                          fontWeight: FontWeight.bold,
                          color: Color(0xFF047857),
                          letterSpacing: 0.5,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 2),
                Text(
                  isPickup
                      ? 'Head towards pickup'
                      : 'Head towards destination',
                  style: TextStyle(
                    fontSize: 12,
                    color: Colors.grey.shade700,
                    fontWeight: FontWeight.w500,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
          IconButton(
            tooltip: _audioGuidanceMuted ? 'Unmute guidance' : 'Mute guidance',
            icon: Icon(
              _audioGuidanceMuted
                  ? Icons.volume_off_outlined
                  : Icons.volume_up_outlined,
              color: _audioGuidanceMuted ? Colors.grey : Colors.black87,
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
  final bool enabled;

  const _PoolArrivalChime({
    required this.streakService,
    required this.driverPosition,
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
      stream: widget.streakService.marketplaceStream(),
      builder: (context, snap) {
        final trips = snap.data ?? const <ActiveTrip>[];
        final count = trips
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

  /// True while the driver is on a rest break. When true, Stage 1 & Stage 2
  /// exclusive pings are suppressed so the driver is not interrupted. The
  /// Quick-Order pool (Tier 3) remains visible and manually browseable.
  final bool Function() isOnBreak;

  const _PingListener({
    required this.service,
    required this.driverId,
    required this.currencySymbol,
    required this.driverPosition,
    required this.isAppPaused,
    required this.isOnBreak,
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
      // Bring app to full foreground immediately for seamless incoming order review
      await DriverOverlayService.instance.bringToForeground();
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
          streakTag: streak.streakLabel(
            fareAmount: ping.fareAmount,
            symbol: widget.currencySymbol,
          ),
          currencySymbol: widget.currencySymbol,
          driverPosition: widget.driverPosition,
          streakService: widget.service,
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
