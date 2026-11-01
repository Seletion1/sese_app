import 'package:flutter_test/flutter_test.dart';
import 'package:app_launcher/app_launcher.dart';
import 'package:app_launcher/app_launcher_platform_interface.dart';
import 'package:app_launcher/app_launcher_method_channel.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';

class MockAppLauncherPlatform
    with MockPlatformInterfaceMixin
    implements AppLauncherPlatform {
  @override
  Future<String?> getPlatformVersion() => Future.value('42');

  @override
  Future<bool> bringToForeground() => Future.value(true);

  @override
  Future<bool> moveTaskToBack() => Future.value(true);
}

void main() {
  final AppLauncherPlatform initialPlatform = AppLauncherPlatform.instance;

  test('$MethodChannelAppLauncher is the default instance', () {
    expect(initialPlatform, isInstanceOf<MethodChannelAppLauncher>());
  });

  test('getPlatformVersion', () async {
    final appLauncherPlugin = AppLauncher();
    final fakePlatform = MockAppLauncherPlatform();
    AppLauncherPlatform.instance = fakePlatform;

    expect(await appLauncherPlugin.getPlatformVersion(), '42');
  });

  test('bringToForeground and moveTaskToBack', () async {
    final appLauncherPlugin = AppLauncher();
    final fakePlatform = MockAppLauncherPlatform();
    AppLauncherPlatform.instance = fakePlatform;

    expect(await appLauncherPlugin.bringToForeground(), true);
    expect(await appLauncherPlugin.moveTaskToBack(), true);
  });
}
