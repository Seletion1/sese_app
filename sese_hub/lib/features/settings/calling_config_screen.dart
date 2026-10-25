import 'package:flutter/material.dart';
import 'package:sese_core/sese_core.dart';

/// Screen allowing administrators to configure, switch, and test in-app calling providers.
///
/// Supports:
/// 1. **Self-Hosted WebRTC:** Zero-cost P2P audio using Firebase Firestore signaling.
/// 2. **Managed ZegoCloud SDK:** Turnkey global VoIP calling requiring App ID & App Sign.
class CallingConfigScreen extends StatefulWidget {
  const CallingConfigScreen({super.key});

  @override
  State<CallingConfigScreen> createState() => _CallingConfigScreenState();
}

class _CallingConfigScreenState extends State<CallingConfigScreen> {
  final _configRepo = CallConfigRepository.instance;
  final _callManager = CallServiceManager.instance;

  late CallProviderType _selectedProvider;
  late final TextEditingController _appIdController;
  late final TextEditingController _appSignController;

  bool _obscureAppSign = true;
  bool _isLoading = true;
  bool _isSaving = false;

  @override
  void initState() {
    super.initState();
    _appIdController = TextEditingController();
    _appSignController = TextEditingController();
    _loadConfig();
  }

  Future<void> _loadConfig() async {
    final config = await _configRepo.loadConfig();
    if (!mounted) return;
    setState(() {
      _selectedProvider = config.providerType;
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

    final updated = _configRepo.currentConfig.copyWith(
      providerType: _selectedProvider,
      zegoAppId: parsedAppId,
      zegoAppSign: parsedAppSign.isEmpty ? null : parsedAppSign,
    );

    await _configRepo.saveConfig(updated);
    await _callManager.switchProvider(_selectedProvider);

    if (mounted) {
      setState(() => _isSaving = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: const Text('Settings updated successfully'),
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
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    if (_isLoading) {
      return Scaffold(
        appBar: AppBar(title: const Text('Calling Configuration')),
        body: const Center(child: CircularProgressIndicator()),
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
                        'Switchable In-App Calling',
                        style: Theme.of(context).textTheme.titleSmall?.copyWith(
                              fontWeight: FontWeight.bold,
                            ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        'Choose between self-hosted WebRTC (zero 3rd-party vendor cost) or managed ZegoCloud calling.',
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
          const _SectionLabel('Active Calling Provider'),

          // ── Option 1: WebRTC Card ────────────────────────────────────────
          _ProviderCard(
            key: const Key('provider_card_webrtc'),
            title: 'Self-Hosted WebRTC',
            badge: 'Zero Vendor Cost (Recommended)',
            badgeColor: Colors.green,
            description:
                'Peer-to-peer VoIP audio using your existing Firebase Firestore for signaling. End-to-end encrypted via DTLS/SRTP with Google STUN servers.',
            isSelected: _selectedProvider == CallProviderType.webrtc,
            icon: Icons.sync_alt_rounded,
            onTap: () => setState(() => _selectedProvider = CallProviderType.webrtc),
          ),

          const SizedBox(height: 12),

          // ── Option 2: ZegoCloud Card ─────────────────────────────────────
          _ProviderCard(
            key: const Key('provider_card_zego'),
            title: 'Managed ZegoCloud SDK',
            badge: 'Turnkey Global Relay',
            badgeColor: Colors.blue,
            description:
                'Managed VoIP cloud SDK. Requires Zego Application ID and App Sign configured below.',
            isSelected: _selectedProvider == CallProviderType.zego,
            icon: Icons.cloud_done_rounded,
            onTap: () => setState(() => _selectedProvider = CallProviderType.zego),
          ),

          const SizedBox(height: 24),

          // ── WebRTC STUN Diagnostics ──────────────────────────────────────
          if (_selectedProvider == CallProviderType.webrtc) ...[
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
          ],

          // ── ZegoCloud Credentials ────────────────────────────────────────
          if (_selectedProvider == CallProviderType.zego) ...[
            const _SectionLabel('ZegoCloud Credentials'),
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
                        labelText: 'Zego App ID',
                        hintText: 'e.g. 123456789',
                        prefixIcon: Icon(Icons.numbers_rounded),
                        border: OutlineInputBorder(),
                        helperText: 'Found in your ZegoCloud Admin Console project details.',
                      ),
                    ),
                    const SizedBox(height: 16),
                    TextField(
                      key: const Key('zego_app_sign_field'),
                      controller: _appSignController,
                      obscureText: _obscureAppSign,
                      decoration: InputDecoration(
                        labelText: 'Zego App Sign',
                        hintText: '64-character hexadecimal sign key',
                        prefixIcon: const Icon(Icons.key_rounded),
                        border: const OutlineInputBorder(),
                        helperText: 'Server/App sign key from Zego project credentials.',
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
          ],

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

    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: isSelected
              ? scheme.primary.withValues(alpha: 0.08)
              : scheme.surface,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: isSelected ? scheme.primary : scheme.outlineVariant,
            width: isSelected ? 2 : 1,
          ),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: isSelected
                    ? scheme.primary
                    : scheme.surfaceContainerHighest,
                shape: BoxShape.circle,
              ),
              child: Icon(
                icon,
                color: isSelected ? scheme.onPrimary : scheme.onSurfaceVariant,
                size: 22,
              ),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Text(
                        title,
                        style: Theme.of(context).textTheme.titleMedium?.copyWith(
                              fontWeight: FontWeight.bold,
                            ),
                      ),
                      const SizedBox(width: 8),
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                        decoration: BoxDecoration(
                          color: badgeColor.withValues(alpha: 0.15),
                          borderRadius: BorderRadius.circular(6),
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
                  const SizedBox(height: 6),
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
            const SizedBox(width: 8),
            Icon(
              isSelected
                  ? Icons.radio_button_checked_rounded
                  : Icons.radio_button_off_rounded,
              color: isSelected ? scheme.primary : scheme.outline,
            ),
          ],
        ),
      ),
    );
  }
}
