import 'dart:async';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'i_call_service.dart';

/// Configuration payload for the SeSe calling subsystem.
@immutable
class CallConfig {
  /// Default Google public STUN servers for NAT discovery.
  static const List<String> defaultGoogleStunServers = [
    'stun:stun.l.google.com:19302',
    'stun:stun1.l.google.com:19302',
    'stun:stun2.l.google.com:19302',
  ];

  /// The active calling routing mode.
  final CallRoutingMode routingMode;

  /// Timeout in seconds before smart fallback drops from WebRTC to third-party SDK.
  final int fallbackTimeoutSeconds;

  /// ZegoCloud Application ID (numeric integer).
  final int? zegoAppId;

  /// ZegoCloud Application Sign (64-character hexadecimal authentication key).
  final String? zegoAppSign;

  /// STUN servers used by WebRTC for ICE candidate discovery and NAT traversal.
  final List<String> stunServers;

  /// Whether WebRTC data channel or diagnostic stats are enabled.
  final bool enableDiagnostics;

  const CallConfig({
    this.routingMode = CallRoutingMode.smartFallback,
    this.fallbackTimeoutSeconds = 10,
    this.zegoAppId,
    this.zegoAppSign,
    this.stunServers = defaultGoogleStunServers,
    this.enableDiagnostics = false,
  });

  /// The primary calling provider derived from the active routing mode.
  CallProviderType get providerType {
    switch (routingMode) {
      case CallRoutingMode.thirdPartyOnly:
        return CallProviderType.zego;
      case CallRoutingMode.customP2pOnly:
      case CallRoutingMode.smartFallback:
        return CallProviderType.webrtc;
    }
  }

  /// True if ZegoCloud credentials are valid and ready for SDK initialization.
  bool get hasValidZegoCredentials {
    return zegoAppId != null &&
        zegoAppId! > 0 &&
        zegoAppSign != null &&
        zegoAppSign!.trim().length >= 32;
  }

  CallConfig copyWith({
    CallRoutingMode? routingMode,
    int? fallbackTimeoutSeconds,
    CallProviderType? providerType,
    int? zegoAppId,
    String? zegoAppSign,
    List<String>? stunServers,
    bool? enableDiagnostics,
  }) {
    // If providerType is passed without routingMode, map it back for backwards compatibility
    CallRoutingMode mode = routingMode ?? this.routingMode;
    if (routingMode == null && providerType != null) {
      mode = providerType == CallProviderType.zego
          ? CallRoutingMode.thirdPartyOnly
          : CallRoutingMode.customP2pOnly;
    }

    return CallConfig(
      routingMode: mode,
      fallbackTimeoutSeconds: fallbackTimeoutSeconds ?? this.fallbackTimeoutSeconds,
      zegoAppId: zegoAppId ?? this.zegoAppId,
      zegoAppSign: zegoAppSign ?? this.zegoAppSign,
      stunServers: stunServers ?? this.stunServers,
      enableDiagnostics: enableDiagnostics ?? this.enableDiagnostics,
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'routingMode': routingMode.name,
      'providerType': providerType.name,
      'fallbackTimeoutSeconds': fallbackTimeoutSeconds,
      'zegoAppId': zegoAppId,
      'zegoAppSign': zegoAppSign,
      'stunServers': stunServers,
      'enableDiagnostics': enableDiagnostics,
      'updatedAt': FieldValue.serverTimestamp(),
    };
  }

  factory CallConfig.fromMap(Map<String, dynamic>? map) {
    if (map == null) return const CallConfig();

    CallRoutingMode routingMode = CallRoutingMode.smartFallback;
    final modeStr = map['routingMode']?.toString().toLowerCase().trim();
    if (modeStr == 'customp2ponly' || modeStr == 'custom_p2p_only' || modeStr == 'webrtc') {
      routingMode = CallRoutingMode.customP2pOnly;
    } else if (modeStr == 'thirdpartyonly' || modeStr == 'third_party_only' || modeStr == 'zego') {
      routingMode = CallRoutingMode.thirdPartyOnly;
    } else if (modeStr == 'smartfallback' || modeStr == 'smart_fallback' || modeStr == 'auto') {
      routingMode = CallRoutingMode.smartFallback;
    } else {
      // Legacy fallback: check providerType
      final providerStr = map['providerType']?.toString().toLowerCase().trim();
      if (providerStr == 'zego') {
        routingMode = CallRoutingMode.thirdPartyOnly;
      } else {
        routingMode = CallRoutingMode.smartFallback;
      }
    }

    int timeout = 10;
    final rawTimeout = map['fallbackTimeoutSeconds'];
    if (rawTimeout is int) {
      timeout = rawTimeout.clamp(3, 30);
    } else if (rawTimeout is String) {
      final parsed = int.tryParse(rawTimeout.trim());
      if (parsed != null) timeout = parsed.clamp(3, 30);
    }

    int? appId;
    final rawAppId = map['zegoAppId'];
    if (rawAppId is int) {
      appId = rawAppId;
    } else if (rawAppId is String) {
      appId = int.tryParse(rawAppId.trim());
    }

    final appSign = map['zegoAppSign']?.toString().trim();

    List<String> stuns = defaultGoogleStunServers;
    if (map['stunServers'] is List) {
      final parsedList = (map['stunServers'] as List)
          .map((e) => e.toString().trim())
          .where((e) => e.isNotEmpty)
          .toList();
      if (parsedList.isNotEmpty) {
        stuns = parsedList;
      }
    }

    return CallConfig(
      routingMode: routingMode,
      fallbackTimeoutSeconds: timeout,
      zegoAppId: appId,
      zegoAppSign: appSign?.isEmpty ?? true ? null : appSign,
      stunServers: stuns,
      enableDiagnostics: map['enableDiagnostics'] == true,
    );
  }
}

/// Repository responsible for persisting calling settings in [SharedPreferences]
/// with real-time bidirectional synchronization against Firestore (`system_settings/calling`).
///
/// Ensures settings survive app restarts and allows staff to hot-swap calling
/// providers and routing modes instantly across `sese_hub` and `sese_ride`.
class CallConfigRepository {
  static final CallConfigRepository instance = CallConfigRepository._internal();

  CallConfigRepository._internal();

  static const String _kPrefRoutingMode = 'sese_call_routing_mode';
  static const String _kPrefFallbackTimeout = 'sese_call_fallback_timeout';
  static const String _kPrefProvider = 'sese_call_provider_type';
  static const String _kPrefZegoAppId = 'sese_call_zego_app_id';
  static const String _kPrefZegoAppSign = 'sese_call_zego_app_sign';
  static const String _kPrefStunServers = 'sese_call_stun_servers';
  static const String _kPrefDiagnostics = 'sese_call_enable_diagnostics';

  final _controller = StreamController<CallConfig>.broadcast();
  CallConfig _currentConfig = const CallConfig();
  bool _initialized = false;
  StreamSubscription<DocumentSnapshot<Map<String, dynamic>>>? _firestoreSub;

  /// Current cached configuration.
  CallConfig get currentConfig => _currentConfig;

  /// Stream of configuration changes for reactive UI bindings.
  Stream<CallConfig> get configStream => _controller.stream;

  /// Loads configuration from local [SharedPreferences], seeding with Firestore
  /// remote overrides and real-time updates.
  Future<CallConfig> loadConfig() async {
    if (_initialized) return _currentConfig;

    try {
      final prefs = await SharedPreferences.getInstance();

      final routingModeStr = prefs.getString(_kPrefRoutingMode);
      CallRoutingMode mode = CallRoutingMode.smartFallback;
      if (routingModeStr == CallRoutingMode.customP2pOnly.name) {
        mode = CallRoutingMode.customP2pOnly;
      } else if (routingModeStr == CallRoutingMode.thirdPartyOnly.name) {
        mode = CallRoutingMode.thirdPartyOnly;
      } else if (routingModeStr == CallRoutingMode.smartFallback.name) {
        mode = CallRoutingMode.smartFallback;
      } else {
        // Fallback to legacy provider key if routing mode not set yet
        final legacyProviderStr = prefs.getString(_kPrefProvider);
        if (legacyProviderStr == CallProviderType.zego.name) {
          mode = CallRoutingMode.thirdPartyOnly;
        }
      }

      final fallbackTimeout = prefs.getInt(_kPrefFallbackTimeout) ?? 10;
      final zegoAppId = prefs.getInt(_kPrefZegoAppId);
      final zegoAppSign = prefs.getString(_kPrefZegoAppSign);
      final stunList = prefs.getStringList(_kPrefStunServers);
      final diagnostics = prefs.getBool(_kPrefDiagnostics) ?? false;

      _currentConfig = CallConfig(
        routingMode: mode,
        fallbackTimeoutSeconds: fallbackTimeout,
        zegoAppId: zegoAppId,
        zegoAppSign: zegoAppSign,
        stunServers: stunList != null && stunList.isNotEmpty
            ? stunList
            : CallConfig.defaultGoogleStunServers,
        enableDiagnostics: diagnostics,
      );
    } catch (e) {
      debugPrint('CallConfigRepository: failed to read SharedPreferences: $e');
      _currentConfig = const CallConfig();
    }

    _initialized = true;
    _controller.add(_currentConfig);

    // Initialize real-time listener for remote settings updates
    _startRemoteSyncListener();

    return _currentConfig;
  }

  /// Starts listening to remote configuration updates from Firestore.
  void _startRemoteSyncListener() {
    try {
      _firestoreSub?.cancel();
      _firestoreSub = FirebaseFirestore.instance
          .collection('system_settings')
          .doc('calling')
          .snapshots()
          .listen(
        (snapshot) {
          if (!snapshot.exists || snapshot.data() == null) return;
          final remoteConfig = CallConfig.fromMap(snapshot.data());

          // Only emit and persist if meaningfully different
          if (remoteConfig.routingMode != _currentConfig.routingMode ||
              remoteConfig.fallbackTimeoutSeconds != _currentConfig.fallbackTimeoutSeconds ||
              remoteConfig.zegoAppId != _currentConfig.zegoAppId ||
              remoteConfig.zegoAppSign != _currentConfig.zegoAppSign ||
              !listEquals(remoteConfig.stunServers, _currentConfig.stunServers)) {
            _currentConfig = remoteConfig;
            _controller.add(remoteConfig);
            _persistToLocal(remoteConfig);
          }
        },
        onError: (e) {
          debugPrint('CallConfigRepository: remote sync listener error: $e');
        },
      );
    } catch (e) {
      debugPrint('CallConfigRepository: remote sync unavailable: $e');
    }
  }

  Future<void> _persistToLocal(CallConfig config) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_kPrefRoutingMode, config.routingMode.name);
      await prefs.setInt(_kPrefFallbackTimeout, config.fallbackTimeoutSeconds);
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
      debugPrint('CallConfigRepository: _persistToLocal error: $e');
    }
  }

  /// Persists [config] to local [SharedPreferences] and syncs to Firestore
  /// `system_settings/calling` if Firebase is initialized.
  Future<void> saveConfig(CallConfig config) async {
    _currentConfig = config;
    _controller.add(config);

    await _persistToLocal(config);

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
    _firestoreSub?.cancel();
    _controller.close();
  }
}
