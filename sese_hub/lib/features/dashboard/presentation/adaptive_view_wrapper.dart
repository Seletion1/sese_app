import 'package:flutter/material.dart';
import '../services/view_mode_controller.dart';

/// Reusable layout wrapper that dynamically adapts the app's root viewport based on [ViewModeController].
///
/// Behavior:
/// - [HubViewMode.auto]: Responsive layout following screen size (native desktop on wide screens, mobile layout on phones).
/// - [HubViewMode.desktop]: Forces full 1280px desktop viewport on mobile devices ("Request Desktop Site") with pinch-to-zoom / panning.
/// - [HubViewMode.mobile]: Constrains content to a touch-optimized 480px mobile frame when viewed on desktop/web surfaces.
class AdaptiveViewWrapper extends StatelessWidget {
  final Widget child;

  const AdaptiveViewWrapper({
    super.key,
    required this.child,
  });

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<HubViewMode>(
      valueListenable: ViewModeController.instance,
      builder: (context, mode, _) {
        final media = MediaQuery.of(context);
        final physicalWidth = media.size.width;
        final physicalHeight = media.size.height;

        // Determine effective view mode
        bool isDesktopRequested = mode == HubViewMode.desktop;
        bool isMobileRequested = mode == HubViewMode.mobile;

        // Auto mode behavior
        if (mode == HubViewMode.auto) {
          return child;
        }

        // Forced Mobile View on wide screens (Web/Desktop)
        if (isMobileRequested && physicalWidth > 600) {
          final isDark = Theme.of(context).brightness == Brightness.dark;
          return Container(
            color: isDark ? const Color(0xFF121212) : const Color(0xFFE0E0E0),
            child: Center(
              child: ClipRRect(
                borderRadius: BorderRadius.circular(12),
                child: SizedBox(
                  width: 480,
                  height: physicalHeight > 900 ? 900 : physicalHeight,
                  child: MediaQuery(
                    data: media.copyWith(
                      size: Size(480, physicalHeight > 900 ? 900 : physicalHeight),
                    ),
                    child: Scaffold(
                      body: child,
                    ),
                  ),
                ),
              ),
            ),
          );
        }

        // Forced Desktop View ("Request Desktop Site") on narrow / mobile devices
        if (isDesktopRequested && physicalWidth < 1024) {
          const targetDesktopWidth = 1280.0;
          final aspectRatio = physicalWidth > 0 ? (physicalHeight / physicalWidth) : 1.6;
          final targetDesktopHeight = targetDesktopWidth * aspectRatio;

          return Stack(
            children: [
              SafeArea(
                child: MediaQuery(
                  data: media.copyWith(
                    size: Size(targetDesktopWidth, targetDesktopHeight),
                    devicePixelRatio: 1.0,
                  ),
                  child: InteractiveViewer(
                    minScale: 0.25,
                    maxScale: 3.0,
                    constrained: false,
                    boundaryMargin: const EdgeInsets.all(20),
                    child: SizedBox(
                      width: targetDesktopWidth,
                      height: targetDesktopHeight,
                      child: child,
                    ),
                  ),
                ),
              ),
              // Persistent Top Switch-to-Mobile Banner
              Positioned(
                top: 0,
                left: 0,
                right: 0,
                child: SafeArea(
                  bottom: false,
                  child: Material(
                    elevation: 4,
                    color: const Color(0xFF1E293B),
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          const Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(Icons.desktop_windows, color: Color(0xFFE2B714), size: 16),
                              SizedBox(width: 8),
                              Text(
                                'Desktop Mode Active',
                                style: TextStyle(
                                  color: Colors.white,
                                  fontSize: 12,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ],
                          ),
                          ElevatedButton.icon(
                            key: const Key('switch_to_mobile_banner_btn'),
                            style: ElevatedButton.styleFrom(
                              backgroundColor: const Color(0xFFE2B714),
                              foregroundColor: Colors.black,
                              visualDensity: VisualDensity.compact,
                              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                              textStyle: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold),
                            ),
                            icon: const Icon(Icons.phone_android, size: 14),
                            label: const Text('Switch to Mobile View'),
                            onPressed: () => ViewModeController.instance.setViewMode(HubViewMode.auto),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
              // Persistent Floating Action Button on Phone Screen (Always Accessible)
              Positioned(
                bottom: 24,
                right: 20,
                child: SafeArea(
                  top: false,
                  child: FloatingActionButton.extended(
                    key: const Key('switch_to_mobile_floating_fab'),
                    backgroundColor: const Color(0xFFE2B714),
                    foregroundColor: Colors.black,
                    icon: const Icon(Icons.phone_android),
                    label: const Text(
                      'Mobile View',
                      style: TextStyle(fontWeight: FontWeight.bold),
                    ),
                    onPressed: () => ViewModeController.instance.setViewMode(HubViewMode.auto),
                  ),
                ),
              ),
            ],
          );
        }

        return child;
      },
    );
  }
}
