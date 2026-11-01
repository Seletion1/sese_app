import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:app_launcher/app_launcher_method_channel.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final MethodChannelAppLauncher platform = MethodChannelAppLauncher();
  const MethodChannel channel = MethodChannel('com.sesetech.sese_ride/app_launcher');

  setUp(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (MethodCall methodCall) async {
          if (methodCall.method == 'getPlatformVersion') {
            return '42';
          } else if (methodCall.method == 'bringToForeground') {
            return true;
          } else if (methodCall.method == 'moveTaskToBack') {
            return true;
          }
          return null;
        });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  test('getPlatformVersion', () async {
    expect(await platform.getPlatformVersion(), '42');
  });

  test('bringToForeground and moveTaskToBack', () async {
    expect(await platform.bringToForeground(), true);
    expect(await platform.moveTaskToBack(), true);
  });
}
