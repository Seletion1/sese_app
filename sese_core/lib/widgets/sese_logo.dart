import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';

/// Brand variant selector for the SeSe logo.
enum SeSeLogoVariant {
  /// Ride/driver app: gold arc + "SeSe".
  ride,

  /// Hub staff app: gold arc + "SeSe" + "HUB" wordmark beneath.
  hub,
}

/// Native vector-rendered SeSe Brand Logo.
///
/// - Exact Amber Gold linear gradient (#FFC107 -> #FF9800 -> #E65100).
/// - Circular arc frame with top opening.
/// - Typography: "SeSe" (+ "HUB" wordmark for [SeSeLogoVariant.hub]).
/// - Served from bundled SVG assets (`assets/sese_logo*.svg`); the
///   authoritative vector is also kept in [rawSvg] for contexts that need
///   an inline string (overlay windows, tests).
class SeSeLogo extends StatelessWidget {
  final double size;
  final BoxFit fit;
  final SeSeLogoVariant variant;

  const SeSeLogo({
    super.key,
    this.size = 200,
    this.fit = BoxFit.contain,
    this.variant = SeSeLogoVariant.ride,
  });

  /// The authoritative raw SVG string for the SeSe brand mark.
  static const String rawSvg = '''
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 500 500" width="100%" height="100%">
  <defs>
    <linearGradient id="seseGoldArc" x1="0%" y1="0%" x2="100%" y2="100%">
      <stop offset="0%" stop-color="#FFC107" />
      <stop offset="50%" stop-color="#FF9800" />
      <stop offset="100%" stop-color="#E65100" />
    </linearGradient>
  </defs>
  <!-- Circular Arc Frame with Top Opening -->
  <path d="M 180,95 A 190,190 0 1,0 320,95"
        fill="none"
        stroke="url(#seseGoldArc)"
        stroke-width="14"
        stroke-linecap="round" />
  <!-- Center SeSe Brand Typography -->
  <text x="250" y="270"
        font-family="Arial, Helvetica, sans-serif"
        font-weight="900"
        font-size="78"
        fill="#FFB300"
        text-anchor="middle">SeSe</text>
</svg>
''';

  /// Hub variant: same mark with the HUB wordmark beneath "SeSe".
  static const String rawSvgHub = '''
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 500 500" width="100%" height="100%">
  <defs>
    <linearGradient id="seseGoldArc" x1="0%" y1="0%" x2="100%" y2="100%">
      <stop offset="0%" stop-color="#FFC107" />
      <stop offset="50%" stop-color="#FF9800" />
      <stop offset="100%" stop-color="#E65100" />
    </linearGradient>
  </defs>
  <path d="M 180,95 A 190,190 0 1,0 320,95"
        fill="none"
        stroke="url(#seseGoldArc)"
        stroke-width="14"
        stroke-linecap="round" />
  <text x="250" y="255"
        font-family="Arial, Helvetica, sans-serif"
        font-weight="900"
        font-size="72"
        fill="#FFB300"
        text-anchor="middle">SeSe</text>
  <text x="250" y="330"
        font-family="Arial, Helvetica, sans-serif"
        font-weight="700"
        font-size="40"
        letter-spacing="14"
        fill="#FFB300"
        text-anchor="middle">HUB</text>
</svg>
''';

  String get _asset => variant == SeSeLogoVariant.hub
      ? 'packages/sese_core/assets/sese_logo_hub.svg'
      : 'packages/sese_core/assets/sese_logo.svg';

  @override
  Widget build(BuildContext context) {
    return SvgPicture.asset(
      _asset,
      width: size,
      height: size,
      fit: fit,
      placeholderBuilder: (_) => SvgPicture.string(
        variant == SeSeLogoVariant.hub ? rawSvgHub : rawSvg,
        width: size,
        height: size,
        fit: fit,
      ),
    );
  }
}
