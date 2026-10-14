import 'package:flutter/material.dart';
import 'package:flutter_overlay_window/flutter_overlay_window.dart';

import '../services/driver_overlay_service.dart';

/// Lifecycle watcher widget that observes app lifecycle state changes.
///
/// When the app enters [AppLifecycleState.paused] or [AppLifecycleState.hidden]
/// while the driver is ONLINE, it displays the circular floating overlay bubble.
/// When the app resumes ([AppLifecycleState.resumed]), it closes the overlay.
class DriverLifecycleWatcher extends StatefulWidget {
  final Widget child;
  final bool isOnline;

  const DriverLifecycleWatcher({
    super.key,
    required this.child,
    this.isOnline = true,
  });

  @override
  State<DriverLifecycleWatcher> createState() => _DriverLifecycleWatcherState();
}

class _DriverLifecycleWatcherState extends State<DriverLifecycleWatcher>
    with WidgetsBindingObserver {
  bool get isOnline => widget.isOnline;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) async {
    if (!isOnline) return;

    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.hidden ||
        state == AppLifecycleState.detached) {
      // App is minimized or hidden while ONLINE: show the round SeSe logo
      // floating bubble (freely draggable along screen edges).
      final hasPermission = await FlutterOverlayWindow.isPermissionGranted();
      if (hasPermission) {
        await DriverOverlayService.instance.showOverlayWidget();
      }
    } else if (state == AppLifecycleState.resumed) {
      // App is re-opened: dismiss the bubble and restore the standard view.
      if (await FlutterOverlayWindow.isActive()) {
        await DriverOverlayService.instance.closeOverlayWidget();
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return widget.child;
  }
}
