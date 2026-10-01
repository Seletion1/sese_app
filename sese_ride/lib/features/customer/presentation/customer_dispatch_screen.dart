import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:latlong2/latlong.dart';
import 'package:sese_core/sese_core.dart';

import '../../../widgets/osm_map_view.dart';
import '../models/fare_models.dart';
import '../services/fare_service.dart';
import '../services/location_service.dart';
import '../../trips/models/trip_models.dart';
import '../../trips/presentation/live_trip_screen.dart';
import '../../trips/services/trip_service.dart';

/// Validates a Nigerian phone number (strict, server-aligned).
///
/// Mirrors the backend `NG_PHONE` contract (`^(\+?234|0)(70|71|80|81|90|91)
/// \d{8}$`): local 11-digit, +234, or 234-prefixed numbers with valid
/// mobile prefixes only. A loose E.164 check here would green-light
/// numbers the server rejects (e.g. US numbers), failing bookings after
/// the client already accepted them.
bool isValidNigerianPhoneNumber(String? input) {
  return SesePhoneSanitizer.isValidNigerianNumber(input);
}

/// Step-by-step booking screen for both Ride-Hailing and Package Delivery.
///
/// Flow:
///   1. **Locations** — GPS + reverse-geocode pickup; auto-focus drop-off;
///      forward-geocode drop-off as user types; inline route-map preview.
///   2. **Choose Option** — server fares from [FareService]; delivery
///      pre-selects Motorcycle (recommended); ride shows car tiers.
///   3. **Review & Confirm** — tagged pickup/drop-off summary with mandatory
///      contact phone numbers + server-authoritative fare breakdown + fareToken.
class CustomerDispatchScreen extends StatefulWidget {
  final RegionConfig? initialConfig;
  final AppUser? user;

  /// 0 = Package Delivery, 1 = Ride-Hailing.
  final int initialModeIndex;

  /// When false the mode toggle is hidden.
  final bool showModeSelector;

  /// AppBar title used when the mode toggle is hidden.
  final String? focusedTitle;

  /// Injectable [FareService] seam for testing.
  final FareService? fareService;

  /// Injectable live-dispatch seam for testing. Defaults to the production
  /// Firestore transport (constructed lazily on first dispatch, never at
  /// widget build time).
  final TripRepository? tripRepository;

  /// Optional initial pickup position and address.
  final LatLng? initialPickupLatLng;
  final String? initialPickupAddress;

  /// Optional initial drop-off position and address (test seam / deep link).
  final LatLng? initialDropoffLatLng;
  final String? initialDropoffAddress;

  /// Optional initial contact phones (test seams). When null, the pickup
  /// phone is pre-filled from [user]'s phone number (editable — e.g. when
  /// booking for someone else); the drop-off phone starts empty.
  final String? initialPickupPhone;
  final String? initialDropoffPhone;

  const CustomerDispatchScreen({
    super.key,
    this.initialConfig,
    this.user,
    this.initialModeIndex = 0,
    this.showModeSelector = true,
    this.focusedTitle,
    this.fareService,
    this.initialPickupLatLng,
    this.initialPickupAddress,
    this.initialDropoffLatLng,
    this.initialDropoffAddress,
    this.initialPickupPhone,
    this.initialDropoffPhone,
    this.tripRepository,
  });

  @override
  State<CustomerDispatchScreen> createState() => _CustomerDispatchScreenState();
}

class _CustomerDispatchScreenState extends State<CustomerDispatchScreen> {
  late final FareService _fareService;
  late RegionConfig _config;

  /// Live-dispatch transport. The production Firestore implementation is
  /// created on first use so widget construction never touches Firebase.
  TripRepository get _tripRepository =>
      widget.tripRepository ?? FirestoreTripRepository();

  /// True while the `createTrip` callable is in flight (Confirm shows a
  /// spinner and ignores repeat taps).
  bool _creatingTrip = false;


  // ── Mode & Step ───────────────────────────────────────────────────────────
  int _selectedModeIndex = 0;
  int _currentStep = 0;

  // ── Step 1: Locations ─────────────────────────────────────────────────────
  final _pickupController = TextEditingController();
  final _dropoffController = TextEditingController();
  final _pickupFocusNode = FocusNode();
  final _dropoffFocusNode = FocusNode();

  LatLng? _pickupLatLng;
  LatLng? _dropoffLatLng;

  /// Address text that produced [_dropoffLatLng]. Guards [_onDropoffChanged]:
  /// focusing the field fires controller notifications for selection-only
  /// changes (same text) — those must not wipe the resolved coordinates.
  /// Only a genuinely edited query invalidates them.
  String? _resolvedDropoffQuery;

  bool _pickupGeocoding = false; // true only while resolving GPS

  /// True while the drop-off field is being GPS-resolved in Receive mode.
  /// Gates Step 1 Next the same way [_pickupGeocoding] does.
  bool _dropoffGeocoding = false;

  // Autocomplete suggestions
  Timer? _debounceTimer;
  List<PlaceSuggestion> _suggestions = [];
  bool _isLoadingSuggestions = false;
  bool _isSelectingSuggestion = false;

  // Route preview
  List<LatLng> _routePoints = [];
  bool _fetchingRoute = false;

  // ── Step 1→2 fare loading ─────────────────────────────────────────────────
  FareResponse? _fareResponse;
  bool _fareLoading = false;
  String? _fareError;

  // ── Smart Dynamic Recommendation Engine ───────────────────────────────────
  // Distance thresholds (system_configs/vehicle_recommendations, editable in
  // sese_hub without a release). Compiled defaults apply when the doc is
  // missing/unreadable, so recommendations always resolve to something sane.
  VehicleRecommendationConfig _recConfig =
      const VehicleRecommendationConfig();

  // ── Step 3: Contact phones ────────────────────────────────────────────────
  // Cached validity driving the guarded _onPhoneChanged refresh.
  bool _lastPhonesValid = false;
  // Mandatory Nigerian-format numbers for driver/rider coordination. Pickup
  // is pre-filled from the signed-in user's number but stays editable (e.g.
  // booking for someone else); drop-off is the recipient's number.
  final _pickupPhoneController = TextEditingController();
  final _dropoffPhoneController = TextEditingController();

  // ── Step 2: Delivery selection ────────────────────────────────────────────
  final Set<VehicleCategory> _selectedDeliveryCategories = {
    VehicleCategory.motorcycle, // pre-selected recommended
  };

  // ── Step 2: Ride-Hailing selection ────────────────────────────────────────
  // Multi-select broadcast set, standardized with delivery: users may check
  // several car tiers at once (first to accept wins). At least one tier
  // must stay selected.
  final Set<String> _selectedRideTierIds = {'comfort'};

  /// Per-tier custom fares entered by the customer (tierId → amount).
  /// Only populated when the customer raises a fare above the baseline.
  /// Sent to the backend as [TripDraft.customTierFares].
  final Map<String, double> _customTierFares = {};

  // ── Dispatch ──────────────────────────────────────────────────────────────
  static const Map<VehicleCategory, String> _deliveryTierIds = {
    VehicleCategory.bicycle: 'bicycle',
    VehicleCategory.motorcycle: 'motorcycle',
    VehicleCategory.tricycle: 'tricycle',
    VehicleCategory.car: 'car',
    VehicleCategory.van: 'van',
    VehicleCategory.truck: 'truck',
  };

  static const List<String> _rideTierIds = ['comfort', 'premium', 'luxe'];

  /// Tier ids requested from the server for passenger rides. Always includes
  /// 'tricycle' so the fare exists when Keke is offered for short trips; the
  /// UI decides per-distance whether to show, badge, or pre-select it.
  /// NOTE: `_rideTierIds` (without tricycle) stays the canonical broadcast
  /// order — see `_orderedRideTierIds`.
  static const List<String> _rideFareTierIds = [
    'comfort',
    'premium',
    'luxe',
    'tricycle',
  ];

  /// Server id of the passenger Keke tier.
  static const String _rideTricycleTierId = 'tricycle';

  // ─────────────────────────────────────────────────────────────────────────
  @override
  void initState() {
    super.initState();
    _config = widget.initialConfig ?? RegionConfig.globalDefault();
    _fareService = widget.fareService ?? FareService();
    _selectedModeIndex = widget.initialModeIndex;
    // Receive Item: the user's own location is the DELIVERY destination, so
    // GPS auto-detect fills the drop-off field and Pickup stays empty for
    // manual entry. Send Item / Ride: GPS fills Pickup as before.
    if (widget.initialPickupAddress != null) {
      _pickupController.text = widget.initialPickupAddress!;
      _pickupLatLng = widget.initialPickupLatLng;
      _pickupGeocoding = false;
    } else if (!_isReceiveMode) {
      _initPickupLocation();
    }
    if (widget.initialDropoffAddress != null) {
      _dropoffController.text = widget.initialDropoffAddress!;
      _dropoffLatLng = widget.initialDropoffLatLng;
      _resolvedDropoffQuery = widget.initialDropoffAddress;
    } else if (_isReceiveMode) {
      _initDropoffLocation();
    }
    // Pre-fill contact phones: explicit seams win, otherwise the pickup
    // phone defaults to the signed-in user's number.
    _pickupPhoneController.text = widget.initialPickupPhone ??
        widget.user?.phoneNumber ??
        '';
    _dropoffPhoneController.text = widget.initialDropoffPhone ?? '';
    // Rebuild on phone edits so the Confirm button enables live once both
    // numbers validate. NOTE: no controller listeners here — the phone
    // fields already refresh via their onChanged callbacks, and the
    // formatter rewrites controller text on every keystroke; listening on
    // top would echo those writes back into setState indefinitely.
    _dropoffController.addListener(_onDropoffChanged);
    if (_pickupLatLng != null && _dropoffLatLng != null) {
      _updateMapBoundsAndRoute();
    }
    // When either address is pre-seeded, focus the mode-appropriate field
    // once the first frame is laid out (pickup for Receive, drop-off
    // otherwise). GPS flows focus via their own delayed call below.
    if (widget.initialPickupAddress != null ||
        widget.initialDropoffAddress != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _focusInitialField();
      });
    }
  }

  /// True when opened as "Receive Item": the sender's pickup address is the
  /// unknown field, so initial focus belongs on pickup. Send Item / Book
  /// Ride focus the drop-off destination instead.
  bool get _isReceiveMode =>
      widget.focusedTitle?.toLowerCase().contains('receive') == true;

  /// Requests focus on the mode-appropriate location field.
  void _focusInitialField() {
    if (_isReceiveMode) {
      _pickupFocusNode.requestFocus();
    } else {
      _dropoffFocusNode.requestFocus();
    }
  }

  @override
  void dispose() {
    _pickupController.dispose();
    _dropoffController.dispose();
    _pickupFocusNode.dispose();
    _dropoffFocusNode.dispose();
    _pickupPhoneController.dispose();
    _dropoffPhoneController.dispose();
    _debounceTimer?.cancel();
    super.dispose();
  }

  // ── Location initialisation ───────────────────────────────────────────────
  //
  // SECURITY: raw GPS coordinates are kept only in memory (`_pickupLatLng` /
  // `_dropoffLatLng`). They are never written to persistent local storage
  // unencrypted (no SharedPreferences / Hive / file caching of LatLng).

  /// Immediate GPS detection on launch for Send Item / Ride: checks service
  /// + runtime permission (via [LocationService], backed by geolocator),
  /// fetches a high-accuracy single fix, reverse-geocodes into the Pickup
  /// field, and pans the map view to the user position. Gracefully
  /// falls back to a manual-entry hint when service is off or permission is
  /// denied. Receive Item never calls this — GPS fills Drop-off instead
  /// (see [_initDropoffLocation]).
  Future<void> _initPickupLocation() async {
    setState(() => _pickupGeocoding = true);
    try {
      final latLng = widget.initialPickupLatLng ??
          await LocationService.getCurrentLatLng();
      if (!mounted) return;

      if (latLng != null) {
        _pickupLatLng = latLng;
        final address =
            await LocationService.reverseGeocode(latLng.latitude, latLng.longitude);
        if (!mounted) return;
        _pickupController.text = address;
        // Pan / fit the map immediately on the auto-detected position.
        _updateMapBoundsAndRoute();
      } else {
        _pickupController.text = 'Location unavailable — tap to enter';
      }
    } finally {
      if (mounted) {
        setState(() => _pickupGeocoding = false);
        // Auto-focus the mode-appropriate field after pickup resolves:
        // pickup for Receive Item, drop-off otherwise.
        Future.delayed(const Duration(milliseconds: 300), () {
          if (mounted) _focusInitialField();
        });
      }
    }
  }

  /// Immediate GPS detection on launch for Receive Item: the user is the
  /// parcel recipient, so their current fix is the DELIVERY destination and
  /// goes into the Drop-off field. Pickup stays empty for manual entry and
  /// receives initial focus so the keyboard is ready to type.
  ///
  /// Coordinate source order: explicit `initialDropoffLatLng`, then the
  /// unclaimed `initialPickupLatLng` position fix passed by the home map
  /// (same user position — avoids a redundant GPS round-trip), then a live
  /// platform fix.
  Future<void> _initDropoffLocation() async {
    setState(() => _dropoffGeocoding = true);
    try {
      final latLng = widget.initialDropoffLatLng ??
          (widget.initialPickupAddress == null
              ? widget.initialPickupLatLng
              : null) ??
          await LocationService.getCurrentLatLng();
      if (!mounted) return;

      if (latLng != null) {
        _dropoffLatLng = latLng;
        final address =
            await LocationService.reverseGeocode(latLng.latitude, latLng.longitude);
        if (!mounted) return;
        // Lock the resolved query BEFORE setting text: the controller
        // listener fires synchronously on set and must see the address as
        // already resolved, or it would wipe these coordinates.
        _resolvedDropoffQuery = address;
        _dropoffController.text = address;
        // Pan / fit the map immediately on the auto-detected position.
        _updateMapBoundsAndRoute();
      } else {
        _dropoffController.text = 'Location unavailable — tap to enter';
      }
    } finally {
      if (mounted) {
        setState(() => _dropoffGeocoding = false);
        // Pickup is the unknown field in Receive mode — focus it so the
        // keyboard pops up ready for the pickup address.
        Future.delayed(const Duration(milliseconds: 300), () {
          if (mounted) _focusInitialField();
        });
      }
    }
  }

  // ── Drop-off autocomplete suggestions (debounced 300ms) ───────────────────

  void _onDropoffChanged() {
    if (_isSelectingSuggestion) return;
    if (_debounceTimer?.isActive ?? false) _debounceTimer!.cancel();

    final query = _dropoffController.text.trim();

    // Selection/focus noise (e.g. auto-focus on open) re-notifies with the
    // same text that already resolved — keep the coordinates.
    if (query == _resolvedDropoffQuery) return;
    _resolvedDropoffQuery = null;

    if (query.isEmpty) {
      if (mounted) {
        setState(() {
          _suggestions = [];
          _isLoadingSuggestions = false;
          _dropoffLatLng = null;
          _routePoints = [];
        });
      }
      return;
    }

    // Invalidate previous coordinates while user is typing a new query
    if (_dropoffLatLng != null) {
      if (mounted) {
        setState(() {
          _dropoffLatLng = null;
          _routePoints = [];
        });
      }
    }

    // Debounce API calls by 300ms while user is actively typing
    _debounceTimer = Timer(const Duration(milliseconds: 300), () async {
      if (!mounted) return;
      setState(() => _isLoadingSuggestions = true);

      // Fetch place suggestions WITHOUT mutating TextField value
      final results = await LocationAutocompleteService.fetchSuggestions(query);

      if (!mounted) return;
      setState(() {
        _suggestions = results;
        _isLoadingSuggestions = false;
      });
    });
  }

  void _selectSuggestion(PlaceSuggestion suggestion) {
    // Explicit user selection: populate text & lock lat/lng
    _isSelectingSuggestion = true;
    _dropoffController.text = suggestion.description;
    _dropoffLatLng = LatLng(suggestion.lat, suggestion.lng);
    _resolvedDropoffQuery = suggestion.description;

    setState(() {
      _suggestions = []; // Clear dropdown list
      _isLoadingSuggestions = false;
    });

    FocusScope.of(context).unfocus(); // Dismiss keyboard
    _isSelectingSuggestion = false;
    _updateMapBoundsAndRoute();
  }

  /// Fetches the route polyline whenever pickup or drop-off coordinates
  /// change, and rebuilds so [_RouteMapPreview] receives updated route points.
  /// Camera fitting is handled inside [_RouteMapPreview.didUpdateWidget] so
  /// both markers and the connecting route stay fully visible.
  ///
  /// Called whenever either text field resolves to new coordinates — on
  /// GPS auto-detect, on suggestion selection, and when both deep-link /
  /// initial points are present.
  void _updateMapBoundsAndRoute() {
    _fetchRoutePreview();
  }

  Future<void> _fetchRoutePreview() async {
    final pickup = _pickupLatLng;
    final dropoff = _dropoffLatLng;
    if (pickup == null || dropoff == null) return;
    setState(() => _fetchingRoute = true);
    // Production safeguard: route geometry should come from an authorized
    // backend (e.g. `seseRoutingHttp` Cloud Function with caching) at scale.
    // The direct OSRM public-server call inside LocationService is a
    // zero-key dev fallback — no routing API keys are hardcoded on the client.
    final points = await LocationService.fetchRoutePolyline(pickup, dropoff);
    if (mounted) {
      setState(() {
        // Direct straight-line fallback so the preview always connects
        // Point A → Point B even when the routing service is unreachable.
        _routePoints = points.isNotEmpty ? points : [pickup, dropoff];
        _fetchingRoute = false;
      });
    }
  }

  // ── Fare calculation (called on Step 1 → 2 transition) ───────────────────

  Future<bool> _loadFares() async {
    final pickup = _pickupLatLng;
    final dropoff = _dropoffLatLng;
    if (pickup == null || dropoff == null) return false;

    setState(() {
      _fareLoading = true;
      _fareError = null;
      _fareResponse = null;
    });

    final isDelivery = _selectedModeIndex == 0;
    // Fare estimation must cover ALL enabled vehicle categories so every
    // card in "Choose Vehicles" gets a server price. Requesting only the
    // user-selected subset (e.g. just motorcycle) left the other tiers with
    // no data and a perpetual loading spinner. Selection remains a separate
    // UI-state concern used only at broadcast time.
    // Category ids match the Cloud Function config 1:1
    // (bicycle, motorcycle, tricycle, van, truck — see pricing.ts
    // DEFAULT_RATES / DELIVERY_TIER_NAMES).
    // Delivery shows ALL 6 eligible vehicle types (incl. Car / Sedan) per spec.
    // Rides additionally request the 'tricycle' passenger tier so short
    // (< kekeMaxDistanceKm) trips can offer Keke with a live server fare. The
    // server prices unknown tier ids at car base rates, so no backend change
    // was needed — see computeFares/carTierConfigForTierId fallback.
    final selectedTiers = isDelivery
        ? VehicleCategory.values
            .where((c) => c.isDeliveryEligible)
            .map((c) => _deliveryTierIds[c] ?? c.name)
            .toList()
        : _rideFareTierIds;

    final serviceType = isDelivery
        ? (_isReceiveMode
            ? FareServiceType.receiveItem
            : FareServiceType.sendItem)
        : FareServiceType.ride;

    try {
      // Recommendation thresholds resolve alongside the fare so badges and
      // pre-selection apply in the same frame. Best-effort: compiled
      // defaults apply when the doc is missing/unreadable.
      final recConfig =
          await const VehicleRecommendationService().getConfig();
      final response = await _fareService.calculateFare(
        pickup: pickup,
        dropoff: dropoff,
        serviceType: serviceType,
        selectedTiers: selectedTiers,
      );
      if (mounted) {
        setState(() {
          _fareResponse = response;
          _fareLoading = false;
          _recConfig = recConfig;
          // Auto-select recommended delivery categories (a set — short and
          // mid-range trips badge two vehicles).
          if (isDelivery) {
            final engineCats =
                VehicleRecommendationEngine.recommendedDeliveriesFor(
              response.distanceKm,
              recConfig,
            );
            final serverCat = response.recommendedTier == null
                ? null
                : _tierIdToCategory(response.recommendedTier!.tierId);
            final cats = engineCats.isNotEmpty
                ? engineCats
                : (serverCat == null ? <VehicleCategory>{} : {serverCat});
            // Engine first, server badge as fallback — never an empty set.
            if (cats.isNotEmpty) {
              _selectedDeliveryCategories
                ..clear()
                ..addAll(cats);
            } else if (_selectedDeliveryCategories.isEmpty) {
              _selectedDeliveryCategories.add(VehicleCategory.motorcycle);
            }
          } else {
            // Keep the user's ride-tier broadcast selection; if none of the
            // selected tiers came back from the server, fall back to the
            // recommended / first tier so at least one stays selected.
            final validIds =
                response.tiers.map((t) => t.tierId).toSet();
            _selectedRideTierIds.retainWhere(validIds.contains);
            // Keke offer is distance-driven: below the ceiling it joins the
            // broadcast set (more drivers for short hops); at/above it the
            // UI unchecks it while keeping the card visible.
            if (VehicleRecommendationEngine.offerKekeForRide(
                response.distanceKm, recConfig)) {
              if (validIds.contains(_rideTricycleTierId)) {
                _selectedRideTierIds.add(_rideTricycleTierId);
              }
            } else {
              _selectedRideTierIds.remove(_rideTricycleTierId);
            }
            if (_selectedRideTierIds.isEmpty) {
              final rec = response.recommendedTier;
              _selectedRideTierIds.add(rec?.tierId ??
                  (response.tiers.isNotEmpty
                      ? response.tiers.first.tierId
                      : 'comfort'));
            }
          }
        });
      }
      return true;
    } on FareException catch (e) {
      if (mounted) {
        setState(() {
          _fareError = e.userMessage;
          _fareLoading = false;
        });
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(e.userMessage),
            backgroundColor: Colors.red.shade700,
            action: SnackBarAction(
              label: 'Retry',
              textColor: Colors.white,
              onPressed: _loadFares,
            ),
          ),
        );
      }
      return false;
    }
  }

  VehicleCategory? _tierIdToCategory(String tierId) {
    for (final entry in _deliveryTierIds.entries) {
      if (entry.value == tierId) return entry.key;
    }
    return null;
  }

  // ── Step navigation ───────────────────────────────────────────────────────
  //
  // Back-navigation contract (Book a Ride / Send Item / Receive Item share
  // this wizard): system back gesture, hardware back button, and the AppBar
  // back arrow step backward sequentially (Step 3 → 2 → 1) and only pop the
  // route back to Home when already on the first step.

  /// Steps back one wizard step, or pops the route when on the first step.
  ///
  /// Shared by the AppBar back arrow, [PopScope] system-back interception,
  /// and the internal step "Back" buttons. Returns `true` when the route
  /// was popped, `false` when we stepped back internally.
  bool _handleBackNavigation() {
    if (_currentStep > 0) {
      setState(() => _currentStep -= 1);
      return false;
    }
    Navigator.of(context).pop();
    return true;
  }

  bool get _addressesReady =>
      _pickupLatLng != null && _dropoffLatLng != null;

  /// Both Step 3 contact numbers must be valid Nigerian phone numbers
  /// (080… / +234…) before the booking can be confirmed.
  bool get _phonesValid =>
      isValidNigerianPhoneNumber(_pickupPhoneController.text) &&
      isValidNigerianPhoneNumber(_dropoffPhoneController.text);

  void _onPhoneChanged() {
    // Refresh Confirm-button enablement + inline validation errors.
    // Guarded on validity flips: the phone formatter rewrites controller
    // text on every keystroke, so an unconditional setState here would
    // re-run its update cycle indefinitely (never-settling UI).
    final valid = _phonesValid;
    if (valid == _lastPhonesValid) return;
    _lastPhonesValid = valid;
    if (mounted) setState(() {});
  }

  bool _canProceedFrom(int step) {
    switch (step) {
      case 0:
        return _addressesReady &&
            !_pickupGeocoding &&
            !_dropoffGeocoding &&
            !_isLoadingSuggestions;
      case 1:
        return _fareResponse != null &&
            (_selectedModeIndex == 0
                ? _selectedDeliveryCategories.isNotEmpty
                : _selectedRideTierIds.isNotEmpty);
      case 2:
        return _fareResponse != null && _phonesValid;
      default:
        return true;
    }
  }

  Future<void> _onNextTapped() async {
    if (_currentStep == 0) {
      // Trigger fare load before advancing
      final ok = await _loadFares();
      if (ok && mounted) setState(() => _currentStep = 1);
    } else if (_currentStep == 1) {
      if (_canProceedFrom(1)) setState(() => _currentStep = 2);
    }
  }

  /// True while a heavy-duty vehicle (Van/Truck) is selected: small-vehicle
  /// cards render disabled so a heavy-cargo broadcast never pages
  /// bicycle/tricycle/motorcycle riders.
  bool get _heavyDutyLocked => _selectedDeliveryCategories
      .any(VehicleRecommendationEngine.isHeavyDuty);

  /// Toggles a delivery category with heavy-duty rules:
  /// - selecting Truck first asks for explicit confirmation (heavy cargo);
  /// - selecting Van/Truck strips + disables the small-vehicle options;
  /// - tapping a disabled small vehicle explains the lock instead of acting.
  Future<void> _toggleDeliveryCategory(VehicleCategory category) async {
    if (!mounted) return;
    if (_heavyDutyLocked &&
        VehicleRecommendationEngine.isSmallVehicle(category) &&
        !_selectedDeliveryCategories.contains(category)) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
              'Deselect Van/Truck first — heavy-duty broadcasts exclude small vehicles.'),
        ),
      );
      return;
    }
    if (!_selectedDeliveryCategories.contains(category) &&
        category == VehicleCategory.truck) {
      final confirmed = await _showTruckConfirmDialog();
      if (!mounted || confirmed != true) return;
    }
    setState(() {
      if (_selectedDeliveryCategories.contains(category)) {
        if (_selectedDeliveryCategories.length > 1) {
          _selectedDeliveryCategories.remove(category);
        } else {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('At least one vehicle category must be selected.'),
            ),
          );
        }
      } else {
        _selectedDeliveryCategories.add(category);
        // Heavy-duty mutual exclusion: adding Van/Truck evicts the small
        // options (server rejects mixed payloads — see createTrip).
        if (VehicleRecommendationEngine.isHeavyDuty(category)) {
          _selectedDeliveryCategories
              .removeWhere(VehicleRecommendationEngine.isSmallVehicle);
        }
      }
    });
  }

  /// Heavy-duty confirmation for Truck: explicit opt-in before the option
  /// checks. Returns true only on "Confirm".
  Future<bool?> _showTruckConfirmDialog() {
    return showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Heavy-Duty Cargo?'),
        content: const Text(
          'Please confirm you are selecting a Truck for heavy-duty cargo. '
          'Bicycle, Tricycle, and Motorcycle options will be disabled for '
          'this broadcast.',
          style: TextStyle(fontSize: 13),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Confirm'),
          ),
        ],
      ),
    );
  }

  /// Toggles a ride-hailing tier in the multi-select broadcast set.
  /// Mirrors [_toggleDeliveryCategory]: at least one tier stays selected.
  void _toggleRideTier(String tierId) {
    setState(() {
      if (_selectedRideTierIds.contains(tierId)) {
        if (_selectedRideTierIds.length > 1) {
          // Retain at least 1 selection.
          _selectedRideTierIds.remove(tierId);
        } else {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('At least one ride tier must be selected.'),
            ),
          );
        }
      } else {
        _selectedRideTierIds.add(tierId);
      }
    });
  }

  /// Selected ride tiers in canonical server order (comfort → premium → luxe
  /// → tricycle) so payloads and the review table stay deterministic.
  List<String> get _orderedRideTierIds => const [
        ..._rideTierIds,
        _rideTricycleTierId,
      ].where(_selectedRideTierIds.contains).toList();

  /// Delivery card badge source. The engine overrides the server badge when it
  /// resolves categories for this distance; otherwise the server value stands.
  bool _deliveryRecommended(VehicleCategory cat, FareResponse resp) {
    final engineCats =
        VehicleRecommendationEngine.recommendedDeliveriesFor(
      resp.distanceKm,
      _recConfig,
    );
    if (engineCats.isNotEmpty) return engineCats.contains(cat);
    return resp.tierById(_deliveryTierIds[cat] ?? cat.name)?.isRecommended ??
        false;
  }

  /// Ride card display tier. Overrides the server row in two cases, both
  /// driven by distance:
  /// - tricycle: renamed to 'Tricycle (Keke)' (server echoes the raw id) and
  ///   badged Recommended only while the Keke offer is active;
  /// - comfort: badge suppressed while Keke holds the recommendation so two
  ///   cards never claim it at once.
  FareTier _displayRideTier(FareTier tier, double distanceKm) {
    if (tier.tierId == _rideTricycleTierId) {
      return FareTier(
        tierId: tier.tierId,
        name: VehicleCategory.tricycle.displayName,
        isRecommended: VehicleRecommendationEngine.offerKekeForRide(
            distanceKm, _recConfig),
        fareFormatted: tier.fareFormatted,
        fareAmount: tier.fareAmount,
      );
    }
    if (tier.tierId == 'comfort' &&
        VehicleRecommendationEngine.offerKekeForRide(
            distanceKm, _recConfig)) {
      return FareTier(
        tierId: tier.tierId,
        name: tier.name,
        isRecommended: false,
        fareFormatted: tier.fareFormatted,
        fareAmount: tier.fareAmount,
      );
    }
    return tier;
  }

  /// Delivery display tier: engine badge override, fares untouched.
  FareTier _displayDeliveryTier(FareTier tier, VehicleCategory cat) {
    final resp = _fareResponse;
    if (resp == null) return tier;
    return FareTier(
      tierId: tier.tierId,
      name: tier.name,
      isRecommended: _deliveryRecommended(cat, resp),
      fareFormatted: tier.fareFormatted,
      fareAmount: tier.fareAmount,
    );
  }

  // ── Dispatch ──────────────────────────────────────────────────────────────

  /// Smart Distance Warning dialog. Returns true when the user confirms the
  /// non-ideal selection anyway, false/null when they go back to change it.
  ///
  /// Copy names the offending vehicle(s) and the actual trip length so the
  /// choice is informed, not generic. Thresholds come from the live
  /// recommendation config, never hardcoded copy.
  Future<bool?> _showDistanceWarningDialog(
    List<VehicleCategory> warned,
    double distanceKm,
  ) {
    final dist = distanceKm.toStringAsFixed(1);
    final lines = warned.map((c) {
      final ceiling =
          VehicleRecommendationEngine.warningCeilingFor(c, _recConfig);
      final name = c.displayName;
      if (c == VehicleCategory.bicycle) {
        return 'You have selected $name for a long-distance trip '
            '($dist km). Bicycles may take significantly longer to arrive '
            'or complete delivery.';
      }
      return '$name${ceiling != null ? 's' : ''} are restricted on major '
          'expressways and long-distance routes ($dist km). Selecting '
          '$name may delay driver matching or lead to cancellation.';
    }).toList();

    final suggestion = warned.contains(VehicleCategory.bicycle)
        ? 'Would you like to switch to ${VehicleCategory.motorcycle.displayName} or proceed anyway?'
        : 'Are you sure you want to proceed?';

    return showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Long-Distance Warning'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (final line in lines) ...[
              Text(line, style: const TextStyle(fontSize: 13)),
              const SizedBox(height: 8),
            ],
            Text(suggestion,
                style: const TextStyle(
                    fontSize: 13, fontWeight: FontWeight.w600)),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Confirm Anyway'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Change Vehicle'),
          ),
        ],
      ),
    );
  }

  Future<void> _confirmAndDispatch() async {
    final fareResp = _fareResponse;
    if (fareResp == null || _creatingTrip) return;
    if (!_phonesValid) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'Enter valid pickup and drop-off phone numbers '
              '(e.g. 08012345678 or +2348012345678).',
            ),
          ),
        );
      }
      return;
    }

    final isDelivery = _selectedModeIndex == 0;
    final pickupPhone =
        SesePhoneSanitizer.normalize(_pickupPhoneController.text.trim());
    final dropoffPhone =
        SesePhoneSanitizer.normalize(_dropoffPhoneController.text.trim());
    final pickup = _pickupLatLng!;
    final dropoff = _dropoffLatLng!;
    final orderedRideTiers = _orderedRideTierIds;
    final selectedTiers = isDelivery
        ? _selectedDeliveryCategories
            .map((c) => _deliveryTierIds[c] ?? c.name)
            .toList()
        : orderedRideTiers;

    // Smart Distance Warning: when a selected vehicle is non-ideal for this
    // trip length, confirm before minting. Fires at confirm-time (not on
    // every tap) so multi-select browsing stays fluid, and re-asks on every
    // confirm while the selection is non-ideal — an explicit per-trip choice.
    final warned = isDelivery
        ? VehicleRecommendationEngine.nonIdealSelections(
            fareResp.distanceKm,
            _selectedDeliveryCategories,
            _recConfig,
          )
        : (_selectedRideTierIds.contains(_rideTricycleTierId)
            ? VehicleRecommendationEngine.nonIdealSelections(
                fareResp.distanceKm,
                const [VehicleCategory.tricycle],
                _recConfig,
              )
            : const <VehicleCategory>[]);
    if (warned.isNotEmpty) {
      final proceed = await _showDistanceWarningDialog(
        warned,
        fareResp.distanceKm,
      );
      if (!mounted || proceed != true) return;
    }

    // 1. Mint the live trip on the server. From here the backend owns
    // matchmaking, ping timeouts, and re-broadcasts — the request stays
    // active even if the customer closes the app.
    // Client-side verification hint (the backend resolves
    // `isVerifiedCustomer` authoritatively from `users/{uid}` on mint).
    bool verifiedCustomer = false;
    try {
      final userDoc = await FirebaseFirestore.instance
          .collection('users')
          .doc(widget.user?.uid ?? '')
          .get();
      final userData = userDoc.data();
      verifiedCustomer =
          userData?[CustomerVerification.fieldStatus] ==
                  CustomerVerification.verified ||
              userData?[CustomerVerification.fieldIsVerified] == true;
    } catch (_) {}
    setState(() => _creatingTrip = true);
    late final String tripId;
    try {
      tripId = await _tripRepository.createTrip(
        TripDraft(
          customerId: widget.user?.uid ?? '',
          pickupLat: pickup.latitude,
          pickupLng: pickup.longitude,
          pickupAddress: _pickupController.text,
          pickupPhone: pickupPhone,
          dropoffLat: dropoff.latitude,
          dropoffLng: dropoff.longitude,
          dropoffAddress: _dropoffController.text,
          dropoffPhone: dropoffPhone,
          serviceType: isDelivery ? 'send_item' : 'ride',
          selectedTiers: selectedTiers,
          fareToken: fareResp.fareToken,
          distanceKm: fareResp.distanceKm,
          durationMins: fareResp.durationMins,
          isVerifiedCustomer: verifiedCustomer,
          customTierFares:
              _customTierFares.isNotEmpty ? Map.from(_customTierFares) : null,
        ),
      );
    } on TripException catch (e) {
      if (mounted) {
        setState(() => _creatingTrip = false);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(e.userMessage),
            backgroundColor: Colors.red.shade700,
          ),
        );
      }
      return;
    } finally {
      if (mounted) setState(() => _creatingTrip = false);
    }
    if (!mounted) return;

    // Payload mirror for the createTrip / createDelivery Cloud Functions
    // (route + server-verified fare + mandatory contact numbers). Sent via
    // the authenticated callable above — never hardcode credentials.
    final dispatchPayload = <String, dynamic>{
      'tripId': tripId,
      'pickup': {
        'lat': pickup.latitude,
        'lng': pickup.longitude,
        'address': _pickupController.text,
        'phone': pickupPhone,
      },
      'dropoff': {
        'lat': dropoff.latitude,
        'lng': dropoff.longitude,
        'address': _dropoffController.text,
        'phone': dropoffPhone,
      },
      'pickupPhone': pickupPhone,
      'dropoffPhone': dropoffPhone,
      'serviceType': isDelivery ? 'send_item' : 'ride',
      'selectedTiers': selectedTiers,
      'fareToken': fareResp.fareToken,
      'distanceKm': fareResp.distanceKm,
      'durationMins': fareResp.durationMins,
    };
    debugPrint('Dispatch payload: $dispatchPayload');

    // 2. Navigate directly to the live tracker — the customer immediately sees
    // "Searching for nearby available drivers..." without an intermediate dialog.
    if (mounted) {
      Navigator.of(context).pushReplacement(
        MaterialPageRoute(
          builder: (_) => LiveTripScreen(
            tripId: tripId,
            repository: _tripRepository,
          ),
        ),
      );
    }
  }

  // ── Build ─────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final focused = !widget.showModeSelector;
    final title = !focused
        ? 'SESE Dispatch & Ride-Hailing'
        : (widget.focusedTitle ??
            (_selectedModeIndex == 1 ? 'Book a Ride' : 'Courier Delivery'));

    return PopScope(
      // Only allow the system to pop the route on the first step; deeper
      // steps are consumed internally via onPopInvokedWithResult.
      canPop: _currentStep == 0,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        // System back gesture / hardware back on Step 2+: step backward
        // instead of exiting to Home.
        if (_currentStep > 0) {
          setState(() => _currentStep -= 1);
        }
      },
      child: Scaffold(
        appBar: AppBar(
          title: Text(title),
          leading: BackButton(
            // Steps back sequentially (Step 3 → 2 → 1); pops to Home only
            // from the first step. Shared handler with PopScope + the
            // internal step "Back" buttons.
            onPressed: _handleBackNavigation,
          ),
          bottom: widget.showModeSelector ? _buildModeSelectorBar() : null,
        ),
        body: Column(
          children: [
            _buildTopStepIndicator(_currentStep),
            // Step 1 (locations) is a bounded, non-scrolling layout: the
            // map preview below takes all remaining vertical space via
            // Expanded. Steps 2-3 keep their scrolling content.
            if (_currentStep == 0)
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 0),
                  child: _buildStep1Content(),
                ),
              )
            else
              Expanded(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                  child: _buildStepContent(),
                ),
              ),
            _buildControls(),
          ],
        ),
      ),
    );
  }

  PreferredSizeWidget _buildModeSelectorBar() {
    return PreferredSize(
      preferredSize: const Size.fromHeight(56),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 10),
        child: SegmentedButton<int>(
          segments: const [
            ButtonSegment(
              value: 0,
              label: Text('Delivery'),
              icon: Icon(Icons.local_shipping),
            ),
            ButtonSegment(
              value: 1,
              label: Text('Ride'),
              icon: Icon(Icons.directions_car),
            ),
          ],
          selected: {_selectedModeIndex},
          onSelectionChanged: (set) => setState(() {
            _selectedModeIndex = set.first;
            _currentStep = 0;
            _fareResponse = null;
          }),
        ),
      ),
    );
  }

  /// Compact horizontal step indicator: circles 1 · 2 · 3 joined by thin
  /// divider lines. Completed steps show a check, the active step a
  /// highlighted number, upcoming steps a subtle grey number. Tapping a
  /// completed circle steps back (same as tapping a previous Stepper step).
  Widget _buildTopStepIndicator(int currentStep) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 16.0, horizontal: 24.0),
      child: Row(
        children: [
          _buildStepCircle(stepNumber: 1, currentStep: currentStep),
          _buildStepConnector(isCompleted: currentStep > 1),
          _buildStepCircle(stepNumber: 2, currentStep: currentStep),
          _buildStepConnector(isCompleted: currentStep > 2),
          _buildStepCircle(stepNumber: 3, currentStep: currentStep),
        ],
      ),
    );
  }

  Widget _buildStepCircle({required int stepNumber, required int currentStep}) {
    // Step indices are 0-based internally; circles are 1-based.
    final int stepIndex = stepNumber - 1;
    final bool isCompleted = _currentStep > stepIndex;
    final bool isActive = _currentStep == stepIndex;
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;

    Color backgroundColor =
        isDark ? theme.colorScheme.surfaceContainerHighest : Colors.grey.shade300;
    Color textColor =
        isDark ? theme.colorScheme.onSurfaceVariant : Colors.grey.shade700;

    if (isCompleted || isActive) {
      backgroundColor = theme.colorScheme.primary;
      textColor = theme.colorScheme.onPrimary;
    }

    final circle = Container(
      width: 32,
      height: 32,
      decoration: BoxDecoration(
        color: backgroundColor,
        shape: BoxShape.circle,
      ),
      child: Center(
        child: isCompleted
            ? Icon(Icons.check, size: 18, color: theme.colorScheme.onPrimary)
            : Text(
                '$stepNumber',
                style: TextStyle(
                  color: textColor,
                  fontWeight: FontWeight.bold,
                  fontSize: 14,
                ),
              ),
      ),
    );

    // Completed circles are tappable shortcuts back to that step.
    if (isCompleted) {
      return InkWell(
        customBorder: const CircleBorder(),
        onTap: () => setState(() => _currentStep = stepIndex),
        child: circle,
      );
    }
    return circle;
  }

  Widget _buildStepConnector({required bool isCompleted}) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    return Expanded(
      child: Container(
        height: 2,
        color: isCompleted
            ? theme.colorScheme.primary
            : (isDark
                ? theme.colorScheme.outlineVariant
                : Colors.grey.shade300),
      ),
    );
  }

  /// Current step header (title + subtitle) shown above the step content.
  /// Keeps the Stepper's text labels so step context is never lost.
  Widget _buildStepHeader() {
    final String title;
    final String subtitle;
    switch (_currentStep) {
      case 0:
        title = 'Enter Locations';
        subtitle = 'Pickup & destination';
        break;
      case 1:
        title = _selectedModeIndex == 0 ? 'Choose Vehicles' : 'Choose Tiers';
        subtitle = _selectedModeIndex == 0
            ? 'Select vehicle types to broadcast'
            : 'Select tiers to broadcast';
        break;
      default:
        title = 'Review & Confirm';
        subtitle = 'Check details before booking';
        break;
    }
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title,
              style:
                  const TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
          const SizedBox(height: 2),
          Text(subtitle,
              style: TextStyle(fontSize: 12, color: Colors.grey.shade600)),
        ],
      ),
    );
  }

  /// Active step content (exactly one step's body is ever in the tree, so a
  /// single Next/Confirm button exists — same contract the Stepper's
  /// controlsBuilder provided).
  Widget _buildStepContent() {
    switch (_currentStep) {
      case 0:
        return _buildStep1Content();
      case 1:
        return _buildStep2Content();
      default:
        return _buildStep3Content();
    }
  }

  /// Single Next/Back/Confirm controls row pinned below the step content.
  Widget _buildControls() {
    final isLast = _currentStep == 2;
    final canContinue = _canProceedFrom(_currentStep);

    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
        child: Row(
          children: [
            Expanded(
              child: isLast
                  ? FilledButton.icon(
                      // Gated on valid pickup + drop-off contact numbers, and
                      // disabled while the trip-creation call is in flight.
                      onPressed: (canContinue && !_creatingTrip)
                          ? _confirmAndDispatch
                          : null,
                      icon: _creatingTrip
                          ? const SizedBox(
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(
                                  strokeWidth: 2, color: Colors.white))
                          : Icon(_selectedModeIndex == 0
                              ? Icons.broadcast_on_personal
                              : Icons.car_rental),
                      label: Text(_selectedModeIndex == 0
                          ? 'Confirm & Broadcast'
                          : 'Confirm & Book Ride'),
                      style: FilledButton.styleFrom(
                        padding: const EdgeInsets.symmetric(vertical: 14)),
                    )
                  : FilledButton(
                      onPressed: (canContinue && !_fareLoading)
                          ? _onNextTapped
                          : null,
                      child: _fareLoading && _currentStep == 0
                          ? const SizedBox(
                              width: 18, height: 18,
                              child: CircularProgressIndicator(
                                  strokeWidth: 2, color: Colors.white))
                          : const Text('Next'),
                    ),
            ),
            if (_currentStep > 0) ...[
              const SizedBox(width: 12),
              OutlinedButton(
                // Same step-decrement path as the AppBar arrow / system back —
                // never pops the route from an internal step card.
                onPressed: _handleBackNavigation,
                style: OutlinedButton.styleFrom(
                  side: BorderSide.none,
                  backgroundColor:
                      Theme.of(context).colorScheme.surfaceContainerHighest,
                ),
                child: const Text('Back'),
              ),
            ],
          ],
        ),
      ),
    );
  }

  // ── Step 1: Locations ─────────────────────────────────────────────────────

  Widget _buildStep1Content() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _buildStepHeader(),
          // ── Pickup field ──────────────────────────────────────────────────
          TextField(
            controller: _pickupController,
            focusNode: _pickupFocusNode,
            decoration: InputDecoration(
              labelText: 'Pickup Location',
              alignLabelWithHint: true,
              prefixIcon: const Icon(Icons.trip_origin, color: Colors.green),
              suffixIcon: _pickupGeocoding
                  ? const Padding(
                      padding: EdgeInsets.all(14),
                      child: SizedBox(
                          width: 16, height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2)))
                  : IconButton(
                      icon: const Icon(Icons.my_location),
                      tooltip: 'Re-detect my location',
                      onPressed: _initPickupLocation,
                    ),
              helperText: 'Auto-detected — tap to edit',
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: BorderSide.none,
              ),
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: BorderSide.none,
              ),
              focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: BorderSide.none,
              ),
              filled: true,
              fillColor: Theme.of(context).colorScheme.surfaceContainerHighest,
              // Roomy (non-dense) layout with explicit top padding so the
              // floating label never clips against the outline border.
              isDense: false,
              contentPadding:
                  const EdgeInsets.fromLTRB(12, 16, 12, 12),
            ),
            onChanged: (_) {
              // Clear stored coords if user manually edits pickup, and drop
              // the stale route so bounds recalculate on the next fix.
              setState(() {
                _pickupLatLng = null;
                _routePoints = [];
              });
            },
          ),
          const SizedBox(height: 12),

          // ── Drop-off field ────────────────────────────────────────────────
          TextField(
            controller: _dropoffController,
            focusNode: _dropoffFocusNode,
            decoration: InputDecoration(
              labelText: 'Destination / Drop-off',
              hintText: 'Where to?',
              alignLabelWithHint: true,
              prefixIcon: const Icon(Icons.location_on, color: Colors.red),
              suffixIcon: (_isLoadingSuggestions || _dropoffGeocoding)
                  ? const Padding(
                      padding: EdgeInsets.all(14),
                      child: SizedBox(
                          width: 16, height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2)))
                  : _dropoffLatLng != null
                      ? const Icon(Icons.check_circle, color: Colors.green)
                      : null,
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: BorderSide.none,
              ),
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: BorderSide.none,
              ),
              focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: BorderSide.none,
              ),
              filled: true,
              fillColor: Theme.of(context).colorScheme.surfaceContainerHighest,
              // Same roomy layout as pickup — prevents floating-label clip.
              isDense: false,
              contentPadding:
                  const EdgeInsets.fromLTRB(12, 16, 12, 12),
            ),
          ),

          // ── Autocomplete suggestions dropdown ─────────────────────────────
          // Flexible (not fixed-height) so the non-scrolling Step 1 column
          // never overflows: the list takes only remaining space and
          // scrolls internally; the map below keeps the rest.
          Flexible(
            child: _buildSuggestionsDropdown(),
          ),

          // ── Hint ──────────────────────────────────────────────────────────
          if (!_addressesReady && !_pickupGeocoding && _suggestions.isEmpty && !_isLoadingSuggestions)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Row(
                children: [
                  Icon(Icons.info_outline,
                      size: 14, color: Colors.grey.shade500),
                  const SizedBox(width: 6),
                  Text(
                    _pickupLatLng == null
                        ? 'Enter your pickup address'
                        : 'Type a destination to continue',
                    style: TextStyle(
                        fontSize: 12, color: Colors.grey.shade500),
                  ),
                ],
              ),
            ),

          // ── Inline route map ──────────────────────────────────────────────
          // Expands to fill all remaining vertical space between the
          // location inputs and the pinned Next button.
          if (_addressesReady)
            Expanded(
              child: Padding(
                padding: const EdgeInsets.only(top: 12, bottom: 12),
                child: _RouteMapPreview(
                  pickup: _pickupLatLng!,
                  dropoff: _dropoffLatLng!,
                  routePoints: _routePoints,
                  isLoadingRoute: _fetchingRoute,
                ),
              ),
            ),
        ],
    );
  }

  // ── Autocomplete suggestions dropdown builder ─────────────────────────────

  Widget _buildSuggestionsDropdown() {
    if (_isLoadingSuggestions) {
      return const Padding(
        padding: EdgeInsets.all(12.0),
        child: Center(child: CircularProgressIndicator(strokeWidth: 2)),
      );
    }

    if (_suggestions.isEmpty) return const SizedBox.shrink();

    return Container(
      margin: const EdgeInsets.only(top: 4),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(12),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.08),
            blurRadius: 8,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Material(
        color: Theme.of(context).cardColor,
        borderRadius: BorderRadius.circular(12),
        clipBehavior: Clip.antiAlias,
        child: ListView.separated(
          shrinkWrap: true,
          physics: const ClampingScrollPhysics(),
          itemCount: _suggestions.length,
          separatorBuilder: (_, _) => const SizedBox(height: 8),
          itemBuilder: (context, index) {
            final suggestion = _suggestions[index];
            return ListTile(
              dense: true,
              leading: const Icon(Icons.location_on_outlined, color: Colors.amber),
              title: Text(
                suggestion.description,
                style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w500),
              ),
              onTap: () => _selectSuggestion(suggestion),
            );
          },
        ),
      ),
    );
  }

  // ── Step 2: Choose Option ─────────────────────────────────────────────────

  Widget _buildStep2Content() {
    if (_fareResponse == null) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _buildStepHeader(),
          const Center(
            child: Padding(
              padding: EdgeInsets.all(24),
              child: CircularProgressIndicator(),
            ),
          ),
        ],
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _buildStepHeader(),
        _selectedModeIndex == 0
            ? _buildDeliverySelector()
            : _buildRideSelector(),
      ],
    );
  }

  Widget _buildDeliverySelector() {
    final resp = _fareResponse!;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            const Text('Multi-Vehicle Broadcast',
                style:
                    TextStyle(fontWeight: FontWeight.bold, fontSize: 15)),
            Chip(
              label:
                  Text('${_selectedDeliveryCategories.length} selected'),
              backgroundColor:
                  Theme.of(context).colorScheme.primaryContainer,
              side: BorderSide.none,
              visualDensity: VisualDensity.compact,
            ),
          ],
        ),
        const SizedBox(height: 4),
        const Text(
          'All selected types are broadcast simultaneously — first to accept gets the order.',
          style: TextStyle(fontSize: 12, color: Colors.grey),
        ),
        const SizedBox(height: 12),
        ...VehicleCategory.values
            .where((c) => c.isDeliveryEligible)
            .map((cat) {
          final tierId = _deliveryTierIds[cat] ?? cat.name;
          final tier = resp.tierById(tierId);
          final isSelected = _selectedDeliveryCategories.contains(cat);
          // Heavy-duty lock: small options disable (not hide) while Van or
          // Truck is selected, so the exclusion is visible, not mysterious.
          final enabled = isSelected ||
              !_heavyDutyLocked ||
              !VehicleRecommendationEngine.isSmallVehicle(cat);
          return _DeliveryVehicleCard(
            category: cat,
            serverFare: tier?.fareFormatted,
            isRecommended:
                tier == null ? false : _deliveryRecommended(cat, resp),
            isSelected: isSelected,
            enabled: enabled,
            onTap: () => _toggleDeliveryCategory(cat),
          );
        }),

        // Fare error hint
        if (_fareError != null)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(_fareError!,
                style:
                    const TextStyle(color: Colors.red, fontSize: 12)),
          ),
      ],
    );
  }

  Widget _buildRideSelector() {
    final resp = _fareResponse!;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            const Text('Passenger Car Tiers',
                style: TextStyle(fontWeight: FontWeight.bold, fontSize: 15)),
            Chip(
              label: Text('${_selectedRideTierIds.length} selected'),
              backgroundColor:
                  Theme.of(context).colorScheme.primaryContainer,
              side: BorderSide.none,
              visualDensity: VisualDensity.compact,
            ),
          ],
        ),
        const SizedBox(height: 4),
        const Text(
          'All selected tiers are broadcast simultaneously — first to accept gets the ride.',
          style: TextStyle(fontSize: 12, color: Colors.grey),
        ),
        const SizedBox(height: 12),
        ...resp.tiers.map((tier) {
          final display = _displayRideTier(tier, resp.distanceKm);
          final isSelected = _selectedRideTierIds.contains(display.tierId);
          return _RideTierCard(
            tier: display,
            isSelected: isSelected,
            description: _rideTierDescription(display.tierId),
            onTap: () => _toggleRideTier(display.tierId),
            customFare: _customTierFares[display.tierId],
            onCustomFareChanged: (val) {
              setState(() {
                if (val == null) {
                  _customTierFares.remove(display.tierId);
                } else {
                  _customTierFares[display.tierId] = val;
                }
              });
            },
          );
        }),
      ],
    );
  }

  // ── Step 3: Review & Confirm ──────────────────────────────────────────────

  Widget _buildStep3Content() {
    if (_fareResponse == null) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _buildStepHeader(),
          const Center(child: CircularProgressIndicator()),
        ],
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _buildStepHeader(),
        _selectedModeIndex == 0 ? _buildDeliveryReview() : _buildRideReview(),
      ],
    );
  }

  Widget _buildDeliveryReview() {
    final resp = _fareResponse!;
    final selectedTiers = _selectedDeliveryCategories
        .map((c) => resp.tierById(_deliveryTierIds[c] ?? c.name))
        .whereType<FareTier>()
        .map((t) {
      final cat = _tierIdToCategory(t.tierId);
      return cat == null ? t : _displayDeliveryTier(t, cat);
    }).toList();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _RouteReviewCard(
          pickup: _pickupController.text,
          dropoff: _dropoffController.text,
          distanceKm: resp.distanceKm,
          durationMins: resp.durationMins,
          pickupPhoneController: _pickupPhoneController,
          dropoffPhoneController: _dropoffPhoneController,
          onPhoneChanged: _onPhoneChanged,
        ),
        const SizedBox(height: 12),
        const Text('Fare by Vehicle Type',
            style: TextStyle(fontWeight: FontWeight.bold, fontSize: 15)),
        const SizedBox(height: 8),
        _ServerFareTable(tiers: selectedTiers),
        const SizedBox(height: 8),
        _InfoBanner(
          icon: Icons.radar,
          color: Colors.green,
          text:
              '${_selectedDeliveryCategories.length} vehicle type(s) broadcast simultaneously. '
              'First driver to accept gets the order.',
        ),
      ],
    );
  }

  Widget _buildRideReview() {
    final resp = _fareResponse!;
    final selectedTiers = _orderedRideTierIds
        .map((id) => resp.tierById(id))
        .whereType<FareTier>()
        .map((t) => _displayRideTier(t, resp.distanceKm))
        .toList();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _RouteReviewCard(
          pickup: _pickupController.text,
          dropoff: _dropoffController.text,
          distanceKm: resp.distanceKm,
          durationMins: resp.durationMins,
          pickupPhoneController: _pickupPhoneController,
          dropoffPhoneController: _dropoffPhoneController,
          onPhoneChanged: _onPhoneChanged,
        ),
        const SizedBox(height: 12),
        const Text('Fare Summary',
            style: TextStyle(fontWeight: FontWeight.bold, fontSize: 15)),
        const SizedBox(height: 8),
        _ServerFareTable(tiers: selectedTiers),
        const SizedBox(height: 8),
        _InfoBanner(
          icon: Icons.info_outline,
          color: Colors.blue,
          text:
              '${selectedTiers.length} tier(s) broadcast simultaneously. '
              'Final fare may vary slightly based on real-time traffic and actual route.',
        ),
      ],
    );
  }

  // ── Helpers ────────────────────────────────────────────────────────────────

  String _rideTierDescription(String tierId) {
    final t = _config.carTierThresholds;
    switch (tierId) {
      case 'comfort':
        return 'Before ${t.premiumMinYear} · Affordable & comfortable';
      case 'premium':
        return '${t.premiumMinYear}–${t.premiumMaxYear} · Modern & spacious';
      case 'luxe':
        return '${t.luxeMinYear}+ · Luxury & newest models';
      case _rideTricycleTierId:
        return 'Short hops · Open-air Keke';
      default:
        return '';
    }
  }
}

/// Inline OpenStreetMap preview showing route between pickup & dropoff.
///
/// Auto-fits camera bounds whenever both points are set or change, so
/// markers and the connecting route polyline stay fully visible. Renders a
/// green pickup marker, red drop-off marker, and an orange route line (OSRM
/// geometry with straight-line fallback supplied by the parent).
class _RouteMapPreview extends StatefulWidget {
  final LatLng pickup;
  final LatLng dropoff;
  final List<LatLng> routePoints;
  final bool isLoadingRoute;

  const _RouteMapPreview({
    required this.pickup,
    required this.dropoff,
    required this.routePoints,
    required this.isLoadingRoute,
  });

  @override
  State<_RouteMapPreview> createState() => _RouteMapPreviewState();
}

class _RouteMapPreviewState extends State<_RouteMapPreview> {
  final SeSeMapController _mapController = SeSeMapController();

  @override
  void initState() {
    super.initState();
    // First frame: midpoint center alone rarely contains both pins at
    // zoom 13, and didUpdateWidget never fires initially — fit now.
    _fitBounds();
  }

  @override
  void didUpdateWidget(covariant _RouteMapPreview oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.pickup != widget.pickup ||
        oldWidget.dropoff != widget.dropoff ||
        oldWidget.routePoints.length != widget.routePoints.length) {
      _fitBounds();
    }
  }

  Future<void> _fitBounds() async {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      try {
        _mapController.fitPoints(
          widget.pickup,
          widget.dropoff,
          padding: 56,
        );
      } catch (_) {
        // Map not attached yet — initialCenter below already frames
        // both points; the next update will fit.
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    // Midpoint as the synchronous first-frame center; _fitBounds() then fits
    // both markers with padding after the controller is available.
    final pickup = widget.pickup;
    final dropoff = widget.dropoff;
    final center = LatLng(
      (pickup.latitude + dropoff.latitude) / 2,
      (pickup.longitude + dropoff.longitude) / 2,
    );

    final markers = [
      OsmMapView.pin(point: pickup, color: Colors.green),
      OsmMapView.pin(point: dropoff, color: Colors.red),
    ];

    final polylines = [
      if (widget.routePoints.isNotEmpty)
        OsmMapView.route(points: widget.routePoints),
    ];

    return Container(
      // No fixed height: the parent sizes this via Expanded so the map
      // fills all remaining vertical space. Rounded corners preserved.
      margin: const EdgeInsets.only(top: 4),
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(16),
        boxShadow: const [
          BoxShadow(color: Colors.black12, blurRadius: 6),
        ],
      ),
      child: Stack(
        children: [
          OsmMapView(
            mapController: _mapController,
            initialCenter: center,
            initialZoom: 13.0,
            markers: markers,
            polylines: polylines,
          ),
          // Explicit fit-route affordance: the SDK zoom/locate buttons
          // are disabled app-wide, so users need a visible control.
          Positioned(
            right: 12,
            bottom: 12,
            child: MapRecenterButton(
              key: const Key('route_fit_button'),
              icon: Icons.fit_screen,
              onTap: _fitBounds,
            ),
          ),
          if (widget.isLoadingRoute)
            const Center(
              child: Card(
                child: Padding(
                  padding: EdgeInsets.all(8),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      SizedBox(
                          width: 14,
                          height: 14,
                          child: CircularProgressIndicator(strokeWidth: 2)),
                      SizedBox(width: 8),
                      Text('Loading route…',
                          style: TextStyle(fontSize: 12)),
                    ],
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// Delivery vehicle selection card with optional "Recommended" badge.
class _DeliveryVehicleCard extends StatelessWidget {
  final VehicleCategory category;
  final String? serverFare; // null while loading
  final bool isRecommended;
  final bool isSelected;

  /// False while a heavy-duty vehicle locks out small options: the card
  /// renders muted and taps explain the lock instead of selecting.
  final bool enabled;
  final VoidCallback onTap;

  const _DeliveryVehicleCard({
    required this.category,
    required this.serverFare,
    required this.isRecommended,
    required this.isSelected,
    this.enabled = true,
    required this.onTap,
  });

  IconData get _icon {
    switch (category) {
      case VehicleCategory.bicycle:
        return Icons.pedal_bike;
      case VehicleCategory.motorcycle:
        return Icons.two_wheeler;
      case VehicleCategory.tricycle:
        return Icons.electric_rickshaw;
      case VehicleCategory.van:
        return Icons.airport_shuttle;
      case VehicleCategory.truck:
        return Icons.local_shipping;
      case VehicleCategory.car:
        return Icons.directions_car;
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final muted = !enabled && !isSelected;
    return Card(
      elevation: isSelected ? 3 : 1,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(10),
        side: BorderSide.none,
      ),
      color: isDark ? cs.surfaceContainerHighest : Colors.grey.shade100,
      margin: const EdgeInsets.only(bottom: 8),
      child: InkWell(
        borderRadius: BorderRadius.circular(10),
        onTap: onTap,
        child: Opacity(
          opacity: muted ? 0.45 : 1.0,
          child: Padding(
          padding: const EdgeInsets.all(12),
          child: Row(
            children: [
              Checkbox(
                  value: isSelected,
                  onChanged: enabled ? (_) => onTap() : null),
              Icon(_icon,
                  color: isSelected ? cs.primary : (isDark ? cs.onSurfaceVariant : Colors.grey), size: 28),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Text(category.displayName,
                            style: TextStyle(
                              fontWeight: FontWeight.bold,
                              fontSize: 15,
                              color: isSelected ? cs.primary : cs.onSurface,
                            )),
                        if (isRecommended) ...[
                          const SizedBox(width: 6),
                          Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 6, vertical: 2),
                            decoration: BoxDecoration(
                              color: isDark
                                  ? Colors.green.shade900.withValues(alpha: 0.3)
                                  : Colors.green.shade50,
                              borderRadius: BorderRadius.circular(6),
                            ),
                            child: Text('Recommended',
                                style: TextStyle(
                                    fontSize: 10,
                                    color: isDark
                                        ? Colors.greenAccent
                                        : Colors.green)),
                          ),
                        ],
                      ],
                    ),
                    Text('Fastest & most available',
                        style: TextStyle(
                            fontSize: 11, color: isDark ? cs.onSurfaceVariant : Colors.grey.shade500)),
                  ],
                ),
              ),
              serverFare != null
                  ? Text(serverFare!,
                      style: const TextStyle(
                          fontWeight: FontWeight.bold, fontSize: 16))
                  : Text('Unavailable',
                      style: TextStyle(
                          fontSize: 12,
                          fontStyle: FontStyle.italic,
                          color: isDark ? cs.onSurfaceVariant : Colors.grey.shade500)),
            ],
          ),
          ),
        ),
      ),
    );
  }
}

/// Ride tier selection card using server-supplied fare.
///
/// Checkbox (multi-select) broadcast: several tiers can be checked at once.
/// Also surfaces a "Recommended" badge for the server-flagged tier.
/// The fare display is tappable — customers may raise it above the server
/// baseline; values below baseline are blocked.
class _RideTierCard extends StatelessWidget {
  final FareTier tier;
  final bool isSelected;
  final String description;
  final VoidCallback onTap;

  /// Current customer-overridden fare, or null if using the server baseline.
  final double? customFare;

  /// Called with the new fare (or null to reset to baseline).
  final void Function(double? fare) onCustomFareChanged;

  const _RideTierCard({
    required this.tier,
    required this.isSelected,
    required this.description,
    required this.onTap,
    required this.onCustomFareChanged,
    this.customFare,
  });

  IconData get _icon {
    switch (tier.tierId) {
      case 'luxe':
        return Icons.star;
      case 'premium':
        return Icons.workspace_premium;
      default:
        return Icons.directions_car;
    }
  }

  /// Opens a dialog for the customer to enter a boosted fare.
  Future<void> _editFare(BuildContext context) async {
    final baseline = tier.fareAmount;
    final controller = TextEditingController(
      text: (customFare ?? baseline).toStringAsFixed(0),
    );
    String? error;

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSt) => AlertDialog(
          title: Text('Set fare — ${tier.name}'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                'Baseline: ${tier.fareFormatted}. You can only increase the fare to attract drivers faster.',
                style: const TextStyle(fontSize: 12),
              ),
              const SizedBox(height: 12),
              // Quick boost presets: +5% / +10% / +20% over baseline.
              Wrap(
                spacing: 8,
                children: [5, 10, 20].map((pct) {
                  final boosted =
                      (tier.fareAmount * (100 + pct) / 100).round().toString();
                  return OutlinedButton(
                    onPressed: () {
                      controller.text = boosted;
                      setSt(() => error = null);
                    },
                    child: Text('+$pct%'),
                  );
                }).toList(),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: controller,
                keyboardType:
                    const TextInputType.numberWithOptions(decimal: false),
                inputFormatters: [
                  FilteringTextInputFormatter.digitsOnly,
                ],
                decoration: InputDecoration(
                  labelText: 'Your offer',
                  prefixText: '₦ ',
                  border: const OutlineInputBorder(
                      borderSide: BorderSide.none),
                  enabledBorder: const OutlineInputBorder(
                      borderSide: BorderSide.none),
                  focusedBorder: const OutlineInputBorder(
                      borderSide: BorderSide.none),
                  filled: true,
                  fillColor: Theme.of(context).colorScheme.surfaceContainerHighest,
                  errorText: error,
                ),
                onChanged: (v) {
                  final val = double.tryParse(v);
                  setSt(() {
                    error = (val == null || val < baseline)
                        ? 'Must be ≥ ${tier.fareFormatted}'
                        : null;
                  });
                },
              ),
            ],
          ),
          actions: [
            if (customFare != null)
              TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('Reset to baseline'),
              ),
            TextButton(
              onPressed: () => Navigator.pop(ctx, null),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: error != null
                  ? null
                  : () => Navigator.pop(ctx, true),
              child: const Text('Confirm'),
            ),
          ],
        ),
      ),
    );

    if (confirmed == null) return; // cancelled
    if (confirmed == false) {
      onCustomFareChanged(null); // reset to baseline
      return;
    }
    final val = double.tryParse(controller.text);
    if (val != null && val >= baseline) {
      onCustomFareChanged(val);
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final hasBoostedFare = customFare != null && customFare! > tier.fareAmount;
    final fareDisplay = hasBoostedFare
        ? '₦${customFare!.toStringAsFixed(0)}'
        : tier.fareFormatted;

    return Card(
      elevation: isSelected ? 3 : 1,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.all(Radius.circular(10)),
        side: BorderSide.none,
      ),
      color: isDark ? cs.surfaceContainerHighest : Colors.grey.shade100,
      margin: const EdgeInsets.only(bottom: 12),
      child: InkWell(
        borderRadius: BorderRadius.circular(10),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Row(
            children: [
              Checkbox(value: isSelected, onChanged: (_) => onTap()),
              Icon(_icon,
                  color: isSelected ? cs.primary : (isDark ? cs.onSurfaceVariant : Colors.grey), size: 28),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Flexible(
                          child: Text(tier.name,
                              style: TextStyle(
                                fontWeight: FontWeight.bold,
                                fontSize: 16,
                                color: isSelected
                                    ? cs.primary
                                    : cs.onSurface,
                              )),
                        ),
                        if (tier.isRecommended) ...[
                          const SizedBox(width: 6),
                          Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 6, vertical: 2),
                            decoration: BoxDecoration(
                              color: isDark
                                  ? Colors.green.shade900.withValues(alpha: 0.3)
                                  : Colors.green.shade50,
                              borderRadius: BorderRadius.circular(6),
                            ),
                            child: Text('Recommended',
                                style: TextStyle(
                                    fontSize: 10,
                                    color: isDark
                                        ? Colors.greenAccent
                                        : Colors.green)),
                          ),
                        ],
                      ],
                    ),
                    Text(description,
                        style: TextStyle(
                            fontSize: 11, color: isDark ? cs.onSurfaceVariant : Colors.grey)),
                  ],
                ),
              ),
              // ── Fare display / boost button ────────────────────────────
              GestureDetector(
                onTap: () => _editFare(context),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Text(fareDisplay,
                        style: TextStyle(
                            fontWeight: FontWeight.bold,
                            fontSize: 18,
                            color: hasBoostedFare ? cs.primary : null)),
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.edit, size: 11, color: cs.onSurfaceVariant),
                        const SizedBox(width: 2),
                        Text('Boost',
                            style: TextStyle(
                                fontSize: 10, color: cs.onSurfaceVariant)),
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Route summary card shown in Step 3, with tagged pickup / drop-off
/// sections and mandatory contact phone fields for driver coordination.
class _RouteReviewCard extends StatelessWidget {
  final String pickup;
  final String dropoff;
  final double distanceKm;
  final double durationMins;
  final TextEditingController pickupPhoneController;
  final TextEditingController dropoffPhoneController;
  final VoidCallback? onPhoneChanged;

  const _RouteReviewCard({
    required this.pickup,
    required this.dropoff,
    required this.distanceKm,
    required this.durationMins,
    required this.pickupPhoneController,
    required this.dropoffPhoneController,
    this.onPhoneChanged,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    return Card(
      elevation: 0,
      color: isDark ? theme.colorScheme.surfaceContainerHighest : Colors.grey.shade50,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide.none,
      ),
      child: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // ── Pickup section ──────────────────────────────────────────
            Row(
              children: [
                const Icon(Icons.circle, color: Colors.green, size: 14),
                const SizedBox(width: 8),
                Text(
                  'Pickup Location',
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.bold,
                    color: isDark ? Colors.greenAccent : Colors.green.shade800,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Padding(
              padding: const EdgeInsets.only(left: 22.0),
              child: Text(
                pickup,
                style:
                    const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
              ),
            ),
            const SizedBox(height: 10),
            Padding(
              padding: const EdgeInsets.only(left: 22.0),
              child: SesePhoneInputField(
                controller: pickupPhoneController,
                labelText: 'Pickup Phone Number',
                autoValidateMode: AutovalidateMode.onUserInteraction,
                onChanged: (e164) {
                  // No echo-back write: the formatter owns the text field
                  // (see onPhoneChanged guard below).
                  onPhoneChanged?.call();
                },
                validator: (value) {
                  return isValidNigerianPhoneNumber(value)
                      ? null
                      : 'Enter a valid phone number';
                },
              ),
            ),

            const Padding(
              padding: EdgeInsets.symmetric(vertical: 14.0),
              child: SizedBox(height: 12),
            ),

            // ── Drop-off section ────────────────────────────────────────
            Row(
              children: [
                const Icon(Icons.location_on, color: Colors.red, size: 18),
                const SizedBox(width: 6),
                Text(
                  'Drop-off Location',
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.bold,
                    color: isDark ? Colors.redAccent : Colors.red.shade800,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Padding(
              padding: const EdgeInsets.only(left: 24.0),
              child: Text(
                dropoff,
                style:
                    const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
              ),
            ),
            const SizedBox(height: 10),
            Padding(
              padding: const EdgeInsets.only(left: 24.0),
              child: SesePhoneInputField(
                controller: dropoffPhoneController,
                labelText: 'Drop-off Contact Phone Number',
                autoValidateMode: AutovalidateMode.onUserInteraction,
                onChanged: (e164) {
                  // No echo-back (see pickup field + onPhoneChanged guard).
                  onPhoneChanged?.call();
                },
                validator: (value) {
                  return isValidNigerianPhoneNumber(value)
                      ? null
                      : 'Enter a valid phone number';
                },
              ),
            ),

            const SizedBox(height: 16),
            // Route stats (distance & duration). Kept to two chips centered
            // in the row — a third badge overflows narrow screens.
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Chip(
                  avatar: const Icon(Icons.straighten, size: 16),
                  label: Text('${distanceKm.toStringAsFixed(1)} km'),
                  backgroundColor:
                      Theme.of(context).colorScheme.surfaceContainerHighest,
                  side: BorderSide.none,
                ),
                const SizedBox(width: 12),
                Chip(
                  avatar: const Icon(Icons.access_time, size: 16),
                  label: Text('~${durationMins.toStringAsFixed(0)} mins'),
                  backgroundColor:
                      Theme.of(context).colorScheme.surfaceContainerHighest,
                  side: BorderSide.none,
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// Table of server-computed fare tiers — renders fareFormatted verbatim.
class _ServerFareTable extends StatelessWidget {
  final List<FareTier> tiers;

  const _ServerFareTable({required this.tiers});

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Column(
        children: tiers.asMap().entries.map((entry) {
          final i = entry.key;
          final t = entry.value;
          return Column(
            children: [
              Padding(
                padding:
                    const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                child: Row(
                  children: [
                    if (t.isRecommended)
                      Padding(
                        padding: const EdgeInsets.only(right: 6),
                        child: Icon(Icons.verified,
                            size: 16, color: Colors.green.shade600),
                      ),
                    Expanded(
                        child: Text(t.name,
                            style: const TextStyle(
                                fontWeight: FontWeight.w500))),
                    Text(t.fareFormatted,
                        style: const TextStyle(
                            fontWeight: FontWeight.bold, fontSize: 16)),
                  ],
                ),
              ),
              if (i < tiers.length - 1) const SizedBox(height: 8),
            ],
          );
        }).toList(),
      ),
    );
  }
}

/// Informational banner used in review steps.
class _InfoBanner extends StatelessWidget {
  final IconData icon;
  final Color color;
  final String text;

  const _InfoBanner(
      {required this.icon, required this.color, required this.text});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.06),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        children: [
          Icon(icon, color: color, size: 18),
          const SizedBox(width: 8),
          Expanded(
              child: Text(text,
                  style: TextStyle(fontSize: 12, color: color))),
        ],
      ),
    );
  }
}


