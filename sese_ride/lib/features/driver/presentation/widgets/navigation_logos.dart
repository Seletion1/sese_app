import 'package:flutter/material.dart';

/// Recognizable Google Maps 4-color pin logo vector rendered strictly via
/// Flutter [CustomPainter] (zero external images, zero flutter_svg dependency).
class GoogleMapsLogo extends StatelessWidget {
  final double size;

  const GoogleMapsLogo({super.key, this.size = 28});

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: size,
      height: size,
      child: CustomPaint(
        painter: _GoogleMapsPinPainter(),
      ),
    );
  }
}

class _GoogleMapsPinPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width;
    final h = size.height;

    final cx = w * 0.5;
    final cy = h * 0.38;
    final r = w * 0.34; // Outer circle radius of the pin head
    final innerR = r * 0.44; // Inner hole cutout radius

    // 1. Build the pin outer boundary path
    final pinPath = Path();
    pinPath.moveTo(cx, cy - r);
    // Top-right arc to right shoulder
    pinPath.arcToPoint(
      Offset(cx + r * 0.88, cy + r * 0.48),
      radius: Radius.circular(r),
      clockwise: true,
    );
    // Smooth quadratic curve down to the bottom tip
    pinPath.quadraticBezierTo(
      cx + r * 0.35,
      cy + r * 1.35,
      cx,
      h * 0.94,
    );
    // Smooth quadratic curve from bottom tip up to left shoulder
    pinPath.quadraticBezierTo(
      cx - r * 0.35,
      cy + r * 1.35,
      cx - r * 0.88,
      cy + r * 0.48,
    );
    // Left arc back to top center
    pinPath.arcToPoint(
      Offset(cx, cy - r),
      radius: Radius.circular(r),
      clockwise: true,
    );
    pinPath.close();

    // 2. Center cutout hole
    final holePath = Path()
      ..addOval(Rect.fromCircle(center: Offset(cx, cy), radius: innerR));

    // Combine difference so the center is transparent
    final pinShape = Path.combine(PathOperation.difference, pinPath, holePath);

    // 3. Draw the 4 Google brand color sectors clipped inside the pin
    canvas.save();
    canvas.clipPath(pinShape);

    // Google Red (#EA4335) - Upper-right quadrant
    final redPath = Path()
      ..moveTo(cx, cy)
      ..lineTo(cx, 0)
      ..lineTo(w, 0)
      ..lineTo(w, cy + r * 0.2)
      ..close();
    canvas.drawPath(redPath, Paint()..color = const Color(0xFFEA4335));

    // Google Yellow (#FBBC04) - Lower-right slope
    final yellowPath = Path()
      ..moveTo(cx, cy)
      ..lineTo(w, cy + r * 0.2)
      ..lineTo(w, h)
      ..lineTo(cx, h)
      ..close();
    canvas.drawPath(yellowPath, Paint()..color = const Color(0xFFFBBC04));

    // Google Green (#34A853) - Lower-left slope & tip base
    final greenPath = Path()
      ..moveTo(cx, cy)
      ..lineTo(cx, h)
      ..lineTo(0, h)
      ..lineTo(0, cy + r * 0.2)
      ..close();
    canvas.drawPath(greenPath, Paint()..color = const Color(0xFF34A853));

    // Google Blue (#4285F4) - Upper-left quadrant
    final bluePath = Path()
      ..moveTo(cx, cy)
      ..lineTo(0, cy + r * 0.2)
      ..lineTo(0, 0)
      ..lineTo(cx, 0)
      ..close();
    canvas.drawPath(bluePath, Paint()..color = const Color(0xFF4285F4));

    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

/// Recognizable Waze mascot logo vector rendered strictly via
/// Flutter [CustomPainter] (zero external images, zero flutter_svg dependency).
class WazeLogo extends StatelessWidget {
  final double size;

  const WazeLogo({super.key, this.size = 28});

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: size,
      height: size,
      child: CustomPaint(
        painter: _WazeMascotPainter(),
      ),
    );
  }
}

class _WazeMascotPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width;

    // Scale from a normalized 40x40 design canvas
    final scale = w / 40.0;
    canvas.save();
    canvas.scale(scale, scale);

    // 1. Two Wheels (drawn first so they sit slightly behind the body bottom)
    final wheelPaint = Paint()
      ..color = const Color(0xFF1E293B)
      ..style = PaintingStyle.fill;
    final hubPaint = Paint()
      ..color = Colors.white
      ..style = PaintingStyle.fill;

    const leftWheelCenter = Offset(13.0, 27.5);
    const rightWheelCenter = Offset(27.0, 27.5);
    const wheelRadius = 3.6;
    const hubRadius = 1.2;

    canvas.drawCircle(leftWheelCenter, wheelRadius, wheelPaint);
    canvas.drawCircle(leftWheelCenter, hubRadius, hubPaint);
    canvas.drawCircle(rightWheelCenter, wheelRadius, wheelPaint);
    canvas.drawCircle(rightWheelCenter, hubRadius, hubPaint);

    // 2. Waze Character Body (pill/car shape with tail speech bubble)
    final bodyPath = Path();
    // Rounded main body
    final bodyRRect = RRect.fromRectAndRadius(
      const Rect.fromLTWH(6.0, 8.0, 28.0, 18.0),
      const Radius.circular(9.0),
    );
    bodyPath.addRRect(bodyRRect);

    // Speech-bubble tail at back left
    final tailPath = Path()
      ..moveTo(6.0, 19.0)
      ..quadraticBezierTo(2.5, 23.0, 4.0, 25.5)
      ..quadraticBezierTo(8.0, 25.0, 11.0, 23.5)
      ..close();
    final combinedBody = Path.combine(PathOperation.union, bodyPath, tailPath);

    // Fill body with Waze Cyan / Soft Blue
    final bodyFillPaint = Paint()
      ..color = const Color(0xFF33CCFF)
      ..style = PaintingStyle.fill;
    canvas.drawPath(combinedBody, bodyFillPaint);

    // Dark outline for the body
    final bodyOutlinePaint = Paint()
      ..color = const Color(0xFF1E293B)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.8
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    canvas.drawPath(combinedBody, bodyOutlinePaint);

    // 3. Eyes (two friendly black circles with white pupils)
    final eyePaint = Paint()
      ..color = const Color(0xFF1E293B)
      ..style = PaintingStyle.fill;
    final pupilPaint = Paint()
      ..color = Colors.white
      ..style = PaintingStyle.fill;

    const leftEye = Offset(19.0, 15.0);
    const rightEye = Offset(27.5, 15.0);
    const eyeRadius = 2.1;
    const pupilRadius = 0.7;

    canvas.drawCircle(leftEye, eyeRadius, eyePaint);
    canvas.drawCircle(
      Offset(leftEye.dx - 0.6, leftEye.dy - 0.6),
      pupilRadius,
      pupilPaint,
    );

    canvas.drawCircle(rightEye, eyeRadius, eyePaint);
    canvas.drawCircle(
      Offset(rightEye.dx - 0.6, rightEye.dy - 0.6),
      pupilRadius,
      pupilPaint,
    );

    // 4. Smile (smooth black arc between and under the eyes)
    final smilePath = Path()
      ..moveTo(21.0, 19.5)
      ..quadraticBezierTo(24.0, 22.5, 27.0, 19.5);
    final smilePaint = Paint()
      ..color = const Color(0xFF1E293B)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5
      ..strokeCap = StrokeCap.round;
    canvas.drawPath(smilePath, smilePaint);

    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
