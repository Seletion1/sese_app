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

          return MediaQuery(
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
          );
        }

        return child;
      },
    );
  }
}
