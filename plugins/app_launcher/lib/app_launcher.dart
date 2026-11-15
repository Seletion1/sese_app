import 'app_launcher_platform_interface.dart';

class AppLauncher {
  Future<String?> getPlatformVersion() {
    return AppLauncherPlatform.instance.getPlatformVersion();
  }

  /// Brings the host app activity to the foreground.
  Future<bool> bringToForeground({Map<String, dynamic>? extras}) {
    return AppLauncherPlatform.instance.bringToForeground(extras: extras);
  }

  /// Checks whether SYSTEM_ALERT_WINDOW (display over other apps) is granted.
  Future<bool> canDrawOverlays() {
    return AppLauncherPlatform.instance.canDrawOverlays();
  }

  /// Opens the system settings screen to allow display over other apps.
  Future<bool> requestOverlayPermission() {
    return AppLauncherPlatform.instance.requestOverlayPermission();
  }

  /// Moves the host app task to the background.
  Future<bool> moveTaskToBack() {
    return AppLauncherPlatform.instance.moveTaskToBack();
  }
}
