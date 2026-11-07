import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';

/// Centralized service for tracking network reachability across sese_ride and sese_hub.
///
/// Features:
/// - Reactive [isOnline] ValueNotifier (starts true for optimistic, zero-blocking initial paint).
/// - Reactive [isChecking] ValueNotifier for subtle non-blocking refresh indicators.
/// - Periodic background reachability checks (adaptive interval: 15s online, 5s offline).
/// - Lightweight, low-overhead reachability probes with short timeouts (2.5s) to avoid UI stalls.
/// - Manual [refresh] trigger for the Top Network Warning Banner.
class NetworkStatusService {
  static final NetworkStatusService instance = NetworkStatusService._internal();
  NetworkStatusService._internal();

  final ValueNotifier<bool> isOnline = ValueNotifier<bool>(true);
  final ValueNotifier<bool> isChecking = ValueNotifier<bool>(false);
  final ValueNotifier<DateTime?> lastChecked = ValueNotifier<DateTime?>(null);

  /// Optional reachability checker override for testing or custom probes.
  Future<bool> Function()? reachabilityChecker;

  Timer? _pollingTimer;
  bool _isMonitoring = false;

  /// Starts background connectivity monitoring.
  void startMonitoring() {
    if (_isMonitoring) return;
    _isMonitoring = true;
    _scheduleNextCheck();
  }

  void _scheduleNextCheck() {
    if (!_isMonitoring) return;
    final interval = isOnline.value ? const Duration(seconds: 15) : const Duration(seconds: 5);
    _pollingTimer?.cancel();
    _pollingTimer = Timer(interval, () async {
      if (!_isMonitoring) return;
      await checkConnectivity();
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

  /// Manual refresh triggered from UI or banner.
  Future<void> refresh() async {
    if (isChecking.value) return;
    isChecking.value = true;
    try {
      await checkConnectivity();
    } finally {
      isChecking.value = false;
    }
  }

  void stopMonitoring() {
    _isMonitoring = false;
    _pollingTimer?.cancel();
    _pollingTimer = null;
  }
}
