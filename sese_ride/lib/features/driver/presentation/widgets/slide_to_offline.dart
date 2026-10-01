import 'package:flutter/material.dart';

/// Slide-to-go-offline track shown while the driver is ONLINE.
///
/// Drag the thumb past ~80% of the track to complete the slide: the thumb
/// snaps back immediately and [onSlideComplete] fires (the confirmation
/// sheet decides the outcome, so cancelling leaves the slider reset in the
/// online position). Custom-built — no extra dependency.
class SlideToOffline extends StatefulWidget {
  final bool enabled;
  final VoidCallback onSlideComplete;

  const SlideToOffline({
    super.key,
    required this.enabled,
    required this.onSlideComplete,
  });

  @override
  State<SlideToOffline> createState() => SlideToOfflineState();
}

/// Exposed for widget tests (drag-distance assertions).
class SlideToOfflineState extends State<SlideToOffline> {
  double dragDistance = 0;

  static const double trackHeight = 52;
  static const double thumbSize = 44;

  /// Completion threshold: fraction of the track the thumb must travel.
  static const double completionFraction = 0.8;

  void _reset() => setState(() => dragDistance = 0);

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return LayoutBuilder(
      builder: (context, constraints) {
        final maxSlide = (constraints.maxWidth - thumbSize - 8)
            .clamp(0.0, double.infinity);
        return GestureDetector(
          key: const Key('slide_thumb'),
          onHorizontalDragUpdate: widget.enabled
              ? (details) => setState(() {
                    dragDistance = (dragDistance + details.delta.dx)
                        .clamp(0.0, maxSlide);
                  })
              : null,
          onHorizontalDragEnd: widget.enabled
              ? (_) {
                  final completed = maxSlide > 0 &&
                      dragDistance >= maxSlide * completionFraction;
                  _reset();
                  if (completed) widget.onSlideComplete();
                }
              : null,
          child: Container(
            height: trackHeight,
            decoration: BoxDecoration(
              color: scheme.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(28),
            ),
            child: Stack(
              alignment: Alignment.centerLeft,
              children: [
                Center(
                  child: Text(
                    'Slide to go offline',
                    style: Theme.of(context).textTheme.titleSmall?.copyWith(
                          color: scheme.onSurfaceVariant,
                          fontWeight: FontWeight.w600,
                          letterSpacing: 0.5,
                        ),
                  ),
                ),
                Transform.translate(
                  offset: Offset(4 + dragDistance, 0),
                  child: Container(
                    width: thumbSize,
                    height: thumbSize,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: widget.enabled
                          ? scheme.primary
                          : scheme.onSurface.withValues(alpha: 0.3),
                    ),
                    child: Icon(
                      Icons.chevron_right,
                      color: scheme.onPrimary,
                      size: 28,
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}
