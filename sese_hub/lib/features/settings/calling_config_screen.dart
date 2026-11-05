import 'package:flutter/material.dart';
import 'package:sese_core/sese_core.dart';

/// Screen allowing administrators to configure, switch, and test in-app calling routing modes.
///
/// Supports 3 routing modes:
/// 1. **Automatic / Smart Fallback (Default):** Attempts custom WebRTC first (using Google STUN
///    servers); if connection fails, times out, or fails ICE gathering, seamlessly drops over to
///    the third-party API backend.
/// 2. **Custom P2P Only:** Strict self-hosted WebRTC with zero vendor cost.
/// 3. **Third-Party API Only:** Forces the use of the plug-and-play third-party SDK.
class CallingConfigScreen extends StatefulWidget {
  const CallingConfigScreen({super.key});

  @override
  State<CallingConfigScreen> createState() => _CallingConfigScreenState();
}

class _CallingConfigScreenState extends State<CallingConfigScreen> {
  final _configRepo = CallConfigRepository.instance;
  final _callManager = CallServiceManager.instance;

  late CallRoutingMode _selectedRoutingMode;
  late final TextEditingController _appIdController;
  late final TextEditingController _appSignController;
  late final TextEditingController _timeoutController;

  bool _obscureAppSign = true;
  bool _isLoading = true;
  bool _isSaving = false;

  @override
  void initState() {
    super.initState();
    _appIdController = TextEditingController();
    _appSignController = TextEditingController();
    _timeoutController = TextEditingController();
    _loadConfig();
  }

  Future<void> _loadConfig() async {
    final config = await _configRepo.loadConfig();
    if (!mounted) return;
    setState(() {
      _selectedRoutingMode = config.routingMode;
      _timeoutController.text = config.fallbackTimeoutSeconds.toString();
      if (config.zegoAppId != null) {
        _appIdController.text = config.zegoAppId.toString();
      }
      if (config.zegoAppSign != null) {
        _appSignController.text = config.zegoAppSign!;
      }
      _isLoading = false;
    });
  }

  Future<void> _saveConfig() async {
    setState(() => _isSaving = true);
    final int? parsedAppId = int.tryParse(_appIdController.text.trim());
    final String parsedAppSign = _appSignController.text.trim();
    final int parsedTimeout = int.tryParse(_timeoutController.text.trim())?.clamp(3, 30) ?? 10;

    final updated = _configRepo.currentConfig.copyWith(
      routingMode: _selectedRoutingMode,
      fallbackTimeoutSeconds: parsedTimeout,
      zegoAppId: parsedAppId,
      zegoAppSign: parsedAppSign.isEmpty ? null : parsedAppSign,
    );

    await _configRepo.saveConfig(updated);
    await _callManager.switchRoutingMode(_selectedRoutingMode);

    if (mounted) {
      setState(() => _isSaving = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: const Text('Calling settings updated successfully'),
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
    _appIdController.dispose();
    _appSignController.dispose();
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
                        'Robust In-App Calling Architecture',
                        style: Theme.of(context).textTheme.titleSmall?.copyWith(
                              fontWeight: FontWeight.bold,
                            ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        'Configure routing between zero-cost self-hosted WebRTC and plug-and-play third-party SDK fallback.',
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
            title: 'Automatic / Smart Fallback',
            badge: 'Smart Routing (Default)',
            badgeColor: Colors.green,
            description:
                'Tries our custom WebRTC setup first using Google STUN servers. If connection fails, times out, or fails ICE gathering due to mobile carrier NAT/firewall blocks, it automatically drops over to the third-party API backend seamlessly without dropping the user experience.',
            isSelected: _selectedRoutingMode == CallRoutingMode.smartFallback,
            icon: Icons.auto_mode_rounded,
            onTap: () => setState(() => _selectedRoutingMode = CallRoutingMode.smartFallback),
          ),

          const SizedBox(height: 12),

          // ── Option 2: Custom P2P Only Card ──────────────────────────────
          _ProviderCard(
            key: const Key('routing_card_custom_p2p'),
            title: 'Custom P2P Only',
            badge: 'Zero Vendor Cost',
            badgeColor: Colors.teal,
            description:
                'Uses our free WebRTC implementation exclusively via Cloud Firestore signaling and Google STUN servers. No third-party API calls will be made.',
            isSelected: _selectedRoutingMode == CallRoutingMode.customP2pOnly,
            icon: Icons.sync_alt_rounded,
            onTap: () => setState(() => _selectedRoutingMode = CallRoutingMode.customP2pOnly),
          ),

          const SizedBox(height: 12),

          // ── Option 3: Third-Party API Only Card ─────────────────────────
          _ProviderCard(
            key: const Key('routing_card_third_party'),
            title: 'Third-Party API Only',
            badge: 'Managed Vendor Relay',
            badgeColor: Colors.indigo,
            description:
                'Forces the use of the plug-and-play third-party calling SDK (e.g. ZegoCloud). Bypasses custom WebRTC entirely.',
            isSelected: _selectedRoutingMode == CallRoutingMode.thirdPartyOnly,
            icon: Icons.cloud_done_rounded,
            onTap: () => setState(() => _selectedRoutingMode = CallRoutingMode.thirdPartyOnly),
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
                      'If WebRTC peer connection is not established within this timeframe (e.g. strict carrier NAT blocks), call drops over to third-party SDK.',
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
          if (_selectedRoutingMode == CallRoutingMode.smartFallback ||
              _selectedRoutingMode == CallRoutingMode.customP2pOnly) ...[
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
                    const SizedBox(height: 6),
                    Row(
                      children: [
                        const Icon(Icons.local_fire_department_rounded, size: 18, color: Colors.orange),
                        const SizedBox(width: 6),
                        Expanded(
                          child: Text(
                            'Signaling Bridge: Firestore collection `/calls` with real-time SDP & candidate exchange.',
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
          ],

          // ── Third-Party API Credentials ──────────────────────────────────
          if (_selectedRoutingMode == CallRoutingMode.smartFallback ||
              _selectedRoutingMode == CallRoutingMode.thirdPartyOnly) ...[
            const _SectionLabel('Third-Party Calling SDK Credentials (ZegoCloud)'),
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    TextField(
                      key: const Key('zego_app_id_field'),
                      controller: _appIdController,
                      keyboardType: TextInputType.number,
                      decoration: const InputDecoration(
                        labelText: 'Third-Party App ID',
                        hintText: 'e.g. 123456789',
                        prefixIcon: Icon(Icons.numbers_rounded),
                        border: OutlineInputBorder(),
                        helperText: 'Found in your third-party VoIP admin console project details.',
                      ),
                    ),
                    const SizedBox(height: 16),
                    TextField(
                      key: const Key('zego_app_sign_field'),
                      controller: _appSignController,
                      obscureText: _obscureAppSign,
                      decoration: InputDecoration(
                        labelText: 'Third-Party App Sign / Secret',
                        hintText: '64-character hexadecimal sign key',
                        prefixIcon: const Icon(Icons.key_rounded),
                        border: const OutlineInputBorder(),
                        helperText: 'Authentication sign key from third-party project credentials.',
                        suffixIcon: IconButton(
                          icon: Icon(
                            _obscureAppSign ? Icons.visibility_outlined : Icons.visibility_off_outlined,
                          ),
                          onPressed: () => setState(() => _obscureAppSign = !_obscureAppSign),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 24),
          ],

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
