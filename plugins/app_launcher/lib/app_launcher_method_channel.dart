import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'app_launcher_platform_interface.dart';

/// An implementation of [AppLauncherPlatform] that uses method channels.
class MethodChannelAppLauncher extends AppLauncherPlatform {
  /// The method channel used to interact with the native platform.
  @visibleForTesting
  final methodChannel = const MethodChannel('com.sesetech.sese_ride/app_launcher');

  @override
  Future<String?> getPlatformVersion() async {
    final version = await methodChannel.invokeMethod<String>(
      'getPlatformVersion',
    );
    return version;
  }

  @override
  Future<bool> bringToForeground({Map<String, dynamic>? extras}) async {
    try {
      final res = await methodChannel.invokeMethod<bool>(
        'bringToForeground',
        extras != null ? {'extras': extras} : null,
      );
      return res ?? false;
    } catch (_) {
      return false;
    }
  }

  @override
  Future<bool> canDrawOverlays() async {
    try {
      final res = await methodChannel.invokeMethod<bool>('canDrawOverlays');
      return res ?? false;
    } catch (_) {
      return false;
    }
  }

  @override
  Future<bool> requestOverlayPermission() async {
    try {
      final res = await methodChannel.invokeMethod<bool>('requestOverlayPermission');
      return res ?? false;
    } catch (_) {
      return false;
    }
  }

  @override
  Future<bool> moveTaskToBack() async {
    try {
      final res = await methodChannel.invokeMethod<bool>('moveTaskToBack');
      return res ?? false;
    } catch (_) {
      return false;
    }
  }
}
