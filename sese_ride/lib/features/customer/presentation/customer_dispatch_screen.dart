import 'dart:async';
import 'dart:math' as math;

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:latlong2/latlong.dart';
import 'package:sese_core/sese_core.dart';

import '../../../widgets/map_provider.dart';
import '../models/fare_models.dart';
import '../services/fare_service.dart';
import '../services/location_service.dart';
import '../../trips/models/trip_models.dart';
import '../../trips/presentation/live_trip_screen.dart';
import '../../trips/services/trip_service.dart';
import 'pick_on_map_screen.dart';
import 'widgets/split_payment_sheet.dart';

/// Minimal model for a saved Home or Work place fetched from
/// `users/{uid}.savedPlaces`. Private to this file — no separate model
/// file needed for this screen-local type.
class _SavedDispatchPlace {
  final String address;
  final double? lat;
  final double? lng;

  const _SavedDispatchPlace({
    required this.address,
    this.lat,
    this.lng,
  });

  bool get hasCoords => lat != null && lng != null;
}

/// Validates a Nigerian phone number (strict, server-aligned).
///
/// Mirrors the backend `NG_PHONE` contract (`^(\+?234|0)(70|71|80|81|90|91)
/// \d{8}$`): local 11-digit, +234, or 234-prefixed numbers with valid
/// mobile prefixes only. A loose E.164 check here would green-light
/// numbers the server rejects (e.g. US numbers), failing bookings after
/// the client already accepted them.
bool isValidNigerianPhoneNumber(String? input) {
  if (input == null || input.trim().isEmpty) return false;
  return SesePhoneSanitizer.isValidNigerianNumber(input) ||
      SesePhoneSanitizer.isValidE164(
        SesePhoneSanitizer.normalize(input),
      );
}

/// Optional variant of phone validation for Step 3 contact fields:
/// empty (no secondary contact — e.g. "call me when you get there") is valid;
/// non-empty entries are normalized and validated for E.164 compliance across
/// all supported countries (Nigeria, Benin, Ghana, etc.).
bool isOptionalNigerianPhoneNumber(String? input) {
  if (input == null || input.trim().isEmpty) return true;
  final activeIso = CountryDetectionService.instance.currentCountryCode;
  final norm = SesePhoneSanitizer.normalize(input, defaultIsoCode: activeIso);
  return SesePhoneSanitizer.isValidE164(norm) || isValidNigerianPhoneNumber(input);
}

/// Strips any hardcoded country prefix from a stored/profile number down to
/// the national digits the [SesePhoneInputField] box expects.
String nationalDisplayDigits(String? raw) {
  if (raw == null || raw.trim().isEmpty) return '';
  final activeIso = CountryDetectionService.instance.currentCountryCode;
  return SesePhoneSanitizer.parse(raw, defaultIsoCode: activeIso).nationalNumber;
}

/// Step-by-step booking screen for both Ride-Hailing and Package Delivery.
///
/// Flow:
///   1. **Locations** — GPS + reverse-geocode pickup; auto-focus drop-off;
///      forward-geocode drop-off as user types; inline route-map preview.
///   2. **Choose Option** — server fares from [FareService]; delivery
///      pre-selects Motorcycle (recommended); ride shows car tiers.
///   3. **Review & Confirm** — tagged pickup/drop-off summary with optional
///      secondary contact phone numbers + server-authoritative fare breakdown + fareToken.
class CustomerDispatchScreen extends StatefulWidget {
  final RegionConfig? initialConfig;
  final AppUser? user;

  /// 0 = Package Delivery, 1 = Ride-Hailing.
  final int initialModeIndex;

  /// When false the mode toggle is hidden.
  final bool showModeSelector;

  /// AppBar title used when the mode toggle is hidden.
  final String? focusedTitle;

  /// Delivery direction requested by the entry route (`{'isReceiving': true}`
  /// from the Home "Receive Item" card). Seeds the Sending/Receiving toggle
  /// so "Receiving Package" is highlighted on open, GPS pre-fills the
  /// drop-off field, and initial focus lands on pickup. Defaults to false
  /// (Send Item / Book a Ride behavior).
  final bool isReceiving;

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

  /// Initial step index (0 = Locations, 1 = Option, 2 = Review/Confirm).
  final int initialStep;

  /// Optional initial contact names (restored booking seam).
  final String? initialPickupName;
  final String? initialDropoffName;

  /// Optional initial payment mode ('sender_pays', 'receiver_pays', 'split').
  final String? initialPaymentMode;

  /// Optional initial category or tier.
  final String? initialCategory;

  const CustomerDispatchScreen({
    super.key,
    this.initialConfig,
    this.user,
    this.initialModeIndex = 0,
    this.showModeSelector = true,
    this.focusedTitle,
    this.isReceiving = false,
    this.fareService,
    this.initialPickupLatLng,
    this.initialPickupAddress,
    this.initialDropoffLatLng,
    this.initialDropoffAddress,
    this.initialPickupPhone,
    this.initialDropoffPhone,
    this.initialStep = 0,
    this.initialPickupName,
    this.initialDropoffName,
    this.initialPaymentMode,
    this.initialCategory,
    this.tripRepository,
  });

  @override
  State<CustomerDispatchScreen> createState() => _CustomerDispatchScreenState();
}

class _CustomerDispatchScreenState extends State<CustomerDispatchScreen> {
  late final FareService _fareService;

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

  // Autocomplete suggestions (shared list; _suggestingForPickup disambiguates)
  Timer? _debounceTimer;
  List<PlaceSuggestion> _suggestions = [];
  bool _isLoadingSuggestions = false;
  bool _isSelectingSuggestion = false;

  // Whether the in-progress suggestion session is for the pickup field.
  // When false (default) the session belongs to drop-off.
  bool _suggestingForPickup = false;

  // Pickup-specific autocomplete guards — mirrors the drop-off path.
  Timer? _pickupDebounceTimer;
  bool _isSelectingPickupSuggestion = false;
  String? _resolvedPickupQuery;

  // Overlay infrastructure: LayerLinks anchor the floating suggestions panel
  // to whichever text field is currently being typed into, without
  // disturbing the Column's layout.
  final _pickupLayerLink = LayerLink();
  final _dropoffLayerLink = LayerLink();
  OverlayEntry? _suggestionsOverlay;

  // ── Zero-cost recents (Google Places cache) ──────────────────────────────
  // Served instantly with 0 API calls when the drop-off field is empty;
  // tapping one fills coordinates from storage. New predictions resolve
  // via one Details call and persist here on selection.
  final RecentLocationsRepository _recents = RecentLocationsRepository();

  // Route preview — points + distance/duration from Google Directions or OSRM.
  List<LatLng> _routePoints = [];
  bool _fetchingRoute = false;
  int _routeDistanceM = 0;
  int _routeDurationS = 0;

  // ── GPS-fix caches (tab-switch fast path) ───────────────────────────────
  // Last GPS-derived fix per slot: raw position + reverse-geocoded address.
  // The Sending/Receiving toggle restores its auto-filled slot synchronously
  // from these instead of re-running GPS + reverse-geocode, so switching
  // tabs is one synchronous setState with no spinner and no network. Set
  // only from the GPS init paths below — never from manual typing — so the
  // cached fix is always the device's own position, not an edited address.
  LatLng? _gpsPickupFix;
  String? _gpsPickupAddress;
  LatLng? _gpsDropoffFix;
  String? _gpsDropoffAddress;

  // ── Sticky preview pair (no map teardown on toggle) ─────────────────────
  // Last pair with both ends known. The route preview stays mounted on this
  // pair across Sending/Receiving toggles, so the native map view, its tiles,
  // and its controller survive the switch. The Next gate still requires the
  // live pair ([_addressesReady]); route overlay/stats below only render
  // when the live pair matches the preview pair (see [_previewMatchesLive]).
  LatLng? _previewPickup;
  LatLng? _previewDropoff;

  /// Whether the Step 1 address sheet is collapsed to show the 2-line summary
  /// and maximize map area once addresses are entered.
  bool _isAddressCardCollapsed = false;

  // Last pair a route was fetched for. Skips redundant Directions calls when
  // coordinates resolve to an already-routed pair (e.g. a toggle round-trip
  // back to the previous A/B restores the cached geometry instantly).
  LatLng? _routedPickup;
  LatLng? _routedDropoff;

  // ── Step 1→2 fare loading ─────────────────────────────────────────────────
  FareResponse? _fareResponse;
  bool _fareLoading = false;

  // ── Smart Dynamic Recommendation Engine ───────────────────────────────────
  // Distance thresholds (system_configs/vehicle_recommendations, editable in
  // sese_hub without a release). Compiled defaults apply when the doc is
  // missing/unreadable, so recommendations always resolve to something sane.
  VehicleRecommendationConfig _recConfig =
      const VehicleRecommendationConfig();

  // ── Step 3: Contact phones & names ───────────────────────────────────────
  // Cached validity driving the guarded _onPhoneChanged refresh.
  bool _lastPhonesValid = false;
  // OPTIONAL secondary numbers and names for driver coordination. Pickup
  // phone + name are pre-filled from the signed-in user's credentials
  // (editable — e.g. booking for someone else); drop-off carries the
  // recipient's details. Either may be left empty — the booker's account
  // number is minted onto the trip server-side and stays reachable regardless.
  final _pickupPhoneController = TextEditingController();
  final _dropoffPhoneController = TextEditingController();

  /// Contact name at the pickup endpoint. Pre-filled from [AppUser.fullName]
  /// in Send / Ride mode (the booker is at pickup); empty in Receive mode
  /// (the remote sender is unknown). Editable for third-party bookings.
  final _pickupNameController = TextEditingController();

  /// Contact name at the drop-off endpoint. Pre-filled from [AppUser.fullName]
  /// in Receive mode (the booker is the recipient); empty in Send mode.
  /// Editable so the booker can name a third-party receiver.
  final _dropoffNameController = TextEditingController();

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

  // ── Context-Aware, Security PIN & Payment selection state ─────────────────
  bool _isReceivePackageMode = false;
  bool _requireDeliveryPin = false;
  String _paymentMode = 'sender_pays'; // 'sender_pays', 'receiver_pays', 'split'
  String _paymentMethod = 'auto'; // 'auto' (default), 'cash', 'wallet'
  double? _splitSenderAmount;
  double? _splitReceiverAmount;
  double _customerWalletBalance = 0.0;
  StreamSubscription<DualWallet>? _walletSub;

  double get _currentEstimatedFare {
    final resp = _fareResponse;
    if (resp == null || resp.tiers.isEmpty) return 0.0;
    if (_selectedModeIndex == 0) {
      if (_selectedDeliveryCategories.isNotEmpty) {
        final cat = _selectedDeliveryCategories.first;
        final tierId = _deliveryTierIds[cat] ?? cat.name;
        final t = resp.tierById(tierId);
        if (t != null) return t.fareAmount;
      }
    } else {
      if (_orderedRideTierIds.isNotEmpty) {
        final t = resp.tierById(_orderedRideTierIds.first);
        if (t != null) return t.fareAmount;
      }
    }
    return resp.tiers.first.fareAmount;
  }

  // ── Remote config (HUB overrides: splitPaymentMasterEnabled, forceDeliveryPinSystemWide)
  // Loaded once in initState from Firestore; falls back to safe defaults when
  // Firestore is absent (widget tests, offline). Never throws.
  RemoteKeysConfig _remoteKeys = const RemoteKeysConfig();

  // ── Module 3: Saved Places (Home / Work) ─────────────────────────────────
  // Loaded once from Firestore on open. Each field is a nullable record
  // so we don't hard-depend on Dart 3 records on all SDK targets —
  // plain named fields in a tiny private class instead.
  _SavedDispatchPlace? _savedHomePlace;
  _SavedDispatchPlace? _savedWorkPlace;

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
    _fareService = widget.fareService ?? FareService();
    _selectedModeIndex = widget.initialModeIndex;
    final uid = widget.user?.uid;
    if (uid != null && uid.isNotEmpty) {
      _walletSub = const SeseCoinService().walletStream(uid).listen((w) {
        if (mounted) {
          setState(() {
            _customerWalletBalance = w.availableBalance;
          });
        }
      });
    }
    // Seed the Sending/Receiving toggle from the entry route (`isReceiving`
    // from the Home "Receive Item" card). The `focusedTitle` text match is a
    // fallback so older call sites without the flag keep working.
    _isReceivePackageMode = widget.isReceiving ||
        (widget.focusedTitle?.toLowerCase().contains('receive') == true);
    // Receive Item: the user's own location is the DELIVERY destination, so
    // GPS auto-detect fills the drop-off field and Pickup stays empty for
    // manual entry. Send Item / Ride: GPS fills Pickup as before.
    if (widget.initialPickupAddress != null) {
      // Lock the resolved query BEFORE setting text so the pickup listener
      // (added below) treats the seeded text as already resolved and does
      // not launch an autocomplete fetch for it.
      _resolvedPickupQuery = widget.initialPickupAddress;
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
    // Pre-fill contact phones: explicit seams win. In Receive mode the user
    // is the recipient, so their number belongs to drop-off (mirrors the
    // manual toggle handler below); otherwise pickup carries it. Numbers
    // are reduced to national digits — the phone field renders its own
    // country prefix, so a raw E.164 value would double it (`+234 +234…`).
    // Both fields are optional: empty means "no secondary contact".
    if (_isReceiveMode) {
      _pickupPhoneController.text =
          nationalDisplayDigits(widget.initialPickupPhone);
      _dropoffPhoneController.text = nationalDisplayDigits(
          widget.initialDropoffPhone ?? widget.user?.phoneNumber);
    } else {
      _pickupPhoneController.text = nationalDisplayDigits(
          widget.initialPickupPhone ?? widget.user?.phoneNumber);
      _dropoffPhoneController.text =
          nationalDisplayDigits(widget.initialDropoffPhone);
    }
    if (widget.initialStep > 0) {
      _currentStep = widget.initialStep;
    }
    if (widget.initialPaymentMode != null &&
        widget.initialPaymentMode!.isNotEmpty) {
      _paymentMode = widget.initialPaymentMode!;
    }
    if (widget.initialCategory != null) {
      final cat = VehicleCategory.values
          .where((c) =>
              c.name.toLowerCase() == widget.initialCategory!.toLowerCase())
          .firstOrNull;
      if (cat != null) {
        _selectedDeliveryCategories.clear();
        _selectedDeliveryCategories.add(cat);
      }
      _selectedRideTierIds.add(widget.initialCategory!.toLowerCase());
    }
    // Pre-fill contact names with the same mode split as phones above.
    // In Send / Ride mode the booker is at pickup, so their name pre-fills
    // the pickup name field. In Receive mode they ARE the recipient, so their
    // name goes into the drop-off field. The OTHER endpoint starts blank —
    // the booker must explicitly name a third-party sender / recipient rather
    // than having their own name accidentally appear on the wrong endpoint.
    if (_isReceiveMode) {
      _pickupNameController.text =
          widget.initialPickupName ?? ''; // remote sender — must be entered
      _dropoffNameController.text =
          widget.initialDropoffName ?? (widget.user?.fullName ?? '');
    } else {
      _pickupNameController.text =
          widget.initialPickupName ?? (widget.user?.fullName ?? '');
      _dropoffNameController.text =
          widget.initialDropoffName ?? ''; // recipient — enter if third-party
    }
    // Rebuild on phone edits so the Confirm button enablement tracks
    // validity live (a malformed non-empty entry still blocks; empty never
    // does). NOTE: no controller listeners here — the phone
    // fields already refresh via their onChanged callbacks, and the
    // formatter rewrites controller text on every keystroke; listening on
    // top would echo those writes back into setState indefinitely.
    _dropoffController.addListener(_onDropoffChanged);
    _pickupController.addListener(_onPickupChanged);
    // Dismiss the suggestions overlay when the active field loses focus.
    // A 200ms delay lets the suggestion ListTile onTap fire first; without
    // the delay the overlay is removed before the tap event is processed.
    _pickupFocusNode.addListener(_onPickupFocusChanged);
    _dropoffFocusNode.addListener(_onDropoffFocusChanged);
    // Zero-cost recents: merge the Firestore backup (heals new devices),
    // then serve the top-5 instantly whenever the drop-off field is empty.
    // ignore: discarded_futures
    _loadRecents();
    // Load Hub override flags once; never rethrows — safe in tests.
    // ignore: discarded_futures
    RemoteKeysService().fetchRemoteKeys().then((cfg) {
      if (mounted) setState(() => _remoteKeys = cfg);
    });
    // Load saved places (Home/Work) for quick-select chips.
    // ignore: discarded_futures
    _loadSavedPlaces();
    if (_pickupLatLng != null && _dropoffLatLng != null) {
      _updateMapBoundsAndRoute();
      if (_currentStep >= 1) {
        // ignore: discarded_futures
        _loadFares();
      }
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

  /// True when the delivery direction is "Receive Item": the sender's pickup
  /// address is the unknown field, so GPS pre-fills drop-off and initial
  /// focus belongs on pickup. Single source of truth — seeded from the entry
  /// route (`isReceiving`) in [initState] and flipped by the toggle after.
  /// Send Item / Book Ride focus the drop-off destination instead.
  bool get _isReceiveMode => _isReceivePackageMode;

  /// Requests focus on the mode-appropriate location field.
  void _focusInitialField() {
    if (_isReceiveMode) {
      _pickupFocusNode.requestFocus();
    } else {
      _dropoffFocusNode.requestFocus();
    }
  }

  // ── Module 3: Saved Places ────────────────────────────────────────────────

  /// Fetches the user's saved Home and Work places from Firestore.
  /// Gracefully handles missing/offline (no throw). Uses an inner private
  /// type so no new file is needed.
  Future<void> _loadSavedPlaces() async {
    final uid = widget.user?.uid;
    if (uid == null || uid.isEmpty) return;
    try {
      final doc = await FirebaseFirestore.instance
          .collection('users')
          .doc(uid)
          .get();
      final data = doc.data() ?? {};
      final raw =
          (data['savedPlaces'] as Map<String, dynamic>?) ?? {};
      final home = _parseSavedPlace(raw['home'] ?? data['home_address'] ?? data['homeAddress']);
      final work = _parseSavedPlace(raw['work'] ?? data['work_address'] ?? data['workAddress']);
      if (mounted) {
        setState(() {
          _savedHomePlace = home;
          _savedWorkPlace = work;
        });
      }
    } catch (_) {
      // Fail silently — chips just won't appear.
    }
  }

  /// Parses either the new `{address, lat, lng}` map or the legacy
  /// plain-string format into a [_SavedDispatchPlace].
  _SavedDispatchPlace? _parseSavedPlace(dynamic raw) {
    if (raw == null) return null;
    if (raw is String) {
      return raw.trim().isEmpty ? null : _SavedDispatchPlace(address: raw.trim());
    }
    if (raw is Map<String, dynamic>) {
      final address = (raw['address'] as String? ?? '').trim();
      if (address.isEmpty) return null;
      final lat = ((raw['lat'] ?? raw['latitude']) as num?)?.toDouble();
      final lng = ((raw['lng'] ?? raw['longitude']) as num?)?.toDouble();
      return _SavedDispatchPlace(
        address: address,
        lat: lat,
        lng: lng,
      );
    }
    return null;
  }

  /// Applies a saved-place chip tap to the drop-off field.
  ///
  /// When the place has stored coordinates we resolve immediately at zero
  /// API cost. When only the address text is stored (legacy or geocoding
  /// previously failed) we run one autocomplete + Details call to resolve
  /// coordinates before populating the field.
  Future<void> _applySavedPlace(_SavedDispatchPlace place) async {
    if (place.hasCoords) {
      _applyResolvedSuggestion(
        place.address,
        LatLng(place.lat!, place.lng!),
      );
      return;
    }
    // Legacy fallback: no coords stored — geocode once.
    setState(() => _isLoadingSuggestions = true);
    try {
      final suggestions =
          await LocationAutocompleteService.fetchSuggestions(place.address);
      if (!mounted) return;
      if (suggestions.isEmpty) {
        setState(() => _isLoadingSuggestions = false);
        _dropoffController.text = place.address;
        return;
      }
      final top = suggestions.first;
      final placeId = top.placeId;
      if (placeId != null && placeId.isNotEmpty) {
        final resolved = await LocationService.resolvePrediction(top);
        if (!mounted) return;
        if (resolved != null) {
          _applyResolvedSuggestion(
              resolved.description, LatLng(resolved.lat, resolved.lng));
          return;
        }
      }
      _applyResolvedSuggestion(
          top.description, LatLng(top.lat, top.lng));
    } catch (_) {
      if (mounted) {
        setState(() => _isLoadingSuggestions = false);
        _dropoffController.text = place.address;
      }
    }
  }

  /// Renders Home / Work quick-select chip row beneath the drop-off field.
  ///
  /// Only shown when the drop-off field is empty (no query typed yet) and at
  /// least one saved place is loaded. Chips are not shown if the user has
  /// already started typing or selected a destination.
  Widget _buildSavedPlaceChips() {
    final dropText = _dropoffController.text.trim();
    if (dropText.isNotEmpty) return const SizedBox.shrink();
    if (_savedHomePlace == null && _savedWorkPlace == null) {
      return const SizedBox.shrink();
    }
    return Padding(
      padding: const EdgeInsets.only(top: 10, bottom: 2),
      child: Wrap(
        spacing: 8,
        runSpacing: 6,
        children: [
          if (_savedHomePlace != null)
            ActionChip(
              key: const Key('saved_place_home_chip'),
              avatar: const Icon(Icons.home_outlined,
                  size: 16, color: AppColors.seseGold),
              label: const Text('Home'),
              onPressed: () => _applySavedPlace(_savedHomePlace!),
            ),
          if (_savedWorkPlace != null)
            ActionChip(
              key: const Key('saved_place_work_chip'),
              avatar: const Icon(Icons.work_outline,
                  size: 16, color: AppColors.seseGold),
              label: const Text('Work'),
              onPressed: () => _applySavedPlace(_savedWorkPlace!),
            ),
        ],
      ),
    );
  }

  @override
  void dispose() {
    _pickupController.dispose();
    _dropoffController.dispose();
    _pickupFocusNode.dispose();
    _dropoffFocusNode.dispose();
    _pickupPhoneController.dispose();
    _dropoffPhoneController.dispose();
    _pickupNameController.dispose();
    _dropoffNameController.dispose();
    _debounceTimer?.cancel();
    _pickupDebounceTimer?.cancel();
    _walletSub?.cancel();
    _hideSuggestionsOverlay();
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
        // Cache the raw device fix for the tab-switch fast path (always the
        // device position even if the user edits the field afterwards).
        _gpsPickupFix = latLng;
        _gpsPickupAddress = address;
        // Lock BEFORE setting text — the pickup controller listener fires
        // synchronously on assignment and must see the address as already
        // resolved, or it would clear _pickupLatLng and start an autocomplete
        // fetch for the GPS-derived string.
        _resolvedPickupQuery = address;
        _pickupController.text = address;
        // Pan / fit the map immediately on the auto-detected position.
        _updateMapBoundsAndRoute();
      } else {
        // Suppress autocomplete for the placeholder text — it is not a real
        // query. The guard is cleared the moment the user edits the field.
        _resolvedPickupQuery = 'Location unavailable — tap to enter';
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
        // Cache the raw device fix for the tab-switch fast path (see pickup).
        _gpsDropoffFix = latLng;
        _gpsDropoffAddress = address;
        // Lock the resolved query BEFORE setting text: the controller
        // listener fires synchronously on set and must see the address as
        // already resolved, or it would wipe these coordinates.
        _resolvedDropoffQuery = address;
        _dropoffController.text = address;
        // Pan / fit the map immediately on the auto-detected position.
        _updateMapBoundsAndRoute();
      } else {
        // Mirror the pickup pattern: suppress suggestions for placeholder text.
        _resolvedDropoffQuery = 'Location unavailable — tap to enter';
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

  /// Loads cached recents and merges the cloud backup (best-effort, never
  /// throws — an empty list simply hides the recents section).
  Future<void> _loadRecents() async {
    final uid = widget.user?.uid;
    if (uid != null && uid.isNotEmpty) {
      await _recents.syncFromCloud(uid);
    }
  }

  // ── Smart Hybrid Search & Zero-Cost Recents System ───────────────────────

  /// Loads local saved places (Home/Work) and frequent/recent addresses (0 API calls).
  Future<List<PlaceSuggestion>> _loadLocalFrequentAndRecent() async {
    final list = <PlaceSuggestion>[];

    // 1. Saved places (Home / Work) with stored coordinates
    if (_savedHomePlace != null && _savedHomePlace!.hasCoords) {
      list.add(PlaceSuggestion(
        description: _savedHomePlace!.address,
        mainText: 'Home',
        secondaryText: _savedHomePlace!.address,
        lat: _savedHomePlace!.lat!,
        lng: _savedHomePlace!.lng!,
        tag: 'Home',
        isFromCache: true,
      ));
    }
    if (_savedWorkPlace != null && _savedWorkPlace!.hasCoords) {
      list.add(PlaceSuggestion(
        description: _savedWorkPlace!.address,
        mainText: 'Work',
        secondaryText: _savedWorkPlace!.address,
        lat: _savedWorkPlace!.lat!,
        lng: _savedWorkPlace!.lng!,
        tag: 'Work',
        isFromCache: true,
      ));
    }

    // 2. Local frequent and recent places from repository (0 API calls)
    final recents = await _recents.getFrequentAndRecent(limit: 8);
    for (final loc in recents) {
      final alreadyPresent = list.any((s) =>
          s.description.toLowerCase() == loc.formattedAddress.toLowerCase() ||
          (loc.placeId.isNotEmpty && s.placeId == loc.placeId));
      if (!alreadyPresent) {
        list.add(PlaceSuggestion.fromRecent(loc));
      }
    }

    return list;
  }

  /// Immediately shows recent & frequent addresses upon focus or empty query (0 API calls).
  Future<void> _showLocalRecentsOrHybrid({required bool forPickup}) async {
    final controller = forPickup ? _pickupController : _dropoffController;
    final query = controller.text.trim();

    setState(() {
      _suggestingForPickup = forPickup;
      _isLoadingSuggestions = true;
    });
    _showOrRefreshSuggestionsOverlay();

    final isPlaceholder = query.isEmpty ||
        query == _resolvedPickupQuery ||
        query == _resolvedDropoffQuery ||
        query.startsWith('Location unavailable');

    if (isPlaceholder) {
      final suggestions = await _loadLocalFrequentAndRecent();
      if (!mounted) return;
      setState(() {
        _suggestions = suggestions;
        _isLoadingSuggestions = false;
      });
      _suggestionsOverlay?.markNeedsBuild();
      if (suggestions.isEmpty) {
        _hideSuggestionsOverlay();
      }
      return;
    }

    await _searchHybrid(query, forPickup: forPickup);
  }

  /// Searches local recent addresses first at zero API cost.
  /// Only queries external Google Places API if no local matches exist and query is novel (>= 3 chars).
  Future<void> _searchHybrid(String query, {required bool forPickup}) async {
    final timer = forPickup ? _pickupDebounceTimer : _debounceTimer;
    if (timer?.isActive ?? false) timer!.cancel();

    final clean = query.trim();
    if (clean.isEmpty) {
      final recents = await _loadLocalFrequentAndRecent();
      if (!mounted) return;
      setState(() {
        _suggestingForPickup = forPickup;
        _suggestions = recents;
        _isLoadingSuggestions = false;
      });
      _suggestionsOverlay?.markNeedsBuild();
      if (recents.isEmpty) _hideSuggestionsOverlay();
      return;
    }

    // 1. Fast local search from local cache (0 API calls)
    final localMatches = await _recents.searchLocal(clean, limit: 6);
    final localSuggestions = <PlaceSuggestion>[];

    // Check Home/Work matches
    if (_savedHomePlace != null && _savedHomePlace!.hasCoords) {
      if ('home'.contains(clean.toLowerCase()) ||
          _savedHomePlace!.address.toLowerCase().contains(clean.toLowerCase())) {
        localSuggestions.add(PlaceSuggestion(
          description: _savedHomePlace!.address,
          mainText: 'Home',
          secondaryText: _savedHomePlace!.address,
          lat: _savedHomePlace!.lat!,
          lng: _savedHomePlace!.lng!,
          tag: 'Home',
          isFromCache: true,
        ));
      }
    }
    if (_savedWorkPlace != null && _savedWorkPlace!.hasCoords) {
      if ('work'.contains(clean.toLowerCase()) ||
          _savedWorkPlace!.address.toLowerCase().contains(clean.toLowerCase())) {
        localSuggestions.add(PlaceSuggestion(
          description: _savedWorkPlace!.address,
          mainText: 'Work',
          secondaryText: _savedWorkPlace!.address,
          lat: _savedWorkPlace!.lat!,
          lng: _savedWorkPlace!.lng!,
          tag: 'Work',
          isFromCache: true,
        ));
      }
    }

    for (final loc in localMatches) {
      final exists = localSuggestions.any((s) =>
          s.description.toLowerCase() == loc.formattedAddress.toLowerCase());
      if (!exists) {
        localSuggestions.add(PlaceSuggestion.fromRecent(loc));
      }
    }

    // If local matches exist, display them immediately with zero API calls!
    if (localSuggestions.isNotEmpty) {
      if (!mounted) return;
      setState(() {
        _suggestingForPickup = forPickup;
        _suggestions = localSuggestions;
        _isLoadingSuggestions = false;
      });
      _showOrRefreshSuggestionsOverlay();
      _suggestionsOverlay?.markNeedsBuild();
      return;
    }

    // 2. No local match found. If query is < 3 characters, do not call external API yet.
    if (clean.length < 3) {
      if (!mounted) return;
      setState(() {
        _suggestingForPickup = forPickup;
        _suggestions = [];
        _isLoadingSuggestions = false;
      });
      _hideSuggestionsOverlay();
      return;
    }

    // 3. User typed a novel query that does not match local history:
    // Debounce and trigger external map autocomplete queries.
    final newTimer = Timer(const Duration(milliseconds: 350), () async {
      if (!mounted) return;
      setState(() {
        _suggestingForPickup = forPickup;
        _isLoadingSuggestions = true;
      });
      _showOrRefreshSuggestionsOverlay();

      final bias = (forPickup ? _pickupLatLng : _dropoffLatLng) ??
          LocationService.lastKnownPosition;
      final results = await LocationAutocompleteService.fetchSuggestions(
        clean,
        biasLatLng: bias,
      );

      if (!mounted) return;
      setState(() {
        _suggestions = results;
        _isLoadingSuggestions = false;
      });
      _suggestionsOverlay?.markNeedsBuild();
      if (results.isEmpty) _hideSuggestionsOverlay();
    });

    if (forPickup) {
      _pickupDebounceTimer = newTimer;
    } else {
      _debounceTimer = newTimer;
    }
  }

  /// Fires whenever the pickup [TextEditingController] value changes.
  void _onPickupChanged() {
    if (_isSelectingPickupSuggestion) return;
    if (_pickupDebounceTimer?.isActive ?? false) _pickupDebounceTimer!.cancel();

    final query = _pickupController.text.trim();

    // Re-notify with the same resolved text — keep coordinates.
    if (query == _resolvedPickupQuery) return;

    // Manual typing invalidates coordinates immediately so Next button stays safely disabled.
    _resolvedPickupQuery = null;
    if (mounted) {
      setState(() {
        _pickupLatLng = null;
        _routePoints = [];
      });
    }

    _searchHybrid(query, forPickup: true);
  }

  /// Fires whenever the drop-off [TextEditingController] value changes.
  void _onDropoffChanged() {
    if (_isSelectingSuggestion) return;
    if (_debounceTimer?.isActive ?? false) _debounceTimer!.cancel();

    final query = _dropoffController.text.trim();

    // Selection/focus noise (e.g. auto-focus on open) re-notifies with the
    // same text that already resolved — keep the coordinates.
    if (query == _resolvedDropoffQuery) return;

    // Manual typing invalidates coordinates immediately so Next button stays safely disabled.
    _resolvedDropoffQuery = null;
    if (mounted) {
      setState(() {
        _dropoffLatLng = null;
        _routePoints = [];
      });
    }

    _searchHybrid(query, forPickup: false);
  }

  void _selectSuggestion(PlaceSuggestion suggestion) {
    // 0 API Cost for cached/local suggestions
    if (suggestion.isFromCache ||
        (suggestion.lat != 0 && suggestion.lng != 0)) {
      _applyResolvedSuggestion(
        suggestion.description,
        LatLng(suggestion.lat, suggestion.lng),
      );
      // Touch/save in cache to increment frequency and refresh recency (0 API cost)
      // ignore: discarded_futures
      _recents.saveLocation(
        address: suggestion.description,
        lat: suggestion.lat,
        lng: suggestion.lng,
        placeId: suggestion.placeId,
        mainText: suggestion.mainText,
        secondaryText: suggestion.secondaryText,
        tag: suggestion.tag,
        uid: widget.user?.uid,
      );
      return;
    }

    final placeId = suggestion.placeId;
    if (placeId == null || placeId.isEmpty) {
      _applyResolvedSuggestion(
        suggestion.description,
        LatLng(suggestion.lat, suggestion.lng),
      );
      return;
    }

    // Google predictions carry a placeId but no coordinates: resolve with
    // one Details call, then persist to recents (all future taps cost 0).
    // ignore: discarded_futures
    LocationService.resolvePrediction(suggestion).then((resolved) {
      if (!mounted) return;
      if (resolved == null) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Could not resolve that place. Try another.'),
          ),
        );
        return;
      }
      // Persist the fresh resolution for zero-cost reuse next time.
      // ignore: discarded_futures
      _recents.saveLocation(
        address: resolved.description,
        lat: resolved.lat,
        lng: resolved.lng,
        placeId: placeId,
        mainText: resolved.mainText,
        secondaryText: resolved.secondaryText,
        uid: widget.user?.uid,
      ).then((_) {
        if (mounted) _loadRecents();
      });
      _applyResolvedSuggestion(
        resolved.description,
        LatLng(resolved.lat, resolved.lng),
      );
    });
  }

  /// Explicit user selection: populate text & lock lat/lng.
  void _applyResolvedSuggestion(String address, LatLng latLng) {
    _isSelectingSuggestion = true;
    _dropoffController.text = address;
    _dropoffLatLng = latLng;
    _resolvedDropoffQuery = address;

    setState(() {
      _suggestions = [];
      _isLoadingSuggestions = false;
      if (_pickupLatLng != null) {
        _isAddressCardCollapsed = true;
      }
    });

    _hideSuggestionsOverlay();
    FocusScope.of(context).unfocus();
    _isSelectingSuggestion = false;
    _updateMapBoundsAndRoute();
  }

  // ── Pickup suggestion selection ───────────────────────────────────────────

  /// Resolves a pickup [PlaceSuggestion] from the overlay, mirroring the
  /// drop-off [_selectSuggestion] path with zero-cost cache resolution.
  void _selectPickupSuggestion(PlaceSuggestion suggestion) {
    // 0 API Cost for cached/local suggestions
    if (suggestion.isFromCache ||
        (suggestion.lat != 0 && suggestion.lng != 0)) {
      _applyResolvedPickupSuggestion(
        suggestion.description,
        LatLng(suggestion.lat, suggestion.lng),
      );
      // ignore: discarded_futures
      _recents.saveLocation(
        address: suggestion.description,
        lat: suggestion.lat,
        lng: suggestion.lng,
        placeId: suggestion.placeId,
        mainText: suggestion.mainText,
        secondaryText: suggestion.secondaryText,
        tag: suggestion.tag,
        uid: widget.user?.uid,
      );
      return;
    }

    final placeId = suggestion.placeId;
    if (placeId == null || placeId.isEmpty) {
      _applyResolvedPickupSuggestion(
        suggestion.description,
        LatLng(suggestion.lat, suggestion.lng),
      );
      return;
    }

    // ignore: discarded_futures
    LocationService.resolvePrediction(suggestion).then((resolved) {
      if (!mounted) return;
      if (resolved == null) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Could not resolve that place. Try another.'),
          ),
        );
        return;
      }
      // ignore: discarded_futures
      _recents.saveLocation(
        address: resolved.description,
        lat: resolved.lat,
        lng: resolved.lng,
        placeId: placeId,
        mainText: resolved.mainText,
        secondaryText: resolved.secondaryText,
        uid: widget.user?.uid,
      ).then((_) {
        if (mounted) _loadRecents();
      });
      _applyResolvedPickupSuggestion(
        resolved.description,
        LatLng(resolved.lat, resolved.lng),
      );
    });
  }

  /// Populates the pickup field with a resolved address and coordinates,
  /// then updates the route preview.
  void _applyResolvedPickupSuggestion(String address, LatLng latLng) {
    _isSelectingPickupSuggestion = true;
    _resolvedPickupQuery = address; // lock before setText to silence listener
    _pickupController.text = address;
    _pickupLatLng = latLng;

    setState(() {
      _suggestions = [];
      _isLoadingSuggestions = false;
      if (_dropoffLatLng != null) {
        _isAddressCardCollapsed = true;
      }
    });

    _hideSuggestionsOverlay();
    FocusScope.of(context).unfocus();
    _isSelectingPickupSuggestion = false;
    _updateMapBoundsAndRoute();
  }

  // ── Suggestions overlay ───────────────────────────────────────────────────

  /// Focus-change callback for the pickup [FocusNode].
  /// Immediately shows recent addresses on tap/focus (0 API calls).
  /// Hides the overlay 200ms after focus is lost so that a suggestion tap has time to complete.
  void _onPickupFocusChanged() {
    if (mounted) setState(() {});
    if (!_pickupFocusNode.hasFocus) {
      Future.delayed(const Duration(milliseconds: 200), () {
        if (mounted && _suggestingForPickup) _hideSuggestionsOverlay();
      });
    } else {
      _showLocalRecentsOrHybrid(forPickup: true);
    }
  }

  /// Focus-change callback for the drop-off [FocusNode].
  /// Immediately shows recent addresses on tap/focus (0 API calls).
  void _onDropoffFocusChanged() {
    if (mounted) setState(() {});
    if (!_dropoffFocusNode.hasFocus) {
      Future.delayed(const Duration(milliseconds: 200), () {
        if (mounted && !_suggestingForPickup) _hideSuggestionsOverlay();
      });
    } else {
      _showLocalRecentsOrHybrid(forPickup: false);
    }
  }

  /// Creates or refreshes the floating suggestions [OverlayEntry].
  ///
  /// The panel is positioned beneath the active input via
  /// [CompositedTransformFollower], so it floats above all sibling widgets
  /// without affecting the Step 1 [Column] layout. Safe to call while
  /// the overlay is already visible — it calls [OverlayEntry.markNeedsBuild]
  /// instead of re-inserting a duplicate.
  void _showOrRefreshSuggestionsOverlay() {
    if (!mounted) return;
    if (_suggestionsOverlay != null) {
      _suggestionsOverlay!.markNeedsBuild();
      return;
    }
    _suggestionsOverlay = OverlayEntry(
      builder: (_) {
        final link =
            _suggestingForPickup ? _pickupLayerLink : _dropoffLayerLink;
        final screenWidth = MediaQuery.of(context).size.width;
        // top: 0 + left: 0 anchor the Positioned in the Overlay stack;
        // CompositedTransformFollower then moves the child to sit directly
        // below the active text field. Without explicit top/left the widget
        // is unpositioned and may render off-screen on some device sizes.
        return Positioned(
          top: 0,
          left: 0,
          width: screenWidth - 32, // matches the 16px horizontal padding
          child: CompositedTransformFollower(
            link: link,
            showWhenUnlinked: false,
            targetAnchor: Alignment.bottomLeft,
            followerAnchor: Alignment.topLeft,
            offset: const Offset(0, 4),
            child: Material(
              elevation: 8,
              borderRadius: BorderRadius.circular(12),
              clipBehavior: Clip.antiAlias,
              child: ConstrainedBox(
                // Cap height so the panel never pushes off the bottom of the
                // screen even for long result sets.
                constraints: const BoxConstraints(maxHeight: 320),
                child: _buildSuggestionsContent(),
              ),
            ),
          ),
        );
      },
    );
    Overlay.of(context).insert(_suggestionsOverlay!);
  }

  /// Removes the suggestions overlay if one is currently displayed.
  void _hideSuggestionsOverlay() {
    _suggestionsOverlay?.remove();
    _suggestionsOverlay = null;
  }

  /// Pins the last both-known pair for the sticky preview and kicks off the
  /// route fetch. Called whenever either text field resolves to new
  /// coordinates — on GPS auto-detect, on suggestion selection, and when
  /// both deep-link / initial points are present.
  void _updateMapBoundsAndRoute() {
    final pickup = _pickupLatLng;
    final dropoff = _dropoffLatLng;
    if (pickup != null && dropoff != null) {
      setState(() {
        _previewPickup = pickup;
        _previewDropoff = dropoff;
        _isAddressCardCollapsed = true;
      });
    }
    _fetchRoutePreview();
  }

  Future<void> _fetchRoutePreview() async {
    final pickup = _pickupLatLng;
    final dropoff = _dropoffLatLng;
    if (pickup == null || dropoff == null) return;
    // Already routed this exact pair with geometry on hand — nothing to do.
    // Makes toggle round-trips back to a previous A/B instant (no spinner,
    // no Directions call); the preview re-shows the cached polyline.
    if (pickup == _routedPickup &&
        dropoff == _routedDropoff &&
        _routePoints.isNotEmpty) {
      return;
    }
    setState(() => _fetchingRoute = true);
    // Route geometry: Google Directions primary → OSRM free fallback.
    // Straight-line [pickup, dropoff] is only used when both sources fail
    // (no connection at all); `_routeDistanceM`/`_routeDurationS` stay 0
    // in that case so the distance badge is hidden.
    final result = await LocationService.fetchRoute(pickup, dropoff);
    if (!mounted) return;
    // Superseded: the user toggled tabs or edited a field while this fetch
    // was in flight. Drop the stale result — the newer pair's own fetch
    // owns the route state now.
    if (_pickupLatLng != pickup || _dropoffLatLng != dropoff) return;
    setState(() {
      _routePoints =
          result.points.isNotEmpty ? result.points : [pickup, dropoff];
      _routeDistanceM = result.distanceM;
      _routeDurationS = result.durationS;
      _routedPickup = pickup;
      _routedDropoff = dropoff;
      _fetchingRoute = false;
    });
  }

  // ── Fare calculation (called on Step 1 → 2 transition) ───────────────────

  Future<bool> _loadFares() async {
    final pickup = _pickupLatLng;
    final dropoff = _dropoffLatLng;
    if (pickup == null || dropoff == null) return false;

    setState(() {
      _fareLoading = true;
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

  /// True when the preview's pinned pair is exactly the live pair, so the
  /// route polyline + distance/duration badge describe the trip on screen.
  /// After a tab toggle the preview keeps showing the last pair (tiles stay
  /// warm) while this is false — pins without a route claim.
  bool get _previewMatchesLive =>
      _pickupLatLng != null &&
      _dropoffLatLng != null &&
      _pickupLatLng == _previewPickup &&
      _dropoffLatLng == _previewDropoff;

  /// Non-intrusive phone input: customer input is free and unconstrained across
  /// all flows (Ride Booking, Send Item, Receive Item). Background normalization
  /// formats E.164 values quietly for the server/driver.
  bool get _phonesValid => true;

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

    final isDelivery = _selectedModeIndex == 0;
    final activeIso = CountryDetectionService.instance.currentCountryCode;
    final pickupPhone = SesePhoneSanitizer.normalize(
      _pickupPhoneController.text.trim(),
      defaultIsoCode: activeIso,
    );
    final dropoffPhone = SesePhoneSanitizer.normalize(
      _dropoffPhoneController.text.trim(),
      defaultIsoCode: activeIso,
    );
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

    if (_paymentMode == 'split') {
      if (!_remoteKeys.splitPaymentMasterEnabled) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Split Payment is currently disabled by Hub admin.')),
          );
        }
        return;
      }
      if (_splitSenderAmount == null || _splitReceiverAmount == null) {
        await _openSplitPaymentSheet();
        if (_splitSenderAmount == null) return;
      }
      // Split settles against a REGISTERED receiver, so it is the one flow
      // that still needs a drop-off number — everything else may ship
      // without secondary contacts.
      if (dropoffPhone.isEmpty) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text(
                'Split payment needs the receiver\'s phone number so their '
                'share can be settled. Add it, or use Sender/Receiver Pays.',
              ),
            ),
          );
        }
        return;
      }
      setState(() => _creatingTrip = true);
      try {
        final result = await P2pService().lookupRecipient(recipientPhone: dropoffPhone);
        if (result.recipientId.isEmpty) {
          throw const P2pException('not-found', 'Unregistered user');
        }
      } catch (e) {
        if (mounted) {
          setState(() => _creatingTrip = false);
          await showDialog<void>(
            context: context,
            builder: (ctx) => AlertDialog(
              title: const Text('Split Payment Restricted'),
              content: const Text(
                'Split payment requires both parties to be registered users. '
                'Ask the receiver to sign up, or select "Sender Pays" / "Receiver Pays".',
              ),
              actions: [
                FilledButton(
                  onPressed: () => Navigator.pop(ctx),
                  child: const Text('OK'),
                ),
              ],
            ),
          );
        }
        return;
      }
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
    final pickupName = _pickupNameController.text.trim();
    final dropoffName = _dropoffNameController.text.trim();
    final totalFare = _currentEstimatedFare;
    double walletCoverage = 0.0;
    double cashToCollect = totalFare;
    String collectAt = 'pickup';
    String payerRole = 'sender';

    if (_paymentMode == 'receiver_pays') {
      walletCoverage = 0.0;
      cashToCollect = totalFare;
      collectAt = 'dropoff';
      payerRole = 'receiver';
    } else if (_paymentMode == 'split') {
      payerRole = 'split';
      final senderShare = _splitSenderAmount ?? (totalFare / 2);
      final receiverShare = _splitReceiverAmount ?? (totalFare - senderShare);
      if (_paymentMethod == 'cash') {
        walletCoverage = 0.0;
        cashToCollect = totalFare;
        collectAt = 'both';
      } else {
        walletCoverage = math.min(senderShare, _customerWalletBalance);
        final senderCash = math.max(0.0, senderShare - walletCoverage);
        cashToCollect = senderCash + receiverShare;
        collectAt = senderCash > 0 ? 'both' : 'dropoff';
      }
    } else {
      payerRole = 'sender';
      collectAt = 'pickup';
      if (_paymentMethod == 'cash') {
        walletCoverage = 0.0;
        cashToCollect = totalFare;
      } else {
        walletCoverage = math.min(totalFare, _customerWalletBalance);
        cashToCollect = math.max(0.0, totalFare - walletCoverage);
      }
    }

    setState(() => _creatingTrip = true);
    late final String tripId;
    try {
      tripId = await _tripRepository.createTrip(
        TripDraft(
          customerId: widget.user?.uid ?? '',
          pickupLat: pickup.latitude,
          pickupLng: pickup.longitude,
          pickupAddress: _pickupController.text,
          pickupName: pickupName,
          pickupPhone: pickupPhone,
          dropoffLat: dropoff.latitude,
          dropoffLng: dropoff.longitude,
          dropoffAddress: _dropoffController.text,
          dropoffName: dropoffName,
          dropoffPhone: dropoffPhone,
          serviceType: isDelivery
              ? (_isReceivePackageMode ? 'receive_item' : 'send_item')
              : 'ride',
          selectedTiers: selectedTiers,
          fareToken: fareResp.fareToken,
          distanceKm: fareResp.distanceKm,
          durationMins: fareResp.durationMins,
          isVerifiedCustomer: verifiedCustomer,
          paymentMethod: _paymentMode == 'receiver_pays' ? 'cash' : _paymentMethod,
          paymentMode: _paymentMode,
          senderShareAmount: _paymentMode == 'split' ? _splitSenderAmount : null,
          receiverShareAmount: _paymentMode == 'split' ? _splitReceiverAmount : null,
          walletCoverageAmount: walletCoverage,
          cashToCollect: cashToCollect,
          collectAt: collectAt,
          payerRole: payerRole,
          // Rides never request a PIN (no toggle exists in the ride review;
          // gating here also covers Delivery→Ride toggles carrying a stale
          // `_requireDeliveryPin`). The server mints rides PIN-free anyway —
          // this keeps the intent honest at the source.
          requireDeliveryPin: isDelivery &&
              (_requireDeliveryPin || _remoteKeys.forceDeliveryPinSystemWide),
          receiverPhone: dropoffPhone,
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

    // Cache booked locations locally and sync to cloud profile (0 API calls on next use)
    // ignore: discarded_futures
    _recents.saveLocation(
      address: _pickupController.text,
      lat: pickup.latitude,
      lng: pickup.longitude,
      uid: widget.user?.uid,
    );
    // ignore: discarded_futures
    _recents.saveLocation(
      address: _dropoffController.text,
      lat: dropoff.latitude,
      lng: dropoff.longitude,
      uid: widget.user?.uid,
    );

    // Payload mirror for the createTrip / createDelivery Cloud Functions
    // (route + server-verified fare + optional contact numbers). Sent via
    // the authenticated callable above — never hardcode credentials.
    final dispatchPayload = <String, dynamic>{
      'tripId': tripId,
      'pickup': {
        'lat': pickup.latitude,
        'lng': pickup.longitude,
        'address': _pickupController.text,
        if (pickupName.isNotEmpty) 'name': pickupName,
        'phone': pickupPhone,
      },
      'dropoff': {
        'lat': dropoff.latitude,
        'lng': dropoff.longitude,
        'address': _dropoffController.text,
        if (dropoffName.isNotEmpty) 'name': dropoffName,
        'phone': dropoffPhone,
      },
      'pickupPhone': pickupPhone,
      'dropoffPhone': dropoffPhone,
      if (pickupName.isNotEmpty) 'pickupName': pickupName,
      if (dropoffName.isNotEmpty) 'dropoffName': dropoffName,
      'serviceType':
          isDelivery ? (_isReceivePackageMode ? 'receive_item' : 'send_item') : 'ride',
      'selectedTiers': selectedTiers,
      'fareToken': fareResp.fareToken,
      'distanceKm': fareResp.distanceKm,
      'durationMins': fareResp.durationMins,
      'paymentMethod': _paymentMode == 'receiver_pays' ? 'cash' : _paymentMethod,
      'paymentMode': _paymentMode,
      if (_splitSenderAmount != null) 'senderShareAmount': _splitSenderAmount,
      if (_splitReceiverAmount != null)
        'receiverShareAmount': _splitReceiverAmount,
      'walletCoverageAmount': walletCoverage,
      'cashToCollect': cashToCollect,
      'collectAt': collectAt,
      'payerRole': payerRole,
    };
    debugPrint('Dispatch payload: $dispatchPayload');

    // 2. Navigate directly to the live tracker while retaining this booking state underneath
    // so any cancellation or re-editing seamlessly restores all inputs without route reset.
    if (mounted) {
      final result = await Navigator.of(context).push<dynamic>(
        MaterialPageRoute(
          builder: (_) => LiveTripScreen(
            tripId: tripId,
            repository: _tripRepository,
          ),
        ),
      );
      if (result == 'completed' && mounted) {
        Navigator.of(context).pop();
      }
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
          // The 1-2-3 step counter lives HERE as a slim header badge
          // (not a standalone row below) so the map canvas below reclaims
          // the full ~64px block. The title flexes with ellipsis on narrow
          // screens; the badge keeps a fixed mini size.
          title: Row(
            children: [
              Expanded(
                child: Text(title, overflow: TextOverflow.ellipsis),
              ),
              if (_currentStep != 0) ...[
                const SizedBox(width: 8),
                _buildHeaderStepBadge(),
              ],
            ],
          ),
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
            // Step 1 (locations) is a bounded, non-scrolling layout: the
            // map preview below takes all remaining vertical space via
            // Expanded. Steps 2-3 keep their scrolling content.
            if (_currentStep == 0)
              Expanded(
                child: _buildStep1Content(),
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

  /// Slim step badge pinned in the AppBar title row: three mini circles
  /// (1 · 2 · 3) joined by fixed connectors. Completed steps show a check
  /// and stay tappable shortcuts back to that step; the active step is
  /// highlighted. Replaces the old full-width indicator row — same state,
  /// same tap-back contract, zero vertical block in the body.
  Widget _buildHeaderStepBadge() {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _buildStepCircle(
              stepNumber: 1, currentStep: _currentStep, compact: true),
          _buildStepConnector(
              isCompleted: _currentStep > 1, compact: true),
          _buildStepCircle(
              stepNumber: 2, currentStep: _currentStep, compact: true),
          _buildStepConnector(
              isCompleted: _currentStep > 2, compact: true),
          _buildStepCircle(
              stepNumber: 3, currentStep: _currentStep, compact: true),
        ],
      ),
    );
  }

  Widget _buildStepCircle(
      {required int stepNumber,
      required int currentStep,
      bool compact = false}) {
    // Step indices are 0-based internally; circles are 1-based.
    final int stepIndex = stepNumber - 1;
    final bool isCompleted = currentStep > stepIndex;
    final bool isActive = currentStep == stepIndex;
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

    // Compact badge size fits the AppBar title row; the regular size is
    // kept for any future in-body use.
    final diameter = compact ? 20.0 : 32.0;
    final circle = Container(
      width: diameter,
      height: diameter,
      decoration: BoxDecoration(
        color: backgroundColor,
        shape: BoxShape.circle,
      ),
      child: Center(
        child: isCompleted
            ? Icon(Icons.check,
                size: compact ? 12 : 18,
                color: theme.colorScheme.onPrimary)
            : Text(
                '$stepNumber',
                style: TextStyle(
                  color: textColor,
                  fontWeight: FontWeight.bold,
                  fontSize: compact ? 11 : 14,
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

  Widget _buildStepConnector({required bool isCompleted, bool compact = false}) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final line = Container(
      // Fixed width in the header badge (Expanded would claim the whole
      // title row); the regular variant flexes for in-body rows.
      width: compact ? 8 : null,
      height: 2,
      color: isCompleted
          ? theme.colorScheme.primary
          : (isDark
              ? theme.colorScheme.outlineVariant
              : Colors.grey.shade300),
    );
    if (compact) return line;
    return Expanded(child: line);
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
                      // Gated on a routed fare plus phone validity (empty
                      // phones pass — only malformed entries block), and
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
    final previewPickup = _previewPickup ?? _pickupLatLng;
    final previewDropoff = _previewDropoff ?? _dropoffLatLng;

    return Stack(
      children: [
        // ── Layer 0: Full Interactive Map Background ──
        if (previewPickup != null)
          Positioned.fill(
            child: _RouteMapPreview(
              pickup: previewPickup,
              dropoff: previewDropoff,
              routePoints:
                  _previewMatchesLive ? _routePoints : const <LatLng>[],
              isLoadingRoute: _fetchingRoute && _previewMatchesLive,
              distanceM: _previewMatchesLive ? _routeDistanceM : 0,
              durationS: _previewMatchesLive ? _routeDurationS : 0,
              padding: _isAddressCardCollapsed ? 96.0 : 130.0,
            ),
          )
        else
          Positioned.fill(
            child: Container(
              color: Theme.of(context)
                  .colorScheme
                  .surfaceContainerHighest
                  .withValues(alpha: 0.3),
              alignment: Alignment.center,
              child: const SizedBox(
                width: 24,
                height: 24,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            ),
          ),

        // ── Layer 1: Merged Draggable / Collapsible Address Sheet ──
        Positioned(
          top: 8,
          left: 12,
          right: 12,
          child: _buildStep1AddressSheet(),
        ),
      ],
    );
  }

  Widget _buildStep1AddressSheet() {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    return GestureDetector(
      onVerticalDragEnd: (details) {
        if (details.primaryVelocity != null) {
          if (details.primaryVelocity! < -150 && _addressesReady) {
            setState(() => _isAddressCardCollapsed = true);
          } else if (details.primaryVelocity! > 150) {
            setState(() => _isAddressCardCollapsed = false);
          }
        }
      },
      child: AnimatedSize(
        duration: const Duration(milliseconds: 250),
        curve: Curves.easeInOut,
        child: _isAddressCardCollapsed && _addressesReady
            ? _buildStep1CollapsedSummary(scheme)
            : _buildStep1ExpandedCard(scheme),
      ),
    );
  }

  Widget _buildStep1CollapsedSummary(ColorScheme scheme) {
    return Card(
      elevation: 4,
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () => setState(() => _isAddressCardCollapsed = false),
        borderRadius: BorderRadius.circular(16),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  const Text(
                    'Step 1: Locations',
                    style: TextStyle(
                      fontWeight: FontWeight.bold,
                      fontSize: 13,
                    ),
                  ),
                  const Spacer(),
                  _buildHeaderStepBadge(),
                  const SizedBox(width: 8),
                  Container(
                    padding: const EdgeInsets.all(5),
                    decoration: BoxDecoration(
                      color: AppColors.seseGold.withValues(alpha: 0.18),
                      shape: BoxShape.circle,
                    ),
                    child: const Icon(
                      Icons.edit,
                      size: 14,
                      color: AppColors.seseGold,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 6),
              const Divider(height: 1),
              const SizedBox(height: 8),
              Row(
                children: [
                  const Icon(Icons.circle, size: 8, color: Colors.green),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      _pickupController.text.isNotEmpty
                          ? _pickupController.text
                          : 'Pickup location',
                      style: const TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w500,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 5),
              Row(
                children: [
                  const Icon(Icons.location_on, size: 10, color: Colors.redAccent),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      _dropoffController.text.isNotEmpty
                          ? _dropoffController.text
                          : 'Destination',
                      style: const TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w500,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
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

  Widget _buildStep1ExpandedCard(ColorScheme scheme) {
    return Card(
      elevation: 6,
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.of(context).size.height * 0.65,
        ),
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(12),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  const Text(
                    'Step 1: Locations',
                    style: TextStyle(
                      fontWeight: FontWeight.bold,
                      fontSize: 14,
                    ),
                  ),
                  const Spacer(),
                  _buildHeaderStepBadge(),
                  if (_addressesReady) ...[
                    const SizedBox(width: 6),
                    IconButton(
                      icon: const Icon(Icons.keyboard_arrow_up),
                      tooltip: 'Collapse sheet',
                      onPressed: () =>
                          setState(() => _isAddressCardCollapsed = true),
                      visualDensity: VisualDensity.compact,
                      padding: EdgeInsets.zero,
                      constraints: const BoxConstraints(),
                    ),
                  ],
                ],
              ),
              const SizedBox(height: 8),
              if (_selectedModeIndex == 0) _buildContextAwareModeSelector(),
              const SizedBox(height: 6),
              // ── Pickup field ──
              CompositedTransformTarget(
                link: _pickupLayerLink,
                child: TextField(
                  controller: _pickupController,
                  focusNode: _pickupFocusNode,
                  decoration: InputDecoration(
                    labelText: 'Pickup Location',
                    hintText: 'Where from?',
                    alignLabelWithHint: true,
                    prefixIcon:
                        const Icon(Icons.trip_origin, color: Colors.green),
                    suffixIcon: (_pickupGeocoding ||
                            (_isLoadingSuggestions && _suggestingForPickup))
                        ? const Padding(
                            padding: EdgeInsets.all(14),
                            child: SizedBox(
                                width: 16,
                                height: 16,
                                child:
                                    CircularProgressIndicator(strokeWidth: 2)))
                        : Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              if (_pickupLatLng != null)
                                const Icon(Icons.check_circle,
                                    color: Colors.green, size: 20),
                              IconButton(
                                key: const Key('pickup_pick_on_map_icon'),
                                icon: const Icon(Icons.map_outlined),
                                tooltip: 'Pick pickup on map',
                                onPressed: () =>
                                    _openPickOnMap(target: 'pickup'),
                              ),
                              IconButton(
                                icon: const Icon(Icons.my_location),
                                tooltip: 'Re-detect my location',
                                onPressed: _initPickupLocation,
                              ),
                            ],
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
                    fillColor: Theme.of(context)
                        .colorScheme
                        .surfaceContainerHighest,
                    isDense: false,
                    contentPadding:
                        const EdgeInsets.fromLTRB(12, 14, 12, 10),
                  ),
                ),
              ),
              const SizedBox(height: 10),
              // ── Drop-off field ──
              CompositedTransformTarget(
                link: _dropoffLayerLink,
                child: TextField(
                  controller: _dropoffController,
                  focusNode: _dropoffFocusNode,
                  decoration: InputDecoration(
                    labelText: 'Destination / Drop-off',
                    hintText: 'Where to?',
                    alignLabelWithHint: true,
                    prefixIcon:
                        const Icon(Icons.location_on, color: Colors.red),
                    suffixIcon: ((_isLoadingSuggestions &&
                                !_suggestingForPickup) ||
                            _dropoffGeocoding)
                        ? const Padding(
                            padding: EdgeInsets.all(14),
                            child: SizedBox(
                                width: 16,
                                height: 16,
                                child:
                                    CircularProgressIndicator(strokeWidth: 2)))
                        : Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              if (_dropoffLatLng != null)
                                const Icon(Icons.check_circle,
                                    color: Colors.green, size: 20),
                              IconButton(
                                key: const Key('dropoff_pick_on_map_icon'),
                                icon: const Icon(Icons.map_outlined),
                                tooltip: 'Pick destination on map',
                                onPressed: () =>
                                    _openPickOnMap(target: 'destination'),
                              ),
                            ],
                          ),
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
                    fillColor: Theme.of(context)
                        .colorScheme
                        .surfaceContainerHighest,
                    isDense: false,
                    contentPadding:
                        const EdgeInsets.fromLTRB(12, 14, 12, 10),
                  ),
                ),
              ),
              // Home / Work chips
              _buildSavedPlaceChips(),
              if (!_addressesReady &&
                  !_pickupGeocoding &&
                  _suggestions.isEmpty &&
                  !_isLoadingSuggestions)
                Padding(
                  padding: const EdgeInsets.only(top: 6),
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
              if (_addressesReady) ...[
                const SizedBox(height: 6),
                Center(
                  child: TextButton.icon(
                    icon: const Icon(Icons.map_outlined, size: 14),
                    label: const Text('Collapse to view map',
                        style: TextStyle(fontSize: 11)),
                    style: TextButton.styleFrom(
                      visualDensity: VisualDensity.compact,
                      foregroundColor: scheme.primary,
                    ),
                    onPressed: () =>
                        setState(() => _isAddressCardCollapsed = true),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  // ── Missing step-content builders ─────────────────────────────────────────

  /// Content widget for the floating suggestions [OverlayEntry].
  ///
  /// Displays a compact spinner while results are loading, then a
  /// [ListView] of [PlaceSuggestion] tiles. Taps route to the pickup
  /// or drop-off selection path depending on [_suggestingForPickup].
  ///
  /// This widget is intentionally **stateless within the builder** — the
  /// [OverlayEntry] builder accesses state directly, so calling
  /// [OverlayEntry.markNeedsBuild] after each [setState] propagates the
  /// latest [_suggestions] list without re-inserting the overlay.
  Widget _buildSuggestionsContent() {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;

    if (_isLoadingSuggestions && _suggestions.isEmpty) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 24, horizontal: 16),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const SizedBox(
              width: 18,
              height: 18,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
            const SizedBox(width: 12),
            Text(
              'Searching addresses...',
              style: TextStyle(
                fontSize: 13,
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      );
    }

    if (_suggestions.isEmpty) return const SizedBox.shrink();

    final hasCached = _suggestions.any((s) => s.isFromCache);

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // Section Header Bar
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
          decoration: BoxDecoration(
            color: isDark
                ? Colors.grey.shade900
                : theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.5),
            border: Border(
              bottom: BorderSide(
                color: theme.dividerColor.withValues(alpha: 0.15),
              ),
            ),
          ),
          child: Row(
            children: [
              Icon(
                hasCached ? Icons.history_rounded : Icons.search_rounded,
                size: 14,
                color: theme.colorScheme.onSurfaceVariant,
              ),
              const SizedBox(width: 6),
              Text(
                hasCached ? 'Recent & Saved Places' : 'Search Results',
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                  color: theme.colorScheme.onSurfaceVariant,
                  letterSpacing: 0.2,
                ),
              ),
            ],
          ),
        ),
        // List of Suggestions
        Flexible(
          child: ListView.separated(
            shrinkWrap: true,
            padding: EdgeInsets.zero,
            physics: const ClampingScrollPhysics(),
            itemCount: _suggestions.length,
            separatorBuilder: (_, _) => Divider(
              height: 1,
              color: theme.dividerColor.withValues(alpha: 0.15),
            ),
            itemBuilder: (context, index) {
              final s = _suggestions[index];
              return _buildSuggestionTile(s, theme);
            },
          ),
        ),
      ],
    );
  }

  Widget _buildSuggestionTile(PlaceSuggestion s, ThemeData theme) {
    final title = (s.mainText != null && s.mainText!.isNotEmpty)
        ? s.mainText!
        : s.description;

    final subtitle = (s.secondaryText != null &&
            s.secondaryText!.isNotEmpty &&
            s.secondaryText != s.mainText)
        ? s.secondaryText!
        : (s.mainText != null && s.mainText != s.description)
            ? s.description
            : null;

    final tag = s.tag;

    // Determine leading icon & color based on tag or cache state
    IconData iconData = Icons.location_on_outlined;
    Color iconColor = theme.colorScheme.onSurfaceVariant;
    if (tag == 'Home') {
      iconData = Icons.home_rounded;
      iconColor = AppColors.seseGold;
    } else if (tag == 'Work') {
      iconData = Icons.work_rounded;
      iconColor = AppColors.seseGold;
    } else if (tag == 'Frequent' || s.useCount >= 3) {
      iconData = Icons.star_rounded;
      iconColor = Colors.amber.shade700;
    } else if (s.isFromCache) {
      iconData = Icons.history_rounded;
      iconColor = theme.colorScheme.primary;
    }

    return InkWell(
      onTap: () => _suggestingForPickup
          ? _selectPickupSuggestion(s)
          : _selectSuggestion(s),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        child: Row(
          children: [
            Container(
              width: 32,
              height: 32,
              decoration: BoxDecoration(
                color: iconColor.withValues(alpha: 0.12),
                shape: BoxShape.circle,
              ),
              child: Icon(iconData, size: 18, color: iconColor),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Row(
                    children: [
                      Flexible(
                        child: Text(
                          title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                      if (tag != null && tag.isNotEmpty) ...[
                        const SizedBox(width: 8),
                        _buildTagPill(tag, theme),
                      ],
                    ],
                  ),
                  if (subtitle != null) ...[
                    const SizedBox(height: 2),
                    Text(
                      subtitle,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 11,
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ],
              ),
            ),
            const SizedBox(width: 8),
            Icon(
              Icons.north_west_rounded,
              size: 14,
              color: theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.5),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildTagPill(String tag, ThemeData theme) {
    Color bg;
    Color fg;
    if (tag == 'Home') {
      bg = AppColors.seseGold.withValues(alpha: 0.15);
      fg = AppColors.seseGold;
    } else if (tag == 'Work') {
      bg = Colors.blue.withValues(alpha: 0.15);
      fg = Colors.blue.shade700;
    } else if (tag.startsWith('Frequent')) {
      bg = Colors.amber.withValues(alpha: 0.15);
      fg = Colors.amber.shade800;
    } else {
      bg = theme.colorScheme.surfaceContainerHighest;
      fg = theme.colorScheme.onSurfaceVariant;
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1.5),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        tag,
        style: TextStyle(
          fontSize: 10,
          fontWeight: FontWeight.w600,
          color: fg,
        ),
      ),
    );
  }

  /// Step 2 content: vehicle / tier selection.
  ///
  /// For delivery the customer chooses one or more [VehicleCategory] vehicle
  /// types that will be broadcast simultaneously. For ride-hailing the
  /// customer picks from [_rideTierIds] tier cards.
  Widget _buildStep2Content() {
    final isDelivery = _selectedModeIndex == 0;
    return isDelivery
        ? _buildDeliveryVehicleSelector()
        : _buildRideTierSelector();
  }

  /// Step 3 content: full route & fare review before final confirmation.
  ///
  /// Delegates to [_buildDeliveryReview] or [_buildRideReview] depending on
  /// the active mode tab, both of which render [_RouteReviewCard],
  /// the Security PIN toggle, payment options, and the server fare table.
  Widget _buildStep3Content() {
    final isDelivery = _selectedModeIndex == 0;
    if (_fareResponse == null) {
      return const Center(child: CircularProgressIndicator());
    }
    return SingleChildScrollView(
      // No horizontal padding here: the steps' outer scroll view already
      // owns the single 16px bezel gutter, so cards/tables below span
      // edge-to-edge within it instead of stacking into a narrow column.
      padding: const EdgeInsets.fromLTRB(0, 8, 0, 16),
      child: isDelivery ? _buildDeliveryReview() : _buildRideReview(),
    );
  }

  // ── Step 2 sub-builders ────────────────────────────────────────────────────

  /// Delivery vehicle multi-selector (Step 2 delivery path).
  ///
  /// Rendered inside the steps' outer [SingleChildScrollView], so this list
  /// must not scroll itself: `shrinkWrap` + non-scrollable physics, otherwise
  /// the viewport gets unbounded height and layout throws.
  ///
  /// Each row shows the server fare (loaded before advancing from Step 1)
  /// and the engine/server "Recommended" badge, plus a live selection
  /// counter — the dispatch review table reuses the same data downstream.
  Widget _buildDeliveryVehicleSelector() {
    const categories = VehicleCategory.values;
    final resp = _fareResponse;
    return ListView(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      // Horizontal gutter comes from the outer scroll view — zero here so
      // vehicle rows run edge-to-edge instead of double-insetting.
      padding: const EdgeInsets.symmetric(horizontal: 0, vertical: 8),
      children: [
        const Text('Select Vehicle Type(s)',
            style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
        const SizedBox(height: 4),
        const Text(
          'Select all vehicle types to broadcast — first driver to accept wins.',
          style: TextStyle(fontSize: 12, color: Colors.grey),
        ),
        const SizedBox(height: 4),
        Text(
          '${_selectedDeliveryCategories.length} selected',
          style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
        ),
        const SizedBox(height: 12),
        ...categories.map((cat) {
          final selected = _selectedDeliveryCategories.contains(cat);
          final tier = resp?.tierById(_deliveryTierIds[cat] ?? cat.name);
          final recommended =
              resp != null && _deliveryRecommended(cat, resp);
          return _VehicleTierTile(
            key: Key('delivery_vehicle_${cat.name}'),
            art: VehicleArt.fromCategory(cat),
            title: _vehicleCategoryLabel(cat),
            subtitle: tier?.fareFormatted,
            selected: selected,
            isRecommended: recommended,
            onChanged: (_) {
              setState(() {
                if (selected && _selectedDeliveryCategories.length > 1) {
                  _selectedDeliveryCategories.remove(cat);
                } else if (!selected) {
                  _selectedDeliveryCategories.add(cat);
                }
              });
            },
          );
        }),
      ],
    );
  }

  /// Ride tier multi-selector (Step 2 ride-hailing path).
  ///
  /// Customers broadcast to multiple car tiers simultaneously — the first
  /// driver of any matching tier who accepts wins. Mirrors the delivery
  /// vehicle multi-selector: custom tier card rows, minimum one selected,
  /// server fare per card, "Recommended" badge, Keke card appears only for
  /// short trips (same engine logic as delivery).
  Widget _buildRideTierSelector() {
    final resp = _fareResponse;
    final distanceKm = resp?.distanceKm ?? -1;
    // Canonical server order; Keke joins only while offered for this distance.
    final ids = [
      ..._rideTierIds,
      if (resp != null &&
          resp.tierById(_rideTricycleTierId) != null &&
          VehicleRecommendationEngine.offerKekeForRide(
              distanceKm, _recConfig))
        _rideTricycleTierId,
    ];
    return ListView(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      // Same single-gutter rule as the delivery selector above.
      padding: const EdgeInsets.symmetric(horizontal: 0, vertical: 8),
      children: [
        const Text('Select Car Tier(s)',
            style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
        const SizedBox(height: 4),
        const Text(
          'Select all tiers to broadcast — first driver to accept wins.',
          style: TextStyle(fontSize: 12, color: Colors.grey),
        ),
        const SizedBox(height: 4),
        Text(
          '${_selectedRideTierIds.length} selected',
          style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
        ),
        const SizedBox(height: 12),
        ...ids.map((id) {
          final raw = resp?.tierById(id);
          final tier = raw == null
              ? null
              : _displayRideTier(raw, distanceKm < 0 ? 0 : distanceKm);
          final label = tier?.name ??
              (id[0].toUpperCase() + id.substring(1));
          final recommended = tier?.isRecommended ?? false;
          final selected = _selectedRideTierIds.contains(id);
          return _VehicleTierTile(
            key: Key('ride_tier_$id'),
            art: VehicleArt.fromTierId(id),
            title: label,
            subtitle: tier?.fareFormatted,
            selected: selected,
            isRecommended: recommended,
            // Keep at least one tier selected so the broadcast payload is
            // never empty (mirrors the delivery at-least-one constraint).
            onChanged: (_) {
              setState(() {
                if (selected && _selectedRideTierIds.length > 1) {
                  _selectedRideTierIds.remove(id);
                } else if (!selected) {
                  _selectedRideTierIds.add(id);
                }
              });
            },
          );
        }),
      ],
    );
  }

  String _vehicleCategoryLabel(VehicleCategory cat) {
    switch (cat) {
      case VehicleCategory.bicycle: return 'Bicycle';
      case VehicleCategory.motorcycle: return 'Motorcycle';
      case VehicleCategory.tricycle: return 'Tricycle (Keke)';
      case VehicleCategory.car: return 'Car / Sedan';
      case VehicleCategory.van: return 'Van';
      case VehicleCategory.truck: return 'Truck';
    }
  }

  /// Synchronously restores the GPS auto-fill slot from the cached device fix.
  ///
  /// Returns true when a cached fix existed and the slot was filled (no work
  /// left — the toggle completes as one synchronous setState); false when
  /// the caller must fall back to the async [_initPickupLocation] /
  /// [_initDropoffLocation] GPS round-trip. Either cache slot holds the same
  /// device position, so the pickup-side and drop-off-side fixes are
  /// interchangeable here. Must run inside setState with the
  /// `_isSelecting*` guards held (see the toggle handler) so the controller
  /// listeners treat the assigned text as already resolved.
  bool _restoreGpsSlot({required bool isPickup}) {
    final fix = _gpsPickupFix ?? _gpsDropoffFix;
    final address =
        _gpsPickupFix != null ? _gpsPickupAddress : _gpsDropoffAddress;
    if (fix == null || address == null || address.isEmpty) return false;
    if (isPickup) {
      _resolvedPickupQuery = address;
      _pickupController.text = address;
      _pickupLatLng = fix;
      _gpsPickupFix = fix;
      _gpsPickupAddress = address;
    } else {
      _resolvedDropoffQuery = address;
      _dropoffController.text = address;
      _dropoffLatLng = fix;
      _gpsDropoffFix = fix;
      _gpsDropoffAddress = address;
    }
    return true;
  }

  /// Opens the full-screen [PickOnMapScreen] so the customer can drag a pin
  /// to any location on the map to set either the pickup or drop-off location.
  ///
  /// [target] specifies whether we are picking the 'pickup' or 'destination'
  /// point. When omitted, it resolves automatically based on the currently
  /// focused field or the active workflow mode (Receive vs Send).
  ///
  /// On success the field is populated identically to a suggestion selection —
  /// locked query, coordinates set, route preview updated.
  Future<void> _openPickOnMap({String? target}) async {
    _hideSuggestionsOverlay();
    FocusScope.of(context).unfocus();

    final effectiveTarget = target ??
        (_pickupFocusNode.hasFocus
            ? 'pickup'
            : _dropoffFocusNode.hasFocus
                ? 'destination'
                : (_isReceiveMode && _pickupLatLng == null)
                    ? 'pickup'
                    : 'destination');

    final center = (effectiveTarget == 'pickup'
            ? (_pickupLatLng ??
                LocationService.lastKnownPosition ??
                _dropoffLatLng)
            : (_dropoffLatLng ??
                _pickupLatLng ??
                LocationService.lastKnownPosition)) ??
        const LatLng(6.4550575, 3.3839020); // Lagos Island fallback

    final result = await Navigator.of(context).push<PickOnMapResult>(
      MaterialPageRoute(
        builder: (_) => PickOnMapScreen(
          initialCenter: center,
          targetType: effectiveTarget,
        ),
      ),
    );

    if (!mounted || result == null) return;
    if (result.targetType == 'pickup' || effectiveTarget == 'pickup') {
      _applyResolvedPickupSuggestion(result.address, result.latLng);
    } else {
      _applyResolvedSuggestion(result.address, result.latLng);
    }
  }

  Widget _buildContextAwareModeSelector() {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: SegmentedButton<bool>(
        showSelectedIcon: false,
        segments: const [
          ButtonSegment(
            value: false,
            label: FittedBox(
              fit: BoxFit.scaleDown,
              child: Text('Sending Package', maxLines: 1),
            ),
            icon: Icon(Icons.outbox),
          ),
          ButtonSegment(
            value: true,
            label: FittedBox(
              fit: BoxFit.scaleDown,
              child: Text('Receiving Package', maxLines: 1),
            ),
            icon: Icon(Icons.inbox),
          ),
        ],
        selected: {_isReceivePackageMode},
        onSelectionChanged: (set) {
          final isReceive = set.first;
          // Silence the controller listeners for the synchronous slot swap:
          // every assignment below is an explicit resolve, not user typing,
          // so invalidation (coord wipe + route clear) must not run. The
          // flags reset before any await, keeping the async init paths
          // guarded the same way the suggestion-apply paths already are.
          _isSelectingSuggestion = true;
          _isSelectingPickupSuggestion = true;
          setState(() {
            _isReceivePackageMode = isReceive;
            if (isReceive) {
              _pickupController.clear();
              _pickupLatLng = null;
              _resolvedPickupQuery = null;
              // Swap names: booker is now the recipient (drop-off).
              _pickupNameController.clear();
              _pickupPhoneController.clear();
              _dropoffPhoneController.text = widget.user?.phoneNumber ?? '';
              _dropoffNameController.text = widget.user?.fullName ?? '';
              if (!_restoreGpsSlot(isPickup: false)) _initDropoffLocation();
            } else {
              _dropoffController.clear();
              _dropoffLatLng = null;
              _resolvedDropoffQuery = null;
              // Swap names: booker is now the sender (pickup).
              _dropoffNameController.clear();
              _dropoffPhoneController.clear();
              _pickupPhoneController.text = widget.user?.phoneNumber ?? '';
              _pickupNameController.text = widget.user?.fullName ?? '';
              if (!_restoreGpsSlot(isPickup: true)) _initPickupLocation();
            }
          });
          _isSelectingSuggestion = false;
          _isSelectingPickupSuggestion = false;
        },
      ),
    );
  }

  Widget _buildSecurityPinToggle() {
    final forced = _remoteKeys.forceDeliveryPinSystemWide;
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: SwitchListTile(
        value: forced ? true : _requireDeliveryPin,
        onChanged: forced ? null : (val) => setState(() => _requireDeliveryPin = val),
        title: Row(
          children: [
            const Expanded(
              child: Text(
                'Require Delivery PIN Verification',
                style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14),
              ),
            ),
            SettingsInfoButton(
              tooltipId: 'delivery_pin_verification',
              userId: widget.user?.uid,
              title: 'Delivery Security PIN',
              description:
                  'Recipient gives driver a 4-digit PIN at drop-off to complete delivery and prevent wrongful release.',
            ),
          ],
        ),
        subtitle: Text(
          forced
              ? 'Enforced System-Wide by Admin Override'
              : 'Recipient gives driver a 4-digit PIN at drop-off to complete delivery',
          style: const TextStyle(fontSize: 12),
        ),
        secondary: Icon(
          Icons.lock_clock,
          color: (_requireDeliveryPin || forced) ? Colors.amber.shade700 : Colors.grey,
        ),
      ),
    );
  }

  double get _currentPrimaryFare {
    final resp = _fareResponse;
    if (resp == null) return 0;
    final isDelivery = _selectedModeIndex == 0;
    if (isDelivery) {
      final firstCat = _selectedDeliveryCategories.isNotEmpty
          ? _selectedDeliveryCategories.first
          : VehicleCategory.motorcycle;
      final tierId = _deliveryTierIds[firstCat] ?? firstCat.name;
      final custom = _customTierFares[tierId];
      if (custom != null && custom > 0) return custom;
      return resp.tierById(tierId)?.fareAmount ?? 0;
    } else {
      final firstTier = _selectedRideTierIds.isNotEmpty
          ? _selectedRideTierIds.first
          : 'comfort';
      final custom = _customTierFares[firstTier];
      if (custom != null && custom > 0) return custom;
      return resp.tierById(firstTier)?.fareAmount ?? 0;
    }
  }

  Future<void> _openSplitPaymentSheet() async {
    final fare = _currentPrimaryFare;
    if (fare <= 0) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content:
              Text('Please select a vehicle category first to calculate fare.'),
        ),
      );
      return;
    }

    final result = await SplitPaymentSheet.show(
      context: context,
      totalFare: fare,
      userId: widget.user?.uid ?? '',
      initialSenderAmount: _splitSenderAmount,
    );

    if (result != null && mounted) {
      setState(() {
        _paymentMode = 'split';
        _splitSenderAmount = result.senderAmount;
        _splitReceiverAmount = result.receiverAmount;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Split confirmed: You pay ₦${result.senderAmount.toStringAsFixed(0)}, Receiver pays ₦${result.receiverAmount.toStringAsFixed(0)}',
          ),
        ),
      );
    }
  }

  /// Who-pays selector. Values are mode-agnostic on the wire (non-split
  /// collapses to `cash` at dispatch) — only the LABELS switch: delivery
  /// talks Sender/Receiver (a parcel changes hands), rides talk
  /// Booker/Rider (a person is moving). Split is identical in both.
  Widget _buildPaymentOptionSelector({required bool isDelivery}) {
    final splitMasterEnabled = _remoteKeys.splitPaymentMasterEnabled;
    final totalFare = _currentEstimatedFare;
    final availableWallet = _customerWalletBalance;
    final isDark = Theme.of(context).brightness == Brightness.dark;

    // Calculate smart breakdown
    double walletCoverage = 0.0;
    double cashToCollect = totalFare;
    if (_paymentMode == 'receiver_pays') {
      walletCoverage = 0.0;
      cashToCollect = totalFare;
    } else if (_paymentMode == 'split') {
      final senderShare = _splitSenderAmount ?? (totalFare / 2);
      final receiverShare = _splitReceiverAmount ?? (totalFare - senderShare);
      if (_paymentMethod == 'cash') {
        walletCoverage = 0.0;
        cashToCollect = totalFare;
      } else {
        walletCoverage = math.min(senderShare, availableWallet);
        final senderCash = math.max(0.0, senderShare - walletCoverage);
        cashToCollect = senderCash + receiverShare;
      }
    } else {
      // sender_pays
      if (_paymentMethod == 'cash') {
        walletCoverage = 0.0;
        cashToCollect = totalFare;
      } else {
        walletCoverage = math.min(totalFare, availableWallet);
        cashToCollect = math.max(0.0, totalFare - walletCoverage);
      }
    }

    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Text(
                  'Payment Mode',
                  style: TextStyle(fontWeight: FontWeight.bold, fontSize: 15),
                ),
                const Spacer(),
                SettingsInfoButton(
                  tooltipId: 'payment_mode',
                  userId: widget.user?.uid,
                  title: 'Payment Mode',
                  description:
                      'Choose who pays for the trip: Sender at pickup, Receiver at drop-off, or Split Payment between both.',
                ),
              ],
            ),
            const SizedBox(height: 10),

            // 1. PRIMARY ROW: [ Sender Pays ] [ Receiver Pays ] [ Split Payment ]
            // Matching the exact styling from the design specification, theme-aware:
            Container(
              padding: const EdgeInsets.all(3),
              decoration: BoxDecoration(
                color: isDark ? const Color(0xFF252530) : const Color(0xFFF3F4F6),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Row(
                children: [
                  Expanded(
                    child: _buildPaymentModeTab(
                      label: isDelivery ? 'Sender Pays' : 'Booker Pays',
                      isSelected: _paymentMode == 'sender_pays',
                      isDark: isDark,
                      onTap: () {
                        setState(() {
                          _paymentMode = 'sender_pays';
                          _splitSenderAmount = null;
                          _splitReceiverAmount = null;
                        });
                      },
                    ),
                  ),
                  Expanded(
                    child: _buildPaymentModeTab(
                      label: isDelivery ? 'Receiver Pays' : 'Rider Pays',
                      isSelected: _paymentMode == 'receiver_pays',
                      isDark: isDark,
                      onTap: () {
                        setState(() {
                          _paymentMode = 'receiver_pays';
                          _paymentMethod = 'cash'; // Enforce Cash Only for receiver pays
                          _splitSenderAmount = null;
                          _splitReceiverAmount = null;
                        });
                      },
                    ),
                  ),
                  Expanded(
                    child: _buildPaymentModeTab(
                      label: 'Split Payment',
                      isSelected: _paymentMode == 'split',
                      isEnabled: splitMasterEnabled,
                      isDark: isDark,
                      onTap: () async {
                        await _openSplitPaymentSheet();
                      },
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 12),

            // 2. PAYMENT METHOD SUB-OPTIONS: [ Auto ] [ Cash ] [ Wallet / Card ]
            if (_paymentMode == 'receiver_pays') ...[
              // Enforce Cash Only
              Container(
                width: double.infinity,
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                decoration: BoxDecoration(
                  color: isDark
                      ? const Color(0xFF78350F).withValues(alpha: 0.25)
                      : const Color(0xFFFEF3C7),
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(
                    color: isDark
                        ? const Color(0xFFF59E0B).withValues(alpha: 0.4)
                        : const Color(0xFFFDE68A),
                  ),
                ),
                child: Row(
                  children: [
                    Icon(
                      Icons.money_rounded,
                      size: 20,
                      color: isDark ? const Color(0xFFFBBF24) : const Color(0xFFD97706),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'Receiver Pays • Cash Only',
                            style: TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.bold,
                              color: isDark ? const Color(0xFFFBBF24) : const Color(0xFF92400E),
                            ),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            'Driver will collect ₦${totalFare.toStringAsFixed(0)} cash from Receiver at drop-off. No payment at pickup.',
                            style: TextStyle(
                              fontSize: 11,
                              color: isDark ? const Color(0xFFFDE68A) : const Color(0xFFB45309),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ] else ...[
              Text(
                'Payment Method',
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: isDark ? Colors.grey.shade400 : Colors.grey.shade700,
                ),
              ),
              const SizedBox(height: 6),
              Row(
                children: [
                  Expanded(
                    child: _buildPaymentMethodPill(
                      label: 'Auto',
                      subtitle: availableWallet > 0 ? 'Smart Split' : 'Cash',
                      icon: Icons.auto_awesome,
                      isSelected: _paymentMethod == 'auto',
                      isDark: isDark,
                      onTap: () => setState(() => _paymentMethod = 'auto'),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: _buildPaymentMethodPill(
                      label: 'Cash',
                      subtitle: 'Pay Driver',
                      icon: Icons.payments_outlined,
                      isSelected: _paymentMethod == 'cash',
                      isDark: isDark,
                      onTap: () => setState(() => _paymentMethod = 'cash'),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: _buildPaymentMethodPill(
                      label: 'Wallet / Card',
                      subtitle: '₦${availableWallet.toStringAsFixed(0)}',
                      icon: Icons.account_balance_wallet_outlined,
                      isSelected: _paymentMethod == 'wallet',
                      isDark: isDark,
                      onTap: () => setState(() => _paymentMethod = 'wallet'),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 10),

              // Breakdown Container
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(12),
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
                      children: [
                        Icon(
                          walletCoverage > 0
                              ? Icons.lock_clock_rounded
                              : Icons.info_outline_rounded,
                          size: 16,
                          color: walletCoverage > 0
                              ? (isDark ? const Color(0xFF34D399) : const Color(0xFF10B981))
                              : (isDark ? Colors.grey.shade400 : Colors.grey.shade700),
                        ),
                        const SizedBox(width: 6),
                        Text(
                          walletCoverage > 0
                              ? 'Wallet Escrow & Collection Breakdown'
                              : 'Payment Summary',
                          style: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.bold,
                            color: walletCoverage > 0
                                ? (isDark ? const Color(0xFF34D399) : const Color(0xFF047857))
                                : (isDark ? Colors.white : Colors.black87),
                          ),
                        ),
                        if (_paymentMode == 'split') ...[
                          const Spacer(),
                          InkWell(
                            onTap: _openSplitPaymentSheet,
                            child: Text(
                              'Edit Split',
                              style: TextStyle(
                                fontSize: 11,
                                fontWeight: FontWeight.bold,
                                color: Theme.of(context).colorScheme.primary,
                                decoration: TextDecoration.underline,
                              ),
                            ),
                          ),
                        ],
                      ],
                    ),
                    const SizedBox(height: 8),
                    if (walletCoverage > 0 && cashToCollect > 0) ...[
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Text(
                            'Wallet Escrow Lock: ₦${walletCoverage.toStringAsFixed(0)}',
                            style: TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.w600,
                              color: isDark ? const Color(0xFF34D399) : const Color(0xFF059669),
                            ),
                          ),
                          Text(
                            'Cash to Driver: ₦${cashToCollect.toStringAsFixed(0)}',
                            style: TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.bold,
                              color: isDark ? Colors.white : Colors.black87,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 4),
                      Text(
                        _paymentMode == 'split'
                            ? 'Sender pays ₦${walletCoverage.toStringAsFixed(0)} from wallet (+ cash if any) at pickup. Receiver pays remaining in cash at drop-off.'
                            : '₦${walletCoverage.toStringAsFixed(0)} locked from your wallet. Pay remaining ₦${cashToCollect.toStringAsFixed(0)} cash at pickup. No payment at drop-off.',
                        style: TextStyle(
                          fontSize: 11,
                          color: isDark ? Colors.grey.shade400 : Colors.grey.shade600,
                        ),
                      ),
                    ] else if (walletCoverage >= totalFare && totalFare > 0) ...[
                      Row(
                        children: [
                          const Icon(
                            Icons.check_circle_rounded,
                            size: 14,
                            color: Color(0xFF10B981),
                          ),
                          const SizedBox(width: 4),
                          Text(
                            '100% Wallet Prepaid (₦${totalFare.toStringAsFixed(0)})',
                            style: TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.bold,
                              color: isDark ? const Color(0xFF34D399) : const Color(0xFF059669),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 2),
                      Text(
                        'Total fare locked in wallet escrow. No cash needed during or after the ride.',
                        style: TextStyle(
                          fontSize: 11,
                          color: isDark ? Colors.grey.shade400 : Colors.grey.shade600,
                        ),
                      ),
                    ] else ...[
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Text(
                            'Total Cash to Collect:',
                            style: TextStyle(
                              fontSize: 12,
                              color: isDark ? Colors.grey.shade400 : Colors.grey.shade700,
                            ),
                          ),
                          Text(
                            '₦${totalFare.toStringAsFixed(0)}',
                            style: TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.bold,
                              color: isDark ? Colors.white : Colors.black87,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 2),
                      Text(
                        'Paid in cash to the driver at pickup.',
                        style: TextStyle(
                          fontSize: 11,
                          color: isDark ? Colors.grey.shade400 : Colors.grey.shade600,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ],
            if (!splitMasterEnabled)
              const Padding(
                padding: EdgeInsets.only(top: 6),
                child: Text(
                  'Split payment disabled globally by admin.',
                  style: TextStyle(fontSize: 11, color: Colors.grey),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildPaymentModeTab({
    required String label,
    required bool isSelected,
    required VoidCallback onTap,
    bool isEnabled = true,
    required bool isDark,
  }) {
    return InkWell(
      onTap: isEnabled ? onTap : null,
      borderRadius: BorderRadius.circular(9),
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 4),
        decoration: BoxDecoration(
          color: isSelected ? const Color(0xFFF59E0B) : Colors.transparent,
          borderRadius: BorderRadius.circular(9),
        ),
        alignment: Alignment.center,
        child: FittedBox(
          fit: BoxFit.scaleDown,
          child: Text(
            label,
            style: TextStyle(
              fontSize: 13,
              fontWeight: isSelected ? FontWeight.bold : FontWeight.w600,
              color: isSelected
                  ? Colors.black
                  : (isEnabled
                      ? (isDark ? const Color(0xFFE5E7EB) : const Color(0xFF374151))
                      : (isDark ? Colors.grey.shade600 : Colors.grey.shade400)),
            ),
            maxLines: 1,
          ),
        ),
      ),
    );
  }

  Widget _buildPaymentMethodPill({
    required String label,
    required String subtitle,
    required IconData icon,
    required bool isSelected,
    required VoidCallback onTap,
    required bool isDark,
  }) {
    final primary = Theme.of(context).colorScheme.primary;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(10),
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 6),
        decoration: BoxDecoration(
          color: isSelected
              ? primary.withValues(alpha: isDark ? 0.22 : 0.1)
              : (isDark ? const Color(0xFF252530) : Colors.white),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(
            color: isSelected
                ? primary
                : (isDark ? const Color(0xFF3A3A46) : Colors.grey.shade300),
            width: isSelected ? 1.5 : 1.0,
          ),
        ),
        child: Column(
          children: [
            Icon(
              icon,
              size: 18,
              color: isSelected
                  ? primary
                  : (isDark ? Colors.grey.shade300 : Colors.grey.shade700),
            ),
            const SizedBox(height: 3),
            Text(
              label,
              style: TextStyle(
                fontSize: 12,
                fontWeight: isSelected ? FontWeight.bold : FontWeight.w600,
                color: isSelected
                    ? primary
                    : (isDark ? Colors.white : Colors.black87),
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            Text(
              subtitle,
              style: TextStyle(
                fontSize: 10,
                color: isSelected
                    ? primary
                    : (isDark ? Colors.grey.shade400 : Colors.grey.shade600),
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ],
        ),
      ),
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
          pickupNameController: _pickupNameController,
          dropoffNameController: _dropoffNameController,
          pickupPhoneController: _pickupPhoneController,
          dropoffPhoneController: _dropoffPhoneController,
          onPhoneChanged: _onPhoneChanged,
        ),
        const SizedBox(height: 12),
        _buildSecurityPinToggle(),
        _buildPaymentOptionSelector(isDelivery: true),
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

    // NOTE: no delivery-PIN card here — rides have no recipient handoff,
    // so there is nothing to verify at drop-off. The toggle + card live
    // in [_buildDeliveryReview] only, and the server mints rides PIN-free
    // (see `isPinRequired` in functions/src/trips.ts).
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _RouteReviewCard(
          pickup: _pickupController.text,
          dropoff: _dropoffController.text,
          distanceKm: resp.distanceKm,
          durationMins: resp.durationMins,
          pickupNameController: _pickupNameController,
          dropoffNameController: _dropoffNameController,
          pickupPhoneController: _pickupPhoneController,
          dropoffPhoneController: _dropoffPhoneController,
          onPhoneChanged: _onPhoneChanged,
        ),
        const SizedBox(height: 12),
        _buildPaymentOptionSelector(isDelivery: false),
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

}

/// Inline route map preview showing route between pickup & dropoff.
///
/// Auto-fits camera bounds whenever both points are set or change, so
/// markers and the connecting route polyline stay fully visible. Renders a
/// green pickup marker, red drop-off marker, and an orange route line (OSRM
/// geometry with straight-line fallback supplied by the parent).
class _RouteMapPreview extends StatefulWidget {
  final LatLng pickup;
  final LatLng? dropoff;
  final List<LatLng> routePoints;
  final bool isLoadingRoute;

  /// Road distance in metres returned by the routing service.
  /// 0 when routing failed and a straight line is shown.
  final int distanceM;

  /// Road travel time in seconds returned by the routing service.
  /// 0 when routing failed and a straight line is shown.
  final int durationS;

  /// Camera padding when framing bounds.
  final double padding;

  const _RouteMapPreview({
    required this.pickup,
    this.dropoff,
    required this.routePoints,
    required this.isLoadingRoute,
    this.distanceM = 0,
    this.durationS = 0,
    this.padding = 88.0,
  });

  @override
  State<_RouteMapPreview> createState() => _RouteMapPreviewState();
}

class _RouteMapPreviewState extends State<_RouteMapPreview> {
  final SeSeMapController _mapController = SeSeMapController();

  /// Bounded auto-fit attempts for the current A/B pair. `newLatLngBounds`
  /// throws when the native view has no size yet (the common first-mount
  /// case) and the controller swallows it — so a single shot is not enough
  /// and the camera would sit at the midpoint zoom forever. Every attempt
  /// is idempotent (same bounds, dynamically zoomed for short and long
  /// trips alike); attempts stop after [_maxFitAttempts].
  int _fitAttempts = 0;
  static const int _maxFitAttempts = 4;
  static const Duration _fitRetryDelay = Duration(milliseconds: 400);

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
        oldWidget.routePoints.length != widget.routePoints.length ||
        oldWidget.padding != widget.padding) {
      // New bounds — restart the attempt budget so the reframe lands even
      // if the first post-layout shot misses.
      _fitAttempts = 0;
      _fitBounds();
    }
  }

  /// Fits the camera to contain both pins with padding, retrying on a short
  /// delay until the view is laid out. Never calls setState (camera moves
  /// don't rebuild), so delayed retries are safe under `mounted` alone and
  /// schedule no extra test frames.
  void _fitBounds() {
    if (!mounted || _fitAttempts >= _maxFitAttempts) return;
    _fitAttempts++;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (widget.dropoff == null) {
        // ignore: discarded_futures
        _mapController.move(widget.pickup, 14.5);
        return;
      }
      // ignore: discarded_futures
      _mapController.fitPoints(
        widget.pickup,
        widget.dropoff!,
        padding: widget.padding,
      );
      if (_fitAttempts < _maxFitAttempts) {
        Future.delayed(_fitRetryDelay, _fitBounds);
      }
    });
  }

  /// Manual reframe (fit-route FAB): restarts the attempt budget so one tap
  /// always drives a fresh fit, even long after mount.
  void _refitFromButton() {
    _fitAttempts = 0;
    _fitBounds();
  }

  @override
  Widget build(BuildContext context) {
    // Midpoint as the synchronous first-frame center; _fitBounds() then fits
    // both markers with padding after the controller is available.
    final pickup = widget.pickup;
    final dropoff = widget.dropoff;
    final center = dropoff != null
        ? LatLng(
            (pickup.latitude + dropoff.latitude) / 2,
            (pickup.longitude + dropoff.longitude) / 2,
          )
        : pickup;

    final markers = [
      SeSeMapView.pin(point: pickup, color: Colors.green),
      if (dropoff != null) SeSeMapView.pin(point: dropoff, color: Colors.red),
    ];

    final polylines = [
      if (widget.routePoints.isNotEmpty)
        SeSeMapView.route(points: widget.routePoints),
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
          SeSeMapView(
            // Route preview while browsing options: Google Maps.
            mapContext: MapContext.browsing,
            mapController: _mapController,
            initialCenter: center,
            initialZoom: 13.0,
            showMyLocation: true,
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
              onTap: _refitFromButton,
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
          // Route info badge — shown once real road data is available.
          // Hidden when distance is 0 (straight-line fallback) or while loading.
          if (!widget.isLoadingRoute &&
              widget.distanceM > 0 &&
              widget.durationS > 0)
            Positioned(
              top: 10,
              left: 0,
              right: 0,
              child: Center(
                child: Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                  decoration: BoxDecoration(
                    color: Colors.black.withAlpha(165),
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(Icons.route_outlined,
                          size: 14, color: Colors.white70),
                      const SizedBox(width: 5),
                      Text(
                        _formatDistance(widget.distanceM),
                        style: const TextStyle(
                            color: Colors.white,
                            fontSize: 13,
                            fontWeight: FontWeight.w600),
                      ),
                      const Text('  ·  ',
                          style: TextStyle(
                              color: Colors.white54, fontSize: 13)),
                      const Icon(Icons.access_time,
                          size: 13, color: Colors.white70),
                      const SizedBox(width: 4),
                      Text(
                        _formatDuration(widget.durationS),
                        style: const TextStyle(
                            color: Colors.white,
                            fontSize: 13,
                            fontWeight: FontWeight.w600),
                      ),
                    ],
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  /// Formats metres as "X.X km" (≥1 km) or "X m" (< 1 km).
  static String _formatDistance(int metres) {
    if (metres >= 1000) {
      return '${(metres / 1000).toStringAsFixed(1)} km';
    }
    return '$metres m';
  }

  /// Formats seconds as "X h Y min" or "Y min".
  static String _formatDuration(int seconds) {
    final mins = (seconds / 60).round();
    if (mins >= 60) {
      final h = mins ~/ 60;
      final m = mins % 60;
      return m > 0 ? '$h h $m min' : '$h h';
    }
    return '$mins min';
  }
}



/// Route summary card shown in Step 3, with tagged pickup / drop-off
/// sections, contact name fields, and contact phone fields for driver coordination.
class _RouteReviewCard extends StatelessWidget {
  final String pickup;
  final String dropoff;
  final double distanceKm;
  final double durationMins;
  final TextEditingController pickupNameController;
  final TextEditingController dropoffNameController;
  final TextEditingController pickupPhoneController;
  final TextEditingController dropoffPhoneController;
  final VoidCallback? onPhoneChanged;

  const _RouteReviewCard({
    required this.pickup,
    required this.dropoff,
    required this.distanceKm,
    required this.durationMins,
    required this.pickupNameController,
    required this.dropoffNameController,
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
              child: TextField(
                controller: pickupNameController,
                decoration: InputDecoration(
                  labelText: 'Pickup Contact Name (Optional)',
                  hintText: 'e.g. Sender or pickup contact name',
                  prefixIcon: const Icon(Icons.person_outline, size: 20),
                  suffixIcon: ValueListenableBuilder<TextEditingValue>(
                    valueListenable: pickupNameController,
                    builder: (context, value, _) {
                      if (value.text.isEmpty) return const SizedBox.shrink();
                      return IconButton(
                        icon: const Icon(Icons.clear, size: 18),
                        onPressed: () {
                          pickupNameController.clear();
                          onPhoneChanged?.call();
                        },
                      );
                    },
                  ),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(10),
                  ),
                  contentPadding:
                      const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
                ),
                onChanged: (_) => onPhoneChanged?.call(),
              ),
            ),
            const SizedBox(height: 8),
            Padding(
              padding: const EdgeInsets.only(left: 22.0),
              child: SesePhoneInputField(
                controller: pickupPhoneController,
                labelText: 'Pickup Phone Number (Optional)',
                hintText: 'Leave empty to skip — e.g. call me on arrival',
                autoValidateMode: AutovalidateMode.onUserInteraction,
                onPickContact: () async {
                  final res = await ContactsService.pickContact(context);
                  if (res != null && res.phoneNumber.isNotEmpty) {
                    pickupPhoneController.text =
                        nationalDisplayDigits(res.phoneNumber);
                    if (res.displayName.isNotEmpty &&
                        pickupNameController.text.trim().isEmpty) {
                      pickupNameController.text = res.displayName;
                    }
                    onPhoneChanged?.call();
                  }
                },
                onChanged: (e164) {
                  // No echo-back write: the formatter owns the text field
                  // (see onPhoneChanged guard below).
                  onPhoneChanged?.call();
                },
                validator: (value) => null,
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
              child: TextField(
                controller: dropoffNameController,
                decoration: InputDecoration(
                  labelText: 'Drop-off Contact Name (Optional)',
                  hintText: 'e.g. Recipient name',
                  prefixIcon: const Icon(Icons.person_outline, size: 20),
                  suffixIcon: ValueListenableBuilder<TextEditingValue>(
                    valueListenable: dropoffNameController,
                    builder: (context, value, _) {
                      if (value.text.isEmpty) return const SizedBox.shrink();
                      return IconButton(
                        icon: const Icon(Icons.clear, size: 18),
                        onPressed: () {
                          dropoffNameController.clear();
                          onPhoneChanged?.call();
                        },
                      );
                    },
                  ),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(10),
                  ),
                  contentPadding:
                      const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
                ),
                onChanged: (_) => onPhoneChanged?.call(),
              ),
            ),
            const SizedBox(height: 8),
            Padding(
              padding: const EdgeInsets.only(left: 24.0),
              child: SesePhoneInputField(
                controller: dropoffPhoneController,
                labelText: 'Drop-off Contact Phone Number (Optional)',
                hintText: 'Leave empty to skip — e.g. call me on arrival',
                autoValidateMode: AutovalidateMode.onUserInteraction,
                onPickContact: () async {
                  final res = await ContactsService.pickContact(context);
                  if (res != null && res.phoneNumber.isNotEmpty) {
                    dropoffPhoneController.text =
                        nationalDisplayDigits(res.phoneNumber);
                    if (res.displayName.isNotEmpty &&
                        dropoffNameController.text.trim().isEmpty) {
                      dropoffNameController.text = res.displayName;
                    }
                    onPhoneChanged?.call();
                  }
                },
                onChanged: (e164) {
                  // No echo-back (see pickup field + onPhoneChanged guard).
                  onPhoneChanged?.call();
                },
                validator: (value) => null,
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

/// Custom Vehicle Tier Selection Card with expanded vehicle artwork,
/// full width title allocation, and compact sub-row "Recommended" chip.
class _VehicleTierTile extends StatelessWidget {
  final VehicleArt art;
  final String title;
  final String? subtitle;
  final bool selected;
  final bool isRecommended;
  final ValueChanged<bool> onChanged;

  const _VehicleTierTile({
    super.key,
    required this.art,
    required this.title,
    this.subtitle,
    required this.selected,
    required this.isRecommended,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      decoration: BoxDecoration(
        color: selected
            ? AppColors.seseGold.withValues(alpha: 0.08)
            : (isDark ? const Color(0xFF252530) : Colors.grey.shade50),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: selected
              ? AppColors.seseGold
              : (isDark ? const Color(0xFF3A3A46) : Colors.grey.shade200),
          width: selected ? 2.0 : 1.0,
        ),
        boxShadow: selected
            ? [
                BoxShadow(
                  color: AppColors.seseGold.withValues(alpha: 0.15),
                  blurRadius: 8,
                  offset: const Offset(0, 2),
                )
              ]
            : null,
      ),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: () => onChanged(!selected),
          borderRadius: BorderRadius.circular(16),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            child: Row(
              children: [
                // 1. Prominent, Larger Vehicle Image (80px width)
                SizedBox(
                  width: 80,
                  child: VehicleIllustration(
                    art: art,
                    height: 48,
                    selected: selected,
                  ),
                ),
                const SizedBox(width: 14),

                // 2. Text Column (Expanded - 100% Full Width for Title & Pricing)
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        title,
                        style: TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.bold,
                          color: isDark ? Colors.white : Colors.black87,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      if (subtitle != null && subtitle!.isNotEmpty) ...[
                        const SizedBox(height: 2),
                        Text(
                          subtitle!,
                          style: const TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w700,
                            color: Color(0xFFD97706),
                          ),
                        ),
                      ],
                      if (isRecommended) ...[
                        const SizedBox(height: 4),
                        // 3. Compact "Recommended" Chip in sub-row
                        Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 6, vertical: 2),
                          decoration: BoxDecoration(
                            color: isDark
                                ? const Color(0xFF78350F).withValues(alpha: 0.3)
                                : const Color(0xFFFEF3C7),
                            borderRadius: BorderRadius.circular(6),
                            border: Border.all(
                              color: isDark
                                  ? const Color(0xFFF59E0B).withValues(alpha: 0.4)
                                  : const Color(0xFFF59E0B).withValues(alpha: 0.3),
                            ),
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(
                                Icons.star_rounded,
                                size: 12,
                                color: isDark ? const Color(0xFFFBBF24) : const Color(0xFFD97706),
                              ),
                              const SizedBox(width: 3),
                              Text(
                                'Recommended',
                                style: TextStyle(
                                  fontSize: 10,
                                  fontWeight: FontWeight.bold,
                                  color: isDark ? const Color(0xFFFDE68A) : const Color(0xFF92400E),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
                const SizedBox(width: 10),

                // 4. Selection Checkbox/Indicator
                Container(
                  width: 24,
                  height: 24,
                  decoration: BoxDecoration(
                    color: selected ? AppColors.seseGold : Colors.transparent,
                    shape: BoxShape.circle,
                    border: Border.all(
                      color: selected ? AppColors.seseGold : Colors.grey.shade400,
                      width: 2,
                    ),
                  ),
                  child: selected
                      ? const Icon(
                          Icons.check,
                          size: 16,
                          color: Colors.black,
                        )
                      : null,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}


