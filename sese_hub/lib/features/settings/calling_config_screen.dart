import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:flutter/material.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
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
  bool _obscureCredential = true;
  bool _hasSavedCredential = false;
  String? _loadError;
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
    String? loadErr;

    try {
      DocumentSnapshot<Map<String, dynamic>> secretDoc;
      try {
        secretDoc = await FirebaseFirestore.instance
            .collection('system_config')
            .doc('call_secrets')
            .get(const GetOptions(source: Source.server))
            .timeout(const Duration(seconds: 8));
      } catch (_) {
        secretDoc = await FirebaseFirestore.instance
            .collection('system_config')
            .doc('call_secrets')
            .get()
            .timeout(const Duration(seconds: 8));
      }
      if (secretDoc.exists && secretDoc.data() != null) {
        final sData = secretDoc.data()!;
        secretTurnUrl = (sData['turnUrl'] ?? sData['urls'] ?? sData['url'])?.toString().trim();
        secretTurnUser = (sData['turnUsername'] ?? sData['username'])?.toString().trim();
        secretTurnCred = (sData['turnCredential'] ?? sData['credential'])?.toString().trim();
      }
    } catch (e) {
      debugPrint('CallingConfigScreen: could not load call_secrets: $e');
      loadErr = 'Could not load saved TURN secrets from server: $e';
    }

    if (!mounted) return;
    setState(() {
      _loadError = loadErr;
      if (secretTurnUrl != null && secretTurnUrl.isNotEmpty) {
        _turnUrlController.text = secretTurnUrl;
      } else if (config.turnServers.isNotEmpty) {
        _turnUrlController.text =
            config.turnServers.first['urls']?.toString().trim() ?? '';
      }
      if (secretTurnUser != null && secretTurnUser.isNotEmpty) {
        _turnUsernameController.text = secretTurnUser;
      } else if (config.turnServers.isNotEmpty) {
        _turnUsernameController.text =
            config.turnServers.first['username']?.toString().trim() ?? '';
      }
      if (secretTurnCred != null && secretTurnCred.isNotEmpty) {
        _turnCredentialController.text = secretTurnCred;
        _hasSavedCredential = true;
      } else if (config.turnServers.isNotEmpty) {
        final fallbackCred =
            config.turnServers.first['credential']?.toString().trim() ?? '';
        _turnCredentialController.text = fallbackCred;
        _hasSavedCredential = fallbackCred.isNotEmpty;
      } else {
        _hasSavedCredential = false;
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
    final parsedTurnUrl = _turnUrlController.text.trim();
    final parsedTurnUser = _turnUsernameController.text.trim();
    final parsedTurnCred = _turnCredentialController.text.trim();

    if ((parsedTurnUser.isNotEmpty || parsedTurnCred.isNotEmpty) &&
        parsedTurnUrl.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Please enter a TURN Server URL before saving credentials.'),
          backgroundColor: Colors.red,
        ),
      );
      return;
    }

    if (parsedTurnUrl.isNotEmpty &&
        !parsedTurnUrl.startsWith('turn:') &&
        !parsedTurnUrl.startsWith('turns:')) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('TURN Server URL must start with turn: or turns:'),
          backgroundColor: Colors.red,
        ),
      );
      return;
    }

    setState(() {
      _isSaving = true;
      _loadError = null;
    });

    // Security: Never write TURN credentials into system_settings/calling
    // (which is readable by user apps). Store them strictly in
    // /system_config/call_secrets so sese_ride/sese_hub fetch them via getIceServers.
    final newConfig = _configRepo.currentConfig.copyWith(
      turnServers: const <Map<String, dynamic>>[],
      turnConfigVersion: DateTime.now().millisecondsSinceEpoch,
    );

    try {
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

      final secretsRef = FirebaseFirestore.instance
          .collection('system_config')
          .doc('call_secrets');

      await secretsRef
          .set(secretsUpdate, SetOptions(merge: true))
          .timeout(const Duration(seconds: 10));

      // Verify server persistence before confirming success.
      final verifySnap = await secretsRef
          .get(const GetOptions(source: Source.server))
          .timeout(const Duration(seconds: 8));
      final savedUrl = (verifySnap.data()?['turnUrl'] ?? '').toString().trim();
      if (parsedTurnUrl.isNotEmpty && savedUrl != parsedTurnUrl) {
        throw StateError('Verification read-back mismatch on /system_config/call_secrets.');
      }

      await _configRepo.saveConfig(newConfig, throwOnRemoteError: true);

      if (!mounted) return;
      setState(() {
        _hasSavedCredential = parsedTurnUrl.isNotEmpty && parsedTurnCred.isNotEmpty;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('WebRTC calling settings saved & verified in /system_config/call_secrets.'),
          backgroundColor: Colors.green,
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Failed to save TURN settings: $e'),
          backgroundColor: Colors.red,
        ),
      );
    } finally {
      if (mounted) setState(() => _isSaving = false);
    }
  }

  Future<void> _verifyTurnServers() async {
    final enteredUrl = _turnUrlController.text.trim();
    final enteredUser = _turnUsernameController.text.trim();
    final enteredCred = _turnCredentialController.text.trim();

    setState(() {
      _isCheckingTurn = true;
      _turnHealthMessage = null;
      _turnHealthOk = null;
    });

    RTCPeerConnection? probePc;
    try {
      // 1. Validate format & credentials if TURN URL is entered.
      if (enteredUrl.isEmpty) {
        setState(() {
          _turnHealthOk = false;
          _turnHealthMessage =
              'No TURN Server URL entered. Enter a turn: or turns: URL and credentials to test relay.';
        });
        return;
      }

      if (!enteredUrl.startsWith('turn:') && !enteredUrl.startsWith('turns:')) {
        setState(() {
          _turnHealthOk = false;
          _turnHealthMessage =
              'Invalid TURN URL format. Must start with turn: or turns:.';
        });
        return;
      }

      if (enteredUser.isEmpty || enteredCred.isEmpty) {
        setState(() {
          _turnHealthOk = false;
          _turnHealthMessage =
              'TURN Username and TURN Credential are both required for relay authentication.';
        });
        return;
      }

      // 2. Check backend getIceServers sync status.
      bool backendHasTurn = false;
      String backendNote = '';
      try {
        final res = await FirebaseFunctions.instance
            .httpsCallable('getIceServers')
            .call<Map<String, dynamic>>()
            .timeout(const Duration(seconds: 6));
        backendHasTurn = res.data['hasTurn'] == true;
        backendNote = backendHasTurn
            ? 'Backend getIceServers synced.'
            : 'Backend not synced yet (tap Save to persist).';
      } catch (e) {
        backendNote = 'Backend check failed: $e';
      }

      // 3. Real WebRTC ICE candidate gathering probe against STUN + TURN.
      final iceServers = <Map<String, dynamic>>[
        for (final stun in _configRepo.currentConfig.stunServers)
          {'urls': stun},
        {
          'urls': enteredUrl,
          'username': enteredUser,
          'credential': enteredCred,
        },
      ];

      probePc = await createPeerConnection({
        'iceServers': iceServers,
        'sdpSemantics': 'unified-plan',
      });

      final relayCompleter = Completer<bool>();
      var sawSrflx = false;
      var sawRelay = false;

      probePc.onIceCandidate = (candidate) {
        final candStr = candidate.candidate ?? '';
        if (candStr.contains('typ srflx')) {
          sawSrflx = true;
        }
        if (candStr.contains('typ relay')) {
          sawRelay = true;
          if (!relayCompleter.isCompleted) relayCompleter.complete(true);
        }
      };

      await probePc.createDataChannel('turn_probe', RTCDataChannelInit());
      final offer = await probePc.createOffer();
      await probePc.setLocalDescription(offer);

      final relayOk = await relayCompleter.future.timeout(
        const Duration(seconds: 6),
        onTimeout: () => sawRelay,
      );

      if (!mounted) return;
      setState(() {
        _turnHealthOk = relayOk;
        _turnHealthMessage = relayOk
            ? 'TURN relay verified! Allocated relay candidate via $enteredUrl. $backendNote'
            : 'TURN relay failed (STUN ${sawSrflx ? "OK" : "failed"}, no relay candidate allocated). Check URL, port, username, or credential. $backendNote';
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _turnHealthOk = false;
        _turnHealthMessage = 'TURN verification failed: $e';
      });
    } finally {
      try {
        await probePc?.close();
      } catch (_) {}
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
                  if (_loadError != null) ...[
                    Container(
                      margin: const EdgeInsets.only(bottom: 12),
                      padding: const EdgeInsets.all(10),
                      decoration: BoxDecoration(
                        color: Colors.red.withValues(alpha: 0.1),
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(color: Colors.red.withValues(alpha: 0.4)),
                      ),
                      child: Text(
                        _loadError!,
                        style: TextStyle(fontSize: 12, color: Colors.red.shade800),
                      ),
                    ),
                  ],
                  TextField(
                    key: const Key('turn_url_input'),
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
                          key: const Key('turn_username_input'),
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
                          key: const Key('turn_credential_input'),
                          controller: _turnCredentialController,
                          obscureText: _obscureCredential,
                          decoration: InputDecoration(
                            labelText: _hasSavedCredential
                                ? 'TURN Credential (Saved)'
                                : 'TURN Credential',
                            border: const OutlineInputBorder(),
                            suffixIcon: IconButton(
                              tooltip: _obscureCredential ? 'Reveal' : 'Hide',
                              icon: Icon(
                                _obscureCredential
                                    ? Icons.visibility_outlined
                                    : Icons.visibility_off_outlined,
                                size: 18,
                              ),
                              onPressed: () => setState(
                                () => _obscureCredential = !_obscureCredential,
                              ),
                            ),
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
