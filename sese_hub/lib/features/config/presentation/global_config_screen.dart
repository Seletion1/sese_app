import 'package:flutter/material.dart';
import 'package:sese_core/sese_core.dart';
import '../services/system_config_service.dart';

class GlobalConfigScreen extends StatefulWidget {
  final SystemConfigService configService;

  const GlobalConfigScreen({
    super.key,
    required this.configService,
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

  // Controllers for Streak & Rewards
  final _streak5Ctrl = TextEditingController(text: '1000');
  final _streak10Ctrl = TextEditingController(text: '2500');
  final _streak20Ctrl = TextEditingController(text: '6000');
  final _grandAwardCtrl = TextEditingController(text: '15000');
  final _grandTargetTripsCtrl = TextEditingController(text: '30');

  // Driver Tiered Commission & Streak Settings (DailyStreakConfig).
  // Active by default platform-wide; admins disable per country/state.
  bool _dailyStreakEnabled = true;
  final _baseCommissionCtrl = TextEditingController(text: '20.0');
  final _completionAwardCtrl = TextEditingController(text: '10000');
  final _noShowWaitCtrl = TextEditingController(text: '10');
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
  final _radiusCtrl = TextEditingController(text: '15');
  final _tier1RadiusCtrl = TextEditingController(text: '3');
  final _tier2RadiusCtrl = TextEditingController(text: '5');
  final _tier1TimeoutCtrl = TextEditingController(text: '15');
  final _tier2TimeoutCtrl = TextEditingController(text: '15');
  final _pingTimeoutCtrl = TextEditingController(text: '60');
  final _repingIntervalCtrl = TextEditingController(text: '30');
  final _tier2CountCtrl = TextEditingController(text: '2');
  final _candidateLimitCtrl = TextEditingController(text: '25');
  final _recycleWindowCtrl = TextEditingController(text: '25');
  final _maxRecyclesCtrl = TextEditingController(text: '5');

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
    _baseCommissionCtrl.dispose();
    _completionAwardCtrl.dispose();
    _noShowWaitCtrl.dispose();
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
    super.dispose();
  }

  Future<void> _loadConfigurations() async {
    setState(() => _loading = true);
    final configs = await widget.configService.getAllConfigs();
    if (!mounted) return;
    final maxBids = await widget.configService.getMaxVisibleBids();
    if (!mounted) return;
    final tuning = await widget.configService.getDispatchTuning();
    if (!mounted) return;
    final vehicleRec =
        await const VehicleRecommendationService().getConfig();
    if (!mounted) return;
    setState(() {
      _allConfigs = configs;
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
      _bicycleMaxCtrl.text =
          vehicleRec.bicycleMaxDistanceKm.toString();
      _kekeMaxCtrl.text = vehicleRec.kekeMaxDistanceKm.toString();
      _motorcycleMinCtrl.text =
          vehicleRec.motorcycleMinDistanceKm.toString();
      _loading = false;
    });
    _populateFormForCurrentSelection();
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

    final daily = existing.dailyStreakConfig;
    _dailyStreakEnabled = daily.streakEnabled;
    _baseCommissionCtrl.text =
        (daily.baseCommissionRate * 100).toStringAsFixed(1);
    _completionAwardCtrl.text = daily.completionCashAward.toStringAsFixed(0);
    _noShowWaitCtrl.text = daily.noShowWaitMinutes.toString();
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
        dailyStreakConfig: dailyStreak,
        updatedAt: DateTime.now(),
      );

      await widget.configService.saveConfig(config);
      final maxBids = int.tryParse(_maxVisibleBidsCtrl.text.trim()) ?? 5;
      await widget.configService.saveMaxVisibleBids(maxBids);
      await widget.configService.saveDispatchTuning(
        DispatchTuning(
          dispatchRadiusKm:
              double.tryParse(_radiusCtrl.text.trim()) ?? 15,
          tier1RadiusKm:
              double.tryParse(_tier1RadiusCtrl.text.trim()) ?? 3,
          tier2RadiusKm:
              double.tryParse(_tier2RadiusCtrl.text.trim()) ?? 5,
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
        ),
      );
      // Vehicle recommendation thresholds are a global singleton outside the
      // regional scope selector. They publish through the shared sese_core
      // service; the ride app picks them up on its next fare load.
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
      await _loadConfigurations();

      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Successfully published config: ${config.id}'),
          backgroundColor: Colors.green.shade800,
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

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }

    final isNarrow = MediaQuery.sizeOf(context).width < 600;

    return Scaffold(
      appBar: AppBar(
        title: const Text(
          'Dynamic Global Configuration Engine',
          overflow: TextOverflow.ellipsis,
        ),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 12),
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
          ),
        ],
      ),
      body: SingleChildScrollView(
        padding: EdgeInsets.all(isNarrow ? 12 : 24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _buildScopeSelectorCard(),
            const SizedBox(height: 20),
            _buildDynamicPricingCard(),
            const SizedBox(height: 20),
            _buildCarTieringCard(),
            const SizedBox(height: 20),
            _buildStreakRewardsCard(),
            const SizedBox(height: 20),
            _buildDailyStreakCard(),
            const SizedBox(height: 20),
            _buildBiddingConfigCard(),
            const SizedBox(height: 20),
            _buildDispatchConsoleCard(),
            const SizedBox(height: 20),
            _buildVehicleRecommendationsCard(),
            const SizedBox(height: 32),
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
                  SizedBox(
                    width: 220,
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
                  SizedBox(
                    width: 180,
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
                SizedBox(
                  width: 180,
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
                SizedBox(
                  width: 140,
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
              SizedBox(
                width: 160,
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
              SizedBox(
                width: 160,
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
              SizedBox(
                width: 160,
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
              SizedBox(
                width: 140,
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
            const SizedBox(height: 8),
            Wrap(
              spacing: 12,
              runSpacing: 12,
              children: [
                SizedBox(
                  width: 200,
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
                SizedBox(
                  width: 220,
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
                SizedBox(
                  width: 220,
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
                SizedBox(
                  width: 160,
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
                SizedBox(
                  width: 140,
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
                SizedBox(
                  width: 180,
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
            const SizedBox(height: 16),
            Wrap(
              spacing: 12,
              runSpacing: 12,
              children: [
                SizedBox(
                  width: 200,
                  child: TextFormField(
                    controller: _streak5Ctrl,
                    keyboardType: TextInputType.number,
                    decoration: InputDecoration(
                      labelText: '5-Trip Streak Bonus',
                      prefixText: '$_currencySymbol ',
                      isDense: true,
                    ),
                  ),
                ),
                SizedBox(
                  width: 200,
                  child: TextFormField(
                    controller: _streak10Ctrl,
                    keyboardType: TextInputType.number,
                    decoration: InputDecoration(
                      labelText: '10-Trip Streak Bonus',
                      prefixText: '$_currencySymbol ',
                      isDense: true,
                    ),
                  ),
                ),
                SizedBox(
                  width: 200,
                  child: TextFormField(
                    controller: _streak20Ctrl,
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
                SizedBox(
                  width: 240,
                  child: TextFormField(
                    controller: _grandTargetTripsCtrl,
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(
                      labelText: 'Grand Completion Target (Trips)',
                      suffixText: 'trips',
                      isDense: true,
                    ),
                  ),
                ),
                SizedBox(
                  width: 240,
                  child: TextFormField(
                    controller: _grandAwardCtrl,
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
            SizedBox(
              width: 240,
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
        SizedBox(
          width: 240,
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
                numField(_radiusCtrl, 'Dispatch coverage radius', 'km',
                    'Default 15 (1–50). Outer pool ~3–5km via recycle.'),
                numField(_tier1RadiusCtrl, 'Stage 1 radius', 'km',
                    'Default 3 (1–50). Single nearest driver offer.'),
                numField(_tier2RadiusCtrl, 'Stage 2 radius', 'km',
                    'Default 5 (1–50). Parallel group offer.'),
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
        SizedBox(
          width: 240,
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
}
