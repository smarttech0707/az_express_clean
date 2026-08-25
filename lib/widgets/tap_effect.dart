import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../utils/app_haptics.dart';

/// Wrapper qui ajoute un effet visuel de pression + haptic feedback
/// sur n'importe quel widget.
///
/// Usage:
///   TapEffect(
///     onTap: () => ...,
///     child: MonWidget(),
///   )
class TapEffect extends StatefulWidget {
  final Widget child;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;
  final double scaleDown;
  final Duration duration;
  final HapticType haptic;
  final BorderRadius? borderRadius;
  // Master Prompt 125 (Partie 2/4) — optionnel, purement additif : ce widget
  // enveloppe un `GestureDetector` brut sans aucune sémantique propre ;
  // quand `child` est une icône/image seule sans texte, ce libellé est le
  // seul moyen pour un lecteur d'écran d'annoncer le rôle du bouton.
  final String? semanticLabel;

  const TapEffect({
    super.key,
    required this.child,
    this.onTap,
    this.onLongPress,
    this.scaleDown = 0.93,
    this.duration = const Duration(milliseconds: 120),
    this.haptic = HapticType.light,
    this.borderRadius,
    this.semanticLabel,
  });

  @override
  State<TapEffect> createState() => _TapEffectState();
}

enum HapticType { none, light, medium, selection }

class _TapEffectState extends State<TapEffect>
    with SingleTickerProviderStateMixin {
  late AnimationController _ctrl;
  late Animation<double> _scale;

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
        // Master Prompt 126 — délègue à AppHaptics.tap() (même
        // HapticFeedback.vibrate() qu'avant, fonctionne sur tous les
        // appareils Android y compris budget), centralisé pour ne plus
        // dupliquer le choix de méthode native à chaque widget.
        AppHaptics.tap();
        break;
      case HapticType.medium:
        HapticFeedback.mediumImpact();
        HapticFeedback.vibrate();
        break;
      case HapticType.selection:
        AppHaptics.selection();
        break;
      case HapticType.none:
        break;
    }
  }

  @override
  Widget build(BuildContext context) {
    final content = GestureDetector(
      onTapDown: widget.onTap != null ? _onTapDown : null,
      onTapUp: widget.onTap != null ? _onTapUp : null,
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
    // Master Prompt 125 — ce GestureDetector brut n'a aucune sémantique par
    // défaut ; quand un libellé est fourni, on en fait un vrai bouton
    // accessible (excludeSemantics évite une double annonce de l'icône).
    if (widget.semanticLabel == null) return content;
    return Semantics(
      label: widget.semanticLabel,
      button: widget.onTap != null,
      enabled: widget.onTap != null,
      onTap: widget.onTap,
      excludeSemantics: true,
      child: content,
    );
  }
}
