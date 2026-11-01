import 'package:plugin_platform_interface/plugin_platform_interface.dart';

import 'app_launcher_method_channel.dart';

abstract class AppLauncherPlatform extends PlatformInterface {
  /// Constructs a AppLauncherPlatform.
  AppLauncherPlatform() : super(token: _token);

  static final Object _token = Object();

  static AppLauncherPlatform _instance = MethodChannelAppLauncher();

  /// The default instance of [AppLauncherPlatform] to use.
  ///
  /// Defaults to [MethodChannelAppLauncher].
  static AppLauncherPlatform get instance => _instance;

  /// Platform-specific implementations should set this with their own
  /// platform-specific class that extends [AppLauncherPlatform] when
  /// they register themselves.
  static set instance(AppLauncherPlatform instance) {
    PlatformInterface.verifyToken(instance, _token);
    _instance = instance;
  }

  Future<String?> getPlatformVersion() {
    throw UnimplementedError('platformVersion() has not been implemented.');
  }

  Future<bool> bringToForeground() {
    throw UnimplementedError('bringToForeground() has not been implemented.');
  }

  Future<bool> moveTaskToBack() {
    throw UnimplementedError('moveTaskToBack() has not been implemented.');
  }
}
