import 'app_launcher_platform_interface.dart';

class AppLauncher {
  Future<String?> getPlatformVersion() {
    return AppLauncherPlatform.instance.getPlatformVersion();
  }

  /// Brings the host app activity to the foreground.
  Future<bool> bringToForeground() {
    return AppLauncherPlatform.instance.bringToForeground();
  }

  /// Moves the host app task to the background.
  Future<bool> moveTaskToBack() {
    return AppLauncherPlatform.instance.moveTaskToBack();
  }
}
