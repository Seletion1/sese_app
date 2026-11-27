import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Bridges native Android [MainActivity], `SeseLocationForegroundService`, and
/// `SeseFirebaseMessagingService` with the existing Flutter dispatch UI.
class DriverWakeService {
  DriverWakeService._();

  static final DriverWakeService instance = DriverWakeService._();

  static const MethodChannel _channel =
      MethodChannel('com.sesetech.sese_ride/driver_wake');
  static const String _fsiPromptedPrefKey = 'fsi_readiness_prompted_v1';

  final StreamController<String> _orderWakeController =
      StreamController<String>.broadcast();
  bool _initialized = false;

  /// Emits validated `orderId`s delivered by `MainActivity` (`onNewIntent` or
  /// cold-start `getInitialWakeOrder`).
  Stream<String> get incomingOrderIdStream => _orderWakeController.stream;

  void initialize() {
    if (_initialized || kIsWeb || !Platform.isAndroid) return;
    _initialized = true;
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'onIncomingOrderWake') {
        final args = call.arguments;
        if (args is Map) {
          final orderId = (args['orderId'] ?? '').toString().trim();
          if (orderId.isNotEmpty) {
            _orderWakeController.add(orderId);
          }
        }
      }
    });
  }

  /// Fetches and clears any cold-start wake `orderId` held by [MainActivity].
  Future<String?> consumeInitialWakeOrderId() async {
    if (kIsWeb || !Platform.isAndroid) return null;
    try {
      final res = await _channel.invokeMethod<dynamic>('getInitialWakeOrder');
      if (res is Map) {
        final orderId = (res['orderId'] ?? '').toString().trim();
        return orderId.isNotEmpty ? orderId : null;
      }
    } catch (_) {}
    return null;
  }

  /// Synchronizes persistent foreground location service state with native
  /// `SharedPreferences` and starts/stops `SeseLocationForegroundService`.
  Future<void> syncForegroundServiceState({
    required bool isOnline,
    required bool hasActiveTrip,
    required String driverUid,
    String? activeTripId,
  }) async {
    if (kIsWeb || !Platform.isAndroid) return;
    try {
      await _channel.invokeMethod<bool>('syncDriverServiceState', {
        'isOnline': isOnline,
        'hasActiveTrip': hasActiveTrip,
        'driverUid': driverUid,
        'activeTripId': activeTripId ?? '',
      });
    } catch (e) {
      debugPrint('DriverWakeService.syncForegroundServiceState error: $e');
    }
  }

  /// Clears native driver session state and stops the foreground service on sign-out.
  Future<void> clearSession() async {
    if (kIsWeb || !Platform.isAndroid) return;
    try {
      await _channel.invokeMethod<bool>('clearDriverSessionState');
    } catch (e) {
      debugPrint('DriverWakeService.clearSession error: $e');
    }
  }

  Future<bool> canUseFullScreenIntent() async {
    if (kIsWeb || !Platform.isAndroid) return true;
    try {
      return (await _channel.invokeMethod<bool>('canUseFullScreenIntent')) ??
          true;
    } catch (_) {
      return true;
    }
  }

  Future<bool> isIgnoringBatteryOptimizations() async {
    if (kIsWeb || !Platform.isAndroid) return true;
    try {
      return (await _channel
              .invokeMethod<bool>('isIgnoringBatteryOptimizations')) ??
          true;
    } catch (_) {
      return true;
    }
  }

  Future<void> openFullScreenIntentSettings() async {
    if (kIsWeb || !Platform.isAndroid) return;
    try {
      await _channel.invokeMethod<bool>('openFullScreenIntentSettings');
    } catch (_) {}
  }

  Future<void> requestIgnoreBatteryOptimizations() async {
    if (kIsWeb || !Platform.isAndroid) return;
    try {
      await _channel.invokeMethod<bool>('requestIgnoreBatteryOptimizations');
    } catch (_) {}
  }

  /// Prompts the driver once on Go-Online if Android 14+ Full-Screen Intent
  /// permission is not yet enabled, and offers a direct link to Settings.
  Future<void> checkAndPromptGoOnlineReadiness(BuildContext context) async {
    if (kIsWeb || !Platform.isAndroid) return;
    try {
      final canFsi = await canUseFullScreenIntent();
      final ignoringBattery = await isIgnoringBatteryOptimizations();
      if (canFsi && ignoringBattery) return;

      final prefs = await SharedPreferences.getInstance();
      final alreadyPrompted = prefs.getBool(_fsiPromptedPrefKey) ?? false;
      if (alreadyPrompted || !context.mounted) return;
      await prefs.setBool(_fsiPromptedPrefKey, true);
      if (!context.mounted) return;

      if (!canFsi) {
        final openSettings = await showDialog<bool>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: const Text('Enable Full-Screen Order Alerts'),
            content: const Text(
              'To wake your screen and pop up incoming ride/delivery requests '
              'immediately over the lock screen or other apps, allow '
              '"Display full-screen notifications" for SeSe Ride in Settings.',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(ctx).pop(false),
                child: const Text('Later'),
              ),
              FilledButton(
                onPressed: () => Navigator.of(ctx).pop(true),
                child: const Text('Open Settings'),
              ),
            ],
          ),
        );
        if (openSettings == true) {
          await openFullScreenIntentSettings();
        }
      }
    } catch (e) {
      debugPrint('DriverWakeService.checkAndPromptGoOnlineReadiness error: $e');
    }
  }
}
