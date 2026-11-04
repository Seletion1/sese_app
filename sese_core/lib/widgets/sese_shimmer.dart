import 'package:flutter/material.dart';

/// A lightweight, zero-dependency shimmer effect widget for non-blocking UI placeholders.
class SeseShimmer extends StatefulWidget {
  final Widget child;
  final Color baseColor;
  final Color highlightColor;
  final Duration duration;

  const SeseShimmer({
    super.key,
    required this.child,
    this.baseColor = const Color(0xFFE0E0E0),
    this.highlightColor = const Color(0xFFF5F5F5),
    this.duration = const Duration(milliseconds: 1200),
  });

  @override
  State<SeseShimmer> createState() => _SeseShimmerState();
}

class _SeseShimmerState extends State<SeseShimmer>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(vsync: this, duration: widget.duration);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (TickerMode.valuesOf(context).enabled) {
      if (!_controller.isAnimating) {
        _controller.repeat();
      }
    } else {
      if (_controller.isAnimating) {
        _controller.stop();
      }
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final baseColor = widget.baseColor == const Color(0xFFE0E0E0)
        ? (isDark ? Colors.grey[850]! : Colors.grey[300]!)
        : widget.baseColor;
    final highlightColor = widget.highlightColor == const Color(0xFFF5F5F5)
        ? (isDark ? Colors.grey[700]! : Colors.grey[100]!)
        : widget.highlightColor;

    return AnimatedBuilder(
      animation: _controller,
      builder: (context, child) {
        return ShaderMask(
          blendMode: BlendMode.srcATop,
          shaderCallback: (bounds) {
            return LinearGradient(
              begin: const Alignment(-1.0, -0.3),
              end: const Alignment(1.0, 0.3),
              stops: const [0.0, 0.5, 1.0],
              colors: [baseColor, highlightColor, baseColor],
              transform: _SlidingGradientTransform(slidePercent: _controller.value),
            ).createShader(bounds);
          },
          child: child,
        );
      },
      child: widget.child,
    );
  }
}

class _SlidingGradientTransform extends GradientTransform {
  final double slidePercent;
  const _SlidingGradientTransform({required this.slidePercent});

  @override
  Matrix4? transform(Rect bounds, {TextDirection? textDirection}) {
    return Matrix4.translationValues(bounds.width * (slidePercent * 2 - 1), 0.0, 0.0);
  }
}

/// Skeleton container box.
class SeseSkeletonBox extends StatelessWidget {
  final double width;
  final double height;
  final double borderRadius;

  const SeseSkeletonBox({
    super.key,
    required this.width,
    required this.height,
    this.borderRadius = 8.0,
  });

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Container(
      width: width,
      height: height,
      decoration: BoxDecoration(
        color: isDark ? Colors.grey[800] : Colors.grey[300],
        borderRadius: BorderRadius.circular(borderRadius),
      ),
    );
  }
}

/// Shimmer skeleton loader for list-based screens (Trips, Notifications, History).
class SeseListSkeleton extends StatelessWidget {
  final int itemCount;
  final double padding;

  const SeseListSkeleton({
    super.key,
    this.itemCount = 5,
    this.padding = 16.0,
  });

  @override
  Widget build(BuildContext context) {
    return SeseShimmer(
      child: ListView.separated(
        padding: EdgeInsets.all(padding),
        physics: const NeverScrollableScrollPhysics(),
        shrinkWrap: true,
        itemCount: itemCount,
        separatorBuilder: (_, _) => const SizedBox(height: 12),
        itemBuilder: (context, index) {
          return Row(
            children: [
              const SeseSkeletonBox(width: 48, height: 48, borderRadius: 24),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: const [
                    SeseSkeletonBox(width: double.infinity, height: 16),
                    SizedBox(height: 8),
                    SeseSkeletonBox(width: 140, height: 12),
                  ],
                ),
              ),
              const SizedBox(width: 12),
              const SeseSkeletonBox(width: 40, height: 20),
            ],
          );
        },
      ),
    );
  }
}

/// Shimmer skeleton loader for card-based components (Dashboards, Wallet, Earnings).
class SeseCardSkeleton extends StatelessWidget {
  final double height;
  final double padding;

  const SeseCardSkeleton({
    super.key,
    this.height = 140,
    this.padding = 16.0,
  });

  @override
  Widget build(BuildContext context) {
    return SeseShimmer(
      child: Padding(
        padding: EdgeInsets.all(padding),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SeseSkeletonBox(width: double.infinity, height: height, borderRadius: 16),
            const SizedBox(height: 16),
            Row(
              children: const [
                Expanded(child: SeseSkeletonBox(width: double.infinity, height: 60, borderRadius: 12)),
                SizedBox(width: 12),
                Expanded(child: SeseSkeletonBox(width: double.infinity, height: 60, borderRadius: 12)),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// Shimmer skeleton loader for profile headers and settings screens.
class SeseProfileSkeleton extends StatelessWidget {
  const SeseProfileSkeleton({super.key});

  @override
  Widget build(BuildContext context) {
    return SeseShimmer(
      child: Padding(
        padding: const EdgeInsets.all(24.0),
        child: Column(
          children: [
            const SizedBox(height: 20),
            const Center(
              child: SeseSkeletonBox(width: 90, height: 90, borderRadius: 45),
            ),
            const SizedBox(height: 16),
            const SeseSkeletonBox(width: 180, height: 20),
            const SizedBox(height: 8),
            const SeseSkeletonBox(width: 120, height: 14),
            const SizedBox(height: 32),
            const SeseSkeletonBox(width: double.infinity, height: 48, borderRadius: 12),
            const SizedBox(height: 12),
            const SeseSkeletonBox(width: double.infinity, height: 48, borderRadius: 12),
            const SizedBox(height: 12),
            const SeseSkeletonBox(width: double.infinity, height: 48, borderRadius: 12),
          ],
        ),
      ),
    );
  }
}

/// Shimmer skeleton loader for detail sheets and modals.
class SeseDetailSkeleton extends StatelessWidget {
  const SeseDetailSkeleton({super.key});

  @override
  Widget build(BuildContext context) {
    return SeseShimmer(
      child: Padding(
        padding: const EdgeInsets.all(20.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: const [
            Center(child: SeseSkeletonBox(width: 40, height: 5, borderRadius: 3)),
            SizedBox(height: 20),
            SeseSkeletonBox(width: 200, height: 22),
            SizedBox(height: 16),
            SeseSkeletonBox(width: double.infinity, height: 80, borderRadius: 12),
            SizedBox(height: 16),
            SeseSkeletonBox(width: double.infinity, height: 48, borderRadius: 12),
          ],
        ),
      ),
    );
  }
}
