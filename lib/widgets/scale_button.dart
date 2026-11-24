import 'package:flutter/material.dart';
import '../utils/app_haptics.dart';

/// Remplace ElevatedButton avec effet "press in" (scale + haptic).
/// Utilise Listener au lieu de GestureDetector pour ne pas interférer
/// avec le gesture arena de ElevatedButton (évite le bug onPressed jamais appelé).
class ScaleButton extends StatefulWidget {
  final Widget child;
  final VoidCallback? onPressed;
  final ButtonStyle? style;
  final bool loading;
  // Master Prompt 125 (Partie 2/4) — optionnel, purement additif : quand
  // fourni, décrit le bouton pour un lecteur d'écran (utile si `child` est
  // une icône seule ou un contenu ambigu sans texte lisible).
  final String? semanticLabel;

  const ScaleButton({
    super.key,
    required this.child,
    required this.onPressed,
    this.style,
    this.loading = false,
    this.semanticLabel,
  });

  @override
  State<ScaleButton> createState() => _ScaleButtonState();
}

class _ScaleButtonState extends State<ScaleButton>
    with SingleTickerProviderStateMixin {
  late AnimationController _ctrl;
  late Animation<double> _scale;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 100),
    );
    _scale = Tween<double>(begin: 1.0, end: 0.94)
        .animate(CurvedAnimation(parent: _ctrl, curve: Curves.easeOut));
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final content = Listener(
      // Listener fire avant le gesture arena — pas de conflit avec ElevatedButton
      onPointerDown: (_) {
        if (widget.onPressed == null || widget.loading) return;
        if (mounted) _ctrl.forward();
        AppHaptics.tap();
      },
      onPointerUp: (_) {
        if (mounted) _ctrl.reverse();
      },
      onPointerCancel: (_) {
        if (mounted) _ctrl.reverse();
      },
      child: AnimatedBuilder(
        animation: _scale,
        builder: (_, child) => Transform.scale(
          scale: _scale.value,
          child: child,
        ),
        child: ElevatedButton(
          // ElevatedButton gère son propre onPressed normalement
          onPressed: widget.loading ? null : widget.onPressed,
          style: widget.style,
          child: widget.loading
              ? const SizedBox(
                  width: 22,
                  height: 22,
                  child: CircularProgressIndicator(
                      color: Colors.white, strokeWidth: 2.5))
              : widget.child,
        ),
      ),
    );
    // ElevatedButton fournit déjà sa propre sémantique de bouton (activé/
    // désactivé) — ce Semantics ajoute seulement le libellé quand fourni,
    // sans la remplacer (pas de excludeSemantics).
    return widget.semanticLabel == null
        ? content
        : Semantics(label: widget.semanticLabel, child: content);
  }
}
