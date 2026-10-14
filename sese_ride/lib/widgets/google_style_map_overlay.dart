import 'package:flutter/material.dart';

/// Google Maps-style map UI overlay: a fixed center blue-dot indicator plus
/// a bottom-right re-center target button.
///
/// Follows the provided blueprint (Appendix C) with two repo-standard
/// adaptations: `withValues(alpha:)` instead of the deprecated
/// `withOpacity`, and no `Key? key` super-parameter (this codebase targets
/// `super.key` style — see sibling widgets).
///
/// - The blue dot is purely positional (map center), NOT the GPS location —
///   pair with `showMyLocation` for the live user dot.
/// - Wrap in [IgnorePointer] (or place the dot branch inside one) so map
///   gestures pass through; the button stays tappable.
class GoogleStyleMapOverlay extends StatelessWidget {
  /// Called when the re-center target button is tapped. When null the
  /// button is hidden (dot-only mode).
  final VoidCallback? onRecenterPressed;

  /// When false, only the re-center button renders (no center dot).
  final bool showCenterDot;

  const GoogleStyleMapOverlay({
    super.key,
    this.onRecenterPressed,
    this.showCenterDot = true,
  });

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        // 1. Center blue dot fixed at the map center.
        if (showCenterDot)
          const Center(
            child: IgnorePointer(
              child: _CenterBlueDot(),
            ),
          ),

        // 2. Google Maps-style re-center target button (bottom right).
        if (onRecenterPressed != null)
          Positioned(
            bottom: 24,
            right: 16,
            child: FloatingActionButton(
              heroTag: 'map_recenter_btn',
              mini: true,
              backgroundColor: Colors.white,
              elevation: 4,
              onPressed: onRecenterPressed,
              child: const Icon(
                Icons.my_location,
                color: Colors.black87,
                size: 22,
              ),
            ),
          ),
      ],
    );
  }
}

/// Fixed center indicator: translucent halo ring around a solid blue dot
/// with a soft drop shadow — the Google Maps "you are centered here" mark.
class _CenterBlueDot extends StatelessWidget {
  const _CenterBlueDot();

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 22,
          height: 22,
          decoration: BoxDecoration(
            color: Colors.blue.withValues(alpha: 0.3),
            shape: BoxShape.circle,
          ),
          child: Center(
            child: Container(
              width: 12,
              height: 12,
              decoration: const BoxDecoration(
                color: Colors.blue,
                shape: BoxShape.circle,
                boxShadow: [
                  BoxShadow(
                    color: Colors.black26,
                    blurRadius: 4,
                    offset: Offset(0, 2),
                  ),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }
}
