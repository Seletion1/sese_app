import 'dart:async';
import 'dart:convert';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'i_call_service.dart';

/// Configuration payload for the SeSe WebRTC calling subsystem.
@immutable
class CallConfig {
  /// Default Google public STUN servers for NAT discovery.
  static const List<String> defaultGoogleStunServers = [
    'stun:stun.l.google.com:19302',
    'stun:stun1.l.google.com:19302',
    'stun:stun2.l.google.com:19302',
  ];

  /// STUN servers used by WebRTC for ICE candidate discovery and NAT traversal.
  final List<String> stunServers;

  /// TURN relay servers for cross-network calling (cellular ↔ Wi-Fi / symmetric NAT).
  ///
  /// Each entry is a fully-formed ICE-server map, e.g.:
  /// ```json
  /// {"urls": "turn:your.turn.server:3478", "username": "u", "credential": "p"}
  /// ```
  final List<Map<String, dynamic>> turnServers;

  /// Whether WebRTC diagnostic stats are enabled.
  final bool enableDiagnostics;

  /// Monotonic/server timestamp token bumped whenever `/system_config/call_secrets`
  /// TURN credentials are updated in SeseHub, signaling clients to refresh ICE servers.
  final int turnConfigVersion;

  const CallConfig({
    this.stunServers = defaultGoogleStunServers,
    this.turnServers = const [],
    this.enableDiagnostics = false,
    this.turnConfigVersion = 0,
  });

  CallProviderType get providerType => CallProviderType.webrtc;

  CallConfig copyWith({
    List<String>? stunServers,
    List<Map<String, dynamic>>? turnServers,
    bool? enableDiagnostics,
    int? turnConfigVersion,
  }) {
    return CallConfig(
      stunServers: stunServers ?? this.stunServers,
      turnServers: turnServers ?? this.turnServers,
      enableDiagnostics: enableDiagnostics ?? this.enableDiagnostics,
      turnConfigVersion: turnConfigVersion ?? this.turnConfigVersion,
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'providerType': CallProviderType.webrtc.name,
      'stunServers': stunServers,
      'turnServers': turnServers,
      'enableDiagnostics': enableDiagnostics,
      'turnConfigVersion': turnConfigVersion,
      'updatedAt': FieldValue.serverTimestamp(),
    };
  }

  factory CallConfig.fromMap(Map<String, dynamic>? map) {
    if (map == null) return const CallConfig();

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

    List<Map<String, dynamic>> turns = const [];
    final rawTurn = map['turnServers'];
    if (rawTurn is List) {
      turns = rawTurn
          .whereType<Map>()
          .map((e) => Map<String, dynamic>.from(e))
          .toList();
    }

    final rawVersion = map['turnConfigVersion'];
    final version = rawVersion is num ? rawVersion.toInt() : 0;

    return CallConfig(
      stunServers: stuns,
      turnServers: turns,
      enableDiagnostics: map['enableDiagnostics'] == true,
      turnConfigVersion: version,
    );
  }
}

/// Repository responsible for persisting WebRTC calling settings in [SharedPreferences]
/// with real-time synchronization against Firestore (`system_settings/calling`).
class CallConfigRepository {
  static final CallConfigRepository instance = CallConfigRepository._internal();

  CallConfigRepository._internal();

  static const String _kPrefStunServers = 'sese_call_stun_servers';
  static const String _kPrefTurnServers = 'sese_call_turn_servers';
  static const String _kPrefDiagnostics = 'sese_call_enable_diagnostics';

  final _controller = StreamController<CallConfig>.broadcast();
  CallConfig _currentConfig = const CallConfig();
  List<Map<String, dynamic>> _cachedRemoteIceServers = const [];
  int _cachedIceVersion = -1;
  bool _initialized = false;
  StreamSubscription<DocumentSnapshot<Map<String, dynamic>>>? _firestoreSub;

  /// Current cached configuration.
  CallConfig get currentConfig => _currentConfig;

  /// Latest ICE server list fetched from `getIceServers` (or empty if not fetched yet).
  List<Map<String, dynamic>> get cachedRemoteIceServers =>
      _cachedRemoteIceServers;

  int get cachedIceVersion => _cachedIceVersion;

  void updateCachedRemoteIceServers(
    List<Map<String, dynamic>> servers, {
    int? version,
  }) {
    _cachedRemoteIceServers = List<Map<String, dynamic>>.unmodifiable(servers);
    _cachedIceVersion = version ?? _currentConfig.turnConfigVersion;
  }

  void invalidateRemoteIceCache() {
    _cachedRemoteIceServers = const [];
    _cachedIceVersion = -1;
  }

  /// Stream of configuration changes for reactive UI bindings.
  Stream<CallConfig> get configStream => _controller.stream;

  /// Loads configuration from local [SharedPreferences], seeding with Firestore
  /// remote overrides and real-time updates.
  Future<CallConfig> loadConfig() async {
    if (_initialized) return _currentConfig;

    try {
      final prefs = await SharedPreferences.getInstance();
      final stunList = prefs.getStringList(_kPrefStunServers);
      final rawTurnJson = prefs.getString(_kPrefTurnServers);
      List<Map<String, dynamic>> turnList = const [];
      if (rawTurnJson != null && rawTurnJson.isNotEmpty) {
        try {
          final decoded = jsonDecode(rawTurnJson);
          if (decoded is List) {
            turnList = decoded
                .whereType<Map>()
                .map((e) => Map<String, dynamic>.from(e))
                .toList();
          }
        } catch (_) {}
      }
      final diagnostics = prefs.getBool(_kPrefDiagnostics) ?? false;

      _currentConfig = CallConfig(
        stunServers: stunList != null && stunList.isNotEmpty
            ? stunList
            : CallConfig.defaultGoogleStunServers,
        turnServers: turnList,
        enableDiagnostics: diagnostics,
      );
    } catch (e) {
      debugPrint('CallConfigRepository: failed to read SharedPreferences: $e');
      _currentConfig = const CallConfig();
    }

    _initialized = true;
    _controller.add(_currentConfig);

    _startRemoteSyncListener();

    return _currentConfig;
  }

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

          if (!listEquals(remoteConfig.stunServers, _currentConfig.stunServers) ||
              jsonEncode(remoteConfig.turnServers) !=
                  jsonEncode(_currentConfig.turnServers) ||
              remoteConfig.enableDiagnostics !=
                  _currentConfig.enableDiagnostics ||
              remoteConfig.turnConfigVersion !=
                  _currentConfig.turnConfigVersion) {
            if (remoteConfig.turnConfigVersion != _currentConfig.turnConfigVersion) {
              invalidateRemoteIceCache();
            }
            _currentConfig = remoteConfig;
            _controller.add(_currentConfig);
            _persistToLocal(_currentConfig);
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
      await prefs.setStringList(_kPrefStunServers, config.stunServers);
      await prefs.setString(_kPrefTurnServers, jsonEncode(config.turnServers));
      await prefs.setBool(_kPrefDiagnostics, config.enableDiagnostics);
    } catch (e) {
      debugPrint('CallConfigRepository: _persistToLocal error: $e');
    }
  }

  /// Persists [config] to local [SharedPreferences] and syncs to Firestore.
  ///
  /// When [throwOnRemoteError] is true (e.g. SeseHub admin saves), any Firestore
  /// write error or timeout is rethrown instead of swallowed so the UI never
  /// shows a false-success message.
  Future<void> saveConfig(
    CallConfig config, {
    bool throwOnRemoteError = false,
  }) async {
    _currentConfig = config;
    invalidateRemoteIceCache();
    _controller.add(config);

    await _persistToLocal(config);

    try {
      await FirebaseFirestore.instance
          .collection('system_settings')
          .doc('calling')
          .set(config.toMap(), SetOptions(merge: true))
          .timeout(const Duration(seconds: 10));
    } catch (e) {
      debugPrint('CallConfigRepository: remote sync deferred: $e');
      if (throwOnRemoteError) rethrow;
    }
  }

  /// Disposes repository resources.
  void dispose() {
    _firestoreSub?.cancel();
    _controller.close();
  }
}
