import 'package:flutter/material.dart';

import '../../theme/az_ia_theme.dart';
import 'az_ia_logo.dart';

class AzIaFloatingButton extends StatefulWidget {
  final VoidCallback onPressed;
  final String semanticLabel;

  const AzIaFloatingButton({
    super.key,
    required this.onPressed,
    this.semanticLabel = 'Ouvrir AZ IA',
  });

  @override
  State<AzIaFloatingButton> createState() => _AzIaFloatingButtonState();
}

class _AzIaFloatingButtonState extends State<AzIaFloatingButton>
    with SingleTickerProviderStateMixin {
  late final AnimationController _halo = AnimationController(
    vsync: this,
    duration: AzIaTheme.ambient,
  )..repeat(reverse: true);
  bool _pressed = false;

  @override
  void dispose() {
    _halo.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final reduceMotion = MediaQuery.disableAnimationsOf(context);
    final child = AnimatedBuilder(
      animation: _halo,
      builder: (_, button) {
        final glow = reduceMotion ? .28 : .18 + _halo.value * .16;
        return Container(
          decoration: BoxDecoration(
            borderRadius: AzIaTheme.pillRadius,
            boxShadow: [
              BoxShadow(
                color: AzIaTheme.electricBlue.withValues(alpha: glow),
                blurRadius: 18,
                spreadRadius: 1,
              ),
            ],
          ),
          child: button,
        );
      },
      child: AnimatedScale(
        scale: _pressed ? .96 : 1,
        duration: AzIaTheme.fast,
        child: Semantics(
          button: true,
          label: widget.semanticLabel,
          child: Material(
            color: Colors.transparent,
            borderRadius: AzIaTheme.pillRadius,
            child: InkWell(
              borderRadius: AzIaTheme.pillRadius,
              onTap: widget.onPressed,
              onHighlightChanged: (value) => setState(() => _pressed = value),
              child: Ink(
                height: 60,
                padding: const EdgeInsets.symmetric(horizontal: 18),
                decoration: BoxDecoration(
                  gradient: AzIaTheme.iaButtonGradient,
                  borderRadius: AzIaTheme.pillRadius,
                  border: Border.all(
                      color: AzIaTheme.electricBlue.withValues(alpha: .8)),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const AzIaLogo(size: 30),
                    const SizedBox(width: 10),
                    const Text(
                      'AZ IA',
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 16,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Icon(Icons.auto_awesome,
                        color: Colors.white.withValues(alpha: .82), size: 18),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
    return reduceMotion ? child : RepaintBoundary(child: child);
  }
}
