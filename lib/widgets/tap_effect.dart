import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Wrapper qui ajoute un effet visuel de pression + haptic feedback
/// sur n'importe quel widget.
///
/// Usage:
///   TapEffect(
///     onTap: () => ...,
///     child: MonWidget(),
///   )
class TapEffect extends StatefulWidget {
  final Widget      child;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;
  final double      scaleDown;
  final Duration    duration;
  final HapticType  haptic;
  final BorderRadius? borderRadius;

  const TapEffect({
    super.key,
    required this.child,
    this.onTap,
    this.onLongPress,
    this.scaleDown    = 0.93,
    this.duration     = const Duration(milliseconds: 120),
    this.haptic       = HapticType.light,
    this.borderRadius,
  });

  @override
  State<TapEffect> createState() => _TapEffectState();
}

enum HapticType { none, light, medium, selection }

class _TapEffectState extends State<TapEffect>
    with SingleTickerProviderStateMixin {
  late AnimationController _ctrl;
  late Animation<double>   _scale;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(vsync: this, duration: widget.duration);
    _scale = Tween<double>(begin: 1.0, end: widget.scaleDown)
        .animate(CurvedAnimation(parent: _ctrl, curve: Curves.easeOut));
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  void _onTapDown(TapDownDetails _) {
    _ctrl.forward();
    _triggerHaptic();
  }

  void _onTapUp(TapUpDetails _) {
    _ctrl.reverse();
    widget.onTap?.call();
  }

  void _onTapCancel() => _ctrl.reverse();

  void _triggerHaptic() {
    switch (widget.haptic) {
      case HapticType.light:
        // vibrate() fonctionne sur tous les appareils Android (y compris budget)
        HapticFeedback.vibrate();
        break;
      case HapticType.medium:
        HapticFeedback.mediumImpact();
        HapticFeedback.vibrate();
        break;
      case HapticType.selection:
        HapticFeedback.selectionClick();
        break;
      case HapticType.none:
        break;
    }
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTapDown:   widget.onTap != null ? _onTapDown   : null,
      onTapUp:     widget.onTap != null ? _onTapUp     : null,
      onTapCancel: widget.onTap != null ? _onTapCancel : null,
      onLongPress: widget.onLongPress,
      child: AnimatedBuilder(
        animation: _scale,
        builder: (_, child) => Transform.scale(
          scale: _scale.value,
          child: child,
        ),
        child: widget.child,
      ),
    );
  }
}
