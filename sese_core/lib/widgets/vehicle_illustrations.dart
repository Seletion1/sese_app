import 'package:flutter/material.dart';

import '../models/vehicle_category.dart';
import '../theme/app_theme.dart';

/// Illustration key for the premium vehicle & package vector set.
///
/// Delivery categories map 1:1 except [VehicleCategory.car], which renders
/// as [sedan]. Passenger tiers ([RideTier]) step up the sedan ladder:
/// comfort → [sedan], premium → [premium], luxe → [luxe].
enum VehicleArt {
  bicycle,
  motorcycle,
  keke,
  sedan,
  premium,
  luxe,
  van,
  truck,
  packageSend,
  packageReceive;

  /// Delivery-category mapping (`car` renders as the standard sedan).
  static VehicleArt fromCategory(VehicleCategory category) {
    switch (category) {
      case VehicleCategory.bicycle:
        return VehicleArt.bicycle;
      case VehicleCategory.motorcycle:
        return VehicleArt.motorcycle;
      case VehicleCategory.tricycle:
        return VehicleArt.keke;
      case VehicleCategory.car:
        return VehicleArt.sedan;
      case VehicleCategory.van:
        return VehicleArt.van;
      case VehicleCategory.truck:
        return VehicleArt.truck;
    }
  }

  /// Server ride-tier-id mapping (`comfort`/`premium`/`luxe`/`tricycle`).
  /// Unknown ids fall back to the standard sedan — never blank.
  static VehicleArt fromTierId(String tierId) {
    switch (tierId.toLowerCase()) {
      case 'premium':
        return VehicleArt.premium;
      case 'luxe':
      case 'super':
        return VehicleArt.luxe;
      case 'tricycle':
      case 'keke':
        return VehicleArt.keke;
      case 'comfort':
      default:
        return VehicleArt.sedan;
    }
  }
}

/// Premium vehicle & package illustrations, drawn as lightweight
/// [CustomPaint] vectors — zero image assets, zero new dependencies, ~one
/// file, so the release APK pays no size cost for the upgrade.
///
/// The car, motorcycle, and package glyphs are exact 1:1 ports of the
/// approved SVG templates (same 24×24 viewBox, same path commands, same
/// fills) — only the stroke color is unified to the brand gold. The
/// bicycle, keke, van, and truck glyphs are drawn in the same outline idiom
/// (gold strokes, neutral fills) so the whole set reads as one family.
///
/// Visual language (strict two-tone + neutral):
/// - Strokes are ALWAYS the brand gold ([AppColors.seseGold]); fills are
///   neutral white or dark charcoal (`#1A1A1A` / `#2C2C2C` per the
///   templates). No green, no multi-color blocks.
/// - Vehicles are clean side-profile silhouettes; packages are charcoal
///   boxes with a gold direction badge (up = send, down = receive).
/// - [selected] paints a soft gold under-glow so selector rows can signal
///   state without swapping widgets.
class VehicleIllustration extends StatelessWidget {
  /// Which illustration to draw.
  final VehicleArt art;

  /// Render height in logical pixels; width follows the 5:3 canvas ratio.
  final double height;

  /// When true, a soft gold under-glow is painted beneath the glyph.
  final bool selected;

  /// Optional overrides. Accent defaults to the brand gold.
  final Color? accentColor;

  const VehicleIllustration({
    super.key,
    required this.art,
    this.height = 40,
    this.selected = false,
    this.accentColor,
  });

  /// Fixed canvas ratio every painter below draws against (120 × 72).
  static const double aspectRatio = 5 / 3;

  @override
  Widget build(BuildContext context) {
    final accent = accentColor ?? AppColors.seseGold;
    return CustomPaint(
      size: Size(height * aspectRatio, height),
      painter: _painterFor(art, accent, selected),
    );
  }

  static CustomPainter _painterFor(
    VehicleArt art,
    Color accent,
    bool selected,
  ) {
    switch (art) {
      case VehicleArt.bicycle:
        return _BicycleGlyph(accent: accent, selected: selected);
      case VehicleArt.motorcycle:
        return _MotorcycleGlyph(accent: accent, selected: selected);
      case VehicleArt.keke:
        return _KekeGlyph(accent: accent, selected: selected);
      case VehicleArt.sedan:
        return _CarGlyph(accent: accent, selected: selected);
      case VehicleArt.premium:
        return _CarGlyph(
            accent: accent, selected: selected, trim: _CarTrim.premium);
      case VehicleArt.luxe:
        return _CarGlyph(accent: accent, selected: selected, trim: _CarTrim.luxe);
      case VehicleArt.van:
        return _VanGlyph(accent: accent, selected: selected);
      case VehicleArt.truck:
        return _TruckGlyph(accent: accent, selected: selected);
      case VehicleArt.packageSend:
        return _PackageGlyph(accent: accent, selected: selected, send: true);
      case VehicleArt.packageReceive:
        return _PackageGlyph(accent: accent, selected: selected, send: false);
    }
  }
}

// ── Shared bits ─────────────────────────────────────────────────────────────

/// Template neutrals (match the approved SVGs verbatim).
const Color _glyphWhite = Color(0xFFFFFFFF);
const Color _glyphCharcoal = Color(0xFF1A1A1A);
const Color _glyphBoxDark = Color(0xFF2C2C2C);

/// Base for the 24-grid outline glyphs. Handles the fit-height transform
/// (centers the 24×24 viewBox inside the 5:3 canvas) plus the shared gold
/// stroke paints and the selection under-glow.
abstract class _OutlineGlyph extends CustomPainter {
  final Color accent;
  final bool selected;

  const _OutlineGlyph({required this.accent, required this.selected});

  /// Runs [draw] inside the 24×24 template space.
  void paint24(Canvas canvas, Size size, void Function(Canvas) draw) {
    final k = size.height / 24;
    canvas.save();
    canvas.translate((size.width - 24 * k) / 2, 0);
    canvas.scale(k);
    if (selected) {
      canvas.drawOval(
        Rect.fromCenter(center: const Offset(12, 21.6), width: 20, height: 2.4),
        Paint()..color = accent.withValues(alpha: 0.28),
      );
    }
    draw(canvas);
    canvas.restore();
  }

  Paint get stroke => Paint()
    ..color = accent
    ..style = PaintingStyle.stroke
    ..strokeWidth = 1.6
    ..strokeCap = StrokeCap.round
    ..strokeJoin = StrokeJoin.round;

  @override
  bool shouldRepaint(covariant _OutlineGlyph old) =>
      old.accent != accent || old.selected != selected;
}

// ── Car (exact Book Ride / Sedan template port) ─────────────────────────────

enum _CarTrim { standard, premium, luxe }

/// Exact port of the approved car SVG (`viewBox 0 0 24 24`): the same path
/// commands, white fill, gold 1.5 stroke. Premium adds a gold under-accent;
/// luxe doubles it and gains a tiny hood diamond.
class _CarGlyph extends _OutlineGlyph {
  final _CarTrim trim;

  const _CarGlyph(
      {required super.accent, required super.selected, this.trim = _CarTrim.standard});

  @override
  void paint(Canvas canvas, Size size) {
    paint24(canvas, size, (c) {
      final body = Path()
        ..moveTo(3, 13)
        ..lineTo(5, 8)
        ..lineTo(19, 8)
        ..lineTo(21, 13)
        ..moveTo(3, 13)
        ..lineTo(3, 18)
        ..lineTo(5, 18)
        ..lineTo(5, 19)
        ..cubicTo(5, 19.5523, 5.44772, 20, 6, 20)
        ..lineTo(7, 20)
        ..cubicTo(7.55228, 20, 8, 19.5523, 8, 19)
        ..lineTo(8, 18)
        ..lineTo(16, 18)
        ..lineTo(16, 19)
        ..cubicTo(16, 19.5523, 16.4477, 20, 17, 20)
        ..lineTo(18, 20)
        ..cubicTo(18.5523, 20, 19, 19.5523, 19, 19)
        ..lineTo(19, 18)
        ..lineTo(21, 18)
        ..lineTo(21, 13)
        ..moveTo(3, 13)
        ..lineTo(21, 13)
        ..moveTo(5, 15)
        ..lineTo(7, 15)
        ..lineTo(7, 17)
        ..lineTo(5, 17)
        ..close()
        ..moveTo(17, 15)
        ..lineTo(19, 15)
        ..lineTo(19, 17)
        ..lineTo(17, 17)
        ..close();
      // Template fill first, then the gold outline — same order as the SVG.
      c.drawPath(body, Paint()..color = _glyphWhite);
      c.drawPath(
        body,
        Paint()
          ..color = accent
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.5
          ..strokeCap = StrokeCap.round
          ..strokeJoin = StrokeJoin.round,
      );
      // Trim ladder (gold only, beneath the body).
      if (trim != _CarTrim.standard) {
        c.drawLine(
          const Offset(7, 21.6),
          const Offset(17, 21.6),
          Paint()
            ..color = accent
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1.2
            ..strokeCap = StrokeCap.round,
        );
      }
      if (trim == _CarTrim.luxe) {
        c.drawLine(
          const Offset(9, 22.8),
          const Offset(15, 22.8),
          Paint()
            ..color = accent
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1
            ..strokeCap = StrokeCap.round,
        );
        final cx = 18.6;
        c.drawPath(
          Path()
            ..moveTo(cx, 9.4)
            ..lineTo(cx + 0.9, 10.3)
            ..lineTo(cx, 11.2)
            ..lineTo(cx - 0.9, 10.3)
            ..close(),
          Paint()..color = accent,
        );
      }
    });
  }

  @override
  bool shouldRepaint(covariant _CarGlyph old) =>
      super.shouldRepaint(old) || old.trim != trim;
}

// ── Motorcycle (exact courier template port) ────────────────────────────────

/// Exact port of the approved motorcycle SVG: charcoal wheels with gold
/// rims, gold street-bike frame silhouette.
class _MotorcycleGlyph extends _OutlineGlyph {
  const _MotorcycleGlyph({required super.accent, required super.selected});

  @override
  void paint(Canvas canvas, Size size) {
    paint24(canvas, size, (c) {
      for (final x in [5.0, 19.0]) {
        c.drawCircle(Offset(x, 18), 3, Paint()..color = _glyphCharcoal);
        c.drawCircle(
          Offset(x, 18),
          3,
          Paint()
            ..color = accent
            ..style = PaintingStyle.stroke
            ..strokeWidth = 2,
        );
      }
      c.drawPath(
        Path()
          ..moveTo(5, 15)
          ..lineTo(9, 15)
          ..lineTo(12, 10)
          ..lineTo(16, 10)
          ..lineTo(19, 15)
          ..moveTo(12, 10)
          ..lineTo(10, 6)
          ..lineTo(6, 6),
        Paint()
          ..color = accent
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2
          ..strokeCap = StrokeCap.round
          ..strokeJoin = StrokeJoin.round,
      );
    });
  }
}

// ── Bicycle (same outline idiom) ────────────────────────────────────────────

/// Ring wheels, triangular frame, gold chainring — drawn in the template's
/// 24-grid outline language.
class _BicycleGlyph extends _OutlineGlyph {
  const _BicycleGlyph({required super.accent, required super.selected});

  @override
  void paint(Canvas canvas, Size size) {
    paint24(canvas, size, (c) {
      final ring = Paint()
        ..color = accent
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.6;
      for (final x in [6.5, 17.5]) {
        c.drawCircle(Offset(x, 17.5), 3.4, ring);
        c.drawCircle(Offset(x, 17.5), 0.5, Paint()..color = accent);
      }
      final frame = Paint()
        ..color = _glyphCharcoal
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.6
        ..strokeCap = StrokeCap.round;
      c.drawLine(const Offset(6.5, 17.5), const Offset(11.5, 11.5), frame);
      c.drawLine(const Offset(11.5, 11.5), const Offset(17.5, 17.5), frame);
      c.drawLine(const Offset(11.5, 11.5), const Offset(11.5, 9.5), frame);
      c.drawLine(const Offset(10.3, 9.5), const Offset(12.7, 9.5), frame);
      c.drawLine(const Offset(11.5, 11.5), const Offset(13.2, 9.2), frame);
      c.drawLine(const Offset(13.2, 9.2), const Offset(14.4, 9.2), frame);
      c.drawCircle(
        const Offset(11.5, 16.6),
        1.2,
        Paint()
          ..color = accent
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.2,
      );
    });
  }
}

// ── Keke (same outline idiom) ──────────────────────────────────────────────

/// Proper 3-wheel keke: canopy roof + posts, passenger tub with gold
/// beltline, front cowl with windshield, twin rear wheels in the courier
/// dark-fill/gold-rim style.
class _KekeGlyph extends _OutlineGlyph {
  const _KekeGlyph({required super.accent, required super.selected});

  @override
  void paint(Canvas canvas, Size size) {
    paint24(canvas, size, (c) {
      final fill = Paint()..color = _glyphWhite;
      final edge = Paint()
        ..color = accent
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5
        ..strokeJoin = StrokeJoin.round;
      // Canopy roof.
      final roof =
          RRect.fromLTRBR(6, 4.5, 18, 6.5, const Radius.circular(1));
      c.drawRRect(roof, fill);
      c.drawRRect(roof, edge);
      // Posts.
      final post = Paint()
        ..color = _glyphCharcoal
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.4
        ..strokeCap = StrokeCap.round;
      c.drawLine(const Offset(7.5, 6.5), const Offset(7.5, 10.5), post);
      c.drawLine(const Offset(16.5, 6.5), const Offset(16.5, 10.5), post);
      // Passenger tub + gold beltline.
      final tub =
          RRect.fromLTRBR(5.5, 10.5, 17, 14.5, const Radius.circular(1.2));
      c.drawRRect(tub, fill);
      c.drawRRect(tub, edge);
      c.drawLine(
        const Offset(6.5, 12.5),
        const Offset(16, 12.5),
        Paint()
          ..color = accent
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.2,
      );
      // Front cowl + windshield.
      c.drawCircle(const Offset(18.6, 13), 2, fill);
      c.drawCircle(
        const Offset(18.6, 13),
        2,
        Paint()
          ..color = accent
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.5,
      );
      c.drawLine(
        const Offset(17.4, 9.4),
        const Offset(18.6, 11.4),
        Paint()
          ..color = _glyphCharcoal
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.2
          ..strokeCap = StrokeCap.round,
      );
      // Twin wheels, courier style.
      for (final x in [8.0, 14.5]) {
        c.drawCircle(Offset(x, 18.5), 2.2, Paint()..color = _glyphCharcoal);
        c.drawCircle(
          Offset(x, 18.5),
          2.2,
          Paint()
            ..color = accent
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1.4,
        );
      }
    });
  }
}

// ── Van (same outline idiom) ────────────────────────────────────────────────

/// Clean delivery van: cargo box with gold stripe, cab with windshield,
/// courier-style wheels.
class _VanGlyph extends _OutlineGlyph {
  const _VanGlyph({required super.accent, required super.selected});

  @override
  void paint(Canvas canvas, Size size) {
    paint24(canvas, size, (c) {
      final fill = Paint()..color = _glyphWhite;
      final edge = Paint()
        ..color = accent
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.6
        ..strokeJoin = StrokeJoin.round;
      final box = RRect.fromLTRBR(2, 6, 13.5, 17, const Radius.circular(1));
      c.drawRRect(box, fill);
      c.drawRRect(box, edge);
      c.drawLine(
        const Offset(3.2, 11.5),
        const Offset(12.3, 11.5),
        Paint()
          ..color = accent
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.4,
      );
      final cab = Path()
        ..moveTo(13.5, 17)
        ..lineTo(13.5, 9)
        ..lineTo(16, 9)
        ..lineTo(18.8, 13)
        ..lineTo(18.8, 17)
        ..close();
      c.drawPath(cab, fill);
      c.drawPath(cab, edge);
      c.drawLine(
        const Offset(14.6, 10.4),
        const Offset(15.9, 10.4),
        Paint()
          ..color = _glyphCharcoal
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.2
          ..strokeCap = StrokeCap.round,
      );
      c.drawLine(
        const Offset(15.9, 10.4),
        const Offset(17.3, 13),
        Paint()
          ..color = _glyphCharcoal
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.2
          ..strokeCap = StrokeCap.round,
      );
      for (final x in [6.0, 16.0]) {
        c.drawCircle(Offset(x, 18.3), 2.3, Paint()..color = _glyphCharcoal);
        c.drawCircle(
          Offset(x, 18.3),
          2.3,
          Paint()
            ..color = accent
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1.5,
        );
      }
    });
  }
}

// ── Truck (same outline idiom) ──────────────────────────────────────────────

/// Detailed truck: ribbed cargo box with gold top edge, cab, triple wheels.
class _TruckGlyph extends _OutlineGlyph {
  const _TruckGlyph({required super.accent, required super.selected});

  @override
  void paint(Canvas canvas, Size size) {
    paint24(canvas, size, (c) {
      final fill = Paint()..color = _glyphWhite;
      final edge = Paint()
        ..color = accent
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.6
        ..strokeJoin = StrokeJoin.round;
      final box = RRect.fromLTRBR(1.5, 4.5, 14, 17, const Radius.circular(0.8));
      c.drawRRect(box, fill);
      c.drawRRect(box, edge);
      // Ribs + heavy gold top edge.
      final rib = Paint()
        ..color = _glyphCharcoal
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1
        ..strokeCap = StrokeCap.round;
      c.drawLine(const Offset(5.8, 6.5), const Offset(5.8, 15), rib);
      c.drawLine(const Offset(9.8, 6.5), const Offset(9.8, 15), rib);
      c.drawLine(
        const Offset(1.5, 4.5),
        const Offset(14, 4.5),
        Paint()
          ..color = accent
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2
          ..strokeCap = StrokeCap.round,
      );
      // Cab + windshield + bumper tick.
      final cab = RRect.fromLTRBR(14.5, 9, 20.5, 17, const Radius.circular(0.8));
      c.drawRRect(cab, fill);
      c.drawRRect(cab, edge);
      c.drawPath(
        Path()
          ..moveTo(15.6, 10.4)
          ..lineTo(17.8, 10.4)
          ..lineTo(19.2, 13)
          ..lineTo(15.6, 13)
          ..close(),
        Paint()..color = _glyphCharcoal,
      );
      c.drawLine(
        const Offset(20.5, 15.6),
        const Offset(22, 15.6),
        Paint()
          ..color = accent
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.4
          ..strokeCap = StrokeCap.round,
      );
      for (final x in [5.0, 10.5, 17.0]) {
        c.drawCircle(Offset(x, 18.5), 2, Paint()..color = _glyphCharcoal);
        c.drawCircle(
          Offset(x, 18.5),
          2,
          Paint()
            ..color = accent
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1.4,
        );
      }
    });
  }
}

// ── Package (exact box template port + direction badge) ─────────────────────

/// Exact port of the approved package SVG (charcoal box, gold edges/flaps),
/// plus a gold direction badge so Send and Receive stay distinct: the badge
/// overlaps the box's lower-right corner (never the flaps) with a charcoal
/// arrow — up for send, down for receive.
class _PackageGlyph extends _OutlineGlyph {
  final bool send;

  const _PackageGlyph(
      {required super.accent, required super.selected, required this.send});

  @override
  void paint(Canvas canvas, Size size) {
    paint24(canvas, size, (c) {
      final edge = Paint()
        ..color = accent
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round;
      c.drawPath(
        Path()
          ..moveTo(21, 8)
          ..lineTo(12, 3)
          ..lineTo(3, 8)
          ..lineTo(3, 16)
          ..lineTo(12, 21)
          ..lineTo(21, 16)
          ..lineTo(21, 8)
          ..close(),
        Paint()..color = _glyphBoxDark,
      );
      c.drawPath(
        Path()
          ..moveTo(21, 8)
          ..lineTo(12, 3)
          ..lineTo(3, 8)
          ..lineTo(3, 16)
          ..lineTo(12, 21)
          ..lineTo(21, 16)
          ..lineTo(21, 8)
          ..close(),
        edge,
      );
      c.drawPath(
        Path()
          ..moveTo(3, 8)
          ..lineTo(12, 13)
          ..lineTo(21, 8),
        edge,
      );
      c.drawPath(
        Path()
          ..moveTo(12, 13)
          ..lineTo(12, 21),
        edge,
      );
      // Direction badge: gold disc + charcoal arrow.
      const badge = Offset(18.2, 18.2);
      c.drawCircle(badge, 4.1, Paint()..color = accent);
      final arrow = Paint()
        ..color = _glyphCharcoal
        ..style = PaintingStyle.fill;
      if (send) {
        c.drawRect(const Rect.fromLTRB(17.5, 16.6, 18.9, 19.4), arrow);
        c.drawPath(
          Path()
            ..moveTo(18.2, 15)
            ..lineTo(19.7, 16.8)
            ..lineTo(16.7, 16.8)
            ..close(),
          arrow,
        );
      } else {
        c.drawRect(const Rect.fromLTRB(17.5, 17, 18.9, 19.8), arrow);
        c.drawPath(
          Path()
            ..moveTo(18.2, 21.4)
            ..lineTo(19.7, 19.6)
            ..lineTo(16.7, 19.6)
            ..close(),
          arrow,
        );
      }
    });
  }

  @override
  bool shouldRepaint(covariant _PackageGlyph old) =>
      super.shouldRepaint(old) || old.send != send;
}
