import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:sese_core/sese_core.dart';

/// Screen allowing administrators to configure, switch, and test in-app calling routing modes.
///
/// Supports 3 routing modes:
/// 1. **Automatic (Smart Fallback):** Uses Agora RTC Engine as the primary provider to leverage
///    its 10,000 free monthly minutes. Monitors global minute usage in real time. If usage reaches
///    the failover threshold (default: 9,900 mins) or if connection fails, automatically switches to WebRTC.
/// 2. **Force Agora:** Forces the use of Agora RTC Engine for all voice calls.
/// 3. **Force Native WebRTC:** Strict self-hosted WebRTC with zero vendor cost.
class CallingConfigScreen extends StatefulWidget {
  const CallingConfigScreen({super.key});

  @override
  State<CallingConfigScreen> createState() => _CallingConfigScreenState();
}

class _CallingConfigScreenState extends State<CallingConfigScreen> {
  final _configRepo = CallConfigRepository.instance;
  final _callManager = CallServiceManager.instance;

  late CallRoutingMode _selectedRoutingMode;
  late final TextEditingController _agoraAppIdController;
  late final TextEditingController _agoraCertController;
  late final TextEditingController _agoraThresholdController;
  late final TextEditingController _timeoutController;

  bool _obscureCert = true;
  bool _isLoading = true;
  bool _isSaving = false;

  int _agoraUsedMins = 0;
  int _agoraCapMins = 10000;
  int _agoraThresholdMins = 9900;

  @override
  void initState() {
    super.initState();
    _agoraAppIdController = TextEditingController();
    _agoraCertController = TextEditingController();
    _agoraThresholdController = TextEditingController();
    _timeoutController = TextEditingController();
    _loadConfig();
  }

  Future<void> _loadConfig() async {
    final config = await _configRepo.loadConfig();
    String? secretCert;
    Map<String, dynamic>? usageData;

    try {
      final secretsSnap = await FirebaseFirestore.instance
          .collection('system_config')
          .doc('call_secrets')
          .get();
      if (secretsSnap.exists && secretsSnap.data() != null) {
        secretCert = secretsSnap.data()?['agoraPrimaryCertificate']?.toString() ??
            secretsSnap.data()?['agoraAppCertificate']?.toString();
      }

      final usageSnap = await FirebaseFirestore.instance
          .collection('system_config')
          .doc('call_usage')
          .get();
      if (usageSnap.exists && usageSnap.data() != null) {
        usageData = usageSnap.data();
      }
    } catch (e) {
      debugPrint('CallingConfigScreen: error fetching secrets or usage: $e');
    }

    if (!mounted) return;
    setState(() {
      _selectedRoutingMode = config.routingMode;
      _timeoutController.text = config.fallbackTimeoutSeconds.toString();
      _agoraThresholdController.text = config.agoraAutoFailoverThresholdMinutes.toString();

      if (config.agoraAppId != null) {
        _agoraAppIdController.text = config.agoraAppId!;
      }
      if (secretCert != null && secretCert.isNotEmpty) {
        _agoraCertController.text = secretCert;
      }

      _agoraCapMins = config.agoraMonthlyFreeMinutesCap;
      _agoraThresholdMins = config.agoraAutoFailoverThresholdMinutes;
      if (usageData != null) {
        _agoraUsedMins = (usageData['agoraMinutesThisMonth'] as num?)?.toInt() ?? 0;
      }

      _isLoading = false;
    });
  }

  Future<void> _saveConfig() async {
    setState(() => _isSaving = true);
    final String parsedAppId = _agoraAppIdController.text.trim();
    final String parsedCert = _agoraCertController.text.trim();
    final int parsedTimeout = int.tryParse(_timeoutController.text.trim())?.clamp(3, 30) ?? 10;
    final int parsedThreshold = int.tryParse(_agoraThresholdController.text.trim())?.clamp(100, 10000) ?? 9900;

    final updated = _configRepo.currentConfig.copyWith(
      routingMode: _selectedRoutingMode,
      fallbackTimeoutSeconds: parsedTimeout,
      agoraAppId: parsedAppId.isNotEmpty ? parsedAppId : null,
      agoraAutoFailoverThresholdMinutes: parsedThreshold,
      agoraAppCertificate: null,
    );

    await _configRepo.saveConfig(updated);

    // Persist secret Agora Primary Certificate strictly to restricted system_config/call_secrets
    try {
      if (parsedCert.isNotEmpty) {
        await FirebaseFirestore.instance
            .collection('system_config')
            .doc('call_secrets')
            .set({
          'agoraPrimaryCertificate': parsedCert,
          'agoraAppCertificate': parsedCert,
          'updatedAt': FieldValue.serverTimestamp(),
        }, SetOptions(merge: true));
      } else {
        await FirebaseFirestore.instance
            .collection('system_config')
            .doc('call_secrets')
            .set({
          'agoraPrimaryCertificate': FieldValue.delete(),
          'agoraAppCertificate': FieldValue.delete(),
          'updatedAt': FieldValue.serverTimestamp(),
        }, SetOptions(merge: true));
      }
    } catch (e) {
      debugPrint('CallingConfigScreen: error persisting call secrets: $e');
    }

    await _callManager.switchRoutingMode(_selectedRoutingMode);

    if (mounted) {
      setState(() => _isSaving = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: const Text('Calling settings & API keys saved successfully'),
          backgroundColor: Colors.green.shade700,
          duration: const Duration(seconds: 3),
        ),
      );
    }
  }

  void _runLoopbackTest() {
    final testCallId = 'test_${DateTime.now().millisecondsSinceEpoch}';
    InAppCallScreen.start(
      context: context,
      callId: testCallId,
      targetUserId: 'test_loopback_bot',
      targetUserName: 'SeSe Audio Loopback Test',
      metadata: {'isDiagnostic': true},
    );
  }

  @override
  void dispose() {
    _agoraAppIdController.dispose();
    _agoraCertController.dispose();
    _agoraThresholdController.dispose();
    _timeoutController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    if (_isLoading) {
      return Scaffold(
        appBar: AppBar(title: const Text('Calling Configuration')),
        body: const SeseCardSkeleton(),
      );
    }

    final bool isFailoverActive = _agoraUsedMins >= _agoraThresholdMins;
    final double usageRatio = (_agoraUsedMins / _agoraCapMins).clamp(0.0, 1.0);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Calling & VoIP Settings'),
        actions: [
          TextButton.icon(
            key: const Key('save_calling_config_button'),
            icon: _isSaving
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.check_rounded),
            label: const Text('Save'),
            onPressed: _isSaving ? null : _saveConfig,
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
        children: [
          // ── Header Banner ────────────────────────────────────────────────
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: scheme.primaryContainer.withValues(alpha: 0.35),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: scheme.primary.withValues(alpha: 0.2)),
            ),
            child: Row(
              children: [
                Icon(Icons.phone_in_talk_rounded, color: scheme.primary, size: 28),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Agora Real-Time Voice & WebRTC Architecture',
                        style: Theme.of(context).textTheme.titleSmall?.copyWith(
                              fontWeight: FontWeight.bold,
                            ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        'Leverages Agora 10,000 monthly free minutes with backend token isolation, live minute tracking, and automatic failover to native WebRTC.',
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                              color: scheme.onSurfaceVariant,
                            ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),

          const SizedBox(height: 24),
          const _SectionLabel('Active Calling Routing Policy'),

          // ── Option 1: Automatic / Smart Fallback Card ────────────────────
          _ProviderCard(
            key: const Key('routing_card_smart_fallback'),
            title: 'Automatic (Agora Primary → WebRTC Failover)',
            badge: 'Smart Failover (Default)',
            badgeColor: Colors.green,
            description:
                'Uses Agora RTC Engine as primary provider for 10,000 free monthly minutes. If monthly usage reaches threshold (9,900 mins) or connection fails, automatically switches future and active calls to native WebRTC.',
            isSelected: _selectedRoutingMode == CallRoutingMode.smartFallback,
            icon: Icons.auto_mode_rounded,
            onTap: () => setState(() => _selectedRoutingMode = CallRoutingMode.smartFallback),
          ),

          const SizedBox(height: 12),

          // ── Option 2: Force Agora ─────────────────────────────────────────
          _ProviderCard(
            key: const Key('routing_card_third_party'),
            title: 'Force Agora',
            badge: 'Agora RTC Engine',
            badgeColor: Colors.indigo,
            description:
                'Forces the use of Agora RTC Engine exclusively. Bypasses automatic minute failover.',
            isSelected: _selectedRoutingMode == CallRoutingMode.thirdPartyOnly,
            icon: Icons.cloud_done_rounded,
            onTap: () => setState(() => _selectedRoutingMode = CallRoutingMode.thirdPartyOnly),
          ),

          const SizedBox(height: 12),

          // ── Option 3: Force Native WebRTC ───────────────────────────────
          _ProviderCard(
            key: const Key('routing_card_custom_p2p'),
            title: 'Force Native WebRTC',
            badge: 'Zero Vendor Cost',
            badgeColor: Colors.teal,
            description:
                'Uses custom self-hosted WebRTC exclusively via Cloud Firestore signaling and Google STUN servers. No Agora API tokens will be requested.',
            isSelected: _selectedRoutingMode == CallRoutingMode.customP2pOnly,
            icon: Icons.sync_alt_rounded,
            onTap: () => setState(() => _selectedRoutingMode = CallRoutingMode.customP2pOnly),
          ),

          const SizedBox(height: 24),

          // ── Live Monthly Call Minute Usage Tracker ───────────────────────
          const _SectionLabel('Live Monthly Minute Usage & Failover Tracker'),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      const Icon(Icons.analytics_outlined, size: 22, color: Colors.blueGrey),
                      const SizedBox(width: 8),
                      Text(
                        'Monthly Call Minutes (Current Billing Cycle)',
                        style: Theme.of(context).textTheme.titleSmall?.copyWith(
                              fontWeight: FontWeight.bold,
                            ),
                      ),
                      const Spacer(),
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                        decoration: BoxDecoration(
                          color: isFailoverActive
                              ? Colors.amber.shade900.withValues(alpha: 0.15)
                              : Colors.green.shade700.withValues(alpha: 0.15),
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Text(
                          isFailoverActive ? 'Failover Active: Native WebRTC' : 'Active: Agora Free Tier',
                          style: TextStyle(
                            color: isFailoverActive ? Colors.amber.shade900 : Colors.green.shade700,
                            fontSize: 11,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 14),
                  ClipRRect(
                    borderRadius: BorderRadius.circular(6),
                    child: LinearProgressIndicator(
                      value: usageRatio,
                      minHeight: 10,
                      backgroundColor: scheme.outlineVariant.withValues(alpha: 0.4),
                      color: isFailoverActive ? Colors.amber.shade800 : scheme.primary,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(
                        '$_agoraUsedMins / $_agoraCapMins minutes used',
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                              fontWeight: FontWeight.bold,
                            ),
                      ),
                      Text(
                        'Auto-failover threshold: $_agoraThresholdMins mins',
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                              color: scheme.onSurfaceVariant,
                            ),
                      ),
                    ],
                  ),
                  const Divider(height: 24),
                  TextField(
                    key: const Key('agora_threshold_field'),
                    controller: _agoraThresholdController,
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(
                      labelText: 'Auto-Failover Minute Threshold',
                      hintText: '9900',
                      suffixText: 'mins',
                      border: OutlineInputBorder(),
                      helperText: 'When usage reaches this limit in Automatic mode, calls auto-failover to WebRTC.',
                    ),
                  ),
                ],
              ),
            ),
          ),

          const SizedBox(height: 24),

          // ── API Keys / Third-Party Services Section ─────────────────────
          const _SectionLabel('API Keys / Third-Party Services (Agora RTC)'),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      const Icon(Icons.security_rounded, size: 20, color: Colors.green),
                      const SizedBox(width: 8),
                      Text(
                        'Backend Isolated Credentials',
                        style: Theme.of(context).textTheme.titleSmall?.copyWith(
                              fontWeight: FontWeight.bold,
                            ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  Text(
                    'Agora App ID is stored in system settings. Primary Certificate is saved strictly to backend secret document /system_config/call_secrets and is NEVER bundled in client mobile apps.',
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: scheme.onSurfaceVariant,
                          height: 1.35,
                        ),
                  ),
                  const SizedBox(height: 16),
                  TextField(
                    key: const Key('agora_app_id_field'),
                    controller: _agoraAppIdController,
                    decoration: const InputDecoration(
                      labelText: 'Agora App ID',
                      hintText: 'e.g. cd70ed7adfca42f7bcadc14259a939c4',
                      prefixIcon: Icon(Icons.numbers_rounded),
                      border: OutlineInputBorder(),
                      helperText: 'Public App ID from Agora Console project management.',
                    ),
                  ),
                  const SizedBox(height: 16),
                  TextField(
                    key: const Key('agora_cert_field'),
                    controller: _agoraCertController,
                    obscureText: _obscureCert,
                    decoration: InputDecoration(
                      labelText: 'Agora Primary Certificate',
                      hintText: 'e.g. 5e0b3b9e939f4338be3e531e0933831f',
                      prefixIcon: const Icon(Icons.key_rounded),
                      border: const OutlineInputBorder(),
                      helperText: 'Secret Primary Certificate from Agora Console project credentials.',
                      suffixIcon: IconButton(
                        icon: Icon(
                          _obscureCert ? Icons.visibility_outlined : Icons.visibility_off_outlined,
                        ),
                        onPressed: () => setState(() => _obscureCert = !_obscureCert),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),

          const SizedBox(height: 24),

          // ── Fallback Watchdog Timeout Setting ────────────────────────────
          if (_selectedRoutingMode == CallRoutingMode.smartFallback) ...[
            const _SectionLabel('Smart Fallback Watchdog Timing'),
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        const Icon(Icons.timer_outlined, size: 20, color: Colors.blueGrey),
                        const SizedBox(width: 8),
                        Text(
                          'Connection Timeout Trigger',
                          style: Theme.of(context).textTheme.titleSmall?.copyWith(
                                fontWeight: FontWeight.bold,
                              ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Text(
                      'If connection is not established within this timeframe, call drops over to secondary provider.',
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                            color: scheme.onSurfaceVariant,
                          ),
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      key: const Key('fallback_timeout_field'),
                      controller: _timeoutController,
                      keyboardType: TextInputType.number,
                      decoration: const InputDecoration(
                        labelText: 'Timeout (seconds)',
                        hintText: '10',
                        suffixText: 'sec',
                        border: OutlineInputBorder(),
                        helperText: 'Recommended: 8–15 seconds.',
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 24),
          ],

          // ── WebRTC STUN Servers ──────────────────────────────────────────
          const _SectionLabel('WebRTC Signaling & STUN Traversal'),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      const Icon(Icons.public_rounded, size: 20, color: Colors.blueGrey),
                      const SizedBox(width: 8),
                      Text(
                        'Google Public STUN Servers',
                        style: Theme.of(context).textTheme.titleSmall?.copyWith(
                              fontWeight: FontWeight.bold,
                            ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  for (final stun in _configRepo.currentConfig.stunServers)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 2),
                      child: Row(
                        children: [
                          const Icon(Icons.check_circle_outline, size: 14, color: Colors.green),
                          const SizedBox(width: 6),
                          Text(
                            stun,
                            style: TextStyle(
                              fontSize: 12,
                              fontFamily: 'monospace',
                              color: scheme.onSurfaceVariant,
                            ),
                          ),
                        ],
                      ),
                    ),
                  const Divider(height: 24),
                  Row(
                    children: [
                      const Icon(Icons.mic_none_rounded, size: 18, color: Colors.cyan),
                      const SizedBox(width: 6),
                      Expanded(
                        child: Text(
                          'Optimized Audio: Echo Cancellation, Noise Suppression, and Auto Gain Control active.',
                          style: Theme.of(context).textTheme.bodySmall?.copyWith(
                                color: scheme.onSurfaceVariant,
                              ),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 24),

          // ── In-App Call Testing / Diagnostics ─────────────────────────────
          const _SectionLabel('Diagnostics & Testing'),
          Card(
            child: ListTile(
              leading: Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: Colors.green.withValues(alpha: 0.15),
                  shape: BoxShape.circle,
                ),
                child: const Icon(Icons.ring_volume_rounded, color: Colors.green),
              ),
              title: const Text('Test In-App Call Pipeline'),
              subtitle: const Text('Launch an interactive test call to verify microphone, speaker, and UI state.'),
              trailing: const Icon(Icons.arrow_forward_ios_rounded, size: 16),
              onTap: _runLoopbackTest,
            ),
          ),
          const SizedBox(height: 32),
        ],
      ),
    );
  }
}

class _SectionLabel extends StatelessWidget {
  final String label;
  const _SectionLabel(this.label);

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(left: 4, bottom: 8),
      child: Text(
        label,
        style: Theme.of(context).textTheme.titleSmall?.copyWith(
              fontWeight: FontWeight.bold,
              color: Theme.of(context).colorScheme.primary,
            ),
      ),
    );
  }
}

class _ProviderCard extends StatelessWidget {
  final String title;
  final String badge;
  final Color badgeColor;
  final String description;
  final bool isSelected;
  final IconData icon;
  final VoidCallback onTap;

  const _ProviderCard({
    super.key,
    required this.title,
    required this.badge,
    required this.badgeColor,
    required this.description,
    required this.isSelected,
    required this.icon,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    return Card(
      elevation: isSelected ? 2 : 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(
          color: isSelected ? scheme.primary : scheme.outlineVariant.withValues(alpha: 0.6),
          width: isSelected ? 2 : 1,
        ),
      ),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(
                    icon,
                    color: isSelected ? scheme.primary : scheme.onSurfaceVariant,
                    size: 24,
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      title,
                      style: Theme.of(context).textTheme.titleMedium?.copyWith(
                            fontWeight: FontWeight.bold,
                            color: isSelected ? scheme.primary : scheme.onSurface,
                          ),
                    ),
                  ),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                    decoration: BoxDecoration(
                      color: badgeColor.withValues(alpha: 0.15),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Text(
                      badge,
                      style: TextStyle(
                        color: badgeColor,
                        fontSize: 10,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Text(
                description,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: scheme.onSurfaceVariant,
                      height: 1.35,
                    ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
