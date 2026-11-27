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

  const CallConfig({
    this.stunServers = defaultGoogleStunServers,
    this.turnServers = const [],
    this.enableDiagnostics = false,
  });

  CallProviderType get providerType => CallProviderType.webrtc;

  CallConfig copyWith({
    List<String>? stunServers,
    List<Map<String, dynamic>>? turnServers,
    bool? enableDiagnostics,
  }) {
    return CallConfig(
      stunServers: stunServers ?? this.stunServers,
      turnServers: turnServers ?? this.turnServers,
      enableDiagnostics: enableDiagnostics ?? this.enableDiagnostics,
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'providerType': CallProviderType.webrtc.name,
      'stunServers': stunServers,
      'turnServers': turnServers,
      'enableDiagnostics': enableDiagnostics,
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

    return CallConfig(
      stunServers: stuns,
      turnServers: turns,
      enableDiagnostics: map['enableDiagnostics'] == true,
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
                  _currentConfig.enableDiagnostics) {
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
    _controller.close();
  }
}
