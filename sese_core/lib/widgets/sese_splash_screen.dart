import 'package:flutter/material.dart';
import 'sese_logo.dart';

/// Native branded splash screen for SeSe applications.
///
/// Features:
/// - Smooth entrance animation (subtle scale and fade) on the SeSe vector logo.
/// - Dark/Light mode adaptive background with subtle ambient gold glow.
/// - Configurable display duration or future/stream trigger.
/// - Transitions gracefully to the next screen (e.g. AuthGate / Dashboard).
class SeSeSplashScreen extends StatefulWidget {
  final Widget nextScreen;
  final Duration minDuration;
  final String? subtitle;

  /// Brand variant: ride shows the SeSe mark, hub shows SeSe + HUB wordmark.
  final SeSeLogoVariant logoVariant;

  const SeSeSplashScreen({
    super.key,
    required this.nextScreen,
    this.minDuration = const Duration(milliseconds: 1800),
    this.subtitle,
    this.logoVariant = SeSeLogoVariant.ride,
  });

  @override
  State<SeSeSplashScreen> createState() => _SeSeSplashScreenState();
}

class _SeSeSplashScreenState extends State<SeSeSplashScreen>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  late final Animation<double> _scaleAnimation;
  late final Animation<double> _fadeAnimation;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1200),
    );

    _scaleAnimation = Tween<double>(begin: 0.82, end: 1.0).animate(
      CurvedAnimation(parent: _controller, curve: Curves.easeOutCubic),
    );

    _fadeAnimation = Tween<double>(begin: 0.0, end: 1.0).animate(
      CurvedAnimation(parent: _controller, curve: Curves.easeIn),
    );

    _controller.forward();

    // Navigate to next screen after minDuration
    Future.delayed(widget.minDuration, () {
      if (!mounted) return;
      Navigator.of(context).pushReplacement(
        PageRouteBuilder(
          transitionDuration: const Duration(milliseconds: 600),
          pageBuilder: (_, animation, secondaryAnimation) => FadeTransition(
            opacity: animation,
            child: widget.nextScreen,
          ),
        ),
      );
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Scaffold(
      backgroundColor: isDark ? const Color(0xFF121212) : Colors.white,
      body: SafeArea(
        child: Center(
          child: AnimatedBuilder(
            animation: _controller,
            builder: (context, child) {
              return FadeTransition(
                opacity: _fadeAnimation,
                child: ScaleTransition(
                  scale: _scaleAnimation,
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      // Glow container
                      Container(
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          boxShadow: [
                            BoxShadow(
                              color: const Color(0xFFFFB800).withValues(alpha: isDark ? 0.18 : 0.12),
                              blurRadius: 48,
                              spreadRadius: 8,
                            ),
                          ],
                        ),
                        child: SeSeLogo(
                            size: 220, variant: widget.logoVariant),
                      ),
                      if (widget.subtitle != null) ...[
                        const SizedBox(height: 24),
                        Text(
                          widget.subtitle!,
                          style: TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.w600,
                            letterSpacing: 1.2,
                            color: isDark ? Colors.grey.shade400 : Colors.grey.shade700,
                          ),
                        ),
                      ],
                      const SizedBox(height: 48),
                      SizedBox(
                        width: 24,
                        height: 24,
                        child: CircularProgressIndicator(
                          strokeWidth: 2.5,
                          valueColor: const AlwaysStoppedAnimation<Color>(Color(0xFFFFB800)),
                        ),
                      ),
                    ],
                  ),
                ),
              );
            },
          ),
        ),
      ),
    );
  }
}
