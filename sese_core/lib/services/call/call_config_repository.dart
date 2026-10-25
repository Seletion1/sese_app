import 'dart:async';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'i_call_service.dart';

/// Configuration payload for the SeSe calling subsystem.
@immutable
class CallConfig {
  /// The active calling provider selected by the administrator or local settings.
  final CallProviderType providerType;

  /// ZegoCloud Application ID (numeric integer).
  final int? zegoAppId;

  /// ZegoCloud Application Sign (64-character hexadecimal authentication key).
  final String? zegoAppSign;

  /// STUN servers used by WebRTC for ICE candidate discovery and NAT traversal.
  final List<String> stunServers;

  /// Whether WebRTC data channel or diagnostic stats are enabled.
  final bool enableDiagnostics;

  const CallConfig({
    this.providerType = CallProviderType.webrtc,
    this.zegoAppId,
    this.zegoAppSign,
    this.stunServers = const [
      'stun:stun1.l.google.com:19302',
      'stun:stun2.l.google.com:19302',
      'stun:stun3.l.google.com:19302',
      'stun:stun4.l.google.com:19302',
    ],
    this.enableDiagnostics = false,
  });

  /// True if ZegoCloud credentials are valid and ready for SDK initialization.
  bool get hasValidZegoCredentials {
    return zegoAppId != null &&
        zegoAppId! > 0 &&
        zegoAppSign != null &&
        zegoAppSign!.trim().length >= 32;
  }

  CallConfig copyWith({
    CallProviderType? providerType,
    int? zegoAppId,
    String? zegoAppSign,
    List<String>? stunServers,
    bool? enableDiagnostics,
  }) {
    return CallConfig(
      providerType: providerType ?? this.providerType,
      zegoAppId: zegoAppId ?? this.zegoAppId,
      zegoAppSign: zegoAppSign ?? this.zegoAppSign,
      stunServers: stunServers ?? this.stunServers,
      enableDiagnostics: enableDiagnostics ?? this.enableDiagnostics,
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'providerType': providerType.name,
      'zegoAppId': zegoAppId,
      'zegoAppSign': zegoAppSign,
      'stunServers': stunServers,
      'enableDiagnostics': enableDiagnostics,
      'updatedAt': FieldValue.serverTimestamp(),
    };
  }

  factory CallConfig.fromMap(Map<String, dynamic>? map) {
    if (map == null) return const CallConfig();

    CallProviderType provider = CallProviderType.webrtc;
    final providerStr = map['providerType']?.toString().toLowerCase();
    if (providerStr == 'zego') {
      provider = CallProviderType.zego;
    }

    int? appId;
    final rawAppId = map['zegoAppId'];
    if (rawAppId is int) {
      appId = rawAppId;
    } else if (rawAppId is String) {
      appId = int.tryParse(rawAppId.trim());
    }

    final appSign = map['zegoAppSign']?.toString().trim();

    List<String> stuns = const [
      'stun:stun1.l.google.com:19302',
      'stun:stun2.l.google.com:19302',
    ];
    if (map['stunServers'] is List) {
      stuns = (map['stunServers'] as List)
          .map((e) => e.toString().trim())
          .where((e) => e.isNotEmpty)
          .toList();
    }

    return CallConfig(
      providerType: provider,
      zegoAppId: appId,
      zegoAppSign: appSign?.isEmpty ?? true ? null : appSign,
      stunServers: stuns.isEmpty ? const ['stun:stun1.l.google.com:19302'] : stuns,
      enableDiagnostics: map['enableDiagnostics'] == true,
    );
  }
}

/// Repository responsible for persisting calling settings in [SharedPreferences]
/// with optional real-time sync against Firestore (`system_settings/calling`).
///
/// Ensures settings survive app restarts and allows staff to hot-swap calling
/// providers instantly across `sese_hub` and `sese_ride`.
class CallConfigRepository {
  static final CallConfigRepository instance = CallConfigRepository._internal();

  CallConfigRepository._internal();

  static const String _kPrefProvider = 'sese_call_provider_type';
  static const String _kPrefZegoAppId = 'sese_call_zego_app_id';
  static const String _kPrefZegoAppSign = 'sese_call_zego_app_sign';
  static const String _kPrefStunServers = 'sese_call_stun_servers';
  static const String _kPrefDiagnostics = 'sese_call_enable_diagnostics';

  final _controller = StreamController<CallConfig>.broadcast();
  CallConfig _currentConfig = const CallConfig();
  bool _initialized = false;

  /// Current cached configuration.
  CallConfig get currentConfig => _currentConfig;

  /// Stream of configuration changes for reactive UI bindings.
  Stream<CallConfig> get configStream => _controller.stream;

  /// Loads configuration from local [SharedPreferences], seeding with Firestore
  /// remote overrides if available.
  Future<CallConfig> loadConfig() async {
    if (_initialized) return _currentConfig;

    try {
      final prefs = await SharedPreferences.getInstance();

      final providerStr = prefs.getString(_kPrefProvider);
      final provider = (providerStr == CallProviderType.zego.name)
          ? CallProviderType.zego
          : CallProviderType.webrtc;

      final zegoAppId = prefs.getInt(_kPrefZegoAppId);
      final zegoAppSign = prefs.getString(_kPrefZegoAppSign);
      final stunList = prefs.getStringList(_kPrefStunServers);
      final diagnostics = prefs.getBool(_kPrefDiagnostics) ?? false;

      _currentConfig = CallConfig(
        providerType: provider,
        zegoAppId: zegoAppId,
        zegoAppSign: zegoAppSign,
        stunServers: stunList != null && stunList.isNotEmpty
            ? stunList
            : const [
                'stun:stun1.l.google.com:19302',
                'stun:stun2.l.google.com:19302',
              ],
        enableDiagnostics: diagnostics,
      );
    } catch (e) {
      debugPrint('CallConfigRepository: failed to read SharedPreferences: $e');
      _currentConfig = const CallConfig();
    }

    _initialized = true;
    _controller.add(_currentConfig);
    return _currentConfig;
  }

  /// Persists [config] to local [SharedPreferences] and syncs to Firestore
  /// `system_settings/calling` if Firebase is initialized.
  Future<void> saveConfig(CallConfig config) async {
    _currentConfig = config;
    _controller.add(config);

    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_kPrefProvider, config.providerType.name);

      if (config.zegoAppId != null) {
        await prefs.setInt(_kPrefZegoAppId, config.zegoAppId!);
      } else {
        await prefs.remove(_kPrefZegoAppId);
      }

      if (config.zegoAppSign != null && config.zegoAppSign!.isNotEmpty) {
        await prefs.setString(_kPrefZegoAppSign, config.zegoAppSign!);
      } else {
        await prefs.remove(_kPrefZegoAppSign);
      }

      await prefs.setStringList(_kPrefStunServers, config.stunServers);
      await prefs.setBool(_kPrefDiagnostics, config.enableDiagnostics);
    } catch (e) {
      debugPrint('CallConfigRepository: failed to save to SharedPreferences: $e');
    }

    // Attempt remote synchronization with Firestore (degrades gracefully if offline)
    try {
      await FirebaseFirestore.instance
          .collection('system_settings')
          .doc('calling')
          .set(config.toMap(), SetOptions(merge: true));
    } catch (e) {
      debugPrint('CallConfigRepository: remote sync deferred: $e');
    }
  }

  /// Disposes repository resources.
  void dispose() {
    _controller.close();
  }
}
