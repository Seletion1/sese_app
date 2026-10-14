import 'package:flutter/material.dart';

/// Slide-to-go-offline track shown while the driver is ONLINE.
///
/// - **Tap** the gold thumb (with no meaningful horizontal drag): fires
///   [onTapBreak] to open the "Take a Break" options sheet.
/// - **Drag** the thumb past ~80 % of the track: fires [onSlideComplete]
///   which opens the go-offline confirmation sheet.
/// - When [breakTimerText] is non-null the thumb renders the countdown label
///   instead of the chevron icon so the driver can see their remaining break
///   time without leaving the home map canvas.
///
/// Custom-built — no extra dependency.
class SlideToOffline extends StatefulWidget {
  final bool enabled;
  final VoidCallback onSlideComplete;

  /// Optional callback fired when the driver taps the thumb without dragging.
  /// Wire to the "Take a Break" options sheet in [_DriverDashboardScreenState].
  final VoidCallback? onTapBreak;

  /// When non-null (e.g. '29m', '58s'), rendered inside the gold thumb instead
  /// of the chevron so the driver sees their remaining break countdown.
  final String? breakTimerText;

  const SlideToOffline({
    super.key,
    required this.enabled,
    required this.onSlideComplete,
    this.onTapBreak,
    this.breakTimerText,
  });

  @override
  State<SlideToOffline> createState() => SlideToOfflineState();
}

/// Exposed for widget tests (drag-distance assertions).
class SlideToOfflineState extends State<SlideToOffline> {
  double dragDistance = 0;

  /// Tracks whether a meaningful horizontal drag has started so we can
  /// distinguish a tap (break sheet) from a slide (go offline).
  bool _isDragging = false;

  static const double trackHeight = 52;
  static const double thumbSize = 44;

  /// Completion threshold: fraction of the track the thumb must travel.
  static const double completionFraction = 0.8;

  /// Minimum drag distance (px) before we consider the gesture a drag rather
  /// than an incidental finger slip on a tap.
  static const double _dragThreshold = 6.0;

  void _reset() => setState(() {
        dragDistance = 0;
        _isDragging = false;
      });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final isOnBreak = widget.breakTimerText != null;
    return LayoutBuilder(
      builder: (context, constraints) {
        final maxSlide = (constraints.maxWidth - thumbSize - 8)
            .clamp(0.0, double.infinity);
        return GestureDetector(
          key: const Key('slide_thumb'),
          onHorizontalDragUpdate: widget.enabled
              ? (details) {
                  if (details.delta.dx.abs() >= _dragThreshold ||
                      dragDistance > 0) {
                    _isDragging = true;
                  }
                  setState(() {
                    dragDistance = (dragDistance + details.delta.dx)
                        .clamp(0.0, maxSlide);
                  });
                }
              : null,
          onHorizontalDragEnd: widget.enabled
              ? (_) {
                  final wasDrag = _isDragging;
                  final completed = wasDrag &&
                      maxSlide > 0 &&
                      dragDistance >= maxSlide * completionFraction;
                  _reset();
                  if (completed) {
                    widget.onSlideComplete();
                  }
                  // If finger lifted with no meaningful drag it was a tap —
                  // but onTap below already handles that case.
                }
              : null,
          // Pure tap on the track fires the break sheet.
          onTap: (widget.enabled && widget.onTapBreak != null)
              ? () {
                  if (!_isDragging) widget.onTapBreak!();
                }
              : null,
          child: Container(
            height: trackHeight,
            decoration: BoxDecoration(
              color: isOnBreak
                  ? scheme.primary.withValues(alpha: 0.22) // gold tint during break
                  : scheme.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(28),
              border: isOnBreak
                  ? Border.all(color: scheme.primary, width: 1.5)
                  : null,
            ),
            child: Stack(
              alignment: Alignment.centerLeft,
              children: [
                Center(
                  child: Text(
                    isOnBreak ? 'On Break — tap to cancel' : 'Slide to go offline',
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
                      // Gold thumb in both states; countdown reads in black.
                      color: widget.enabled
                          ? scheme.primary
                          : scheme.onSurface.withValues(alpha: 0.3),
                    ),
                    alignment: Alignment.center,
                    child: isOnBreak && widget.breakTimerText != null
                        ? Text(
                            widget.breakTimerText!,
                            style: TextStyle(
                              color: scheme.onPrimary,
                              fontSize: 11,
                              fontWeight: FontWeight.bold,
                            ),
                          )
                        : Icon(
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
