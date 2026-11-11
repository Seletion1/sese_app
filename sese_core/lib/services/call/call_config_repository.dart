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

  /// Timeout in seconds before smart fallback drops from WebRTC/Agora to secondary provider.
  final int fallbackTimeoutSeconds;

  /// Agora RTC Application ID (32-character hex/alphanumeric string).
  final String? agoraAppId;

  /// Agora Primary Certificate (32-character secret key, server-only).
  final String? agoraAppCertificate;

  /// Monthly free tier minutes cap for Agora RTC (default: 10,000 mins).
  final int agoraMonthlyFreeMinutesCap;

  /// Minute-usage threshold that triggers automatic failover from Agora to native WebRTC (default: 9,900 mins).
  final int agoraAutoFailoverThresholdMinutes;

  /// Tracked global call minutes used in the current billing cycle.
  final int agoraCallsUsedMinutesThisMonth;

  /// ZegoCloud Application ID (numeric integer, legacy).
  final int? zegoAppId;

  /// ZegoCloud Application Sign (64-character hexadecimal authentication key, legacy).
  final String? zegoAppSign;

  /// STUN servers used by WebRTC for ICE candidate discovery and NAT traversal.
  final List<String> stunServers;

  /// Whether WebRTC data channel or diagnostic stats are enabled.
  final bool enableDiagnostics;

  const CallConfig({
    this.routingMode = CallRoutingMode.smartFallback,
    this.fallbackTimeoutSeconds = 10,
    this.agoraAppId,
    this.agoraAppCertificate,
    this.agoraMonthlyFreeMinutesCap = 10000,
    this.agoraAutoFailoverThresholdMinutes = 9900,
    this.agoraCallsUsedMinutesThisMonth = 0,
    this.zegoAppId,
    this.zegoAppSign,
    this.stunServers = defaultGoogleStunServers,
    this.enableDiagnostics = false,
  });

  /// The primary calling provider derived from the active routing mode.
  CallProviderType get providerType {
    switch (routingMode) {
      case CallRoutingMode.thirdPartyOnly:
        return CallProviderType.agora;
      case CallRoutingMode.customP2pOnly:
      case CallRoutingMode.smartFallback:
        return CallProviderType.webrtc;
    }
  }

  /// True if valid Agora credentials exist for RTC audio calls.
  bool get hasValidAgoraCredentials {
    if (agoraAppId == null || agoraAppId!.trim().isEmpty) return false;
    return agoraAppId!.trim().length >= 16;
  }

  /// True if Agora monthly usage has reached the automatic failover threshold.
  bool get isAgoraLimitReached {
    return agoraCallsUsedMinutesThisMonth >= agoraAutoFailoverThresholdMinutes;
  }

  /// True if ZegoCloud credentials are valid (legacy fallback).
  bool get hasValidZegoCredentials {
    if (zegoAppId == null || zegoAppId! <= 0) return false;
    if (zegoAppSign != null && zegoAppSign!.isNotEmpty) {
      return zegoAppSign!.trim().length >= 32;
    }
    return true;
  }

  CallConfig copyWith({
    CallRoutingMode? routingMode,
    int? fallbackTimeoutSeconds,
    CallProviderType? providerType,
    String? agoraAppId,
    String? agoraAppCertificate,
    int? agoraMonthlyFreeMinutesCap,
    int? agoraAutoFailoverThresholdMinutes,
    int? agoraCallsUsedMinutesThisMonth,
    int? zegoAppId,
    String? zegoAppSign,
    List<String>? stunServers,
    bool? enableDiagnostics,
  }) {
    CallRoutingMode mode = routingMode ?? this.routingMode;
    if (routingMode == null && providerType != null) {
      mode = (providerType == CallProviderType.agora || providerType == CallProviderType.zego)
          ? CallRoutingMode.thirdPartyOnly
          : CallRoutingMode.customP2pOnly;
    }

    return CallConfig(
      routingMode: mode,
      fallbackTimeoutSeconds: fallbackTimeoutSeconds ?? this.fallbackTimeoutSeconds,
      agoraAppId: agoraAppId ?? this.agoraAppId,
      agoraAppCertificate: agoraAppCertificate ?? this.agoraAppCertificate,
      agoraMonthlyFreeMinutesCap: agoraMonthlyFreeMinutesCap ?? this.agoraMonthlyFreeMinutesCap,
      agoraAutoFailoverThresholdMinutes:
          agoraAutoFailoverThresholdMinutes ?? this.agoraAutoFailoverThresholdMinutes,
      agoraCallsUsedMinutesThisMonth:
          agoraCallsUsedMinutesThisMonth ?? this.agoraCallsUsedMinutesThisMonth,
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
      'agoraAppId': agoraAppId,
      // Security: Secret credentials (agoraAppCertificate, zegoAppSign) are strictly
      // omitted from client Firestore write payloads to prevent client key exposure.
      'agoraMonthlyFreeMinutesCap': agoraMonthlyFreeMinutesCap,
      'agoraAutoFailoverThresholdMinutes': agoraAutoFailoverThresholdMinutes,
      'agoraCallsUsedMinutesThisMonth': agoraCallsUsedMinutesThisMonth,
      'zegoAppId': zegoAppId,
      'stunServers': stunServers,
      'enableDiagnostics': enableDiagnostics,
      'updatedAt': FieldValue.serverTimestamp(),
    };
  }

  factory CallConfig.fromMap(Map<String, dynamic>? map) {
    if (map == null) return const CallConfig();

    CallRoutingMode routingMode = CallRoutingMode.smartFallback;
    final modeStr = map['routingMode']?.toString().toLowerCase().trim();
    if (modeStr == 'customp2ponly' ||
        modeStr == 'custom_p2p_only' ||
        modeStr == 'forcewebrtc' ||
        modeStr == 'force_webrtc' ||
        modeStr == 'webrtc') {
      routingMode = CallRoutingMode.customP2pOnly;
    } else if (modeStr == 'thirdpartyonly' ||
        modeStr == 'third_party_only' ||
        modeStr == 'forceagora' ||
        modeStr == 'force_agora' ||
        modeStr == 'agora' ||
        modeStr == 'zego') {
      routingMode = CallRoutingMode.thirdPartyOnly;
    } else if (modeStr == 'smartfallback' ||
        modeStr == 'smart_fallback' ||
        modeStr == 'auto' ||
        modeStr == 'automatic') {
      routingMode = CallRoutingMode.smartFallback;
    } else {
      final providerStr = map['providerType']?.toString().toLowerCase().trim();
      if (providerStr == 'agora' || providerStr == 'zego') {
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

    String? agoraAppId;
    final rawAgoraAppId = map['agoraAppId'] ?? map['appId'];
    if (rawAgoraAppId != null) {
      agoraAppId = rawAgoraAppId.toString().trim();
    }

    int agoraCap = 10000;
    final rawAgoraCap = map['agoraMonthlyFreeMinutesCap'];
    if (rawAgoraCap is int) {
      agoraCap = rawAgoraCap;
    } else if (rawAgoraCap is String) {
      agoraCap = int.tryParse(rawAgoraCap.trim()) ?? 10000;
    }

    int agoraThreshold = 9900;
    final rawAgoraThreshold = map['agoraAutoFailoverThresholdMinutes'];
    if (rawAgoraThreshold is int) {
      agoraThreshold = rawAgoraThreshold;
    } else if (rawAgoraThreshold is String) {
      agoraThreshold = int.tryParse(rawAgoraThreshold.trim()) ?? 9900;
    }

    int agoraUsedMins = 0;
    final rawAgoraUsed = map['agoraCallsUsedMinutesThisMonth'] ?? map['agoraMinutesThisMonth'];
    if (rawAgoraUsed is int) {
      agoraUsedMins = rawAgoraUsed;
    } else if (rawAgoraUsed is String) {
      agoraUsedMins = int.tryParse(rawAgoraUsed.trim()) ?? 0;
    }

    int? appId;
    final rawAppId = map['zegoAppId'];
    if (rawAppId is int) {
      appId = rawAppId;
    } else if (rawAppId is String) {
      appId = int.tryParse(rawAppId.trim());
    }

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
      agoraAppId: agoraAppId,
      agoraAppCertificate: null,
      agoraMonthlyFreeMinutesCap: agoraCap,
      agoraAutoFailoverThresholdMinutes: agoraThreshold,
      agoraCallsUsedMinutesThisMonth: agoraUsedMins,
      zegoAppId: appId,
      zegoAppSign: null,
      stunServers: stuns,
      enableDiagnostics: map['enableDiagnostics'] == true,
    );
  }
}

/// Repository responsible for persisting calling settings in [SharedPreferences]
/// with real-time bidirectional synchronization against Firestore (`system_settings/calling`).
class CallConfigRepository {
  static final CallConfigRepository instance = CallConfigRepository._internal();

  CallConfigRepository._internal();

  static const String _kPrefRoutingMode = 'sese_call_routing_mode';
  static const String _kPrefFallbackTimeout = 'sese_call_fallback_timeout';
  static const String _kPrefProvider = 'sese_call_provider_type';
  static const String _kPrefAgoraAppId = 'sese_call_agora_app_id';
  static const String _kPrefAgoraCap = 'sese_call_agora_cap';
  static const String _kPrefAgoraThreshold = 'sese_call_agora_threshold';
  static const String _kPrefAgoraUsedMins = 'sese_call_agora_used_mins';
  static const String _kPrefZegoAppId = 'sese_call_zego_app_id';
  static const String _kPrefZegoAppSign = 'sese_call_zego_app_sign';
  static const String _kPrefStunServers = 'sese_call_stun_servers';
  static const String _kPrefDiagnostics = 'sese_call_enable_diagnostics';

  final _controller = StreamController<CallConfig>.broadcast();
  CallConfig _currentConfig = const CallConfig();
  bool _initialized = false;
  StreamSubscription<DocumentSnapshot<Map<String, dynamic>>>? _firestoreSub;
  StreamSubscription<DocumentSnapshot<Map<String, dynamic>>>? _usageSub;

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
      }

      final fallbackTimeout = prefs.getInt(_kPrefFallbackTimeout) ?? 10;
      final agoraAppId = prefs.getString(_kPrefAgoraAppId);
      final agoraCap = prefs.getInt(_kPrefAgoraCap) ?? 10000;
      final agoraThreshold = prefs.getInt(_kPrefAgoraThreshold) ?? 9900;
      final agoraUsed = prefs.getInt(_kPrefAgoraUsedMins) ?? 0;
      final zegoAppId = prefs.getInt(_kPrefZegoAppId);
      final stunList = prefs.getStringList(_kPrefStunServers);
      final diagnostics = prefs.getBool(_kPrefDiagnostics) ?? false;

      _currentConfig = CallConfig(
        routingMode: mode,
        fallbackTimeoutSeconds: fallbackTimeout,
        agoraAppId: agoraAppId,
        agoraAppCertificate: null,
        agoraMonthlyFreeMinutesCap: agoraCap,
        agoraAutoFailoverThresholdMinutes: agoraThreshold,
        agoraCallsUsedMinutesThisMonth: agoraUsed,
        zegoAppId: zegoAppId,
        zegoAppSign: null,
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

    // Initialize real-time listener for remote settings & minute usage updates
    _startRemoteSyncListener();

    return _currentConfig;
  }

  /// Starts listening to remote configuration and call usage updates from Firestore.
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

          if (remoteConfig.routingMode != _currentConfig.routingMode ||
              remoteConfig.fallbackTimeoutSeconds != _currentConfig.fallbackTimeoutSeconds ||
              remoteConfig.agoraAppId != _currentConfig.agoraAppId ||
              remoteConfig.agoraAutoFailoverThresholdMinutes != _currentConfig.agoraAutoFailoverThresholdMinutes ||
              remoteConfig.agoraMonthlyFreeMinutesCap != _currentConfig.agoraMonthlyFreeMinutesCap ||
              !listEquals(remoteConfig.stunServers, _currentConfig.stunServers)) {
            _currentConfig = remoteConfig.copyWith(
              agoraCallsUsedMinutesThisMonth: _currentConfig.agoraCallsUsedMinutesThisMonth,
            );
            _controller.add(_currentConfig);
            _persistToLocal(_currentConfig);
          }
        },
        onError: (e) {
          debugPrint('CallConfigRepository: remote sync listener error: $e');
        },
      );

      // Subscribes to live call minute usage updates
      _usageSub?.cancel();
      _usageSub = FirebaseFirestore.instance
          .collection('system_config')
          .doc('call_usage')
          .snapshots()
          .listen(
        (snapshot) {
          if (!snapshot.exists || snapshot.data() == null) return;
          final usageData = snapshot.data()!;
          final agoraMinutes = (usageData['agoraMinutesThisMonth'] as num?)?.toInt() ?? 0;

          if (agoraMinutes != _currentConfig.agoraCallsUsedMinutesThisMonth) {
            _currentConfig = _currentConfig.copyWith(
              agoraCallsUsedMinutesThisMonth: agoraMinutes,
            );
            _controller.add(_currentConfig);
            _persistToLocal(_currentConfig);
          }
        },
        onError: (_) {},
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

      if (config.agoraAppId != null) {
        await prefs.setString(_kPrefAgoraAppId, config.agoraAppId!);
      } else {
        await prefs.remove(_kPrefAgoraAppId);
      }

      await prefs.setInt(_kPrefAgoraCap, config.agoraMonthlyFreeMinutesCap);
      await prefs.setInt(_kPrefAgoraThreshold, config.agoraAutoFailoverThresholdMinutes);
      await prefs.setInt(_kPrefAgoraUsedMins, config.agoraCallsUsedMinutesThisMonth);

      if (config.zegoAppId != null) {
        await prefs.setInt(_kPrefZegoAppId, config.zegoAppId!);
      } else {
        await prefs.remove(_kPrefZegoAppId);
      }

      await prefs.remove(_kPrefZegoAppSign);
      await prefs.setStringList(_kPrefStunServers, config.stunServers);
      await prefs.setBool(_kPrefDiagnostics, config.enableDiagnostics);
    } catch (e) {
      debugPrint('CallConfigRepository: _persistToLocal error: $e');
    }
  }

  /// Persists [config] to local [SharedPreferences] and syncs to Firestore.
  Future<void> saveConfig(CallConfig config) async {
    _currentConfig = config;
    _controller.add(config);

    await _persistToLocal(config);

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
    _usageSub?.cancel();
    _controller.close();
  }
}
