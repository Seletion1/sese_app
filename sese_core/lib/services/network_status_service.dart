import 'dart:async';
import 'dart:io';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/foundation.dart';

/// Centralized service for tracking network reachability and connectivity state across sese_ride and sese_hub.
///
/// Features:
/// - Instant OS connectivity changes via [Connectivity.onConnectivityChanged].
/// - Reactive [isOnline] ValueNotifier (starts true for optimistic, zero-blocking initial paint).
/// - Reactive [isChecking] ValueNotifier for subtle non-blocking refresh indicators.
/// - [onReconnected] broadcast stream fired immediately when internet connection is restored.
/// - Automatic forced server state re-sync and Firestore socket re-handshake ([forceResync]).
/// - Periodic background reachability checks (adaptive interval: 15s online, 5s offline).
/// - Lightweight, low-overhead reachability probes with short timeouts (2.5s) to avoid UI stalls.
/// - Manual [refresh] trigger for the Top Network Warning Banner.
class NetworkStatusService {
  static final NetworkStatusService instance = NetworkStatusService._internal();
  NetworkStatusService._internal();

  final ValueNotifier<bool> isOnline = ValueNotifier<bool>(true);
  final ValueNotifier<bool> isChecking = ValueNotifier<bool>(false);
  final ValueNotifier<DateTime?> lastChecked = ValueNotifier<DateTime?>(null);

  /// Stream controller broadcasting when connectivity is restored after a drop.
  final StreamController<void> _reconnectedController = StreamController<void>.broadcast();

  /// Stream that emits whenever internet connectivity is restored.
  Stream<void> get onReconnected => _reconnectedController.stream;

  /// Registered callbacks to execute when re-syncing on connection recovery.
  final Set<Future<void> Function()> _resyncCallbacks = {};

  /// Optional reachability checker override for testing or custom probes.
  Future<bool> Function()? reachabilityChecker;

  /// Optional connectivity override for testing.
  Connectivity? connectivityOverride;

  Timer? _pollingTimer;
  StreamSubscription<List<ConnectivityResult>>? _connectivitySubscription;
  bool _isMonitoring = false;
  bool _wasOffline = false;

  /// Registers a callback to be executed whenever connection recovers and state is re-synced.
  void registerResyncCallback(Future<void> Function() callback) {
    _resyncCallbacks.add(callback);
  }

  /// Unregisters a previously registered re-sync callback.
  void unregisterResyncCallback(Future<void> Function() callback) {
    _resyncCallbacks.remove(callback);
  }

  /// Starts background connectivity monitoring and OS connectivity listeners.
  void startMonitoring() {
    if (_isMonitoring) return;
    _isMonitoring = true;

    final connectivity = connectivityOverride ?? Connectivity();
    _connectivitySubscription = connectivity.onConnectivityChanged.listen(_handleConnectivityChanged);

    _scheduleNextCheck();
  }

  Future<void> _handleConnectivityChanged(List<ConnectivityResult> results) async {
    if (!_isMonitoring) return;

    final isNone = results.isEmpty ||
        (results.length == 1 && results.first == ConnectivityResult.none);

    if (isNone) {
      if (isOnline.value) {
        _wasOffline = true;
        isOnline.value = false;
      }
      return;
    }

    // Active interface detected (WiFi, Mobile, Ethernet, etc.) — probe reachability immediately.
    final online = await checkConnectivity();
    if (online) {
      if (_wasOffline) {
        _wasOffline = false;
        await forceResync();
      }
    } else {
      _wasOffline = true;
    }
  }

  void _scheduleNextCheck() {
    if (!_isMonitoring) return;
    final interval = isOnline.value ? const Duration(seconds: 15) : const Duration(seconds: 5);
    _pollingTimer?.cancel();
    _pollingTimer = Timer(interval, () async {
      if (!_isMonitoring) return;
      final online = await checkConnectivity();
      if (online && _wasOffline) {
        _wasOffline = false;
        await forceResync();
      } else if (!online) {
        _wasOffline = true;
      }
      _scheduleNextCheck();
    });
  }

  /// Probes network connectivity without blocking the main isolate.
  Future<bool> checkConnectivity() async {
    if (reachabilityChecker != null) {
      final online = await reachabilityChecker!();
      if (isOnline.value != online) {
        isOnline.value = online;
      }
      lastChecked.value = DateTime.now();
      return online;
    }

    if (kIsWeb) {
      // In web environments, socket lookups are unsupported.
      isOnline.value = true;
      lastChecked.value = DateTime.now();
      return true;
    }

    try {
      final res = await InternetAddress.lookup('dns.google')
          .timeout(const Duration(milliseconds: 2500));
      final online = res.isNotEmpty && res[0].rawAddress.isNotEmpty;
      if (isOnline.value != online) {
        isOnline.value = online;
      }
      lastChecked.value = DateTime.now();
      return online;
    } catch (_) {
      try {
        final res2 = await InternetAddress.lookup('google.com')
            .timeout(const Duration(milliseconds: 2500));
        final online = res2.isNotEmpty && res2[0].rawAddress.isNotEmpty;
        if (isOnline.value != online) {
          isOnline.value = online;
        }
        lastChecked.value = DateTime.now();
        return online;
      } catch (_) {
        if (isOnline.value != false) {
          isOnline.value = false;
        }
        lastChecked.value = DateTime.now();
        return false;
      }
    }
  }

  /// Forces an immediate network re-sync and triggers all registered listeners.
  ///
  /// Re-enables Firestore network layer to force socket reconnection and flushes pending writes.
  Future<void> forceResync() async {
    if (isChecking.value) return;
    isChecking.value = true;

    try {
      // Force Firestore socket re-handshake and pending mutation reconciliation
      try {
        await FirebaseFirestore.instance.enableNetwork();
      } catch (e) {
        // Degrades gracefully when Firestore is uninitialized or in test harness
        debugPrint('NetworkStatusService: Firestore enableNetwork skipped ($e)');
      }

      // Execute all registered screen re-sync handlers in parallel
      final callbacks = List<Future<void> Function()>.from(_resyncCallbacks);
      await Future.wait(
        callbacks.map((cb) async {
          try {
            await cb();
          } catch (e) {
            debugPrint('NetworkStatusService resync callback failed: $e');
          }
        }),
      );

      // Broadcast reconnection notification to all stream listeners
      _reconnectedController.add(null);
    } finally {
      isChecking.value = false;
    }
  }

  /// Manual refresh triggered from UI or banner.
  Future<void> refresh() async {
    if (isChecking.value) return;
    isChecking.value = true;
    try {
      final online = await checkConnectivity();
      if (online) {
        await forceResync();
      }
    } finally {
      isChecking.value = false;
    }
  }

  /// Stops monitoring and releases resources.
  void stopMonitoring() {
    _isMonitoring = false;
    _pollingTimer?.cancel();
    _pollingTimer = null;
    _connectivitySubscription?.cancel();
    _connectivitySubscription = null;
  }
}
