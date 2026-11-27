import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:flutter/material.dart';
import 'package:sese_core/sese_core.dart';

/// Screen allowing administrators to configure and test WebRTC in-app calling
/// (STUN/TURN relay credentials and call pipeline diagnostics).
class CallingConfigScreen extends StatefulWidget {
  const CallingConfigScreen({super.key});

  @override
  State<CallingConfigScreen> createState() => _CallingConfigScreenState();
}

class _CallingConfigScreenState extends State<CallingConfigScreen> {
  final _configRepo = CallConfigRepository.instance;
  final _callManager = CallServiceManager.instance;

  late final TextEditingController _turnUrlController;
  late final TextEditingController _turnUsernameController;
  late final TextEditingController _turnCredentialController;

  bool _isLoading = true;
  bool _isSaving = false;
  bool _isCheckingTurn = false;
  String? _turnHealthMessage;
  bool? _turnHealthOk;

  @override
  void initState() {
    super.initState();
    _turnUrlController = TextEditingController();
    _turnUsernameController = TextEditingController();
    _turnCredentialController = TextEditingController();
    _loadConfig();
  }

  Future<void> _loadConfig() async {
    final config = await _configRepo.loadConfig();

    String? secretTurnUrl;
    String? secretTurnUser;
    String? secretTurnCred;

    try {
      final secretDoc = await FirebaseFirestore.instance
          .collection('system_config')
          .doc('call_secrets')
          .get();
      if (secretDoc.exists && secretDoc.data() != null) {
        final sData = secretDoc.data()!;
        secretTurnUrl = sData['turnUrl']?.toString();
        secretTurnUser = sData['turnUsername']?.toString();
        secretTurnCred = sData['turnCredential']?.toString();
      }
    } catch (e) {
      debugPrint('CallingConfigScreen: could not load call_secrets: $e');
    }

    if (!mounted) return;
    setState(() {
      if (secretTurnUrl != null && secretTurnUrl.isNotEmpty) {
        _turnUrlController.text = secretTurnUrl;
      } else if (config.turnServers.isNotEmpty) {
        _turnUrlController.text =
            config.turnServers.first['urls']?.toString() ?? '';
      }
      if (secretTurnUser != null && secretTurnUser.isNotEmpty) {
        _turnUsernameController.text = secretTurnUser;
      } else if (config.turnServers.isNotEmpty) {
        _turnUsernameController.text =
            config.turnServers.first['username']?.toString() ?? '';
      }
      if (secretTurnCred != null && secretTurnCred.isNotEmpty) {
        _turnCredentialController.text = secretTurnCred;
      } else if (config.turnServers.isNotEmpty) {
        _turnCredentialController.text =
            config.turnServers.first['credential']?.toString() ?? '';
      }
      _isLoading = false;
    });
  }

  @override
  void dispose() {
    _turnUrlController.dispose();
    _turnUsernameController.dispose();
    _turnCredentialController.dispose();
    super.dispose();
  }

  Future<void> _saveConfig() async {
    setState(() => _isSaving = true);

    final parsedTurnUrl = _turnUrlController.text.trim();
    final parsedTurnUser = _turnUsernameController.text.trim();
    final parsedTurnCred = _turnCredentialController.text.trim();

    // Security: Never write TURN credentials into system_settings/calling
    // (which is readable by user apps). Store them strictly in
    // /system_config/call_secrets so sese_ride fetches them via getIceServers.
    final newConfig = _configRepo.currentConfig.copyWith(
      turnServers: const <Map<String, dynamic>>[],
    );

    try {
      await _configRepo.saveConfig(newConfig);

      final secretsUpdate = <String, dynamic>{
        'updatedAt': FieldValue.serverTimestamp(),
      };
      if (parsedTurnUrl.isNotEmpty) {
        secretsUpdate['turnUrl'] = parsedTurnUrl;
        secretsUpdate['turnUsername'] = parsedTurnUser;
        secretsUpdate['turnCredential'] = parsedTurnCred;
      } else {
        secretsUpdate['turnUrl'] = FieldValue.delete();
        secretsUpdate['turnUsername'] = FieldValue.delete();
        secretsUpdate['turnCredential'] = FieldValue.delete();
      }
      await FirebaseFirestore.instance
          .collection('system_config')
          .doc('call_secrets')
          .set(secretsUpdate, SetOptions(merge: true));

      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('WebRTC calling settings saved & synced across apps.'),
          backgroundColor: Colors.green,
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Error saving settings: $e'),
          backgroundColor: Colors.red,
        ),
      );
    } finally {
      if (mounted) setState(() => _isSaving = false);
    }
  }

  Future<void> _verifyTurnServers() async {
    setState(() {
      _isCheckingTurn = true;
      _turnHealthMessage = null;
    });
    try {
      final res = await FirebaseFunctions.instance
          .httpsCallable('getIceServers')
          .call<Map<String, dynamic>>();
      final hasTurn = res.data['hasTurn'] == true;
      final servers = res.data['iceServers'];
      final count = servers is List ? servers.length : 0;
      if (!mounted) return;
      setState(() {
        _turnHealthOk = hasTurn;
        _turnHealthMessage = hasTurn
            ? 'TURN active ($count ICE servers returned by getIceServers).'
            : 'STUN-only ($count servers). Save TURN credentials above for cross-network WebRTC.';
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _turnHealthOk = false;
        _turnHealthMessage = 'Unable to verify getIceServers: $e';
      });
    } finally {
      if (mounted) setState(() => _isCheckingTurn = false);
    }
  }

  void _triggerTestCall() {
    final testCallId = 'test_${DateTime.now().millisecondsSinceEpoch}';
    InAppCallScreen.start(
      context: context,
      callId: testCallId,
      targetUserId: 'test_peer_001',
      targetUserName: 'SeSe Audio Test Peer',
      metadata: const {'isTestCall': true},
    );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    if (_isLoading) {
      return Scaffold(
        appBar: AppBar(title: const Text('Calling & VoIP Settings')),
        body: const Center(child: CircularProgressIndicator()),
      );
    }

    return Scaffold(
      appBar: AppBar(
        title: const Text('Calling & VoIP Settings'),
        actions: [
          if (_isSaving)
            const Padding(
              padding: EdgeInsets.all(16),
              child: SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            )
          else
            TextButton.icon(
              key: const Key('calling_config_save_button'),
              onPressed: _saveConfig,
              icon: const Icon(Icons.check_rounded),
              label: const Text('Save'),
            ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          // ── Status Banner ────────────────────────────────────────────────
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: Colors.teal.withValues(alpha: 0.1),
              borderRadius: BorderRadius.circular(14),
              border: Border.all(
                color: Colors.teal.withValues(alpha: 0.35),
              ),
            ),
            child: Row(
              children: [
                const Icon(
                  Icons.graphic_eq_rounded,
                  color: Colors.teal,
                  size: 32,
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        'Self-Hosted WebRTC Voice Engine',
                        style: TextStyle(
                          fontWeight: FontWeight.bold,
                          fontSize: 15,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        'End-to-end DTLS/SRTP encrypted audio via Firestore signaling and STUN/TURN traversal.',
                        style: TextStyle(
                          fontSize: 12,
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

          // ── WebRTC STUN & TURN Traversal ─────────────────────────────────
          const _SectionLabel('WebRTC Signaling, STUN & TURN Traversal'),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      const Icon(Icons.public_rounded,
                          size: 20, color: Colors.blueGrey),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          'Google Public STUN Servers',
                          style:
                              Theme.of(context).textTheme.titleSmall?.copyWith(
                                    fontWeight: FontWeight.bold,
                                  ),
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
                          const Icon(Icons.check_circle_outline,
                              size: 14, color: Colors.green),
                          const SizedBox(width: 6),
                          Expanded(
                            child: Text(
                              stun,
                              style: TextStyle(
                                fontSize: 12,
                                fontFamily: 'monospace',
                                color: scheme.onSurfaceVariant,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  const Divider(height: 24),
                  Text(
                    'TURN Relay (Cross-Carrier Mobile NAT)',
                    style: Theme.of(context).textTheme.titleSmall?.copyWith(
                          fontWeight: FontWeight.bold,
                        ),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    'Required for WebRTC audio when caller and receiver are on different mobile networks (MTN/Airtel/Glo). Saved to /system_config/call_secrets.',
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: scheme.onSurfaceVariant,
                        ),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: _turnUrlController,
                    decoration: const InputDecoration(
                      labelText: 'TURN Server URL',
                      hintText: 'turn:relay.example.com:3478?transport=udp',
                      border: OutlineInputBorder(),
                    ),
                  ),
                  const SizedBox(height: 10),
                  Row(
                    children: [
                      Expanded(
                        child: TextField(
                          controller: _turnUsernameController,
                          decoration: const InputDecoration(
                            labelText: 'TURN Username',
                            border: OutlineInputBorder(),
                          ),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: TextField(
                          controller: _turnCredentialController,
                          obscureText: true,
                          decoration: const InputDecoration(
                            labelText: 'TURN Credential',
                            border: OutlineInputBorder(),
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  OutlinedButton.icon(
                    key: const Key('verify_turn_servers_button'),
                    onPressed: _isCheckingTurn ? null : _verifyTurnServers,
                    icon: _isCheckingTurn
                        ? const SizedBox(
                            width: 14,
                            height: 14,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.network_check_rounded, size: 18),
                    label: const Text('Verify TURN / ICE Servers'),
                  ),
                  if (_turnHealthMessage != null) ...[
                    const SizedBox(height: 8),
                    Text(
                      _turnHealthMessage!,
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        color: _turnHealthOk == true
                            ? Colors.green.shade700
                            : Colors.amber.shade800,
                      ),
                    ),
                  ],
                  const Divider(height: 24),
                  Row(
                    children: [
                      const Icon(Icons.mic_none_rounded,
                          size: 18, color: Colors.cyan),
                      const SizedBox(width: 6),
                      Expanded(
                        child: Text(
                          'Optimized Audio: Echo Cancellation, Noise Suppression, and Auto Gain Control active.',
                          style:
                              Theme.of(context).textTheme.bodySmall?.copyWith(
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
              subtitle: const Text(
                  'Launch an interactive test call to verify microphone, speaker, and UI state.'),
              trailing: const Icon(Icons.arrow_forward_ios_rounded, size: 16),
              onTap: _triggerTestCall,
            ),
          ),

          const SizedBox(height: 16),

          // ── Current Runtime Summary ───────────────────────────────────────
          Card(
            color: scheme.surfaceContainerHighest.withValues(alpha: 0.4),
            child: Padding(
              padding: const EdgeInsets.all(14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Active Manager State',
                    style: Theme.of(context).textTheme.labelMedium?.copyWith(
                          color: scheme.onSurfaceVariant,
                          fontWeight: FontWeight.bold,
                        ),
                  ),
                  const SizedBox(height: 8),
                  _InfoRow(
                    'Initialized',
                    _callManager.isInitialized ? 'Yes' : 'No',
                  ),
                  _InfoRow('Engine', 'Native WebRTC'),
                  _InfoRow('Current State', _callManager.currentState.name),
                ],
              ),
            ),
          ),

          const SizedBox(height: 36),
        ],
      ),
    );
  }
}

class _SectionLabel extends StatelessWidget {
  final String text;
  const _SectionLabel(this.text);

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(left: 4, bottom: 8),
      child: Text(
        text.toUpperCase(),
        style: TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w700,
          letterSpacing: 1.0,
          color: Theme.of(context).colorScheme.primary,
        ),
      ),
    );
  }
}

class _InfoRow extends StatelessWidget {
  final String label;
  final String value;

  const _InfoRow(this.label, this.value);

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(
            label,
            style: TextStyle(
              fontSize: 13,
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
          Text(
            value,
            style: const TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }
}
