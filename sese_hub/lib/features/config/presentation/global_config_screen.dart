import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:sese_core/sese_core.dart';
import '../services/system_config_service.dart';
import '../../dashboard/presentation/hub_module_shell.dart';
import '../../staff/services/hub_access_service.dart';

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

  // Controllers for Streak & Rewards (Drivers)
  bool _driverStreakRewardEnabled = true;
  String _driverStreakCycle = 'daily';
  final _streak5Ctrl = TextEditingController(text: '1000');
  final _streak10Ctrl = TextEditingController(text: '2500');
  final _streak20Ctrl = TextEditingController(text: '6000');
  final _grandAwardCtrl = TextEditingController(text: '15000');
  final _grandTargetTripsCtrl = TextEditingController(text: '30');

  // Controllers for Streak & Rewards (Customers)
  bool _customerStreakRewardEnabled = true;
  String _customerStreakCycle = 'weekly';
  final _custStreak5Ctrl = TextEditingController(text: '500');
  final _custStreak10Ctrl = TextEditingController(text: '1200');
  final _custStreak20Ctrl = TextEditingController(text: '3000');
  final _custGrandAwardCtrl = TextEditingController(text: '5000');
  final _custGrandTargetTripsCtrl = TextEditingController(text: '25');

  String _selectedRewardRole = 'driver';

  // Driver Tiered Commission & Streak Settings (DailyStreakConfig).
  // Active by default platform-wide; admins disable per country/state.
  bool _dailyStreakEnabled = true;
  bool _autoArrivalEnabled = true;
  final _baseCommissionCtrl = TextEditingController(text: '20.0');
  final _completionAwardCtrl = TextEditingController(text: '10000');
  final _noShowWaitCtrl = TextEditingController(text: '10');
  final _autoArrivalCountdownCtrl = TextEditingController(text: '5');
  final Set<String> _disabledCountries = {};
  final Set<String> _disabledStates = {};
  String _disableCountryPick = 'KE';
  String _disableStateCountryPick = 'NG';
  final _disableStateCtrl = TextEditingController();

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
  final _radiusCtrl = TextEditingController(text: '10');
  final _tier1RadiusCtrl = TextEditingController(text: '3');
  final _tier2RadiusCtrl = TextEditingController(text: '6');
  final _tier1TimeoutCtrl = TextEditingController(text: '15');
  final _tier2TimeoutCtrl = TextEditingController(text: '15');
  final _pingTimeoutCtrl = TextEditingController(text: '60');
  final _repingIntervalCtrl = TextEditingController(text: '30');
  final _tier2CountCtrl = TextEditingController(text: '2');
  final _candidateLimitCtrl = TextEditingController(text: '25');
  final _recycleWindowCtrl = TextEditingController(text: '25');
  final _maxRecyclesCtrl = TextEditingController(text: '5');
  final _cameraPickupDwellCtrl = TextEditingController(text: '5');
  final _cameraDropoffDwellCtrl = TextEditingController(text: '2');

  // Financial System Parameters Controllers (/system_configs/financials)
  final _minWalletBalanceToOnlineCtrl = TextEditingController(text: '1.0');
  final _minTopUpAmountCtrl = TextEditingController(text: '1300');
  final _userReferralCommissionRateCtrl = TextEditingController(text: '1.0');
  final _agentReferralCommissionRateCtrl = TextEditingController(text: '2.0');
  final _standardReferralDurationDaysCtrl = TextEditingController(text: '365');
  final _agentReferralDurationDaysCtrl = TextEditingController(text: '547');
  final _minConvertibleBonusCtrl = TextEditingController(text: '5000');
  final _maxBonusThresholdCtrl = TextEditingController(text: '10000');
  final _minPayoutThresholdCtrl = TextEditingController(text: '20000');

  // Remote Keys & API Configuration Controllers (/system_config/remote_keys)
  final _paystackPublicKeyCtrl = TextEditingController(text: 'pk_test_07354be9dc28e79ca4cb7d2cc4818d81ebfd696b');
  final _paystackSecretKeyCtrl = TextEditingController(text: 'sk_test_4e0edebfb09041155f816f2e8cff7cfb5bbfac98');
  final _googleMapsApiKeyCtrl = TextEditingController();
  final _mapboxApiKeyCtrl = TextEditingController();
  final _mapboxStyleCtrl =
      TextEditingController(text: GlobalMapConfig.defaultMapboxStyle);
  final _googleQuotaCapCtrl = TextEditingController(text: '20000');
  final _mapboxQuotaCapCtrl = TextEditingController(text: '50000');
  final _cartoQuotaCapCtrl = TextEditingController(text: '100000');
  final _exchangeRateApiKeyCtrl = TextEditingController(text: 'ex_live_79a2b8c3d4e5f6g7h8i9_sample');
  final _osmTileServerUrlCtrl = TextEditingController(
      text: 'https://{s}.basemaps.cartocdn.com/rastertiles/voyager/{z}/{x}/{y}.png');
  final _remoteMinTopUpCtrl = TextEditingController(text: '1300');
  final _remoteWithdrawalThresholdCtrl = TextEditingController(text: '20000');
  final _maxCashTripAmountCtrl = TextEditingController(text: '50000');
  String _activeMapProvider = 'cartodb';
  String _manualOverrideProvider = 'auto';

  /// Per-feature provider pins, keyed by [MapFeature.code]. `'auto'` (or
  /// absent) follows the global chain above.
  Map<String, String> _featureProviders = {};
  bool _appMaintenanceMode = false;
  bool _splitPaymentMasterEnabled = true;
  bool _forceDeliveryPinSystemWide = false;
  bool _requireDriverCashVerification = true;
  bool _obscurePaystackPublic = true;
  bool _obscurePaystackSecret = true;
  bool _obscureGoogleMapsKey = true;
  bool _obscureMapboxKey = true;
  bool _obscureExchangeRateKey = true;

  // Driver Resting Break & Timer Configuration
  final _driverBreakOption1Ctrl = TextEditingController(text: '30');
  final _driverBreakOption2Ctrl = TextEditingController(text: '60');
  bool _driverBreakEnabled = true;

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
    _streak5Ctrl.dispose();
    _streak10Ctrl.dispose();
    _streak20Ctrl.dispose();
    _grandAwardCtrl.dispose();
    _grandTargetTripsCtrl.dispose();
    _custStreak5Ctrl.dispose();
    _custStreak10Ctrl.dispose();
    _custStreak20Ctrl.dispose();
    _custGrandAwardCtrl.dispose();
    _custGrandTargetTripsCtrl.dispose();
    _baseCommissionCtrl.dispose();
    _completionAwardCtrl.dispose();
    _noShowWaitCtrl.dispose();
    _autoArrivalCountdownCtrl.dispose();
    _disableStateCtrl.dispose();
    _maxVisibleBidsCtrl.dispose();
    _bicycleMaxCtrl.dispose();
    _kekeMaxCtrl.dispose();
    _motorcycleMinCtrl.dispose();
    _radiusCtrl.dispose();
    _tier1RadiusCtrl.dispose();
    _tier2RadiusCtrl.dispose();
    _tier1TimeoutCtrl.dispose();
    _tier2TimeoutCtrl.dispose();
    _pingTimeoutCtrl.dispose();
    _repingIntervalCtrl.dispose();
    _tier2CountCtrl.dispose();
    _candidateLimitCtrl.dispose();
    _recycleWindowCtrl.dispose();
    _maxRecyclesCtrl.dispose();
    _cameraPickupDwellCtrl.dispose();
    _cameraDropoffDwellCtrl.dispose();
    _minWalletBalanceToOnlineCtrl.dispose();
    _minTopUpAmountCtrl.dispose();
    _userReferralCommissionRateCtrl.dispose();
    _agentReferralCommissionRateCtrl.dispose();
    _standardReferralDurationDaysCtrl.dispose();
    _agentReferralDurationDaysCtrl.dispose();
    _minConvertibleBonusCtrl.dispose();
    _maxBonusThresholdCtrl.dispose();
    _minPayoutThresholdCtrl.dispose();
    _paystackPublicKeyCtrl.dispose();
    _paystackSecretKeyCtrl.dispose();
    _googleMapsApiKeyCtrl.dispose();
    _mapboxApiKeyCtrl.dispose();
    _mapboxStyleCtrl.dispose();
    _googleQuotaCapCtrl.dispose();
    _mapboxQuotaCapCtrl.dispose();
    _cartoQuotaCapCtrl.dispose();
    _exchangeRateApiKeyCtrl.dispose();
    _osmTileServerUrlCtrl.dispose();
    _remoteMinTopUpCtrl.dispose();
    _remoteWithdrawalThresholdCtrl.dispose();
    _maxCashTripAmountCtrl.dispose();
    _driverBreakOption1Ctrl.dispose();
    _driverBreakOption2Ctrl.dispose();
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
    // Monthly API-call quota caps (backend-enforced sequential fallback).
    // Missing doc/first run → compiled defaults; never throws. Loaded
    // BEFORE setState (async has no place inside the sync closure).
    String? googleCapText;
    String? mapboxCapText;
    String? cartoCapText;
    try {
      final quotas = await FirebaseFirestore.instance
          .collection('system_config')
          .doc('map_quotas')
          .get();
      final qd = quotas.data();
      if (qd != null) {
        final g = (qd['googleMonthlyCap'] as num?)?.toInt();
        final m = (qd['mapboxMonthlyCap'] as num?)?.toInt();
        final c = (qd['cartoMonthlyCap'] as num?)?.toInt();
        if (g != null && g > 0) googleCapText = g.toString();
        if (m != null && m > 0) mapboxCapText = m.toString();
        if (c != null && c > 0) cartoCapText = c.toString();
      }
    } catch (_) {}
    if (!mounted) return;
    setState(() {
      _allConfigs = configs;
      if (!silent) {
        _paystackPublicKeyCtrl.text = remoteKeys.paystackPublicKey;
      _paystackSecretKeyCtrl.text = remoteKeys.paystackSecretKey;
      _googleMapsApiKeyCtrl.text = remoteKeys.googleMapsApiKey;
      _mapboxApiKeyCtrl.text = remoteKeys.mapboxToken;
      _exchangeRateApiKeyCtrl.text = remoteKeys.exchangeRateApiKey.isEmpty
          ? 'ex_live_79a2b8c3d4e5f6g7h8i9_sample'
          : remoteKeys.exchangeRateApiKey;
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
      if (cartoCapText != null) _cartoQuotaCapCtrl.text = cartoCapText;
      final loadedTileUrl = remoteKeys.osmTileServerUrl.trim();
      _osmTileServerUrlCtrl.text =
          (loadedTileUrl.isEmpty || loadedTileUrl.contains('light_all'))
              ? 'https://{s}.basemaps.cartocdn.com/rastertiles/voyager/{z}/{x}/{y}.png'
              : loadedTileUrl;
      _remoteMinTopUpCtrl.text = remoteKeys.minimumWalletTopUp.toStringAsFixed(0);
      _remoteWithdrawalThresholdCtrl.text = remoteKeys.withdrawalPayoutThreshold.toStringAsFixed(0);
      _maxCashTripAmountCtrl.text = remoteKeys.maxCashTripAmountNaira.toStringAsFixed(0);
      _appMaintenanceMode = remoteKeys.appMaintenanceMode;
      _splitPaymentMasterEnabled = remoteKeys.splitPaymentMasterEnabled;
      _forceDeliveryPinSystemWide = remoteKeys.forceDeliveryPinSystemWide;
      _requireDriverCashVerification = remoteKeys.requireDriverCashVerification;
      _driverBreakOption1Ctrl.text = remoteKeys.driverBreakOption1Minutes.toString();
      _driverBreakOption2Ctrl.text = remoteKeys.driverBreakOption2Minutes.toString();
      _driverBreakEnabled = remoteKeys.driverBreakEnabled;
      _maxVisibleBidsCtrl.text = maxBids.toString();
      _radiusCtrl.text = tuning.dispatchRadiusKm.toString();
      _tier1RadiusCtrl.text = tuning.tier1RadiusKm.toString();
      _tier2RadiusCtrl.text = tuning.tier2RadiusKm.toString();
      _tier1TimeoutCtrl.text = tuning.tier1TimeoutSec.toString();
      _tier2TimeoutCtrl.text = tuning.tier2TimeoutSec.toString();
      _pingTimeoutCtrl.text = tuning.pingTimeoutSec.toString();
      _repingIntervalCtrl.text = tuning.repingIntervalSec.toString();
      _tier2CountCtrl.text = tuning.tier2Count.toString();
      _candidateLimitCtrl.text = tuning.candidateLimit.toString();
      _recycleWindowCtrl.text = tuning.recycleWindowMin.toString();
      _maxRecyclesCtrl.text = tuning.maxRecycles.toString();
      _cameraPickupDwellCtrl.text = tuning.cameraPickupDwellSec.toString();
      _cameraDropoffDwellCtrl.text = tuning.cameraDropoffDwellSec.toString();
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
      _minConvertibleBonusCtrl.text = finConfig.minConvertibleBonus.toStringAsFixed(0);
      _maxBonusThresholdCtrl.text = finConfig.maxBonusThreshold.toStringAsFixed(0);
      _minPayoutThresholdCtrl.text = finConfig.minPayoutThreshold.toStringAsFixed(0);
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

    final streaks = existing.streakRewards;
    _driverStreakRewardEnabled = streaks.enabled;
    _driverStreakCycle = streaks.cycle;
    if (streaks.tiers.isNotEmpty) {
      _streak5Ctrl.text = streaks.tiers[0].bonusPayout.toStringAsFixed(0);
    }
    if (streaks.tiers.length > 1) {
      _streak10Ctrl.text = streaks.tiers[1].bonusPayout.toStringAsFixed(0);
    }
    if (streaks.tiers.length > 2) {
      _streak20Ctrl.text = streaks.tiers[2].bonusPayout.toStringAsFixed(0);
    }
    _grandAwardCtrl.text = streaks.grandCompletionCashAward.toStringAsFixed(0);
    _grandTargetTripsCtrl.text = streaks.grandCompletionTargetTrips.toString();

    final custStreaks = existing.customerStreakRewards;
    _customerStreakRewardEnabled = custStreaks.enabled;
    _customerStreakCycle = custStreaks.cycle;
    if (custStreaks.tiers.isNotEmpty) {
      _custStreak5Ctrl.text = custStreaks.tiers[0].bonusPayout.toStringAsFixed(0);
    }
    if (custStreaks.tiers.length > 1) {
      _custStreak10Ctrl.text = custStreaks.tiers[1].bonusPayout.toStringAsFixed(0);
    }
    if (custStreaks.tiers.length > 2) {
      _custStreak20Ctrl.text = custStreaks.tiers[2].bonusPayout.toStringAsFixed(0);
    }
    _custGrandAwardCtrl.text = custStreaks.grandCompletionCashAward.toStringAsFixed(0);
    _custGrandTargetTripsCtrl.text = custStreaks.grandCompletionTargetTrips.toString();

    final daily = existing.dailyStreakConfig;
    _dailyStreakEnabled = daily.streakEnabled;
    _autoArrivalEnabled = daily.autoArrivalEnabled;
    _baseCommissionCtrl.text =
        (daily.baseCommissionRate * 100).toStringAsFixed(1);
    _completionAwardCtrl.text = daily.completionCashAward.toStringAsFixed(0);
    _noShowWaitCtrl.text = daily.noShowWaitMinutes.toString();
    _autoArrivalCountdownCtrl.text =
        daily.autoArrivalCountdownSeconds.toString();
    _disabledCountries
      ..clear()
      ..addAll(daily.disabledCountries.map((e) => e.trim().toUpperCase()));
    _disabledStates
      ..clear()
      ..addAll(daily.disabledStates.map((e) => e.trim().toUpperCase()));

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

      final streakRewards = StreakRewardConfig(
        enabled: _driverStreakRewardEnabled,
        cycle: _driverStreakCycle,
        tiers: [
          StreakTier(
            completedTripsTrigger: 5,
            bonusPayout: double.tryParse(_streak5Ctrl.text) ?? 1000.0,
          ),
          StreakTier(
            completedTripsTrigger: 10,
            bonusPayout: double.tryParse(_streak10Ctrl.text) ?? 2500.0,
          ),
          StreakTier(
            completedTripsTrigger: 20,
            bonusPayout: double.tryParse(_streak20Ctrl.text) ?? 6000.0,
          ),
        ],
        grandCompletionCashAward:
            double.tryParse(_grandAwardCtrl.text) ?? 15000.0,
        grandCompletionTargetTrips:
            int.tryParse(_grandTargetTripsCtrl.text) ?? 30,
      );

      final customerStreakRewards = StreakRewardConfig(
        enabled: _customerStreakRewardEnabled,
        cycle: _customerStreakCycle,
        tiers: [
          StreakTier(
            completedTripsTrigger: 5,
            bonusPayout: double.tryParse(_custStreak5Ctrl.text) ?? 500.0,
          ),
          StreakTier(
            completedTripsTrigger: 10,
            bonusPayout: double.tryParse(_custStreak10Ctrl.text) ?? 1200.0,
          ),
          StreakTier(
            completedTripsTrigger: 20,
            bonusPayout: double.tryParse(_custStreak20Ctrl.text) ?? 3000.0,
          ),
        ],
        grandCompletionCashAward:
            double.tryParse(_custGrandAwardCtrl.text) ?? 5000.0,
        grandCompletionTargetTrips:
            int.tryParse(_custGrandTargetTripsCtrl.text) ?? 25,
      );

      // The form is always populated from the stored doc (see
      // _populateFormForCurrentSelection), so round-tripping the edited
      // values preserves admin streak settings instead of wiping them.
      final dailyStreak = DailyStreakConfig(
        streakEnabled: _dailyStreakEnabled,
        baseCommissionRate:
            (double.tryParse(_baseCommissionCtrl.text) ?? 20.0) / 100.0,
        noShowWaitMinutes: int.tryParse(_noShowWaitCtrl.text) ?? 10,
        completionCashAward:
            double.tryParse(_completionAwardCtrl.text) ?? 10000.0,
        autoArrivalEnabled: _autoArrivalEnabled,
        autoArrivalCountdownSeconds:
            int.tryParse(_autoArrivalCountdownCtrl.text) ?? 5,
        disabledCountries: _disabledCountries.toList()..sort(),
        disabledStates: _disabledStates.toList()..sort(),
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
        streakRewards: streakRewards,
        customerStreakRewards: customerStreakRewards,
        dailyStreakConfig: dailyStreak,
        updatedAt: DateTime.now(),
      );

      await widget.configService.saveConfig(config);
      final maxBids = int.tryParse(_maxVisibleBidsCtrl.text.trim()) ?? 5;
      await widget.configService.saveMaxVisibleBids(maxBids);
      final poolRadius = double.tryParse(_radiusCtrl.text.trim()) ?? 10;
      await widget.configService.saveDispatchTuning(
        DispatchTuning(
          dispatchRadiusKm: poolRadius,
          tier1RadiusKm:
              double.tryParse(_tier1RadiusCtrl.text.trim()) ?? 3,
          tier2RadiusKm:
              double.tryParse(_tier2RadiusCtrl.text.trim()) ?? 6,
          tier3RadiusKm: poolRadius,
          tier1TimeoutSec: int.tryParse(_tier1TimeoutCtrl.text.trim()) ?? 15,
          tier2TimeoutSec: int.tryParse(_tier2TimeoutCtrl.text.trim()) ?? 15,
          pingTimeoutSec: int.tryParse(_pingTimeoutCtrl.text.trim()) ?? 60,
          repingIntervalSec:
              int.tryParse(_repingIntervalCtrl.text.trim()) ?? 30,
          tier2Count: int.tryParse(_tier2CountCtrl.text.trim()) ?? 2,
          candidateLimit:
              int.tryParse(_candidateLimitCtrl.text.trim()) ?? 25,
          recycleWindowMin:
              int.tryParse(_recycleWindowCtrl.text.trim()) ?? 25,
          maxRecycles: int.tryParse(_maxRecyclesCtrl.text.trim()) ?? 5,
          cameraPickupDwellSec:
              int.tryParse(_cameraPickupDwellCtrl.text.trim()) ?? 5,
          cameraDropoffDwellSec:
              int.tryParse(_cameraDropoffDwellCtrl.text.trim()) ?? 2,
        ),
      );
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

      // Save P2P Wallet Rules
      await widget.configService.saveP2pWalletRules(
        P2pWalletRules(
          minDriverTrips: int.tryParse(_p2pMinDriverTripsCtrl.text.trim()) ?? 3,
          maxP2pLimitNaira: double.tryParse(_p2pMaxLimitCtrl.text.trim()) ?? 20000.0,
          adminOverrideEnabled: _p2pAdminOverrideEnabled,
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
              double.tryParse(_minTopUpAmountCtrl.text.trim()) ?? 1300.0,
          userReferralCommissionRate:
              (double.tryParse(_userReferralCommissionRateCtrl.text.trim()) ?? 1.0) / 100.0,
          agentReferralCommissionRate:
              (double.tryParse(_agentReferralCommissionRateCtrl.text.trim()) ?? 2.0) / 100.0,
          standardReferralDurationDays:
              int.tryParse(_standardReferralDurationDaysCtrl.text.trim()) ?? 365,
          agentReferralDurationDays:
              int.tryParse(_agentReferralDurationDaysCtrl.text.trim()) ?? 547,
          minConvertibleBonus:
              double.tryParse(_minConvertibleBonusCtrl.text.trim()) ?? 5000.0,
          maxBonusThreshold:
              double.tryParse(_maxBonusThresholdCtrl.text.trim()) ?? 10000.0,
          minPayoutThreshold:
              double.tryParse(_minPayoutThresholdCtrl.text.trim()) ?? 20000.0,
        ),
      );

      // Advisory check if Google Maps or CartoDB is selected with blank API key
      if ((_activeMapProvider == 'google' || _activeMapProvider == 'google_maps') &&
          _googleMapsApiKeyCtrl.text.trim().isEmpty) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text(
                'Admin Notice: Google Maps is selected without an API key. Client apps will cascade to Mapbox (if token is set) or CartoDB.',
              ),
              backgroundColor: Colors.orange,
              duration: Duration(seconds: 4),
            ),
          );
        }
      }

      // Save Remote Keys & API Config
      await const RemoteKeysService().saveRemoteKeys(
        RemoteKeysConfig(
          paystackPublicKey: _paystackPublicKeyCtrl.text.trim(),
          paystackSecretKey: _paystackSecretKeyCtrl.text.trim(),
          googleMapsApiKey: _googleMapsApiKeyCtrl.text.trim(),
          mapboxToken: _mapboxApiKeyCtrl.text.trim(),
          mapboxStyle: _mapboxStyleCtrl.text.trim().isNotEmpty
              ? _mapboxStyleCtrl.text.trim()
              : GlobalMapConfig.defaultMapboxStyle,
          featureProviders: Map<String, String>.from(_featureProviders),
          exchangeRateApiKey: _exchangeRateApiKeyCtrl.text.trim(),
          activeMapProvider: _activeMapProvider,
          osmTileServerUrl: _osmTileServerUrlCtrl.text.trim(),
          manualOverrideProvider:
              _manualOverrideProvider == 'auto' ? '' : _manualOverrideProvider,
          minimumWalletTopUp:
              double.tryParse(_remoteMinTopUpCtrl.text.trim()) ?? 1300.0,
          withdrawalPayoutThreshold:
              double.tryParse(_remoteWithdrawalThresholdCtrl.text.trim()) ?? 20000.0,
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
        ),
      );

      MapConfigController.instance.updateConfig(
        GlobalMapConfig(
          activeProvider: _activeMapProvider,
          apiKey: _googleMapsApiKeyCtrl.text.trim().isNotEmpty
              ? _googleMapsApiKeyCtrl.text.trim()
              : GlobalMapConfig.defaultGoogleMapsApiKey,
          mapboxToken: _mapboxApiKeyCtrl.text.trim().isNotEmpty
              ? _mapboxApiKeyCtrl.text.trim()
              : null,
          mapboxStyle: _mapboxStyleCtrl.text.trim().isNotEmpty
              ? _mapboxStyleCtrl.text.trim()
              : GlobalMapConfig.defaultMapboxStyle,
          featureProviders: Map<String, String>.from(_featureProviders),
          tileUrlTemplate: (_osmTileServerUrlCtrl.text.trim().isNotEmpty &&
                  !_osmTileServerUrlCtrl.text.trim().contains('light_all'))
              ? _osmTileServerUrlCtrl.text.trim()
              : 'https://{s}.basemaps.cartocdn.com/rastertiles/voyager/{z}/{x}/{y}{r}.png',
          manualOverrideProvider:
              _manualOverrideProvider == 'auto' ? null : _manualOverrideProvider,
        ),
      );

      // Save monthly API-call quota caps (backend sequential fallback).
      // Admin-scoped write per firestore.rules; counters themselves are
      // server-managed. Never blocks the config publish on failure.
      try {
        final googleCap =
            int.tryParse(_googleQuotaCapCtrl.text.trim()) ?? 20000;
        final mapboxCap =
            int.tryParse(_mapboxQuotaCapCtrl.text.trim()) ?? 50000;
        final cartoCap =
            int.tryParse(_cartoQuotaCapCtrl.text.trim()) ?? 100000;
        await FirebaseFirestore.instance
            .collection('system_config')
            .doc('map_quotas')
            .set({
          'googleMonthlyCap': googleCap > 0 ? googleCap : 20000,
          'mapboxMonthlyCap': mapboxCap > 0 ? mapboxCap : 50000,
          'cartoMonthlyCap': cartoCap > 0 ? cartoCap : 100000,
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
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Failed to save config: $e')),
      );
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  // P2P Wallet Rules Controllers
  final _p2pMinDriverTripsCtrl = TextEditingController(text: '3');
  final _p2pMaxLimitCtrl = TextEditingController(text: '20000');
  bool _p2pAdminOverrideEnabled = true;

  // Residual Referral Revenue Controls
  final _platformBaseCommissionCtrl = TextEditingController(text: '20.0');
  final _driverReferrerRateCtrl = TextEditingController(text: '5.0');
  final _customerReferrerRateCtrl = TextEditingController(text: '5.0');

  @override
  Widget build(BuildContext context) {
    if (_loading && _allConfigs.isEmpty) {
      return const Center(child: CircularProgressIndicator());
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
          id: 'wallet',
          title: 'Wallet & Payouts',
          icon: Icons.account_balance_wallet,
          permission: secConfigWallet,
          child: sectionScroll([
            _buildFinancialConfigCard(),
            const SizedBox(height: 20),
            _buildP2pWalletRulesCard(),
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
            _buildVehicleRecommendationsCard(),
          ]),
        ),
        HubModuleSection(
          id: 'engagement',
          title: 'Driver Engagement',
          icon: Icons.emoji_events,
          permission: secConfigEngagement,
          child: sectionScroll([
            _buildStreakRewardsCard(),
            const SizedBox(height: 20),
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
                      labelText: 'Paystack Secret Key',
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
                    controller: _googleMapsApiKeyCtrl,
                    obscureText: _obscureGoogleMapsKey,
                    decoration: InputDecoration(
                      labelText: 'Google Maps API Key',
                      helperText: 'Required when Google Maps is the active provider.',
                      border: const OutlineInputBorder(),
                      suffixIcon: IconButton(
                        icon: Icon(
                          _obscureGoogleMapsKey
                              ? Icons.visibility_off
                              : Icons.visibility,
                        ),
                        onPressed: () {
                          setState(() {
                            _obscureGoogleMapsKey = !_obscureGoogleMapsKey;
                          });
                        },
                      ),
                    ),
                  ),
                ),
                _CappedField(
                  preferredWidth: 320,
                  child: TextFormField(
                    controller: _mapboxApiKeyCtrl,
                    obscureText: _obscureMapboxKey,
                    decoration: InputDecoration(
                      labelText: 'Mapbox Access Token (pk.eyJ1…)',
                      helperText:
                          'Required for Mapbox (secondary provider). Leave blank to skip Mapbox in fallback.',
                      border: const OutlineInputBorder(),
                      suffixIcon: IconButton(
                        icon: Icon(
                          _obscureMapboxKey
                              ? Icons.visibility_off
                              : Icons.visibility,
                        ),
                        onPressed: () {
                          setState(() {
                            _obscureMapboxKey = !_obscureMapboxKey;
                          });
                        },
                      ),
                    ),
                  ),
                ),
                _CappedField(
                  preferredWidth: 320,
                  child: TextFormField(
                    controller: _exchangeRateApiKeyCtrl,
                    obscureText: _obscureExchangeRateKey,
                    decoration: InputDecoration(
                      labelText: 'Exchange Rate API Key',
                      border: const OutlineInputBorder(),
                      suffixIcon: IconButton(
                        icon: Icon(
                          _obscureExchangeRateKey
                              ? Icons.visibility_off
                              : Icons.visibility,
                        ),
                        onPressed: () {
                          setState(() {
                            _obscureExchangeRateKey = !_obscureExchangeRateKey;
                          });
                        },
                      ),
                    ),
                  ),
                ),
                _CappedField(
                  preferredWidth: 360,
                  child: InputDecorator(
                    decoration: const InputDecoration(
                      labelText: 'Active Map Engine (All Screens)',
                      helperText:
                          'Fallback chain: Google Maps → Mapbox → CartoDB. OSM is deprecated.',
                      border: OutlineInputBorder(),
                      contentPadding: EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 4,
                      ),
                    ),
                    child: DropdownButton<String>(
                      value: (_activeMapProvider == 'google_maps' || _activeMapProvider == 'google')
                          ? 'google'
                          : (_activeMapProvider == 'mapbox'
                              ? 'mapbox'
                              : 'cartodb'),
                      isExpanded: true,
                      underline: const SizedBox.shrink(),
                      items: const [
                        DropdownMenuItem(
                          value: 'google',
                          child: Text('Google Maps (Primary — Pay-as-you-go)'),
                        ),
                        DropdownMenuItem(
                          value: 'mapbox',
                          child: Text('Mapbox (Secondary — Token required)'),
                        ),
                        DropdownMenuItem(
                          value: 'cartodb',
                          child: Text('CartoDB (Tertiary — Free basemaps, no key)'),
                        ),
                      ],
                      onChanged: (val) {
                        if (val != null) {
                          setState(() => _activeMapProvider = val);
                        }
                      },
                    ),
                  ),
                ),
                _CappedField(
                  preferredWidth: 360,
                  child: InputDecorator(
                    decoration: const InputDecoration(
                      labelText: 'Manual Provider Override (Admin Pin)',
                      helperText:
                          'Auto-Fallback: normal cascade logic. Pinning a provider bypasses fallback.',
                      border: OutlineInputBorder(),
                      contentPadding: EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 4,
                      ),
                    ),
                    child: DropdownButton<String>(
                      value: _manualOverrideProvider,
                      isExpanded: true,
                      underline: const SizedBox.shrink(),
                      items: const [
                        DropdownMenuItem(
                          value: 'auto',
                          child: Text('Auto-Fallback (Recommended)'),
                        ),
                        DropdownMenuItem(
                          value: 'google',
                          child: Text('Force Google Maps'),
                        ),
                        DropdownMenuItem(
                          value: 'mapbox',
                          child: Text('Force Mapbox'),
                        ),
                        DropdownMenuItem(
                          value: 'cartodb',
                          child: Text('Force CartoDB'),
                        ),
                      ],
                      onChanged: (val) {
                        if (val != null) {
                          setState(() => _manualOverrideProvider = val);
                        }
                      },
                    ),
                  ),
                ),
                // ── Per-feature provider pins ──────────────────────────
                // Each feature area follows the global engine above on
                // 'auto', or pins to one provider (credential/fallback
                // safety still applies — a pin without a key cascades).
                for (final feature in MapFeature.values)
                  _CappedField(
                    preferredWidth: 360,
                    child: InputDecorator(
                      decoration: InputDecoration(
                        labelText: feature.displayName,
                        helperText: 'Auto = follow the global engine.',
                        border: const OutlineInputBorder(),
                        contentPadding: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 4,
                        ),
                      ),
                      child: DropdownButton<String>(
                        value: _featureProviders[feature.code] ?? 'auto',
                        isExpanded: true,
                        underline: const SizedBox.shrink(),
                        items: const [
                          DropdownMenuItem(
                            value: 'auto',
                            child: Text('Auto (follow global engine)'),
                          ),
                          DropdownMenuItem(
                            value: 'google',
                            child: Text('Force Google Maps'),
                          ),
                          DropdownMenuItem(
                            value: 'mapbox',
                            child: Text('Force Mapbox'),
                          ),
                          DropdownMenuItem(
                            value: 'cartodb',
                            child: Text('Force CartoDB / Nominatim'),
                          ),
                        ],
                        onChanged: (val) {
                          if (val != null) {
                            setState(() {
                              if (val == 'auto') {
                                _featureProviders.remove(feature.code);
                              } else {
                                _featureProviders[feature.code] = val;
                              }
                            });
                          }
                        },
                      ),
                    ),
                  ),
                _CappedField(
                  preferredWidth: 360,
                  child: TextFormField(
                    controller: _mapboxStyleCtrl,
                    decoration: const InputDecoration(
                      labelText: 'Mapbox Style ID (Google mimesis)',
                      helperText:
                          'Default mapbox/light-v11. Custom: mapbox://styles/<user>/<id>.',
                      border: OutlineInputBorder(),
                    ),
                  ),
                ),
                // ── Monthly API-call quota caps (backend sequential
                // fallback: Google → Mapbox → CartoDB/coast → Google PAYG).
                // Counters reset on month roll-over, server-side.
                _CappedField(
                  preferredWidth: 200,
                  child: TextFormField(
                    controller: _googleQuotaCapCtrl,
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(
                      labelText: 'Google Monthly Call Cap',
                      helperText: 'Free-tier allowance before Mapbox rollover.',
                      border: OutlineInputBorder(),
                    ),
                  ),
                ),
                _CappedField(
                  preferredWidth: 200,
                  child: TextFormField(
                    controller: _mapboxQuotaCapCtrl,
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(
                      labelText: 'Mapbox Monthly Call Cap',
                      helperText: 'Allowance before CartoDB/PAYG overflow.',
                      border: OutlineInputBorder(),
                    ),
                  ),
                ),
                _CappedField(
                  preferredWidth: 200,
                  child: TextFormField(
                    controller: _cartoQuotaCapCtrl,
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(
                      labelText: 'CartoDB Monthly Call Cap',
                      helperText:
                          'Policy marker only — tiles load direct client→CDN, so this is not enforced.',
                      border: OutlineInputBorder(),
                    ),
                  ),
                ),
                if (_activeMapProvider == 'google' &&
                    _googleMapsApiKeyCtrl.text.trim().isEmpty)
                  _CappedField(
                    preferredWidth: 360,
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                      decoration: BoxDecoration(
                        color: Colors.orange.shade50,
                        borderRadius: BorderRadius.circular(6),
                        border: Border.all(color: Colors.orange.shade300),
                      ),
                      child: Row(
                        children: [
                          Icon(Icons.warning_amber_rounded, color: Colors.orange.shade800, size: 20),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              'Admin Alert: Google Maps is active without an API key. Client apps cascade to Mapbox (if token set) or CartoDB.',
                              style: TextStyle(color: Colors.orange.shade900, fontSize: 12),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                if (_activeMapProvider == 'mapbox' &&
                    _mapboxApiKeyCtrl.text.trim().isEmpty)
                  _CappedField(
                    preferredWidth: 360,
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                      decoration: BoxDecoration(
                        color: Colors.orange.shade50,
                        borderRadius: BorderRadius.circular(6),
                        border: Border.all(color: Colors.orange.shade300),
                      ),
                      child: Row(
                        children: [
                          Icon(Icons.warning_amber_rounded, color: Colors.orange.shade800, size: 20),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              'Admin Alert: Mapbox is active without an access token. Client apps will fall back to CartoDB.',
                              style: TextStyle(color: Colors.orange.shade900, fontSize: 12),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                // Circuit-breaker reset button — visible when the Google circuit is open
                _CappedField(
                  preferredWidth: 360,
                  child: OutlinedButton.icon(
                    icon: const Icon(Icons.electrical_services_rounded),
                    label: const Text('Reset Google Circuit Breaker'),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: Colors.red.shade700,
                      side: BorderSide(color: Colors.red.shade300),
                    ),
                    onPressed: () {
                      MapConfigController.instance.resetCircuitBreaker();
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(
                          content: Text(
                            'Google Maps circuit breaker reset. Will attempt Google Maps on next map load.',
                          ),
                          duration: Duration(seconds: 3),
                        ),
                      );
                    },
                  ),
                ),
                _CappedField(
                  preferredWidth: 320,
                  child: TextFormField(
                    controller: _osmTileServerUrlCtrl,
                    decoration: const InputDecoration(
                      labelText: 'Tile Server URL Template (CartoDB / Mapbox / Custom)',
                      helperText: 'Default: https://{s}.basemaps.cartocdn.com/rastertiles/voyager/{z}/{x}/{y}.png (CartoDB Voyager)',
                      border: OutlineInputBorder(),
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
                      labelText: 'Minimum Wallet Top-Up',
                      prefixText: '₦ ',
                      border: OutlineInputBorder(),
                    ),
                  ),
                ),
                _CappedField(
                  preferredWidth: 200,
                  child: TextFormField(
                    controller: _remoteWithdrawalThresholdCtrl,
                    keyboardType:
                        const TextInputType.numberWithOptions(decimal: true),
                    decoration: const InputDecoration(
                      labelText: 'Payout Floor Threshold',
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
                const Icon(Icons.account_balance_wallet_outlined,
                    color: Colors.amber),
                const SizedBox(width: 8),
                const Expanded(
                  child: Text(
                    'Financial System Parameters (/system_configs/financials)',
                    style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                    softWrap: true,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            const Text(
              'Configures real-time financial thresholds, deposit rules, referral commission rates, coin limits, and payout floors strictly in Naira (₦).',
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
                      labelText: 'Min Wallet to Online',
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
                      labelText: 'Min Deposit / Top-up',
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
                _CappedField(
                  preferredWidth: 220,
                  child: TextFormField(
                    controller: _minConvertibleBonusCtrl,
                    keyboardType: const TextInputType.numberWithOptions(decimal: true),
                    decoration: const InputDecoration(
                      labelText: 'Min Convertible Bonus',
                      prefixText: '₦ ',
                      border: OutlineInputBorder(),
                    ),
                  ),
                ),
                _CappedField(
                  preferredWidth: 220,
                  child: TextFormField(
                    controller: _maxBonusThresholdCtrl,
                    keyboardType: const TextInputType.numberWithOptions(decimal: true),
                    decoration: const InputDecoration(
                      labelText: 'Auto-Convert Bonus Cap',
                      prefixText: '₦ ',
                      border: OutlineInputBorder(),
                    ),
                  ),
                ),
                _CappedField(
                  preferredWidth: 220,
                  child: TextFormField(
                    controller: _minPayoutThresholdCtrl,
                    keyboardType: const TextInputType.numberWithOptions(decimal: true),
                    decoration: const InputDecoration(
                      labelText: 'Weekly Payout Floor',
                      prefixText: '₦ ',
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

  Widget _buildP2pWalletRulesCard() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.swap_horizontal_circle_outlined,
                    color: Colors.blue),
                const SizedBox(width: 8),
                const Expanded(
                  child: Text(
                    'Dynamic P2P Wallet Transfer Settings',
                    style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                    softWrap: true,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            const Text(
              'Configures P2P receiver eligibility guards, transaction caps, and admin overrides.',
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
                    controller: _p2pMinDriverTripsCtrl,
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(
                      labelText: 'Min Driver Trips to Receive',
                      suffixText: 'trips',
                      border: OutlineInputBorder(),
                    ),
                  ),
                ),
                _CappedField(
                  preferredWidth: 220,
                  child: TextFormField(
                    controller: _p2pMaxLimitCtrl,
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(
                      labelText: 'Single Transaction P2P Limit',
                      prefixText: '₦ ',
                      border: OutlineInputBorder(),
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Admin Override Enabled'),
              subtitle: const Text('Allows staff/admins to send P2P transfers bypassing trip minimums.'),
              value: _p2pAdminOverrideEnabled,
              onChanged: (v) => setState(() => _p2pAdminOverrideEnabled = v),
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

  /// "Driver Tiered Commission & Streak Settings" control module.
  ///
  /// Active by default platform-wide ([DailyStreakConfig.streakEnabled]).
  /// Country/state cascading selectors add entries to the disable lists;
  /// scalar fields configure the base commission, grand-completion cash
  /// award (local currency), and customer no-show wait threshold.
  Widget _buildDailyStreakCard() {
    final countryOptions =
        SeseCountryCatalog.allCountries.map((c) => c.countryCode).toList();
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
                  '5. Driver Tiered Commission & Streak Settings',
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                ),
                Text(
                  'Scope: $_currentDocId',
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
              ],
            ),
            const SizedBox(height: 4),
            const Text(
              'Streak is ACTIVE BY DEFAULT for all countries and states. '
              'Disable it below for specific countries or states. '
              'Level 1: 15% → 0% step-down · Level 2: 0% + cash-back · '
              'Level 3: 0% + cash bonus + grand award.',
              style: TextStyle(fontSize: 12, color: Colors.grey),
            ),
            const SizedBox(height: 12),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Streak system active'),
              subtitle: const Text('Default ON — applies to this scope'),
              value: _dailyStreakEnabled,
              onChanged: (v) => setState(() => _dailyStreakEnabled = v),
            ),
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
                    controller: _completionAwardCtrl,
                    keyboardType: TextInputType.number,
                    decoration: InputDecoration(
                      labelText: 'Completion Cash Reward',
                      prefixText: '$_currencySymbol ',
                      helperText: 'Default ₦10,000',
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
            const SizedBox(height: 16),
            const Text(
              'Regional Disable — Countries',
              style: TextStyle(fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                _CappedField(
                  preferredWidth: 160,
                  child: DropdownButtonFormField<String>(
                    initialValue: countryOptions.contains(_disableCountryPick)
                        ? _disableCountryPick
                        : countryOptions.first,
                    isExpanded: true,
                    decoration: const InputDecoration(
                      labelText: 'Country',
                      isDense: true,
                    ),
                    items: [
                      for (final c in countryOptions)
                        DropdownMenuItem(
                          value: c,
                          child: Text(
                            '${SeseCountryCatalog.findByCode(c)?.flagEmoji ?? ''} ${SeseCountryCatalog.findByCode(c)?.countryName ?? c} (${SeseCountryCatalog.findByCode(c)?.dialCode ?? ''})',
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                    ],
                    onChanged: (v) {
                      if (v != null) {
                        setState(() => _disableCountryPick = v);
                      }
                    },
                  ),
                ),
                OutlinedButton.icon(
                  icon: const Icon(Icons.block),
                  label: const Text('Disable country'),
                  onPressed: () => setState(
                      () => _disabledCountries.add(_disableCountryPick)),
                ),
              ],
            ),
            const SizedBox(height: 8),
            if (_disabledCountries.isEmpty)
              const Text('No countries disabled — streak active everywhere.',
                  style: TextStyle(fontSize: 12, color: Colors.grey))
            else
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final c in _disabledCountries)
                    Chip(
                      label: Text('$c (disabled)'),
                      deleteIcon: const Icon(Icons.close, size: 16),
                      onDeleted: () =>
                          setState(() => _disabledCountries.remove(c)),
                    ),
                ],
              ),
            const SizedBox(height: 16),
            const Text(
              'Regional Disable — States / Regions',
              style: TextStyle(fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                _CappedField(
                  preferredWidth: 140,
                  child: DropdownButtonFormField<String>(
                    initialValue:
                        countryOptions.contains(_disableStateCountryPick)
                            ? _disableStateCountryPick
                            : countryOptions.first,
                    isExpanded: true,
                    decoration: const InputDecoration(
                      labelText: 'Country',
                      isDense: true,
                    ),
                    items: [
                      for (final c in countryOptions)
                        DropdownMenuItem(
                          value: c,
                          child: Text(
                            '${SeseCountryCatalog.findByCode(c)?.flagEmoji ?? ''} ${SeseCountryCatalog.findByCode(c)?.countryName ?? c} (${SeseCountryCatalog.findByCode(c)?.dialCode ?? ''})',
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                    ],
                    onChanged: (v) {
                      if (v != null) {
                        setState(() => _disableStateCountryPick = v);
                      }
                    },
                  ),
                ),
                _CappedField(
                  preferredWidth: 180,
                  child: TextFormField(
                    controller: _disableStateCtrl,
                    decoration: const InputDecoration(
                      labelText: 'State / Region',
                      hintText: 'e.g. Lagos',
                      isDense: true,
                    ),
                  ),
                ),
                OutlinedButton.icon(
                  icon: const Icon(Icons.block),
                  label: const Text('Disable state'),
                  onPressed: () {
                    final state = _disableStateCtrl.text
                        .trim()
                        .toUpperCase()
                        .replaceAll(' ', '_');
                    if (state.isEmpty) return;
                    setState(() {
                      _disabledStates
                          .add('${_disableStateCountryPick}_$state');
                      _disableStateCtrl.clear();
                    });
                  },
                ),
              ],
            ),
            const SizedBox(height: 8),
            if (_disabledStates.isEmpty)
              const Text('No states disabled.',
                  style: TextStyle(fontSize: 12, color: Colors.grey))
            else
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final s in _disabledStates)
                    Chip(
                      label: Text('$s (disabled)'),
                      deleteIcon: const Icon(Icons.close, size: 16),
                      onDeleted: () =>
                          setState(() => _disabledStates.remove(s)),
                    ),
                ],
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildStreakRewardsCard() {
    final isDriver = _selectedRewardRole == 'driver';
    final isEnabled = isDriver ? _driverStreakRewardEnabled : _customerStreakRewardEnabled;
    final currentCycle = isDriver ? _driverStreakCycle : _customerStreakCycle;

    final s5Ctrl = isDriver ? _streak5Ctrl : _custStreak5Ctrl;
    final s10Ctrl = isDriver ? _streak10Ctrl : _custStreak10Ctrl;
    final s20Ctrl = isDriver ? _streak20Ctrl : _custStreak20Ctrl;
    final grandTargetCtrl = isDriver ? _grandTargetTripsCtrl : _custGrandTargetTripsCtrl;
    final grandAwardCtrl = isDriver ? _grandAwardCtrl : _custGrandAwardCtrl;

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
                  '4. Dynamic Streak & Reward Overrides',
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                ),
                Text(
                  'Awards in $_currencySymbol',
                  style: const TextStyle(fontWeight: FontWeight.bold),
                ),
              ],
            ),
            const SizedBox(height: 12),
            // Role selector
            SegmentedButton<String>(
              segments: const [
                ButtonSegment(
                  value: 'driver',
                  label: Text('Driver Streaks'),
                  icon: Icon(Icons.drive_eta, size: 16),
                ),
                ButtonSegment(
                  value: 'customer',
                  label: Text('Customer Streaks'),
                  icon: Icon(Icons.person, size: 16),
                ),
              ],
              selected: {_selectedRewardRole},
              onSelectionChanged: (val) {
                if (val.isNotEmpty) {
                  setState(() => _selectedRewardRole = val.first);
                }
              },
            ),
            const SizedBox(height: 16),
            Wrap(
              spacing: 20,
              runSpacing: 12,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Switch(
                      value: isEnabled,
                      onChanged: (val) {
                        setState(() {
                          if (isDriver) {
                            _driverStreakRewardEnabled = val;
                          } else {
                            _customerStreakRewardEnabled = val;
                          }
                        });
                      },
                    ),
                    const SizedBox(width: 8),
                    Text(
                      isEnabled
                          ? '${isDriver ? "Driver" : "Customer"} Rewards Active'
                          : '${isDriver ? "Driver" : "Customer"} Rewards Disabled',
                      style: TextStyle(
                        fontWeight: FontWeight.w600,
                        color: isEnabled ? null : Colors.grey,
                      ),
                    ),
                  ],
                ),
                _CappedField(
                  preferredWidth: 200,
                  child: DropdownButtonFormField<String>(
                    initialValue: currentCycle,
                    decoration: const InputDecoration(
                      labelText: 'Evaluation Cycle',
                      isDense: true,
                    ),
                    items: const [
                      DropdownMenuItem(value: 'daily', child: Text('Daily Cycle')),
                      DropdownMenuItem(value: 'weekly', child: Text('Weekly Cycle')),
                      DropdownMenuItem(value: 'monthly', child: Text('Monthly Cycle')),
                    ],
                    onChanged: (val) {
                      if (val != null) {
                        setState(() {
                          if (isDriver) {
                            _driverStreakCycle = val;
                          } else {
                            _customerStreakCycle = val;
                          }
                        });
                      }
                    },
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            Wrap(
              spacing: 12,
              runSpacing: 12,
              children: [
                _CappedField(
                  preferredWidth: 200,
                  child: TextFormField(
                    controller: s5Ctrl,
                    keyboardType: TextInputType.number,
                    decoration: InputDecoration(
                      labelText: '5-Trip Streak Bonus',
                      prefixText: '$_currencySymbol ',
                      isDense: true,
                    ),
                  ),
                ),
                _CappedField(
                  preferredWidth: 200,
                  child: TextFormField(
                    controller: s10Ctrl,
                    keyboardType: TextInputType.number,
                    decoration: InputDecoration(
                      labelText: '10-Trip Streak Bonus',
                      prefixText: '$_currencySymbol ',
                      isDense: true,
                    ),
                  ),
                ),
                _CappedField(
                  preferredWidth: 200,
                  child: TextFormField(
                    controller: s20Ctrl,
                    keyboardType: TextInputType.number,
                    decoration: InputDecoration(
                      labelText: '20-Trip Streak Bonus',
                      prefixText: '$_currencySymbol ',
                      isDense: true,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            Wrap(
              spacing: 12,
              runSpacing: 12,
              children: [
                _CappedField(
                  preferredWidth: 240,
                  child: TextFormField(
                    controller: grandTargetCtrl,
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(
                      labelText: 'Grand Completion Target',
                      suffixText: 'trips',
                      isDense: true,
                    ),
                  ),
                ),
                _CappedField(
                  preferredWidth: 240,
                  child: TextFormField(
                    controller: grandAwardCtrl,
                    keyboardType: TextInputType.number,
                    decoration: InputDecoration(
                      labelText: 'Grand Cash Award Payout',
                      prefixText: '$_currencySymbol ',
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
              '7. Dispatch Console — Radii, Countdowns & Auto-Recycle',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 8),
            const Text(
              'Live tunables for the cascading dispatch engine '
              '(stored in system_settings/dispatch, applied within ~60s). '
              'Stage 1 pings the single nearest driver, Stage 2 the next '
              'group in parallel, Stage 3 broadcasts to the marketplace pool.',
              style: TextStyle(fontSize: 12, color: Colors.grey),
            ),
            const SizedBox(height: 16),
            Wrap(
              spacing: 16,
              runSpacing: 12,
              children: [
                numField(_tier1RadiusCtrl, 'Stage 1 radius', 'km',
                    'Default 3 (0–3 km). Broadcasts to nearest available driver.'),
                numField(_tier2RadiusCtrl, 'Stage 2 radius', 'km',
                    'Default 6 (0–6 km). Expands search on ignore/timeout/reject.'),
                numField(_radiusCtrl, 'Stage 3 Marketplace pool radius', 'km',
                    'Default 10 (~10 km). Quick Order / Marketplace open pool.'),
                numField(_tier1TimeoutCtrl, 'Stage 1 countdown', 'sec',
                    'Default 15 (5–120). Exclusive offer window.'),
                numField(_tier2TimeoutCtrl, 'Stage 2 countdown', 'sec',
                    'Default 15 (5–120). Parallel offer window.'),
                numField(_pingTimeoutCtrl, 'Ping expiry', 'sec',
                    'Default 60 (10–600).'),
                numField(_repingIntervalCtrl, 'Re-ping interval', 'sec',
                    'Default 30 (10–600).'),
                numField(_tier2CountCtrl, 'Stage 2 parallel drivers', 'drivers',
                    'Default 2 (1–5). Atomic first-wins lock.'),
                numField(_candidateLimitCtrl, 'Candidate scan limit', 'drivers',
                    'Default 25 (5–100).'),
                numField(_recycleWindowCtrl, 'Auto-recycle timer', 'min',
                    'Default 25 (5–120). Stale orders restart.'),
                numField(_maxRecyclesCtrl, 'Max recycles per trip', 'times',
                    'Default 5 (1-20). Bounds execution.'),
                numField(_cameraPickupDwellCtrl, 'Live search pickup dwell', 'sec',
                    'Default 5 (2–30 sec). Camera hold duration at pickup before panning.'),
                numField(_cameraDropoffDwellCtrl, 'Live search drop-off dwell', 'sec',
                    'Default 2 (1–15 sec). Camera hold duration at destination before returning.'),
              ],
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
