import 'dart:async';
import 'package:flutter/foundation.dart';

import 'call_config_repository.dart';
import 'i_call_service.dart';
import 'webrtc_call_service_impl.dart';
import 'zego_call_service_impl.dart';

/// Dynamic factory and singleton manager for in-app calling services.
///
/// Reads saved calling settings from [CallConfigRepository] on boot, instantiates
/// the corresponding implementation ([WebRtcCallServiceImpl] or [ZegoCallServiceImpl]),
/// and provides unified access to UI callers.
class CallServiceManager {
  static final CallServiceManager instance = CallServiceManager._internal();

  CallServiceManager._internal() {
    _configRepo = CallConfigRepository.instance;
    _webrtcService = WebRtcCallServiceImpl(configRepo: _configRepo);
    _zegoService = ZegoCallServiceImpl(configRepo: _configRepo);
  }

  late final CallConfigRepository _configRepo;
  late final WebRtcCallServiceImpl _webrtcService;
  late final ZegoCallServiceImpl _zegoService;

  String? _currentUserId;
  String? _displayName;
  String? _avatarUrl;
  bool _initialized = false;

  StreamSubscription<CallConfig>? _configSub;

  /// The currently active calling service according to [CallConfigRepository].
  ICallService get activeService {
    final provider = _configRepo.currentConfig.providerType;
    return provider == CallProviderType.zego ? _zegoService : _webrtcService;
  }

  /// Active calling provider type.
  CallProviderType get activeProviderType => _configRepo.currentConfig.providerType;

  /// Initializes the calling subsystem for [currentUserId].
  ///
  /// Loads saved configuration and prepares both providers.
  Future<void> initialize({
    required String currentUserId,
    String? displayName,
    String? avatarUrl,
  }) async {
    _currentUserId = currentUserId;
    _displayName = displayName;
    _avatarUrl = avatarUrl;

    await _configRepo.loadConfig();

    await _webrtcService.initialize(
      currentUserId: currentUserId,
      displayName: displayName,
      avatarUrl: avatarUrl,
    );

    await _zegoService.initialize(
      currentUserId: currentUserId,
      displayName: displayName,
      avatarUrl: avatarUrl,
    );

    _configSub?.cancel();
    _configSub = _configRepo.configStream.listen((config) async {
      debugPrint('CallServiceManager: Active calling provider updated to ${config.providerType}');
    });

    _initialized = true;
  }

  /// Dynamically switches the active calling provider.
  ///
  /// Persists the change in [CallConfigRepository] and notifies listeners.
  Future<void> switchProvider(CallProviderType newProvider) async {
    final current = _configRepo.currentConfig;
    if (current.providerType == newProvider) return;

    final updated = current.copyWith(providerType: newProvider);
    await _configRepo.saveConfig(updated);

    if (_initialized && _currentUserId != null) {
      if (newProvider == CallProviderType.zego) {
        await _zegoService.initialize(
          currentUserId: _currentUserId!,
          displayName: _displayName,
          avatarUrl: _avatarUrl,
        );
      } else {
        await _webrtcService.initialize(
          currentUserId: _currentUserId!,
          displayName: _displayName,
          avatarUrl: _avatarUrl,
        );
      }
    }
  }

  /// Starts a call using the currently active provider.
  Future<void> startCall({
    required String targetUserId,
    required String callId,
    String? targetUserName,
    String? targetUserAvatar,
    Map<String, dynamic>? metadata,
  }) async {
    await activeService.startCall(
      targetUserId: targetUserId,
      callId: callId,
      targetUserName: targetUserName,
      targetUserAvatar: targetUserAvatar,
      metadata: metadata,
    );
  }

  /// Answers a call using the currently active provider.
  Future<void> answerCall(String callId) async {
    await activeService.answerCall(callId);
  }

  /// Terminates the active call on whichever service is running.
  Future<void> endCall({String? reason}) async {
    await activeService.endCall(reason: reason);
  }

  /// Disposes resources held by the manager and services.
  Future<void> dispose() async {
    await _configSub?.cancel();
    _configSub = null;
    await _webrtcService.dispose();
    await _zegoService.dispose();
    _initialized = false;
  }
}
