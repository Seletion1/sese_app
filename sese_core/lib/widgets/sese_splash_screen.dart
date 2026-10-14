import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'sese_logo.dart';

/// Native branded splash screen for SeSe applications.
///
/// Designed as the single, premium launch experience — the native Android
/// window is intentionally a plain coloured fill (no logo) so there is no
/// double-splash. This Flutter screen is what the user "sees" as the brand.
///
/// Features:
/// - Adapts background to system theme (dark → `#121212`, light → `Colors.white`),
///   so the edge between the native solid window and this first Flutter frame
///   is invisible — zero flash.
/// - Entrance: logo scales from 0.82→1.0 + fades in over 1 200 ms.
/// - Ambient gold glow pulse that breathes once while waiting.
/// - Status-bar icons adapt to theme (dark icons on white, light on dark).
/// - Configurable [minDuration]; navigates to [nextScreen] with a 600 ms
///   cross-fade once the timer fires.
class SeSeSplashScreen extends StatefulWidget {
  final Widget nextScreen;
  final Duration minDuration;
  final String? subtitle;

  /// Brand variant: ride shows the SeSe mark, hub shows SeSe + HUB wordmark.
  final SeSeLogoVariant logoVariant;

  const SeSeSplashScreen({
    super.key,
    required this.nextScreen,
    this.minDuration = const Duration(milliseconds: 2000),
    this.subtitle,
    this.logoVariant = SeSeLogoVariant.ride,
  });

  @override
  State<SeSeSplashScreen> createState() => _SeSeSplashScreenState();
}

class _SeSeSplashScreenState extends State<SeSeSplashScreen>
    with TickerProviderStateMixin {
  late final AnimationController _entranceController;
  late final AnimationController _glowController;

  late final Animation<double> _scaleAnimation;
  late final Animation<double> _fadeAnimation;
  late final Animation<double> _glowAnimation;
  late final Animation<double> _subtitleFadeAnimation;

  @override
  void initState() {
    super.initState();

    // --- Entrance: scale + fade ---
    _entranceController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1200),
    );

    _scaleAnimation = Tween<double>(begin: 0.80, end: 1.0).animate(
      CurvedAnimation(parent: _entranceController, curve: Curves.easeOutCubic),
    );

    _fadeAnimation = Tween<double>(begin: 0.0, end: 1.0).animate(
      CurvedAnimation(
        parent: _entranceController,
        curve: const Interval(0.0, 0.7, curve: Curves.easeIn),
      ),
    );

    _subtitleFadeAnimation = Tween<double>(begin: 0.0, end: 1.0).animate(
      CurvedAnimation(
        parent: _entranceController,
        curve: const Interval(0.5, 1.0, curve: Curves.easeOut),
      ),
    );

    // --- Glow pulse: one slow breathe cycle ---
    _glowController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 2000),
    );

    _glowAnimation = Tween<double>(begin: 0.10, end: 0.28).animate(
      CurvedAnimation(parent: _glowController, curve: Curves.easeInOut),
    );

    _entranceController.forward().then((_) {
      if (mounted) _glowController.repeat(reverse: true);
    });

    // Navigate to next screen after minDuration.
    Future.delayed(widget.minDuration, () {
      if (!mounted) return;
      Navigator.of(context).pushReplacement(
        PageRouteBuilder(
          transitionDuration: const Duration(milliseconds: 700),
          pageBuilder: (_, animation, _) => FadeTransition(
            opacity: animation,
            child: widget.nextScreen,
          ),
        ),
      );
    });
  }

  @override
  void dispose() {
    _entranceController.dispose();
    _glowController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final bg = isDark ? const Color(0xFF121212) : Colors.white;

    // Keep system-UI overlay style in sync with splash background so the
    // status bar icons are readable (dark icons on white, light on dark).
    SystemChrome.setSystemUIOverlayStyle(
      isDark
          ? SystemUiOverlayStyle.light.copyWith(
              statusBarColor: Colors.transparent,
              systemNavigationBarColor: bg,
            )
          : SystemUiOverlayStyle.dark.copyWith(
              statusBarColor: Colors.transparent,
              systemNavigationBarColor: bg,
            ),
    );

    return Scaffold(
      backgroundColor: bg,
      body: Center(
        child: AnimatedBuilder(
          animation: Listenable.merge([_entranceController, _glowController]),
          builder: (context, _) {
            return FadeTransition(
              opacity: _fadeAnimation,
              child: ScaleTransition(
                scale: _scaleAnimation,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    // ─── Logo + ambient glow ────────────────────────────────
                    Container(
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        boxShadow: [
                          BoxShadow(
                            color: const Color(0xFFFFB800)
                                .withValues(alpha: _glowAnimation.value),
                            blurRadius: 64,
                            spreadRadius: 12,
                          ),
                        ],
                      ),
                      child: SeSeLogo(
                        size: 200,
                        variant: widget.logoVariant,
                      ),
                    ),

                    // ─── Subtitle ───────────────────────────────────────────
                    if (widget.subtitle != null) ...[
                      const SizedBox(height: 28),
                      FadeTransition(
                        opacity: _subtitleFadeAnimation,
                        child: Text(
                          widget.subtitle!,
                          style: TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                            letterSpacing: 1.8,
                            color: isDark
                                ? const Color(0xFF9E9E9E)
                                : const Color(0xFF757575),
                          ),
                        ),
                      ),
                    ],

                    // ─── Gold dot progress indicator ────────────────────────
                    const SizedBox(height: 52),
                    FadeTransition(
                      opacity: _subtitleFadeAnimation,
                      child: SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          valueColor: const AlwaysStoppedAnimation<Color>(
                            Color(0xFFFFB800),
                          ),
                          backgroundColor: isDark
                              ? const Color(0xFF2A2A2A)
                              : const Color(0xFFF0F0F0),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}
