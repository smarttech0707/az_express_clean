import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../theme/az_ia_theme.dart';

enum AzIaLogoVariant { iconOnly, compact, full, avatar, splash }

/// Monogramme AZ autonome : lisible à petite taille, sans dépendance asset.
class AzIaLogo extends StatelessWidget {
  final AzIaLogoVariant variant;
  final double size;
  final bool showLabel;

  const AzIaLogo({
    super.key,
    this.variant = AzIaLogoVariant.iconOnly,
    this.size = 48,
    this.showLabel = false,
  });

  bool get _withIa =>
      variant == AzIaLogoVariant.full ||
      variant == AzIaLogoVariant.splash ||
      showLabel;

  @override
  Widget build(BuildContext context) {
    final mark = RepaintBoundary(
      child: SizedBox.square(
        dimension: size,
        child: CustomPaint(
          painter: _AzCircuitPainter(),
          child: Center(
            child: Text(
              'AZ',
              style: TextStyle(
                color: AzIaTheme.azOrange,
                fontSize: size * .43,
                fontStyle: FontStyle.italic,
                fontWeight: FontWeight.w900,
                letterSpacing: -size * .075,
                shadows: const [
                  Shadow(
                    color: Color(0x99000000),
                    blurRadius: 4,
                    offset: Offset(0, 2),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );

    if (!_withIa) return mark;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        mark,
        SizedBox(width: math.max(6, size * .16)),
        Text(
          'IA',
          style: TextStyle(
            color: AzIaTheme.textPrimary,
            fontSize: size * .44,
            fontWeight: FontWeight.w700,
            letterSpacing: size * .03,
          ),
        ),
      ],
    );
  }
}

class _AzCircuitPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final center = size.center(Offset.zero);
    final radius = size.shortestSide / 2;
    final rect = Offset.zero & size;

    final fill = Paint()
      ..shader = const RadialGradient(
        colors: [Color(0xFF17243A), AzIaTheme.deepBlue, AzIaTheme.night],
        stops: [.02, .64, 1],
      ).createShader(rect);
    canvas.drawCircle(center, radius, fill);

    final ring = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = math.max(1.1, size.width * .027)
      ..shader = const SweepGradient(
        colors: [
          AzIaTheme.azOrange,
          AzIaTheme.azOrange,
          Color(0x330066FF),
          AzIaTheme.electricBlue,
          AzIaTheme.electricBlue,
          Color(0x33FF6A00),
          AzIaTheme.azOrange,
        ],
      ).createShader(rect);
    canvas.drawCircle(center, radius - ring.strokeWidth / 2, ring);

    final circuit = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = math.max(.8, size.width * .018)
      ..strokeCap = StrokeCap.round;
    final node = Paint()..style = PaintingStyle.fill;
    final inner = radius * .48;
    final outer = radius * .79;
    for (var i = 0; i < 12; i++) {
      final a = i * math.pi * 2 / 12 + .15;
      final start = center + Offset(math.cos(a) * inner, math.sin(a) * inner);
      final bend = center +
          Offset(math.cos(a) * (inner + outer) / 2,
              math.sin(a) * (inner + outer) / 2);
      final end = center + Offset(math.cos(a) * outer, math.sin(a) * outer);
      final color = i.isEven ? AzIaTheme.azOrange : AzIaTheme.electricBlue;
      circuit.color = color.withValues(alpha: .78);
      node.color = color;
      final path = Path()
        ..moveTo(start.dx, start.dy)
        ..lineTo(bend.dx, bend.dy)
        ..lineTo(end.dx, bend.dy);
      canvas.drawPath(path, circuit);
      canvas.drawCircle(
          Offset(end.dx, bend.dy), math.max(1.5, size.width * .035), node);
    }
  }

  @override
  bool shouldRepaint(covariant _AzCircuitPainter oldDelegate) => false;
}
