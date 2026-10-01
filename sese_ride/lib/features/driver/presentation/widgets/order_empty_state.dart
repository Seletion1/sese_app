import 'dart:math' as math;

import 'package:flutter/material.dart';

/// Centered empty-state for the driver marketplace order pool.
///
/// Shows a smooth radar ripple (three expanding rings around a radar icon)
/// with the headline "Searching for available orders...". The parent feed
/// swaps this out via [AnimatedSwitcher] the moment an order enters the
/// pool, so the transition is seamless.
class OrderEmptyState extends StatefulWidget {
  const OrderEmptyState({super.key});

  @override
  State<OrderEmptyState> createState() => OrderEmptyStateState();
}

/// Exposed for widget tests (animation presence, headline text).
class OrderEmptyStateState extends State<OrderEmptyState>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 2400),
    )..repeat();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Center(
      key: const Key('marketplace_empty_state'),
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              width: 140,
              height: 140,
              child: AnimatedBuilder(
                animation: _controller,
                builder: (context, child) => CustomPaint(
                  painter: _RadarRipplePainter(
                    progress: _controller.value,
                    color: scheme.primary,
                  ),
                  child: Center(
                    child: Container(
                      width: 64,
                      height: 64,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: scheme.primaryContainer.withValues(alpha: 0.35),
                      ),
                      child: Icon(Icons.radar, size: 34, color: scheme.primary),
                    ),
                  ),
                ),
              ),
            ),
            const SizedBox(height: 16),
            Text(
              'Searching for available orders...',
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.w600,
                color: scheme.onSurface,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Paints three staggered expanding rings (radar ripple) from the center.
class _RadarRipplePainter extends CustomPainter {
  final double progress;
  final Color color;

  static const int _rings = 3;

  const _RadarRipplePainter({required this.progress, required this.color});

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final maxRadius = math.min(size.width, size.height) / 2;
    for (var i = 0; i < _rings; i++) {
      final t = (progress + i / _rings) % 1.0;
      final radius = maxRadius * t;
      final opacity = (1.0 - t) * 0.45;
      canvas.drawCircle(
        center,
        radius,
        Paint()
          ..color = color.withValues(alpha: opacity)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2.0,
      );
    }
  }

  @override
  bool shouldRepaint(_RadarRipplePainter oldDelegate) =>
      oldDelegate.progress != progress || oldDelegate.color != color;
}
