import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import 'package:latlong2/latlong.dart';
import 'package:sese_core/sese_core.dart';
import '../../../core/services/remote_config_service.dart';
import '../../trips/models/trip_models.dart';
import '../../../widgets/osm_map_view.dart';
import '../../wallet/earnings_service.dart';
import '../../payments/payment_service.dart';
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
  static const Color _offlineColor = AppColors.seseGold;

  bool _isOnline = false;
  VehicleModel? _activeVehicle;
  List<VehicleModel> _fleet = [];
  bool _loading = true;

  /// True while the activity is backgrounded (overlay bubble owns the UI).
  bool _appPaused = false;

  /// Camera for the home map canvas. Created once; positions move through
  /// it (never recreated — OsmMapView applies the initial center only).
  final SeSeMapController _mapController = SeSeMapController();

  /// Earnings source for the offline snapshot card. Null-Firestore safe.
  late final EarningsService _earnings = EarningsService();

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
  /// platform location fix when available. Used for the signed online
  /// payload and the incoming-offer route preview (the home screen itself
  /// shows no map — the map lives on the incoming offer only).
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
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _mapController.move(_driverPosition, 15.0);
    });
    // Overlay → app actions (bubble tap, overlay accept/reject/expired).
    DriverOverlayService.instance.listenActions(_handleOverlayAction);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final paused = state == AppLifecycleState.paused ||
        state == AppLifecycleState.inactive ||
        state == AppLifecycleState.detached;
    if (paused == _appPaused) return;
    setState(() => _appPaused = paused);
    if (!mounted) return;
    if (paused) {
      // Minimized while ONLINE: the floating SeSe bubble owns the screen.
      if (_isOnline) {
        // ignore: discarded_futures
        DriverOverlayService.instance.showBubble();
      }
    } else {
      // Back in foreground: overlay yields to the in-app UI.
      // ignore: discarded_futures
      DriverOverlayService.instance.hide();
    }
  }

  /// Overlay isolate actions: bubble tap (foreground request) and overlay
  /// accept/reject/expired outcomes for background order popups.
  Future<void> _handleOverlayAction(String action, String tripId) async {
    switch (action) {
      case 'foreground':
        // Bubble tapped while minimized: close the bubble and raise a
        // tap-to-open alert (system foregrounding needs a user gesture).
        await DriverOverlayService.instance.hide();
        if (!mounted) return;
        await PushNotificationService.showReturnToAppAlert(
          body: _isOnline
              ? 'You are ONLINE. Tap to open SeSe.'
              : 'Tap to open SeSe.',
        );
        break;
      case 'accepted':
      case 'rejected':
      case 'expired':
        // Overlay already executed/closed the popup; refresh local state so
        // the feed reflects the outcome when the driver returns.
        await DriverOverlayService.instance.hide();
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
        permission = await Geolocator.requestPermission();
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
      final vehicles = await widget.fleetService.getDriverFleet(widget.driverId);
      if (!mounted) return;
      setState(() {
        _fleet = vehicles;
        if (!silent) _loading = false;
        // If there's an active selected vehicle that is verified, keep it ready
        try {
          _activeVehicle = vehicles.firstWhere((v) => v.isActiveSelected && v.isApproved);
        } catch (_) {
          _activeVehicle = null;
        }
      });
    } catch (e) {
      debugPrint('DriverDashboardScreen._loadFleet error: $e');
      if (mounted && !silent) {
        setState(() => _loading = false);
      }
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
        });
        // Audio feedback: offline double-tone.
        // ignore: discarded_futures
        AppSoundService.instance.playOfflineSound();
        // Bubble/overlay teardown + driver-topic unsubscribe.
        // ignore: discarded_futures
        DriverOverlayService.instance.hide();
        // ignore: discarded_futures
        PushNotificationService.unsubscribe('driver_${widget.driverId}');
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
      _goOnlineWithVerifiedProfile();
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

  void _goOnlineWithVerifiedProfile() async {
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

  /// Lightweight session-vehicle chooser used when the live snapshot is
  /// disabled by Remote Config. Returns null when the driver dismisses.
  Future<VehicleModel?> _pickSessionVehicle(List<VehicleModel> vehicles) {
    return showModalBottomSheet<VehicleModel>(
      context: context,
      builder: (ctx) {
        var selected = vehicles.firstWhere(
          (v) => v.isActiveSelected,
          orElse: () => vehicles.first,
        );
        return StatefulBuilder(
          builder: (ctx, setSheetState) {
            return SafeArea(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(20, 16, 20, 20),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'Select Session Vehicle',
                      style: TextStyle(
                          fontSize: 18, fontWeight: FontWeight.bold),
                    ),
                    const SizedBox(height: 4),
                    const Text(
                      'Choose the vehicle you will use for this session.',
                      style: TextStyle(fontSize: 13),
                    ),
                    const SizedBox(height: 12),
                    Flexible(
                      child: SingleChildScrollView(
                        child: RadioGroup<VehicleModel>(
                          groupValue: selected,
                          onChanged: (val) {
                            if (val != null) {
                              setSheetState(() => selected = val);
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
                                      fontSize: 14),
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
                            onPressed: () => Navigator.pop(ctx, selected),
                            child: const Text('Go Online'),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
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
        });
        // Audio feedback: online chime.
        // ignore: discarded_futures
        AppSoundService.instance.playOnlineSound();
        // Overlay bubble readiness + driver-topic push subscription.
        // ignore: discarded_futures
        DriverOverlayService.instance.ensurePermission();
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
          config: widget.config,
        ),
      ),
    );
    _loadFleet();
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Scaffold(
        body: Center(child: CircularProgressIndicator()),
      );
    }

    // Full-screen map canvas base. Offline renders the same tiles through
    // a grayscale filter; online is full color. The OSM view lives here
    // (plus the offer-sheet route preview) and nowhere else on this tab.
    // No AppBar: the home occupies the top space. Fleet and document
    // management live in Settings.
    return Scaffold(
      body: SafeArea(
        child: SizedBox.expand(
          child: _buildMapStack(),
        ),
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
  /// - bottom shows the live-trip card, else the offline snapshot card, else
  ///   the streak banner. Tier 1/2 offers arrive as full-screen sheets via
  ///   [_PingListener], never inline — the inline [OrderFeed] list is
  ///   superseded by the pool sheet and is no longer mounted here.
  Widget _buildMapStack() {
    return StreamBuilder<ActiveTrip?>(
      stream: _streaks.activeTripStream(widget.driverId),
      builder: (context, tripSnap) {
        final active = tripSnap.data;
        return Stack(
          fit: StackFit.expand,
          children: [
            // 0. Map canvas base.
            Positioned.fill(child: _buildMapBase()),
            // Invisible listeners: incoming-offer page + grand-award
            // celebration modal (dialogs driven by Firestore streams).
            _PingListener(
              service: _streaks,
              driverId: widget.driverId,
              currencySymbol: _currencySymbol,
              driverPosition: _driverPosition,
              isAppPaused: () => _appPaused,
            ),
            _CelebrationListener(
              service: _streaks,
              driverId: widget.driverId,
              currencySymbol: _currencySymbol,
            ),
            // New pool arrivals chime once while browsing the map.
            _PoolArrivalChime(
              streakService: _streaks,
              driverPosition: _driverPosition,
              enabled: _isOnline && active == null,
            ),
            // 1. Floating top controls.
            Positioned(
              top: 0,
              left: 0,
              right: 0,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  _buildOnlineHeader(),
                  if (_isOnline)
                    Padding(
                      padding:
                          const EdgeInsets.only(top: 8, left: 12, right: 12),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.end,
                        children: [
                          PoolBadge(
                            streakService: _streaks,
                            driverPosition: _driverPosition,
                            onTap: _openPoolSheet,
                          ),
                        ],
                      ),
                    ),
                  const SizedBox(height: 8),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    child: VerificationBanner(driverId: widget.driverId),
                  ),
                ],
              ),
            ),
            // 2. Center radar while online, idle, and pool-empty.
            if (_isOnline && active == null)
              _PoolRadarOverlay(
                streakService: _streaks,
                driverPosition: _driverPosition,
              ),
            // 3. Bottom card: live trip, else offline snapshot, else streak.
            Positioned(
              left: 12,
              right: 12,
              bottom: 12,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const Align(
                    alignment: Alignment.centerRight,
                    child: _OsmCredit(),
                  ),
                  const SizedBox(height: 4),
                  if (active != null)
                    ConstrainedBox(
                      constraints: BoxConstraints(
                        maxHeight:
                            MediaQuery.sizeOf(context).height * 0.45,
                      ),
                      child: SingleChildScrollView(
                        child: _buildActiveTripCard(active),
                      ),
                    )
                  else if (_isOnline)
                    _buildBottomStreakSlot()
                  else
                    _OfflineSnapshotCard(
                      driverId: widget.driverId,
                      streakService: _streaks,
                      earnings: _earnings,
                      driverPosition: _driverPosition,
                      currencySymbol: _currencySymbol,
                    ),
                ],
              ),
            ),
          ],
        );
      },
    );
  }

  /// Tile canvas with a driver-position marker. Offline mutes the tiles to
  /// grayscale; the marker stays gold either way.
  Widget _buildMapBase() {
    final map = OsmMapView(
      mapController: _mapController,
      initialCenter: _driverPosition,
      initialZoom: 15.0,
      markers: [
        OsmMapView.pin(
          point: _driverPosition,
          color: AppColors.seseGold,
        ),
      ],
    );
    if (_isOnline) return map;
    // Standard luminance grayscale — signals "not receiving orders" while
    // keeping streets readable underneath.
    return ColorFiltered(
      colorFilter: const ColorFilter.matrix(<double>[
        0.2126, 0.7152, 0.0722, 0, 0,
        0.2126, 0.7152, 0.0722, 0, 0,
        0.2126, 0.7152, 0.0722, 0, 0,
        0, 0, 0, 1, 0,
      ]),
      child: map,
    );
  }

  /// Compact status pill up top (minimal vertical space).
  ///
  /// - OFFLINE: glowing green "GO ONLINE" pill — one tap goes online
  ///   immediately (verification guard + server grant still apply).
  /// - ONLINE: "Slide to go offline" slider thumb; completing the slide
  ///   opens the go-offline confirmation sheet.
  Widget _buildOnlineHeader() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 0),
      child: _isOnline
          ? SlideToOffline(
              key: const Key('slide_to_offline'),
              enabled: !_syncing,
              onSlideComplete: _showGoOfflineConfirmation,
            )
          : GestureDetector(
              key: const Key('power_toggle'),
              onTap: _syncing ? null : _goOnlineNow,
              child: Container(
                height: 52,
                decoration: BoxDecoration(
                  color: _offlineColor,
                  borderRadius: BorderRadius.circular(28),
                  boxShadow: [
                    BoxShadow(
                      color: _offlineColor.withValues(alpha: 0.5),
                      blurRadius: 12,
                      offset: const Offset(0, 3),
                    ),
                  ],
                ),
                alignment: Alignment.center,
                child: _syncing
                    ? const SizedBox(
                        width: 22,
                        height: 22,
                        child: CircularProgressIndicator(
                            strokeWidth: 2, color: Colors.black),
                      )
                    : Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Icon(Icons.power_settings_new,
                              color: Colors.black, size: 22),
                          const SizedBox(width: 8),
                          Text(
                            'GO ONLINE',
                            style: Theme.of(context)
                                .textTheme
                                .titleMedium
                                ?.copyWith(
                                  color: Colors.black,
                                  fontWeight: FontWeight.bold,
                                  letterSpacing: 0.5,
                                ),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ],
                      ),
              ),
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
        );
      },
    );
  }

  /// Bottom slot: daily streak banner (+ live arrived wait timer), floating
  /// above the map canvas while online and idle.
  Widget _buildBottomStreakSlot() {    return StreamBuilder<DailyStreakConfig>(
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
                return Material(
                  elevation: 8,
                  child: Padding(
                    padding: const EdgeInsets.only(bottom: 12),
                    child: StreakProgressBanner(
                      streak: streak,
                      fareAmount: active?.fareAmount ?? 0,
                      currencySymbol: _currencySymbol,
                      waitThresholdMinutes: cfg.noShowWaitMinutes,
                      arrivedAt: active?.arrivedAt,
                    ),
                  ),
                );
              },
            );
          },
        );
      },
    );
  }
}

/// Visible OSM attribution credit.
///
/// The tile layer's built-in credit sits bottom-right, which the bottom card
/// covers — so this chip renders just above the card, right-aligned, keeping
/// the required OpenStreetMap credit visible at all times.
class _OsmCredit extends StatelessWidget {
  const _OsmCredit();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.55),
        borderRadius: BorderRadius.circular(6),
      ),
      child: const Text(
        '© OpenStreetMap contributors',
        style: TextStyle(fontSize: 10, color: Colors.white70),
      ),
    );
  }
}

/// Center radar overlay while online, idle, and pool-empty.
///
/// The badge already pulses when orders exist, so this draws the eye only
/// when there is nothing to tap — a breathing radar glyph plus the idle
/// line. Ignores pointers so map gestures pass straight through.
class _PoolRadarOverlay extends StatefulWidget {
  final DriverStreakService streakService;
  final LatLng driverPosition;

  const _PoolRadarOverlay({
    required this.streakService,
    required this.driverPosition,
  });

  @override
  State<_PoolRadarOverlay> createState() => _PoolRadarOverlayState();
}

class _PoolRadarOverlayState extends State<_PoolRadarOverlay>
    with SingleTickerProviderStateMixin {
  late final AnimationController _pulse;

  @override
  void initState() {
    super.initState();
    _pulse = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 2400),
    )..repeat();
  }

  @override
  void dispose() {
    _pulse.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<List<ActiveTrip>>(
      stream: widget.streakService.marketplaceStream(),
      builder: (context, snap) {
        final count = (snap.data ?? const <ActiveTrip>[])
            .where((t) => OrderFeedState.withinPoolRadius(
                t, widget.driverPosition))
            .length;
        // Pool non-empty: the pulsing badge owns attention; stay out of
        // the way (but keep the layout slot stable to avoid jumps).
        if (count > 0) return const SizedBox.shrink();
        return IgnorePointer(
          child: Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                AnimatedBuilder(
                  animation: _pulse,
                  builder: (context, child) => Transform.scale(
                    scale: 1.0 + _pulse.value * 0.12,
                    child: Opacity(
                      opacity: 0.65 + _pulse.value * 0.35,
                      child: child,
                    ),
                  ),
                  child: Container(
                    width: 72,
                    height: 72,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: Theme.of(context)
                          .colorScheme
                          .primaryContainer
                          .withValues(alpha: 0.75),
                    ),
                    child: Icon(
                      Icons.radar,
                      size: 34,
                      color:
                          Theme.of(context).colorScheme.primary,
                    ),
                  ),
                ),
                const SizedBox(height: 10),
                Container(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 14, vertical: 7),
                  decoration: BoxDecoration(
                    color: Colors.black.withValues(alpha: 0.55),
                    borderRadius: BorderRadius.circular(16),
                  ),
                  child: const Text(
                    'Searching for available orders...',
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: Colors.white,
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

/// One-shot chime when fresh pool orders arrive while browsing the map.
///
/// Fires only on count *increases* past the first snapshot (initial load
/// never chimes), and only while [enabled] (online, no live trip). Uses the
/// short message chime rather than the 6s order loop — the loop belongs to
/// exclusive pings with a countdown, not to background pool arrivals.
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
  int? _lastCount;

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<List<ActiveTrip>>(
      stream: widget.streakService.marketplaceStream(),
      builder: (context, snap) {
        if (snap.hasData) {
          final count = snap.data!
              .where((t) => OrderFeedState.withinPoolRadius(
                  t, widget.driverPosition))
              .length;
          final prev = _lastCount;
          _lastCount = count;
          if (widget.enabled &&
              prev != null &&
              count > prev &&
              mounted) {
            WidgetsBinding.instance.addPostFrameCallback((_) {
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

/// Offline snapshot card: today's earnings, today's completed trips, and a
/// live demand hint derived from the current pool (count + nearest pickup
/// area). Pool reads require a driver doc, not online status, so an offline
/// driver can still see real demand — with neutral copy when empty.
class _OfflineSnapshotCard extends StatelessWidget {
  final String driverId;
  final DriverStreakService streakService;
  final EarningsService earnings;
  final LatLng driverPosition;
  final String currencySymbol;

  const _OfflineSnapshotCard({
    required this.driverId,
    required this.streakService,
    required this.earnings,
    required this.driverPosition,
    required this.currencySymbol,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Card(
      elevation: 8,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              "You're offline",
              style: Theme.of(context)
                  .textTheme
                  .titleMedium
                  ?.copyWith(fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 10),
            StreamBuilder<List<TripEarning>>(
              stream: earnings.completedTripEarningsStream(driverId),
              builder: (context, snap) {
                final day = EarningsService.summarizeDay(
                  snap.data ?? const <TripEarning>[],
                  DateTime.now(),
                ).day;
                return Row(
                  children: [
                    Expanded(
                      child: _SnapshotStat(
                        label: "Today's earnings",
                        value: PaymentService.formatNaira(day.gross),
                      ),
                    ),
                    Expanded(
                      child: _SnapshotStat(
                        label: 'Trips today',
                        value: '${day.tripCount}',
                      ),
                    ),
                  ],
                );
              },
            ),
            const SizedBox(height: 10),
            StreamBuilder<List<ActiveTrip>>(
              stream: streakService.marketplaceStream(),
              builder: (context, snap) {
                final trips = (snap.data ?? const <ActiveTrip>[])
                    .where((t) => OrderFeedState.withinPoolRadius(
                        t, driverPosition))
                    .toList();
                final hotspot = _hotspotText(trips);
                return Row(
                  children: [
                    Icon(
                      trips.isEmpty
                          ? Icons.nights_stay_outlined
                          : Icons.local_fire_department_outlined,
                      size: 16,
                      color: trips.isEmpty
                          ? scheme.onSurfaceVariant
                          : Colors.orange.shade800,
                    ),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        hotspot,
                        style: TextStyle(
                          fontSize: 12,
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                    ),
                  ],
                );
              },
            ),
          ],
        ),
      ),
    );
  }

  /// Demand hint from live pool density: count plus the nearest pickup area.
  /// Falls back to neutral copy when the pool is empty — never invented.
  String _hotspotText(List<ActiveTrip> trips) {
    if (trips.isEmpty) {
      return 'No open requests nearby right now.';
    }
    ActiveTrip? nearest;
    var best = double.infinity;
    for (final t in trips) {
      final d = OrderFeedState.haversineKm(
        driverPosition.latitude,
        driverPosition.longitude,
        t.pickupLat,
        t.pickupLng,
      );
      if (d < best) {
        best = d;
        nearest = t;
      }
    }
    final area = ((nearest?.pickupAddress ?? '').split(',').first).trim();
    final where_ = area.isEmpty ? 'near you' : 'near $area';
    final n = trips.length;
    return 'High demand $where_ — $n open request${n == 1 ? '' : 's'}.';
  }
}

class _SnapshotStat extends StatelessWidget {
  final String label;
  final String value;

  const _SnapshotStat({required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          value,
          style: const TextStyle(
            fontSize: 20,
            fontWeight: FontWeight.bold,
          ),
        ),
        Text(
          label,
          style: TextStyle(
            fontSize: 12,
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
        ),
      ],
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

  const _PingListener({
    required this.service,
    required this.driverId,
    required this.currencySymbol,
    required this.driverPosition,
    required this.isAppPaused,
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
              _sheetForTrip = ping.tripId;
              WidgetsBinding.instance.addPostFrameCallback((_) {
                if (mounted) _showPing(ping, streak);
              });
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
      // Backgrounded: expand the overlay into the full-screen order popup
      // (details + live 6s countdown + atomic ACCEPT/REJECT in the overlay
      // isolate). No in-app sheet while the activity is paused.
      setState(() => _sheetOpen = true);
      // ignore: discarded_futures
      AppSoundService.instance
          .playIncomingOrderAlert(minDuration: const Duration(seconds: 6));
      await DriverOverlayService.instance.showOrderOffer(
        tripId: ping.tripId,
        pickup: ping.pickupAddress,
        dropoff: ping.dropoffAddress,
        distanceKm: ping.distanceKm.toStringAsFixed(1),
        fare: fareLabel,
      );
      if (mounted) setState(() => _sheetOpen = false);
      // The overlay plays no sound itself, so stop the loop here — mirroring
      // the foreground path below. The deferred-stop logic still guarantees
      // the 6s minimum even if the overlay returns immediately. Without this
      // the chime looped until the next foreground sheet disposed it.
      // ignore: discarded_futures
      AppSoundService.instance.stopIncomingOrderAlert();
      return;
    }
    setState(() => _sheetOpen = true);
    // Urgent order alert loop — enforces min 6s playback (full countdown).
    // ignore: discarded_futures
    AppSoundService.instance
        .playIncomingOrderAlert(minDuration: const Duration(seconds: 6));
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


