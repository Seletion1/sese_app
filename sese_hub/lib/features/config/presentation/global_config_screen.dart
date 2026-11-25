import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:flutter/material.dart';
import 'package:sese_core/sese_core.dart';
import '../services/system_config_service.dart';
import '../../dashboard/presentation/hub_module_shell.dart';
import '../../staff/services/hub_access_service.dart';
import '../../settings/map_api_key_config_screen.dart';

class GlobalConfigScreen extends StatefulWidget {
  final SystemConfigService configService;

  /// RBAC context for per-section gating (null = no gate: tests, previews).
  /// The dashboard always passes the staffer's real grants.
  final List<String>? permissions;
  final UserRole? staffRole;
  final bool? isOwner;

  const GlobalConfigScreen({
    super.key,
    required this.configService,
    this.permissions,
    this.staffRole,
    this.isOwner,
  });

  @override
  State<GlobalConfigScreen> createState() => _GlobalConfigScreenState();
}

class _GlobalConfigScreenState extends State<GlobalConfigScreen> {
  List<RegionConfig> _allConfigs = [];
  bool _loading = true;
  bool _saving = false;
  bool _runningBackfill = false;

  Future<void> _triggerSequentialIdBackfill({bool resetAll = true}) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Row(
          children: [
            Icon(Icons.sync, color: AppColors.seseGold),
            SizedBox(width: 8),
            Text('Sync Sequential IDs'),
          ],
        ),
        content: Text(
          resetAll
              ? 'This will sort all Customers, Drivers, and Hub Staff strictly by earliest registration date, assign unique sequential IDs (SC0001..., SD0001..., SH0001...) with zero duplicates, and set dedicated counters (counters/SC, counters/SD, counters/SH) to the highest issued number.\n\nProceed?'
              : 'This will assign sequential IDs to any records currently missing them.\n\nProceed?',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: FilledButton.styleFrom(backgroundColor: AppColors.seseGold, foregroundColor: Colors.black),
            child: const Text('Run Sync'),
          ),
        ],
      ),
    );
    if (confirm != true || !mounted) return;

    setState(() => _runningBackfill = true);
    try {
      final callable = FirebaseFunctions.instance.httpsCallable('backfillSequentialIds');
      final result = await callable.call({'resetAll': resetAll});
      final data = Map<String, dynamic>.from(result.data as Map);
      final results = Map<String, dynamic>.from(data['results'] as Map? ?? {});
      if (!mounted) return;
      showDialog(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Row(
            children: [
              Icon(Icons.check_circle, color: Colors.green),
              SizedBox(width: 8),
              Text('Sync Completed'),
            ],
          ),
          content: Text(
            'Sequential Member ID audit complete:\n\n'
            '• Verified customers updated: ${results['customersSequentialAssigned'] ?? 0} (Counter: ${results['customerCounterSet'] ?? 0})\n'
            '• Verified drivers updated: ${results['driversSequentialAssigned'] ?? 0} (Counter: ${results['driverCounterSet'] ?? 0})\n'
            '• Staff updated: ${results['staffSequentialAssigned'] ?? 0} (Counter: ${results['staffCounterSet'] ?? 0})',
          ),
          actions: [
            FilledButton(
              onPressed: () => Navigator.pop(ctx),
              style: FilledButton.styleFrom(backgroundColor: AppColors.seseGold, foregroundColor: Colors.black),
              child: const Text('OK'),
            ),
          ],
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Backfill failed: $e'),
          backgroundColor: Colors.red,
        ),
      );
    } finally {
      if (mounted) setState(() => _runningBackfill = false);
    }
  }

  // Selected Scope
  String _selectedScope = 'global_default'; // 'global_default', 'country', 'state'
  String _countryCode = 'NG';
  String _stateOrRegion = 'Lagos';
  String _currencyCode = 'NGN';
  String _currencySymbol = '₦';
  double _regionalSurgeMultiplier = 1.0;

  // Controllers for vehicle pricing: [category] -> {baseFee, distanceRate, timeRate, surge}
  final Map<VehicleCategory, TextEditingController> _baseFeeControllers = {};
  final Map<VehicleCategory, TextEditingController> _distRateControllers = {};
  final Map<VehicleCategory, TextEditingController> _timeRateControllers = {};
  final Map<VehicleCategory, TextEditingController> _surgeControllers = {};

  // Controllers for Car / Sedan Tiering
  final _comfortYearCtrl = TextEditingController(text: '2009');
  final _premiumMinYearCtrl = TextEditingController(text: '2010');
  final _premiumMaxYearCtrl = TextEditingController(text: '2019');
  final _luxeMinYearCtrl = TextEditingController(text: '2020');

  final _comfortLabelCtrl = TextEditingController(text: 'Standard / Comfort');
  final _premiumLabelCtrl = TextEditingController(text: 'Executive / Premium');
  final _luxeLabelCtrl = TextEditingController(text: 'Luxe / Super');

  final _comfortMultCtrl = TextEditingController(text: '1.0');
  final _premiumMultCtrl = TextEditingController(text: '1.35');
  final _luxeMultCtrl = TextEditingController(text: '1.75');

  // Driver Commission & Dispatch Settings (DailyStreakConfig).
  bool _autoArrivalEnabled = true;
  final _baseCommissionCtrl = TextEditingController(text: '20.0');
  final _noShowWaitCtrl = TextEditingController(text: '10');
  final _autoArrivalCountdownCtrl = TextEditingController(text: '5');

  // Multi-driver Bidding Settings
  final _maxVisibleBidsCtrl = TextEditingController(text: '5');

  // Vehicle recommendation thresholds (system_configs/vehicle_recommendations).
  // Global singleton, not per-scope: one set of distance bands applies
  // platform-wide. Reads/writes go through the shared sese_core service so
  // the hub and the ride app never disagree on the doc shape.
  final _bicycleMaxCtrl = TextEditingController(text: '10.0');
  final _kekeMaxCtrl = TextEditingController(text: '5.0');
  final _motorcycleMinCtrl = TextEditingController(text: '10.0');

  // Super Admin Dispatch Console (system_settings/dispatch tunables).
  // Backend clamps into safe bands; changes apply within ~60s.
  final _radiusCtrl = TextEditingController(text: '15');
  final _tier1RadiusCtrl = TextEditingController(text: '3');
  final _tier1TimeoutCtrl = TextEditingController(text: '15');
  final _pingTimeoutCtrl = TextEditingController(text: '15');
  final _repingIntervalCtrl = TextEditingController(text: '30');
  final _candidateLimitCtrl = TextEditingController(text: '25');
  final _maxSequentialDriversCtrl = TextEditingController(text: '1');
  final _publicPoolDurationCtrl = TextEditingController(text: '60');
  final _bidCountdownSecCtrl = TextEditingController(text: '15');
  final _cameraPickupDwellCtrl = TextEditingController(text: '5');
  final _cameraDropoffDwellCtrl = TextEditingController(text: '2');
  final _maxOfferBoostPctCtrl = TextEditingController(text: '100');
  bool _allowStackedOrders = true;
  bool _allowBidding = true;
  final _maxDistanceToDropoffKmCtrl = TextEditingController(text: '2.0');
  final _maxRemainingTimeMinutesCtrl = TextEditingController(text: '10');
  final _dispatchReferralCommissionPercentCtrl = TextEditingController(text: '1.0');
  final _dispatchStandardReferralDurationDaysCtrl = TextEditingController(text: '365');
  final _dispatchAdminReferralDurationDaysCtrl = TextEditingController(text: '548');

  // Map & API Key Management Controllers (/system_config/api_keys)
  final _googleAndroidKeyCtrl = TextEditingController();
  final _googleIosKeyCtrl = TextEditingController();
  final _googleWebKeyCtrl = TextEditingController();
  final _mapboxAndroidTokenCtrl = TextEditingController();
  final _mapboxIosTokenCtrl = TextEditingController();
  final _mapboxWebTokenCtrl = TextEditingController();

  // Financial System Parameters Controllers (/system_configs/financials)
  final _minWalletBalanceToOnlineCtrl = TextEditingController(text: '1.0');
  final _minTopUpAmountCtrl = TextEditingController(text: '1300');
  final _userReferralCommissionRateCtrl = TextEditingController(text: '1.0');
  final _agentReferralCommissionRateCtrl = TextEditingController(text: '2.0');
  final _standardReferralDurationDaysCtrl = TextEditingController(text: '365');
  final _agentReferralDurationDaysCtrl = TextEditingController(text: '547');

  // Remote Keys & API Configuration Controllers (/system_config/remote_keys)
  final _paystackPublicKeyCtrl = TextEditingController();
  final _paystackSecretKeyCtrl = TextEditingController();
  final _opayMerchantIdCtrl = TextEditingController();
  final _opayPublicKeyCtrl = TextEditingController();
  final _opaySecretKeyCtrl = TextEditingController();
  final _googleMapsApiKeyCtrl = TextEditingController();
  final _mapboxApiKeyCtrl = TextEditingController();
  final _mapboxStyleCtrl =
      TextEditingController(text: GlobalMapConfig.defaultMapboxStyle);
  final _googleQuotaCapCtrl = TextEditingController(text: '20000');
  final _mapboxQuotaCapCtrl = TextEditingController(text: '50000');
  final _resendApiKeyCtrl = TextEditingController();
  final _osmTileServerUrlCtrl = TextEditingController();
  final _remoteMinTopUpCtrl = TextEditingController(text: '1000');
  final _maxCashTripAmountCtrl = TextEditingController(text: '50000');
  String _activeMapProvider = 'google';
  String _manualOverrideProvider = 'auto';

  /// Per-feature provider pins, keyed by [MapFeature.code]. `'auto'` (or
  /// absent) follows the global chain above.
  Map<String, String> _featureProviders = {};
  bool _appMaintenanceMode = false;
  bool _splitPaymentMasterEnabled = true;
  bool _forceDeliveryPinSystemWide = false;
  bool _requireDriverCashVerification = true;
  bool _enablePaystack = true;
  bool _enableOpay = true;
  bool _obscurePaystackPublic = true;
  bool _obscurePaystackSecret = true;
  bool _obscureOpayPublic = true;
  bool _obscureOpaySecret = true;
  bool _obscureResendKey = true;

  // Driver Resting Break & Timer Configuration
  final _driverBreakOption1Ctrl = TextEditingController(text: '30');
  final _driverBreakOption2Ctrl = TextEditingController(text: '60');
  final _dropoffRadiusCtrl = TextEditingController(text: '500');
  final _freeWaitingMinutesCtrl = TextEditingController(text: '10');
  final _waitingRatePerMinuteCtrl = TextEditingController(text: '20');
  bool _driverBreakEnabled = true;
  bool _enableWaitingTimeBilling = true;
  bool _enableCancellationLock = true;

  @override
  void initState() {
    super.initState();
    for (final cat in VehicleCategory.values) {
      _baseFeeControllers[cat] = TextEditingController();
      _distRateControllers[cat] = TextEditingController();
      _timeRateControllers[cat] = TextEditingController();
      _surgeControllers[cat] = TextEditingController();
    }
    _loadConfigurations();
  }

  @override
  void dispose() {
    for (final c in _baseFeeControllers.values) {
      c.dispose();
    }
    for (final c in _distRateControllers.values) {
      c.dispose();
    }
    for (final c in _timeRateControllers.values) {
      c.dispose();
    }
    for (final c in _surgeControllers.values) {
      c.dispose();
    }
    _comfortYearCtrl.dispose();
    _premiumMinYearCtrl.dispose();
    _premiumMaxYearCtrl.dispose();
    _luxeMinYearCtrl.dispose();
    _comfortLabelCtrl.dispose();
    _premiumLabelCtrl.dispose();
    _luxeLabelCtrl.dispose();
    _comfortMultCtrl.dispose();
    _premiumMultCtrl.dispose();
    _luxeMultCtrl.dispose();
    _baseCommissionCtrl.dispose();
    _noShowWaitCtrl.dispose();
    _autoArrivalCountdownCtrl.dispose();
    _maxVisibleBidsCtrl.dispose();
    _bicycleMaxCtrl.dispose();
    _kekeMaxCtrl.dispose();
    _motorcycleMinCtrl.dispose();
    _radiusCtrl.dispose();
    _tier1RadiusCtrl.dispose();
    _tier1TimeoutCtrl.dispose();
    _pingTimeoutCtrl.dispose();
    _repingIntervalCtrl.dispose();
    _candidateLimitCtrl.dispose();
    _maxSequentialDriversCtrl.dispose();
    _publicPoolDurationCtrl.dispose();
    _bidCountdownSecCtrl.dispose();
    _cameraPickupDwellCtrl.dispose();
    _cameraDropoffDwellCtrl.dispose();
    _maxOfferBoostPctCtrl.dispose();
    _dispatchReferralCommissionPercentCtrl.dispose();
    _dispatchStandardReferralDurationDaysCtrl.dispose();
    _dispatchAdminReferralDurationDaysCtrl.dispose();
    _minWalletBalanceToOnlineCtrl.dispose();
    _minTopUpAmountCtrl.dispose();
    _userReferralCommissionRateCtrl.dispose();
    _agentReferralCommissionRateCtrl.dispose();
    _standardReferralDurationDaysCtrl.dispose();
    _agentReferralDurationDaysCtrl.dispose();
    _paystackPublicKeyCtrl.dispose();
    _paystackSecretKeyCtrl.dispose();
    _opayMerchantIdCtrl.dispose();
    _opayPublicKeyCtrl.dispose();
    _opaySecretKeyCtrl.dispose();
    _googleMapsApiKeyCtrl.dispose();
    _mapboxApiKeyCtrl.dispose();
    _mapboxStyleCtrl.dispose();
    _googleQuotaCapCtrl.dispose();
    _mapboxQuotaCapCtrl.dispose();
    _resendApiKeyCtrl.dispose();
    _osmTileServerUrlCtrl.dispose();
    _remoteMinTopUpCtrl.dispose();
    _maxCashTripAmountCtrl.dispose();
    _driverBreakOption1Ctrl.dispose();
    _driverBreakOption2Ctrl.dispose();
    _dropoffRadiusCtrl.dispose();
    _freeWaitingMinutesCtrl.dispose();
    _waitingRatePerMinuteCtrl.dispose();
    super.dispose();
  }

  Future<void> _loadConfigurations({bool silent = false}) async {
    if (!silent) {
      setState(() => _loading = true);
    }
    final configs = await widget.configService.getAllConfigs();
    if (!mounted) return;
    final maxBids = await widget.configService.getMaxVisibleBids();
    if (!mounted) return;
    final tuning = await widget.configService.getDispatchTuning();
    if (!mounted) return;
    final vehicleRec =
        await const VehicleRecommendationService().getConfig();
    if (!mounted) return;
    final finConfig = await const FinancialConfigService().getConfig();
    if (!mounted) return;
    final remoteKeys = await const RemoteKeysService().fetchRemoteKeys();
    if (!mounted) return;
    final apiKeys = await const ApiKeysService().fetchApiKeys();
    if (!mounted) return;
    String? googleCapText;
    String? mapboxCapText;
    try {
      final quotas = await FirebaseFirestore.instance
          .collection('system_config')
          .doc('map_quotas')
          .get();
      final qd = quotas.data();
      if (qd != null) {
        int? capOf(dynamic v) {
          if (v is num) return v.toInt();
          if (v is String) return int.tryParse(v.trim());
          return null;
        }
        final g = capOf(qd['googleMonthlyCap']);
        final m = capOf(qd['mapboxMonthlyCap']);
        if (g != null && g > 0) googleCapText = g.toString();
        if (m != null && m > 0) mapboxCapText = m.toString();
      }
    } catch (_) {}

    if (!mounted) return;
    setState(() {
      _allConfigs = configs;
      if (!silent) {
        _paystackPublicKeyCtrl.text = remoteKeys.paystackPublicKey;
        _opayMerchantIdCtrl.text = remoteKeys.opayMerchantId;
        _opayPublicKeyCtrl.text = remoteKeys.opayPublicKey;
        _enablePaystack = remoteKeys.enablePaystack;
        _enableOpay = remoteKeys.enableOpay;
        _googleMapsApiKeyCtrl.text = remoteKeys.googleMapsApiKey;
      _mapboxApiKeyCtrl.text = remoteKeys.mapboxToken;
      _resendApiKeyCtrl.text = remoteKeys.resendApiKey;
      _activeMapProvider =
          GlobalMapConfig(activeProvider: remoteKeys.activeMapProvider).normalizedProvider;
      _manualOverrideProvider =
          remoteKeys.manualOverrideProvider.isEmpty ? 'auto' : remoteKeys.manualOverrideProvider;
      _featureProviders = Map<String, String>.from(remoteKeys.featureProviders);
      final loadedStyle = remoteKeys.mapboxStyle.trim();
      _mapboxStyleCtrl.text = loadedStyle.isNotEmpty
          ? loadedStyle
          : GlobalMapConfig.defaultMapboxStyle;
      if (googleCapText != null) _googleQuotaCapCtrl.text = googleCapText;
      if (mapboxCapText != null) _mapboxQuotaCapCtrl.text = mapboxCapText;
      _osmTileServerUrlCtrl.text = remoteKeys.osmTileServerUrl.trim();
      _remoteMinTopUpCtrl.text = remoteKeys.minimumWalletTopUp.toStringAsFixed(0);
      _maxCashTripAmountCtrl.text = remoteKeys.maxCashTripAmountNaira.toStringAsFixed(0);
      _appMaintenanceMode = remoteKeys.appMaintenanceMode;
      _splitPaymentMasterEnabled = remoteKeys.splitPaymentMasterEnabled;
      _forceDeliveryPinSystemWide = remoteKeys.forceDeliveryPinSystemWide;
      _requireDriverCashVerification = remoteKeys.requireDriverCashVerification;
      _driverBreakOption1Ctrl.text = remoteKeys.driverBreakOption1Minutes.toString();
      _driverBreakOption2Ctrl.text = remoteKeys.driverBreakOption2Minutes.toString();
      _driverBreakEnabled = remoteKeys.driverBreakEnabled;
      _dropoffRadiusCtrl.text = remoteKeys.dropoffCompletionRadiusMeters.toStringAsFixed(0);
      _maxVisibleBidsCtrl.text = maxBids.toString();
      _radiusCtrl.text = tuning.dispatchRadiusKm.toString();
      _tier1RadiusCtrl.text = tuning.tier1RadiusKm.toString();
      _tier1TimeoutCtrl.text = tuning.tier1TimeoutSec.toString();
      _pingTimeoutCtrl.text = tuning.pingTimeoutSec.toString();
      _repingIntervalCtrl.text = tuning.repingIntervalSec.toString();
      _candidateLimitCtrl.text = tuning.candidateLimit.toString();
      _maxSequentialDriversCtrl.text = tuning.maxSequentialDrivers.toString();
      _publicPoolDurationCtrl.text = tuning.publicPoolDurationMin.toString();
      _bidCountdownSecCtrl.text = tuning.bidCountdownSec.toString();
      _cameraPickupDwellCtrl.text = tuning.cameraPickupDwellSec.toString();
      _cameraDropoffDwellCtrl.text = tuning.cameraDropoffDwellSec.toString();
      _maxOfferBoostPctCtrl.text = tuning.maxOfferBoostPct.toStringAsFixed(0);
      _allowStackedOrders = tuning.allowStackedOrders;
      _allowBidding = tuning.allowBidding;
      _maxDistanceToDropoffKmCtrl.text = tuning.maxDistanceToDropoffKm.toString();
      _maxRemainingTimeMinutesCtrl.text = tuning.maxRemainingTimeMinutes.toString();
      _dispatchReferralCommissionPercentCtrl.text = tuning.referralCommissionPercent.toString();
      _dispatchStandardReferralDurationDaysCtrl.text = tuning.standardReferralDurationDays.toString();
      _dispatchAdminReferralDurationDaysCtrl.text = tuning.adminReferralDurationDays.toString();

      _googleAndroidKeyCtrl.text = apiKeys.googleAndroidKey;
      _googleIosKeyCtrl.text = apiKeys.googleIosKey;
      _googleWebKeyCtrl.text = apiKeys.googleWebKey;
      _mapboxAndroidTokenCtrl.text = apiKeys.mapboxAndroidToken;
      _mapboxIosTokenCtrl.text = apiKeys.mapboxIosToken;
      _mapboxWebTokenCtrl.text = apiKeys.mapboxWebToken;
      _bicycleMaxCtrl.text =
          vehicleRec.bicycleMaxDistanceKm.toString();
      _kekeMaxCtrl.text = vehicleRec.kekeMaxDistanceKm.toString();
      _motorcycleMinCtrl.text =
          vehicleRec.motorcycleMinDistanceKm.toString();
      _minWalletBalanceToOnlineCtrl.text = finConfig.minWalletBalanceToOnline.toStringAsFixed(2);
      _minTopUpAmountCtrl.text = finConfig.minTopUpAmount.toStringAsFixed(0);
      _userReferralCommissionRateCtrl.text = (finConfig.userReferralCommissionRate * 100).toStringAsFixed(2);
      _agentReferralCommissionRateCtrl.text = (finConfig.agentReferralCommissionRate * 100).toStringAsFixed(2);
      _standardReferralDurationDaysCtrl.text = finConfig.standardReferralDurationDays.toString();
      _agentReferralDurationDaysCtrl.text = finConfig.agentReferralDurationDays.toString();
      _loading = false;
    }
  });
  if (!silent) {
    _populateFormForCurrentSelection();
  }
  }

  String get _currentDocId {
    if (_selectedScope == 'global_default') return 'global_default';
    if (_selectedScope == 'country') return 'country_$_countryCode';
    final statePart = _stateOrRegion.trim().toUpperCase().replaceAll(' ', '_');
    return 'state_${_countryCode}_$statePart';
  }

  void _populateFormForCurrentSelection() {
    final docId = _currentDocId;
    final existing = _allConfigs.firstWhere(
      (c) => c.id == docId,
      orElse: () {
        // Fallback resolve
        return ConfigResolutionEngine.resolveFromList(
          allConfigs: _allConfigs,
          countryCode: _countryCode,
          stateOrRegion: _selectedScope == 'state' ? _stateOrRegion : null,
        );
      },
    );

    _currencyCode = existing.currencyCode;
    _currencySymbol = existing.currencySymbol;
    _regionalSurgeMultiplier = existing.regionalSurgeMultiplier;

    for (final cat in VehicleCategory.values) {
      final rate = existing.pricingRates[cat] ??
          RegionConfig.globalDefault().pricingRates[cat]!;
      _baseFeeControllers[cat]?.text = rate.baseFee.toStringAsFixed(0);
      _distRateControllers[cat]?.text = rate.distanceRatePerKm.toStringAsFixed(0);
      _timeRateControllers[cat]?.text = rate.timeRatePerMinute.toStringAsFixed(0);
      _surgeControllers[cat]?.text = rate.surgeMultiplier.toStringAsFixed(2);
    }

    final tiers = existing.carTierThresholds;
    _comfortYearCtrl.text = tiers.comfortMaxYear.toString();
    _premiumMinYearCtrl.text = tiers.premiumMinYear.toString();
    _premiumMaxYearCtrl.text = tiers.premiumMaxYear.toString();
    _luxeMinYearCtrl.text = tiers.luxeMinYear.toString();

    _comfortLabelCtrl.text = tiers.comfortLabel;
    _premiumLabelCtrl.text = tiers.premiumLabel;
    _luxeLabelCtrl.text = tiers.luxeLabel;

    _comfortMultCtrl.text = tiers.comfortMultiplier.toString();
    _premiumMultCtrl.text = tiers.premiumMultiplier.toString();
    _luxeMultCtrl.text = tiers.luxeMultiplier.toString();

    final daily = existing.dailyStreakConfig;
    _autoArrivalEnabled = daily.autoArrivalEnabled;
    _enableWaitingTimeBilling = daily.enableWaitingTimeBilling;
    _freeWaitingMinutesCtrl.text = daily.freeWaitingMinutes.toString();
    _waitingRatePerMinuteCtrl.text = daily.waitingRatePerMinute.toStringAsFixed(0);
    _enableCancellationLock = daily.enableCancellationLock;
    _baseCommissionCtrl.text =
        (daily.baseCommissionRate * 100).toStringAsFixed(1);
    _noShowWaitCtrl.text = daily.noShowWaitMinutes.toString();
    _autoArrivalCountdownCtrl.text =
        daily.autoArrivalCountdownSeconds.toString();

    setState(() {});
  }

  void _onCurrencyChanged(String code) {
    setState(() {
      _currencyCode = code;
      _currencySymbol = SeseCountryCatalog.getCurrencySymbolForCode(code);
    });
  }

  Future<void> _saveConfig() async {
    setState(() => _saving = true);
    try {
      final pricingRates = <VehicleCategory, VehiclePricingRate>{};
      for (final cat in VehicleCategory.values) {
        pricingRates[cat] = VehiclePricingRate(
          baseFee: double.tryParse(_baseFeeControllers[cat]?.text ?? '') ?? 500.0,
          distanceRatePerKm:
              double.tryParse(_distRateControllers[cat]?.text ?? '') ?? 150.0,
          timeRatePerMinute:
              double.tryParse(_timeRateControllers[cat]?.text ?? '') ?? 20.0,
          surgeMultiplier:
              double.tryParse(_surgeControllers[cat]?.text ?? '') ?? 1.0,
        );
      }

      final carTiers = CarTierThresholds(
        comfortMaxYear: int.tryParse(_comfortYearCtrl.text) ?? 2009,
        premiumMinYear: int.tryParse(_premiumMinYearCtrl.text) ?? 2010,
        premiumMaxYear: int.tryParse(_premiumMaxYearCtrl.text) ?? 2019,
        luxeMinYear: int.tryParse(_luxeMinYearCtrl.text) ?? 2020,
        comfortLabel: _comfortLabelCtrl.text.trim(),
        premiumLabel: _premiumLabelCtrl.text.trim(),
        luxeLabel: _luxeLabelCtrl.text.trim(),
        comfortMultiplier: double.tryParse(_comfortMultCtrl.text) ?? 1.0,
        premiumMultiplier: double.tryParse(_premiumMultCtrl.text) ?? 1.35,
        luxeMultiplier: double.tryParse(_luxeMultCtrl.text) ?? 1.75,
      );

      final dailyStreak = DailyStreakConfig(
        baseCommissionRate:
            (double.tryParse(_baseCommissionCtrl.text) ?? 20.0) / 100.0,
        noShowWaitMinutes: int.tryParse(_noShowWaitCtrl.text) ?? 10,
        autoArrivalEnabled: _autoArrivalEnabled,
        autoArrivalCountdownSeconds:
            int.tryParse(_autoArrivalCountdownCtrl.text) ?? 5,
        enableWaitingTimeBilling: _enableWaitingTimeBilling,
        freeWaitingMinutes: int.tryParse(_freeWaitingMinutesCtrl.text.trim()) ?? 10,
        waitingRatePerMinute: double.tryParse(_waitingRatePerMinuteCtrl.text.trim()) ?? 20.0,
        enableCancellationLock: _enableCancellationLock,
      );

      final config = RegionConfig(
        id: _currentDocId,
        countryCode: _selectedScope == 'global_default' ? 'GLOBAL' : _countryCode,
        stateOrRegion: _selectedScope == 'state' ? _stateOrRegion : '',
        currencyCode: _currencyCode,
        currencySymbol: _currencySymbol,
        regionalSurgeMultiplier: _regionalSurgeMultiplier,
        pricingRates: pricingRates,
        carTierThresholds: carTiers,
        dailyStreakConfig: dailyStreak,
        updatedAt: DateTime.now(),
      );

      await widget.configService.saveConfig(config);
      final maxBids = int.tryParse(_maxVisibleBidsCtrl.text.trim()) ?? 5;
      await widget.configService.saveMaxVisibleBids(maxBids);
      final poolRadius = double.tryParse(_radiusCtrl.text.trim()) ?? 15;
      await widget.configService.saveDispatchTuning(
        DispatchTuning(
          dispatchRadiusKm: poolRadius,
          tier1RadiusKm:
              double.tryParse(_tier1RadiusCtrl.text.trim()) ?? 3,
          tier3RadiusKm: poolRadius,
          tier1TimeoutSec: int.tryParse(_tier1TimeoutCtrl.text.trim()) ?? 15,
          pingTimeoutSec: int.tryParse(_pingTimeoutCtrl.text.trim()) ?? 15,
          repingIntervalSec:
              int.tryParse(_repingIntervalCtrl.text.trim()) ?? 30,
          candidateLimit:
              int.tryParse(_candidateLimitCtrl.text.trim()) ?? 25,
          maxSequentialDrivers:
              int.tryParse(_maxSequentialDriversCtrl.text.trim()) ?? 1,
          publicPoolDurationMin:
              int.tryParse(_publicPoolDurationCtrl.text.trim()) ?? 60,
          bidCountdownSec:
              int.tryParse(_bidCountdownSecCtrl.text.trim()) ?? 15,
          cameraPickupDwellSec:
              int.tryParse(_cameraPickupDwellCtrl.text.trim()) ?? 5,
          cameraDropoffDwellSec:
              int.tryParse(_cameraDropoffDwellCtrl.text.trim()) ?? 2,
          maxOfferBoostPct:
              double.tryParse(_maxOfferBoostPctCtrl.text.trim()) ?? 100.0,
          allowStackedOrders: _allowStackedOrders,
          allowBidding: _allowBidding,
          maxDistanceToDropoffKm:
              double.tryParse(_maxDistanceToDropoffKmCtrl.text.trim()) ?? 2.0,
          maxRemainingTimeMinutes:
              int.tryParse(_maxRemainingTimeMinutesCtrl.text.trim()) ?? 10,
          referralCommissionPercent:
              double.tryParse(_dispatchReferralCommissionPercentCtrl.text.trim()) ?? 1.0,
          standardReferralDurationDays:
              int.tryParse(_dispatchStandardReferralDurationDaysCtrl.text.trim()) ?? 365,
          adminReferralDurationDays:
              int.tryParse(_dispatchAdminReferralDurationDaysCtrl.text.trim()) ?? 548,
          maxConcurrentBids: maxBids,
        ),
      );

      // Persist OPay & Paystack gateway settings cleanly without blocking on map keys.
      await const VehicleRecommendationService().saveConfig(
        VehicleRecommendationConfig(
          bicycleMaxDistanceKm:
              double.tryParse(_bicycleMaxCtrl.text.trim()) ?? 10.0,
          kekeMaxDistanceKm:
              double.tryParse(_kekeMaxCtrl.text.trim()) ?? 5.0,
          motorcycleMinDistanceKm:
              double.tryParse(_motorcycleMinCtrl.text.trim()) ?? 10.0,
        ),
      );

      // Save Residual Referral Revenue Controls
      await widget.configService.saveReferralRevenueSettings(
        ReferralRevenueSettings(
          platformBaseCommissionRate: double.tryParse(_platformBaseCommissionCtrl.text.trim()) ?? 20.0,
          driverReferrerRate: double.tryParse(_driverReferrerRateCtrl.text.trim()) ?? 5.0,
          customerReferrerRate: double.tryParse(_customerReferrerRateCtrl.text.trim()) ?? 5.0,
        ),
      );

      // Save Financial System Parameters
      await const FinancialConfigService().saveConfig(
        FinancialConfig(
          minWalletBalanceToOnline:
              double.tryParse(_minWalletBalanceToOnlineCtrl.text.trim()) ?? 1.0,
          minTopUpAmount:
              double.tryParse(_minTopUpAmountCtrl.text.trim()) ?? 1000.0,
          userReferralCommissionRate:
              (double.tryParse(_userReferralCommissionRateCtrl.text.trim()) ?? 1.0) / 100.0,
          agentReferralCommissionRate:
              (double.tryParse(_agentReferralCommissionRateCtrl.text.trim()) ?? 2.0) / 100.0,
          standardReferralDurationDays:
              int.tryParse(_standardReferralDurationDaysCtrl.text.trim()) ?? 365,
          agentReferralDurationDays:
              int.tryParse(_agentReferralDurationDaysCtrl.text.trim()) ?? 547,
        ),
      );

      // Save Remote Keys & API Config (payment gateways, email, and general flags).
      final remoteKeysConfig = RemoteKeysConfig(
        paystackPublicKey: _paystackPublicKeyCtrl.text.trim(),
        opayMerchantId: _opayMerchantIdCtrl.text.trim(),
        opayPublicKey: _opayPublicKeyCtrl.text.trim(),
        enablePaystack: _enablePaystack,
        enableOpay: _enableOpay,
        googleMapsApiKey: _googleMapsApiKeyCtrl.text.trim(),
        mapboxToken: _mapboxApiKeyCtrl.text.trim(),
        mapboxStyle: _mapboxStyleCtrl.text.trim().isNotEmpty
            ? _mapboxStyleCtrl.text.trim()
            : GlobalMapConfig.defaultMapboxStyle,
        featureProviders: Map<String, String>.from(_featureProviders),
        resendApiKey: _resendApiKeyCtrl.text.trim(),
        activeMapProvider: _activeMapProvider,
        osmTileServerUrl: _osmTileServerUrlCtrl.text.trim(),
        manualOverrideProvider:
            _manualOverrideProvider == 'auto' ? '' : _manualOverrideProvider,
        minimumWalletTopUp:
            double.tryParse(_remoteMinTopUpCtrl.text.trim()) ?? 1000.0,
        appMaintenanceMode: _appMaintenanceMode,
        splitPaymentMasterEnabled: _splitPaymentMasterEnabled,
        forceDeliveryPinSystemWide: _forceDeliveryPinSystemWide,
        maxCashTripAmountNaira:
            double.tryParse(_maxCashTripAmountCtrl.text.trim()) ?? 50000.0,
        requireDriverCashVerification: _requireDriverCashVerification,
        driverBreakOption1Minutes:
            int.tryParse(_driverBreakOption1Ctrl.text.trim()) ?? 30,
        driverBreakOption2Minutes:
            int.tryParse(_driverBreakOption2Ctrl.text.trim()) ?? 60,
        driverBreakEnabled: _driverBreakEnabled,
        dropoffCompletionRadiusMeters:
            double.tryParse(_dropoffRadiusCtrl.text.trim()) ?? 500.0,
        googleMonthlyCap:
            int.tryParse(_googleQuotaCapCtrl.text.trim()) ?? 20000,
        mapboxMonthlyCap:
            int.tryParse(_mapboxQuotaCapCtrl.text.trim()) ?? 50000,
      );
      await const RemoteKeysService().saveRemoteKeys(remoteKeysConfig);

      final enteredSecret = _paystackSecretKeyCtrl.text.trim();
      if (enteredSecret.isNotEmpty &&
          (enteredSecret.startsWith('sk_test_') ||
              enteredSecret.startsWith('sk_live_'))) {
        try {
          await FirebaseFirestore.instance
              .collection('system_config')
              .doc('paystack_secrets')
              .set({
            'secretKey': enteredSecret,
            'updatedAt': FieldValue.serverTimestamp(),
          }, SetOptions(merge: true));
          _paystackSecretKeyCtrl.clear();
        } catch (e) {
          debugPrint('GlobalConfigScreen: paystack secret key save warning: $e');
        }
      }

      final enteredOpaySecret = _opaySecretKeyCtrl.text.trim();
      if (enteredOpaySecret.isNotEmpty) {
        try {
          await FirebaseFirestore.instance
              .collection('system_config')
              .doc('opay_secrets')
              .set({
            'secretKey': enteredOpaySecret,
            'merchantId': _opayMerchantIdCtrl.text.trim(),
            'publicKey': _opayPublicKeyCtrl.text.trim(),
            'updatedAt': FieldValue.serverTimestamp(),
          }, SetOptions(merge: true));
          _opaySecretKeyCtrl.clear();
        } catch (e) {
          debugPrint('GlobalConfigScreen: opay secret key save warning: $e');
        }
      }

      try {
        await FirebaseFirestore.instance
            .collection('system_settings')
            .doc('dispatch')
            .set({
          'enablePaystack': _enablePaystack,
          'enable_paystack': _enablePaystack,
          'enableOpay': _enableOpay,
          'enable_opay': _enableOpay,
          'updatedAt': FieldValue.serverTimestamp(),
        }, SetOptions(merge: true));
      } catch (e) {
        debugPrint('GlobalConfigScreen: dispatch gateway toggles save warning: $e');
      }

      // Map provider, keys, caps, and live usage counters are managed
      // exclusively in Map & API Key Management (system_config/api_keys).

      try {
        final googleCap =
            int.tryParse(_googleQuotaCapCtrl.text.trim()) ?? 20000;
        final mapboxCap =
            int.tryParse(_mapboxQuotaCapCtrl.text.trim()) ?? 50000;
        await FirebaseFirestore.instance
            .collection('system_config')
            .doc('map_quotas')
            .set({
          'googleMonthlyCap': googleCap > 0 ? googleCap : 20000,
          'mapboxMonthlyCap': mapboxCap > 0 ? mapboxCap : 50000,
          'updatedAt': FieldValue.serverTimestamp(),
        }, SetOptions(merge: true));
      } catch (_) {}

      await _loadConfigurations(silent: true);

      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: const Text('Settings updated successfully'),
          backgroundColor: Colors.green.shade800,
          duration: const Duration(seconds: 3),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      debugPrint('GlobalConfigScreen saveConfig error: $e');
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Unable to save configuration. Please try again.'),
        ),
      );
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  // Residual Referral Revenue Controls
  final _platformBaseCommissionCtrl = TextEditingController(text: '20.0');
  final _driverReferrerRateCtrl = TextEditingController(text: '5.0');
  final _customerReferrerRateCtrl = TextEditingController(text: '5.0');

  @override
  Widget build(BuildContext context) {
    if (_loading && _allConfigs.isEmpty) {
      return const SeseCardSkeleton();
    }

    final isNarrow = MediaQuery.sizeOf(context).width < 600;

    bool canSee(HubModuleSection s) {
      final perms = widget.permissions;
      if (perms == null) return true;
      return canSeeSection(
        isOwner: widget.isOwner ?? false,
        role: widget.staffRole ?? UserRole.agent,
        permissions: perms,
        modulePermission: permDynamicConfig,
        sectionPermission: s.permission,
      );
    }

    Widget sectionScroll(List<Widget> children) => SingleChildScrollView(
          padding: EdgeInsets.all(isNarrow ? 12 : 24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: children,
          ),
        );

    // Publish action stays pinned in the AppBar (shell actions) so every
    // section saves through the same `_saveConfig` path.
    final publishAction = Padding(
      padding: const EdgeInsets.only(right: 4),
      child: isNarrow
          ? IconButton.filled(
              tooltip: 'Publish Config',
              onPressed: _saving ? null : _saveConfig,
              icon: _saving
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: Colors.white,
                      ),
                    )
                  : const Icon(Icons.cloud_upload),
            )
          : FilledButton.icon(
              icon: _saving
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: Colors.white,
                      ),
                    )
                  : const Icon(Icons.cloud_upload),
              label: const Text('Publish Config'),
              onPressed: _saving ? null : _saveConfig,
            ),
    );

    // One card per section would re-mount form state on every switch, so
    // the existing card builders stay exactly where they are — the shell
    // only decides WHICH group is visible (IndexedStack keeps the rest
    // mounted with controllers intact).
    return HubModuleShell(
      title: 'Dynamic Global Configuration Engine',
      actions: [publishAction],
      isSectionVisible: canSee,
      sections: [
        HubModuleSection(
          id: 'scope',
          title: 'Scope & Region',
          icon: Icons.public,
          child: sectionScroll([
            _buildScopeSelectorCard(),
          ]),
        ),
        HubModuleSection(
          id: 'pricing',
          title: 'Pricing Engines',
          icon: Icons.payments,
          permission: secConfigPricing,
          child: sectionScroll([
            _buildDynamicPricingCard(),
            const SizedBox(height: 20),
            _buildCarTieringCard(),
          ]),
        ),
        HubModuleSection(
          id: 'api_keys',
          title: 'API & Remote Keys',
          icon: Icons.key,
          permission: secConfigApiKeys,
          child: sectionScroll([
            _buildRemoteKeysCard(),
          ]),
        ),
        HubModuleSection(
          id: 'financials',
          title: 'Credits & Commissions',
          icon: Icons.confirmation_number_outlined,
          permission: secConfigPricing,
          child: sectionScroll([
            _buildFinancialConfigCard(),
          ]),
        ),
        HubModuleSection(
          id: 'referral',
          title: 'Referral & Revenue',
          icon: Icons.group_add,
          permission: secConfigReferral,
          child: sectionScroll([
            _buildReferralRevenueControlsCard(),
          ]),
        ),
        HubModuleSection(
          id: 'dispatch',
          title: 'Dispatch & Trips',
          icon: Icons.local_shipping,
          permission: secConfigDispatch,
          child: sectionScroll([
            _buildBiddingConfigCard(),
            const SizedBox(height: 20),
            _buildDispatchConsoleCard(),
            const SizedBox(height: 20),
            _buildApiKeysCard(),
            const SizedBox(height: 20),
            _buildVehicleRecommendationsCard(),
          ]),
        ),
        HubModuleSection(
          id: 'dispatch_policies',
          title: 'Dispatch & Policies',
          icon: Icons.tune,
          permission: secConfigEngagement,
          child: sectionScroll([
            _buildDailyStreakCard(),
            const SizedBox(height: 20),
            _buildDriverBreakCard(),
          ]),
        ),
      ],
    );
  }

  Widget _buildRemoteKeysCard() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.key, color: Colors.deepOrange),
                const SizedBox(width: 8),
                const Expanded(
                  child: Text(
                    'Remote Backend & API Keys Config (/system_config/remote_keys)',
                    style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                    softWrap: true,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            const Text(
              'Dynamic platform key store and map provider engine. Fields use password obfuscation to protect API credentials.',
              style: TextStyle(fontSize: 12, color: Colors.grey),
            ),
            const SizedBox(height: 16),
            Wrap(
              spacing: 16,
              runSpacing: 16,
              children: [
                _CappedField(
                  preferredWidth: 320,
                  child: SwitchListTile(
                    title: const Text('Enable Paystack Gateway'),
                    subtitle: const Text('Cards, Bank Transfer, USSD via Paystack'),
                    value: _enablePaystack,
                    onChanged: (val) => setState(() => _enablePaystack = val),
                  ),
                ),
                _CappedField(
                  preferredWidth: 320,
                  child: SwitchListTile(
                    title: const Text('Enable OPay Checkout Gateway'),
                    subtitle: const Text('OPay App, Cards, Bank Transfer via OPay'),
                    value: _enableOpay,
                    onChanged: (val) => setState(() => _enableOpay = val),
                  ),
                ),
                _CappedField(
                  preferredWidth: 320,
                  child: TextFormField(
                    controller: _paystackPublicKeyCtrl,
                    obscureText: _obscurePaystackPublic,
                    decoration: InputDecoration(
                      labelText: 'Paystack Public Key',
                      border: const OutlineInputBorder(),
                      suffixIcon: IconButton(
                        icon: Icon(
                          _obscurePaystackPublic
                              ? Icons.visibility_off
                              : Icons.visibility,
                        ),
                        onPressed: () {
                          setState(() {
                            _obscurePaystackPublic = !_obscurePaystackPublic;
                          });
                        },
                      ),
                    ),
                  ),
                ),
                _CappedField(
                  preferredWidth: 320,
                  child: TextFormField(
                    controller: _paystackSecretKeyCtrl,
                    obscureText: _obscurePaystackSecret,
                    decoration: InputDecoration(
                      labelText: 'Paystack Secret Key (write-only)',
                      helperText:
                          'Leave blank to keep current server value. '
                          'Only sk_test_… or sk_live_… accepted.',
                      helperMaxLines: 2,
                      border: const OutlineInputBorder(),
                      suffixIcon: IconButton(
                        icon: Icon(
                          _obscurePaystackSecret
                              ? Icons.visibility_off
                              : Icons.visibility,
                        ),
                        onPressed: () {
                          setState(() {
                            _obscurePaystackSecret = !_obscurePaystackSecret;
                          });
                        },
                      ),
                    ),
                  ),
                ),
                _CappedField(
                  preferredWidth: 320,
                  child: TextFormField(
                    controller: _opayMerchantIdCtrl,
                    decoration: const InputDecoration(
                      labelText: 'OPay Merchant ID',
                      helperText: 'Merchant ID assigned by OPay (e.g. 2566...)',
                      border: OutlineInputBorder(),
                    ),
                  ),
                ),
                _CappedField(
                  preferredWidth: 320,
                  child: TextFormField(
                    controller: _opayPublicKeyCtrl,
                    obscureText: _obscureOpayPublic,
                    decoration: InputDecoration(
                      labelText: 'OPay Public Key',
                      helperText: 'OPAYPUB... credential from OPay dashboard.',
                      border: const OutlineInputBorder(),
                      suffixIcon: IconButton(
                        icon: Icon(
                          _obscureOpayPublic
                              ? Icons.visibility_off
                              : Icons.visibility,
                        ),
                        onPressed: () {
                          setState(() {
                            _obscureOpayPublic = !_obscureOpayPublic;
                          });
                        },
                      ),
                    ),
                  ),
                ),
                _CappedField(
                  preferredWidth: 320,
                  child: TextFormField(
                    controller: _opaySecretKeyCtrl,
                    obscureText: _obscureOpaySecret,
                    decoration: InputDecoration(
                      labelText: 'OPay Secret Key (write-only)',
                      helperText:
                          'Leave blank to keep current server value. '
                          'Only OPAYPRV... or private key accepted.',
                      helperMaxLines: 2,
                      border: const OutlineInputBorder(),
                      suffixIcon: IconButton(
                        icon: Icon(
                          _obscureOpaySecret
                              ? Icons.visibility_off
                              : Icons.visibility,
                        ),
                        onPressed: () {
                          setState(() {
                            _obscureOpaySecret = !_obscureOpaySecret;
                          });
                        },
                      ),
                    ),
                  ),
                ),
                _CappedField(
                  preferredWidth: 320,
                  child: TextFormField(
                    controller: _resendApiKeyCtrl,
                    obscureText: _obscureResendKey,
                    decoration: InputDecoration(
                      labelText: 'Resend API Key (re_...)',
                      helperText: 'Transactional email API key for noreply@sesetech.com',
                      border: const OutlineInputBorder(),
                      suffixIcon: IconButton(
                        icon: Icon(
                          _obscureResendKey
                              ? Icons.visibility_off
                              : Icons.visibility,
                        ),
                        onPressed: () {
                          setState(() {
                            _obscureResendKey = !_obscureResendKey;
                          });
                        },
                      ),
                    ),
                  ),
                ),
                _CappedField(
                  preferredWidth: 200,
                  child: TextFormField(
                    controller: _remoteMinTopUpCtrl,
                    keyboardType:
                        const TextInputType.numberWithOptions(decimal: true),
                    decoration: const InputDecoration(
                      labelText: 'Minimum Sese Credits Top-Up',
                      prefixText: '₦ ',
                      border: OutlineInputBorder(),
                    ),
                  ),
                ),
                _CappedField(
                  preferredWidth: 250,
                  child: SwitchListTile(
                    title: const Text('Maintenance Mode'),
                    subtitle: const Text('Block driver online status'),
                    value: _appMaintenanceMode,
                    onChanged: (val) {
                      setState(() => _appMaintenanceMode = val);
                    },
                  ),
                ),
                _CappedField(
                  preferredWidth: 250,
                  child: SwitchListTile(
                    title: const Text('Split Payment Enabled'),
                    subtitle: const Text('Allow split fares platform-wide'),
                    value: _splitPaymentMasterEnabled,
                    onChanged: (val) {
                      setState(() => _splitPaymentMasterEnabled = val);
                    },
                  ),
                ),
                _CappedField(
                  preferredWidth: 250,
                  child: SwitchListTile(
                    title: const Text('Force Delivery PIN'),
                    subtitle: const Text('Enforce 4-digit PIN system-wide'),
                    value: _forceDeliveryPinSystemWide,
                    onChanged: (val) {
                      setState(() => _forceDeliveryPinSystemWide = val);
                    },
                  ),
                ),
                _CappedField(
                  preferredWidth: 280,
                  child: SwitchListTile(
                    title: const Text('Enable Paid Waiting Billing'),
                    subtitle: const Text('Bill waiting time after arrival countdown expires'),
                    value: _enableWaitingTimeBilling,
                    onChanged: (val) {
                      setState(() => _enableWaitingTimeBilling = val);
                    },
                  ),
                ),
                _CappedField(
                  preferredWidth: 200,
                  child: TextFormField(
                    controller: _freeWaitingMinutesCtrl,
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(
                      labelText: 'Grace Waiting Minutes',
                      helperText: 'Free minutes at pickup (default 10m)',
                      suffixText: 'mins',
                      border: OutlineInputBorder(),
                      prefixIcon: Icon(Icons.timer_outlined),
                    ),
                  ),
                ),
                _CappedField(
                  preferredWidth: 200,
                  child: TextFormField(
                    controller: _waitingRatePerMinuteCtrl,
                    keyboardType: const TextInputType.numberWithOptions(decimal: true),
                    decoration: const InputDecoration(
                      labelText: 'Waiting Rate / Min',
                      helperText: 'Fee per minute after grace (default ₦20)',
                      prefixText: '₦ ',
                      border: OutlineInputBorder(),
                      prefixIcon: Icon(Icons.money_outlined),
                    ),
                  ),
                ),
                _CappedField(
                  preferredWidth: 280,
                  child: SwitchListTile(
                    title: const Text('Lock In-Progress Cancel'),
                    subtitle: const Text('Disallow rider/driver cancel once trip is started'),
                    value: _enableCancellationLock,
                    onChanged: (val) {
                      setState(() => _enableCancellationLock = val);
                    },
                  ),
                ),
                _CappedField(
                  preferredWidth: 250,
                  child: TextFormField(
                    controller: _dropoffRadiusCtrl,
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(
                      labelText: 'Drop-Off Completion Radius (m)',
                      helperText: 'Max distance to complete (default 500m)',
                      suffixText: 'm',
                      border: OutlineInputBorder(),
                      prefixIcon: Icon(Icons.radar_outlined),
                    ),
                  ),
                ),
                _CappedField(
                  preferredWidth: 200,
                  child: TextFormField(
                    controller: _maxCashTripAmountCtrl,
                    keyboardType:
                        const TextInputType.numberWithOptions(decimal: true),
                    decoration: const InputDecoration(
                      labelText: 'Max Cash Trip Floor',
                      prefixText: '₦ ',
                      border: OutlineInputBorder(),
                    ),
                  ),
                ),
                _CappedField(
                  preferredWidth: 250,
                  child: SwitchListTile(
                    title: const Text('Driver Cash Check'),
                    subtitle: const Text('Require cash collection modal'),
                    value: _requireDriverCashVerification,
                    onChanged: (val) {
                      setState(() => _requireDriverCashVerification = val);
                    },
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildFinancialConfigCard() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.confirmation_number_outlined,
                    color: Colors.amber),
                const SizedBox(width: 8),
                const Expanded(
                  child: Text(
                    'Driver Credits & Commissions (/system_configs/financials)',
                    style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                    softWrap: true,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            const Text(
              'Configures platform driver credit thresholds for dispatches and referral commission rates.',
              style: TextStyle(fontSize: 12, color: Colors.grey),
            ),
            const SizedBox(height: 16),
            Wrap(
              spacing: 16,
              runSpacing: 16,
              children: [
                _CappedField(
                  preferredWidth: 220,
                  child: TextFormField(
                    controller: _minWalletBalanceToOnlineCtrl,
                    keyboardType: const TextInputType.numberWithOptions(decimal: true),
                    decoration: const InputDecoration(
                      labelText: 'Min Sese Credits to Online',
                      prefixText: '₦ ',
                      border: OutlineInputBorder(),
                    ),
                  ),
                ),
                _CappedField(
                  preferredWidth: 220,
                  child: TextFormField(
                    controller: _minTopUpAmountCtrl,
                    keyboardType: const TextInputType.numberWithOptions(decimal: true),
                    decoration: const InputDecoration(
                      labelText: 'Min Sese Credits Top-Up',
                      prefixText: '₦ ',
                      border: OutlineInputBorder(),
                    ),
                  ),
                ),
                _CappedField(
                  preferredWidth: 220,
                  child: TextFormField(
                    controller: _userReferralCommissionRateCtrl,
                    keyboardType: const TextInputType.numberWithOptions(decimal: true),
                    decoration: const InputDecoration(
                      labelText: 'User Referral Rate',
                      suffixText: '%',
                      border: OutlineInputBorder(),
                    ),
                  ),
                ),
                _CappedField(
                  preferredWidth: 220,
                  child: TextFormField(
                    controller: _agentReferralCommissionRateCtrl,
                    keyboardType: const TextInputType.numberWithOptions(decimal: true),
                    decoration: const InputDecoration(
                      labelText: 'Agent Referral Rate',
                      suffixText: '%',
                      border: OutlineInputBorder(),
                    ),
                  ),
                ),
                _CappedField(
                  preferredWidth: 220,
                  child: TextFormField(
                    controller: _standardReferralDurationDaysCtrl,
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(
                      labelText: 'Standard Referral Window',
                      suffixText: 'days',
                      border: OutlineInputBorder(),
                    ),
                  ),
                ),
                _CappedField(
                  preferredWidth: 220,
                  child: TextFormField(
                    controller: _agentReferralDurationDaysCtrl,
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(
                      labelText: 'Agent Referral Window',
                      suffixText: 'days',
                      border: OutlineInputBorder(),
                    ),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildReferralRevenueControlsCard() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.monetization_on_outlined, color: Colors.green),
                const SizedBox(width: 8),
                const Expanded(
                  child: Text(
                    'Super Admin Residual Referral Revenue Controls',
                    style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                    softWrap: true,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            const Text(
              'Configures base platform commission and residual referral cuts credited automatically on ride completion.',
              style: TextStyle(fontSize: 12, color: Colors.grey),
            ),
            const SizedBox(height: 16),
            Wrap(
              spacing: 16,
              runSpacing: 16,
              children: [
                _CappedField(
                  preferredWidth: 220,
                  child: TextFormField(
                    controller: _platformBaseCommissionCtrl,
                    keyboardType: const TextInputType.numberWithOptions(decimal: true),
                    decoration: const InputDecoration(
                      labelText: 'Platform Base Commission Rate',
                      suffixText: '%',
                      border: OutlineInputBorder(),
                    ),
                  ),
                ),
                _CappedField(
                  preferredWidth: 220,
                  child: TextFormField(
                    controller: _driverReferrerRateCtrl,
                    keyboardType: const TextInputType.numberWithOptions(decimal: true),
                    decoration: const InputDecoration(
                      labelText: 'Driver Referrer Rate (% of Fee)',
                      suffixText: '%',
                      border: OutlineInputBorder(),
                    ),
                  ),
                ),
                _CappedField(
                  preferredWidth: 220,
                  child: TextFormField(
                    controller: _customerReferrerRateCtrl,
                    keyboardType: const TextInputType.numberWithOptions(decimal: true),
                    decoration: const InputDecoration(
                      labelText: 'Customer Referrer Rate (% of Fee)',
                      suffixText: '%',
                      border: OutlineInputBorder(),
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 20),
            const Divider(),
            const SizedBox(height: 12),
            Row(
              children: [
                const Icon(Icons.tag, size: 20, color: AppColors.seseGold),
                const SizedBox(width: 8),
                const Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Sequential IDs & Referral Codes Audit',
                        style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14),
                      ),
                      Text(
                        'Sorts all Customer (SC), Driver (SD), and Hub (SH) records strictly by earliest registration date, guarantees zero duplicates, and syncs dedicated counters (counters/SC, counters/SD, counters/SH).',
                        style: TextStyle(fontSize: 12, color: Colors.grey),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 12),
                FilledButton.icon(
                  onPressed: _runningBackfill ? null : () => _triggerSequentialIdBackfill(resetAll: true),
                  icon: _runningBackfill
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                        )
                      : const Icon(Icons.sync, size: 16),
                  label: Text(_runningBackfill ? 'Syncing...' : 'Sync & Audit IDs'),
                  style: FilledButton.styleFrom(
                    backgroundColor: AppColors.seseGold,
                    foregroundColor: Colors.black,
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildScopeSelectorCard() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              '1. Regional & Currency Scoping',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
              softWrap: true,
            ),
            const SizedBox(height: 16),
            // Horizontal scroll for the segmented toggle so it never
            // RenderFlex-overflows on narrow phones; dropdowns wrap below.
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: SegmentedButton<String>(
                segments: const [
                  ButtonSegment(
                    value: 'global_default',
                    label: Text('Global Default'),
                    icon: Icon(Icons.public),
                  ),
                  ButtonSegment(
                    value: 'country',
                    label: Text('Country Rule'),
                    icon: Icon(Icons.flag),
                  ),
                  ButtonSegment(
                    value: 'state',
                    label: Text('State Override'),
                    icon: Icon(Icons.location_city),
                  ),
                ],
                selected: {_selectedScope},
                onSelectionChanged: (set) {
                  setState(() => _selectedScope = set.first);
                  _populateFormForCurrentSelection();
                },
              ),
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 12,
              runSpacing: 12,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                if (_selectedScope != 'global_default')
                  _CappedField(
                    preferredWidth: 220,
                    child: DropdownButtonFormField<String>(
                      key: const Key('config_country_picker'),
                      initialValue: _countryCode,
                      isExpanded: true,
                      decoration: const InputDecoration(
                        labelText: 'Country',
                        isDense: true,
                      ),
                      items: SeseCountryCatalog.allCountries.map((c) {
                        return DropdownMenuItem<String>(
                          value: c.countryCode,
                          child: Text(
                            '${c.flagEmoji} ${c.countryName} (${c.dialCode})',
                            overflow: TextOverflow.ellipsis,
                          ),
                        );
                      }).toList(),
                      onChanged: (val) {
                        if (val != null) {
                          setState(() {
                            _countryCode = val;
                            // Reset state selection when country changes
                            _stateOrRegion = '';
                          });
                          final autoCurrency =
                              SeseCountryCatalog.getCurrencyForCountry(val);
                          _onCurrencyChanged(autoCurrency);
                          _populateFormForCurrentSelection();
                        }
                      },
                    ),
                  ),
                if (_selectedScope == 'state')
                  _CappedField(
                    preferredWidth: 180,
                    child: SeseStateDropdownFormField(
                      countryCode: _countryCode,
                      value: _stateOrRegion.isNotEmpty
                          ? _stateOrRegion
                          : null,
                      decoration: const InputDecoration(
                        labelText: 'State / Region',
                        isDense: true,
                        contentPadding: EdgeInsets.symmetric(
                          horizontal: 12, vertical: 12),
                      ),
                      onChanged: (v) {
                        if (v != null) {
                          setState(() => _stateOrRegion = v);
                          _populateFormForCurrentSelection();
                        }
                      },
                    ),
                  ),
                _CappedField(
                  preferredWidth: 180,
                  child: DropdownButtonFormField<String>(
                    key: const Key('config_currency_picker'),
                    initialValue: _currencyCode,
                    isExpanded: true,
                    decoration: const InputDecoration(
                      labelText: 'Currency',
                      isDense: true,
                    ),
                    items: SeseCountryCatalog.operationalCurrencies.map((curr) {
                      return DropdownMenuItem<String>(
                        value: curr.code,
                        child: Text('${curr.code} (${curr.symbol})'),
                      );
                    }).toList(),
                    onChanged: (val) {
                      if (val != null) _onCurrencyChanged(val);
                    },
                  ),
                ),
                _CappedField(
                  preferredWidth: 140,
                  child: TextFormField(
                    initialValue: _regionalSurgeMultiplier.toString(),
                    decoration: const InputDecoration(
                      labelText: 'Regional Surge',
                      suffixText: 'x',
                    ),
                    keyboardType: TextInputType.number,
                    onChanged: (v) => _regionalSurgeMultiplier =
                        double.tryParse(v) ?? 1.0,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Container(
              padding:
                  const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              decoration: BoxDecoration(
                color: Theme.of(context)
                    .colorScheme
                    .secondaryContainer
                    .withValues(alpha: 0.6),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Icon(Icons.tag, size: 16),
                  const SizedBox(width: 6),
                  Flexible(
                    child: Text(
                      'Target Config Document ID: $_currentDocId',
                      style:
                          const TextStyle(fontWeight: FontWeight.bold),
                      softWrap: true,
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

  Widget _buildDynamicPricingCard() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Wrap(
              alignment: WrapAlignment.spaceBetween,
              crossAxisAlignment: WrapCrossAlignment.center,
              spacing: 8,
              runSpacing: 4,
              children: [
                const Text(
                  '2. Dynamic Pricing Engine (Per Vehicle Type)',
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                ),
                Text(
                  'Values in $_currencySymbol ($_currencyCode)',
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
              ],
            ),
            const SizedBox(height: 12),
            const Text(
              'Base Fee is the minimum floor price for any trip or delivery.',
              style: TextStyle(fontSize: 12, color: Colors.grey),
            ),
            const SizedBox(height: 16),
            ...VehicleCategory.values.map((cat) => _buildVehiclePricingRow(cat)),
          ],
        ),
      ),
    );
  }

  Widget _buildVehiclePricingRow(VehicleCategory category) {
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerHighest.withValues(alpha: 0.3),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(
                category.displayName,
                style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 12,
            runSpacing: 12,
            children: [
              _CappedField(
                preferredWidth: 160,
                child: TextFormField(
                  controller: _baseFeeControllers[category],
                  keyboardType: TextInputType.number,
                  decoration: InputDecoration(
                    labelText: 'Base / Floor Fee',
                    prefixText: '$_currencySymbol ',
                    isDense: true,
                  ),
                ),
              ),
              _CappedField(
                preferredWidth: 160,
                child: TextFormField(
                  controller: _distRateControllers[category],
                  keyboardType: TextInputType.number,
                  decoration: InputDecoration(
                    labelText: 'Distance Rate / km',
                    prefixText: '$_currencySymbol ',
                    isDense: true,
                  ),
                ),
              ),
              _CappedField(
                preferredWidth: 160,
                child: TextFormField(
                  controller: _timeRateControllers[category],
                  keyboardType: TextInputType.number,
                  decoration: InputDecoration(
                    labelText: 'Time Rate / min',
                    prefixText: '$_currencySymbol ',
                    isDense: true,
                  ),
                ),
              ),
              _CappedField(
                preferredWidth: 140,
                child: TextFormField(
                  controller: _surgeControllers[category],
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(
                    labelText: 'Vehicle Surge',
                    suffixText: 'x',
                    isDense: true,
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildCarTieringCard() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              '3. Car / Sedan Passenger Ride Tiers (Year-Based Logic)',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 8),
            const Text(
              'Automatically categorizes passenger cars during registration and applies dynamic multiplier during dispatch.',
              style: TextStyle(fontSize: 12, color: Colors.grey),
            ),
            const SizedBox(height: 16),
            // Comfort Tier
            _buildTierEditorRow(
              tierName: 'Standard / Comfort',
              ruleDescription: 'Manufactured before Year: < ',
              yearCtrl: _comfortYearCtrl,
              labelCtrl: _comfortLabelCtrl,
              multiplierCtrl: _comfortMultCtrl,
            ),
            const SizedBox(height: 12),
            // Premium Tier
            _buildTierRangeEditorRow(
              tierName: 'Executive / Premium',
              minYearCtrl: _premiumMinYearCtrl,
              maxYearCtrl: _premiumMaxYearCtrl,
              labelCtrl: _premiumLabelCtrl,
              multiplierCtrl: _premiumMultCtrl,
            ),
            const SizedBox(height: 12),
            // Luxe Tier
            _buildTierEditorRow(
              tierName: 'Luxe / Super',
              ruleDescription: 'Manufactured on or after Year: >= ',
              yearCtrl: _luxeMinYearCtrl,
              labelCtrl: _luxeLabelCtrl,
              multiplierCtrl: _luxeMultCtrl,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildTierEditorRow({
    required String tierName,
    required String ruleDescription,
    required TextEditingController yearCtrl,
    required TextEditingController labelCtrl,
    required TextEditingController multiplierCtrl,
  }) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final isNarrow = constraints.maxWidth < 520;
        final labelField = TextFormField(
          controller: labelCtrl,
          decoration: InputDecoration(
            labelText: '$tierName Label',
            isDense: true,
          ),
        );
        final yearField = TextFormField(
          controller: yearCtrl,
          keyboardType: TextInputType.number,
          decoration: InputDecoration(
            labelText: ruleDescription,
            isDense: true,
          ),
        );
        final multField = TextFormField(
          controller: multiplierCtrl,
          keyboardType: TextInputType.number,
          decoration: const InputDecoration(
            labelText: 'Multiplier',
            suffixText: 'x',
            isDense: true,
          ),
        );
        return Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: Theme.of(context)
                .colorScheme
                .surfaceContainerHighest
                .withValues(alpha: 0.2),
            borderRadius: BorderRadius.circular(8),
          ),
          child: isNarrow
              ? Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    labelField,
                    const SizedBox(height: 8),
                    yearField,
                    const SizedBox(height: 8),
                    multField,
                  ],
                )
              : Row(
                  children: [
                    Expanded(flex: 2, child: labelField),
                    const SizedBox(width: 8),
                    Expanded(flex: 2, child: yearField),
                    const SizedBox(width: 8),
                    Expanded(flex: 1, child: multField),
                  ],
                ),
        );
      },
    );
  }

  Widget _buildTierRangeEditorRow({
    required String tierName,
    required TextEditingController minYearCtrl,
    required TextEditingController maxYearCtrl,
    required TextEditingController labelCtrl,
    required TextEditingController multiplierCtrl,
  }) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final isNarrow = constraints.maxWidth < 560;
        final labelField = TextFormField(
          controller: labelCtrl,
          decoration: InputDecoration(
            labelText: '$tierName Label',
            isDense: true,
          ),
        );
        final minField = TextFormField(
          controller: minYearCtrl,
          keyboardType: TextInputType.number,
          decoration: const InputDecoration(
            labelText: 'Min Year',
            isDense: true,
          ),
        );
        final maxField = TextFormField(
          controller: maxYearCtrl,
          keyboardType: TextInputType.number,
          decoration: const InputDecoration(
            labelText: 'Max Year',
            isDense: true,
          ),
        );
        final multField = TextFormField(
          controller: multiplierCtrl,
          keyboardType: TextInputType.number,
          decoration: const InputDecoration(
            labelText: 'Multiplier',
            suffixText: 'x',
            isDense: true,
          ),
        );
        return Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: Theme.of(context)
                .colorScheme
                .surfaceContainerHighest
                .withValues(alpha: 0.2),
            borderRadius: BorderRadius.circular(8),
          ),
          child: isNarrow
              ? Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    labelField,
                    const SizedBox(height: 8),
                    Row(
                      children: [
                        Expanded(child: minField),
                        const SizedBox(width: 8),
                        Expanded(child: maxField),
                      ],
                    ),
                    const SizedBox(height: 8),
                    multField,
                  ],
                )
              : Row(
                  children: [
                    Expanded(flex: 2, child: labelField),
                    const SizedBox(width: 8),
                    Expanded(flex: 1, child: minField),
                    const SizedBox(width: 8),
                    Expanded(flex: 1, child: maxField),
                    const SizedBox(width: 8),
                    Expanded(flex: 1, child: multField),
                  ],
                ),
        );
      },
    );
  }

  /// "Driver Commission & Proximity Settings" control module.
  Widget _buildDailyStreakCard() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Wrap(
              alignment: WrapAlignment.spaceBetween,
              crossAxisAlignment: WrapCrossAlignment.center,
              spacing: 8,
              runSpacing: 4,
              children: [
                const Text(
                  '4. Driver Commission & Proximity Settings',
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                ),
                Text(
                  'Scope: $_currentDocId',
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
              ],
            ),
            const SizedBox(height: 12),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Proximity Auto-Arrival'),
              subtitle: const Text('Auto-countdown and mark driver arrived when inside geofence radius'),
              value: _autoArrivalEnabled,
              onChanged: (v) => setState(() => _autoArrivalEnabled = v),
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 12,
              runSpacing: 12,
              children: [
                _CappedField(
                  preferredWidth: 200,
                  child: TextFormField(
                    controller: _baseCommissionCtrl,
                    keyboardType: const TextInputType.numberWithOptions(
                        decimal: true),
                    decoration: const InputDecoration(
                      labelText: 'Standard Base Commission',
                      suffixText: '%',
                      helperText: 'Default 20.0%',
                      isDense: true,
                    ),
                  ),
                ),
                _CappedField(
                  preferredWidth: 220,
                  child: TextFormField(
                    controller: _noShowWaitCtrl,
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(
                      labelText: 'No-Show Wait Threshold',
                      suffixText: 'min',
                      helperText: 'Default 10 minutes',
                      isDense: true,
                    ),
                  ),
                ),
                _CappedField(
                  preferredWidth: 220,
                  child: TextFormField(
                    controller: _autoArrivalCountdownCtrl,
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(
                      labelText: 'Auto-Arrival Countdown',
                      suffixText: 'sec',
                      helperText: 'Default 5 seconds',
                      isDense: true,
                    ),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildBiddingConfigCard() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              '6. Multi-Driver Bidding & Marketplace Limits',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 8),
            const Text(
              'Configure the maximum number of driver bids visible simultaneously to a customer in the bid carousel.',
              style: TextStyle(fontSize: 12, color: Colors.grey),
            ),
            const SizedBox(height: 16),
            _CappedField(
              preferredWidth: 240,
              child: TextFormField(
                controller: _maxVisibleBidsCtrl,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(
                  labelText: 'Max Visible Bids in Carousel',
                  suffixText: 'bids',
                  helperText: 'Default: 5 (stored in system_settings/dispatch)',
                  isDense: true,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 7. Super Admin Dispatch Console: live radii / countdowns / recycle
  /// tunables for the Tier 1→2→3 cascade. The backend reads
  /// system_settings/dispatch every ~60s and clamps each value into a
  /// safe band, so the console cannot brick live dispatch. Publishing
  /// requires Super Admin (or the system-settings scope) per rules.
  Widget _buildDispatchConsoleCard() {
    Widget numField(
      TextEditingController controller,
      String label,
      String suffix,
      String helper,
    ) =>
        _CappedField(
          preferredWidth: 240,
          child: TextFormField(
            controller: controller,
            keyboardType:
                const TextInputType.numberWithOptions(decimal: true),
            decoration: InputDecoration(
              labelText: label,
              suffixText: suffix,
              helperText: helper,
              isDense: true,
            ),
          ),
        );
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              '7. Sequential Dispatch Console (1 -> 2 -> 3 -> Public Pool)',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 8),
            const Text(
              'Live tunables for the strict sequential single-driver matching system '
              '(stored in system_settings/dispatch, applied dynamically). '
              'Routes exclusively: 1st nearest driver -> 2nd nearest driver -> 3rd nearest driver '
              '-> Public Order Pool fallback.',
              style: TextStyle(fontSize: 12, color: Colors.grey),
            ),
            const SizedBox(height: 16),
            Wrap(
              spacing: 16,
              runSpacing: 12,
              children: [
                numField(_tier1RadiusCtrl, 'Sequential search radius', 'km',
                    'Default 3 (0–3 km). Dynamically read for 1st, 2nd, & 3rd nearest driver.'),
                numField(_radiusCtrl, 'Public Order Pool radius', 'km',
                    'Default 15 (1–50 km). Extended pool radius for public driver claiming.'),
                numField(_tier1TimeoutCtrl, 'Driver response timeout', 'sec',
                    'Default 15 (5–120 sec). Offer countdown per sequential driver before fallback.'),
                numField(_candidateLimitCtrl, 'Candidate scan limit', 'drivers',
                    'Default 25 (5–100). Max candidate pool evaluated for proximity.'),
                numField(_maxSequentialDriversCtrl, 'Sequential driver attempts', 'drivers',
                    'Default 1 driver. Number of sequential driver pings before sending order to Public Pool.'),
                numField(_publicPoolDurationCtrl, 'Public Pool timeout', 'min',
                    'Default 60 min (1 hr). Automatically expires orders from the pool and returns them to customer.'),
                numField(_bidCountdownSecCtrl, 'Driver bidding countdown', 'sec',
                    'Default 15 (5–60 sec). Duration drivers and customers wait during active counter-offers.'),
                numField(_cameraPickupDwellCtrl, 'Live search pickup dwell', 'sec',
                    'Default 5 (2–30 sec). Camera hold duration at pickup before panning.'),
                numField(_cameraDropoffDwellCtrl, 'Live search drop-off dwell', 'sec',
                    'Default 2 (1–15 sec). Camera hold duration at destination before returning.'),
                numField(_maxOfferBoostPctCtrl, 'Max offer boost cap', '%',
                    'Default 100% (50–300%). Hard cap on customer fare boosts above baseline fare.'),
                numField(_maxDistanceToDropoffKmCtrl, 'Stacked max drop-off distance', 'km',
                    'Default 2.0 km (0.1–10 km). Max distance to active drop-off to receive next stacked order.'),
                numField(_maxRemainingTimeMinutesCtrl, 'Stacked max drop-off time', 'min',
                    'Default 10 min (1–60 min). Max remaining ETA to active drop-off for next stacked order.'),
                numField(_dispatchReferralCommissionPercentCtrl, 'Referral credit rate', '%',
                    'Default 1.0 (1%). Fare percentage credited to referrer on completed trips.'),
                numField(_dispatchStandardReferralDurationDaysCtrl, 'Standard referral window', 'days',
                    'Default 365 days (1 yr). Active referral window for Customers & Drivers.'),
                numField(_dispatchAdminReferralDurationDaysCtrl, 'Admin referral window', 'days',
                    'Default 548 days (1.5 yrs). Active referral window for Hub Admins/Staff.'),
              ],
            ),
            const SizedBox(height: 12),
            SwitchListTile(
              title: const Text('Allow Stacked Orders (Final Stage Proximity)'),
              subtitle: const Text(
                'Permit online drivers with active trips in IN_PROGRESS to receive next-trip/stacked orders when within proximity thresholds of their active drop-off.',
              ),
              value: _allowStackedOrders,
              onChanged: (val) => setState(() => _allowStackedOrders = val),
            ),
            SwitchListTile(
              title: const Text('Allow Driver Bidding & Counter-Offers Platform-Wide'),
              subtitle: const Text(
                'Enable custom fare counter-bids between drivers and customers. When disabled, all orders are strictly fixed-fare and all bidding carousels, inputs, and endpoints are hidden.',
              ),
              value: _allowBidding,
              onChanged: (val) => setState(() => _allowBidding = val),
            ),
          ],
        ),
      ),
    );
  }

  /// Dedicated Map & API Key Management link card (consolidated in MapApiKeyConfigScreen / system_config/api_keys)
  Widget _buildApiKeysCard() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Map & API Key Management (system_config/api_keys)',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 8),
            const Text(
              'All map providers, platform-restricted Google Maps / Mapbox keys, monthly call caps, '
              'auto-fallback, and live usage counters are managed in Map & API Key Management.',
              style: TextStyle(fontSize: 12, color: Colors.grey),
            ),
            const SizedBox(height: 16),
            OutlinedButton.icon(
              key: const Key('global_config_open_api_keys_screen_btn'),
              icon: const Icon(Icons.map_rounded, size: 18),
              label: const Text('Open Map & API Key Management'),
              onPressed: () {
                Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) => const MapApiKeyConfigScreen(),
                  ),
                );
              },
            ),
          ],
        ),
      ),
    );
  }

  /// 8. Vehicle recommendation thresholds: distance bands for the Smart
  /// Dynamic Recommendation Engine (stored in
  /// system_configs/vehicle_recommendations, applied on the next fare load).
  /// Unlike the cards above this is a global singleton — it ignores the
  /// regional scope selector. Publishing requires Super Admin per rules.
  Widget _buildVehicleRecommendationsCard() {
    Widget numField(
      TextEditingController controller,
      String label,
      String helper,
    ) =>
        _CappedField(
          preferredWidth: 240,
          child: TextFormField(
            controller: controller,
            keyboardType:
                const TextInputType.numberWithOptions(decimal: true),
            decoration: InputDecoration(
              labelText: label,
              suffixText: 'km',
              helperText: helper,
              isDense: true,
            ),
          ),
        );
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              '8. Vehicle Recommendations — Distance Thresholds',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 8),
            const Text(
              'Distance bands for Recommended badges and long-distance '
              'warnings in the ride app (stored in '
              'system_configs/vehicle_recommendations, applied on next fare '
              'load, no release needed).',
              style: TextStyle(fontSize: 12, color: Colors.grey),
            ),
            const SizedBox(height: 16),
            Wrap(
              spacing: 16,
              runSpacing: 12,
              children: [
                numField(_bicycleMaxCtrl, 'Bicycle max distance',
                    'Default 10. Delivery bicycle recommended below.'),
                numField(_kekeMaxCtrl, 'Keke max distance',
                    'Default 5. Keke offered/recommended below; warned above.'),
                numField(_motorcycleMinCtrl, 'Motorcycle min distance',
                    'Default 10. Delivery motorcycle recommended at/above.'),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildDriverBreakCard() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.timer_outlined, color: AppColors.seseGold),
                const SizedBox(width: 8),
                const Expanded(
                  child: Text(
                    'Driver Resting Break & Timer Configuration',
                    style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                    softWrap: true,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            const Text(
              'Dynamically configure driver resting break durations and feature availability platform-wide '
              '(stored in /system_config/remote_keys and mirrored to /system_configs/global_default).',
              style: TextStyle(fontSize: 12, color: Colors.grey),
            ),
            const SizedBox(height: 16),
            SwitchListTile(
              title: const Text('Enable Driver Break Feature'),
              subtitle: const Text('Allows drivers to tap the gold circle button to take a resting break'),
              value: _driverBreakEnabled,
              onChanged: (val) => setState(() => _driverBreakEnabled = val),
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 16,
              runSpacing: 12,
              children: [
                _CappedField(
                  preferredWidth: 240,
                  child: TextFormField(
                    controller: _driverBreakOption1Ctrl,
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(
                      labelText: 'Option 1 Duration (Minutes)',
                      suffixText: 'min',
                      helperText: 'Default 30 minutes',
                      isDense: true,
                    ),
                  ),
                ),
                _CappedField(
                  preferredWidth: 240,
                  child: TextFormField(
                    controller: _driverBreakOption2Ctrl,
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(
                      labelText: 'Option 2 Duration (Minutes)',
                      suffixText: 'min',
                      helperText: 'Default 60 minutes (1 Hour)',
                      isDense: true,
                    ),
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

/// Fixed-preferred-width field box that shrinks to fit narrow screens.
///
/// Card fields declare desktop-comfortable widths (320/240/220/…) inside
/// [Wrap]s, but a 360dp phone only offers ~304px after body + card padding,
/// so hard widths stripe-overflow on the right edge. This caps the box at
/// the incoming max width instead — full preferred width on wide screens,
/// edge-to-edge (never clipped) on phones.
class _CappedField extends StatelessWidget {
  final double preferredWidth;
  final Widget child;

  const _CappedField({
    required this.preferredWidth,
    required this.child,
  });

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final max = constraints.maxWidth;
        final width =
            max.isFinite && max < preferredWidth ? max : preferredWidth;
        return SizedBox(width: width, child: child);
      },
    );
  }
}
