import 'package:flutter/material.dart';

/// Master Prompt 126 (Partie 14) — bibliothèque commune d'animations
/// d'entrée. Ne redéfinit pas ce qui existe déjà et fonctionne :
/// - **Fade + Slide** : déjà couvert par `FadeSlideIn` (`fade_slide_in.dart`,
///   Master Prompt 124) — réutilisé tel quel, pas dupliqué ici.
/// - **Ripple** : déjà global via `AppTheme._build().splashFactory =
///   InkRipple.splashFactory` — tout `InkWell`/`ElevatedButton`/etc. en
///   bénéficie automatiquement, rien à ajouter.
/// - **Hero** : widget natif Flutter `Hero(tag: ..., child: ...)` — déjà
///   disponible sans wrapper supplémentaire ; son adoption reste une
///   décision produit par écran (transition liste→détail), pas un manque
///   d'infrastructure.
/// Ce fichier ajoute les 2 briques qui manquaient réellement : une entrée
/// par échelle (`ScaleIn`) et une entrée avec rebond (`BounceIn`, même
/// courbe `easeOutBack` déjà utilisée pour l'icône de nav active du Prompt
/// 124, généralisée en widget réutilisable).
class ScaleIn extends StatefulWidget {
  final Widget child;
  final Duration duration;
  final double from;

  const ScaleIn({
    super.key,
    required this.child,
    this.duration = const Duration(milliseconds: 260),
    this.from = 0.92,
  });

  @override
  State<ScaleIn> createState() => _ScaleInState();
}

class _ScaleInState extends State<ScaleIn> with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;
  late final Animation<double> _scale;
  late final Animation<double> _fade;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(vsync: this, duration: widget.duration);
    _scale = Tween<double>(begin: widget.from, end: 1.0)
        .animate(CurvedAnimation(parent: _ctrl, curve: Curves.easeOutCubic));
    _fade = CurvedAnimation(parent: _ctrl, curve: Curves.easeOut);
    _ctrl.forward();
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FadeTransition(
      opacity: _fade,
      child: ScaleTransition(scale: _scale, child: widget.child),
    );
  }
}

/// Entrée avec léger rebond — pour un élément qu'on veut mettre en avant
/// (badge, icône de succès, carte de confirmation), pas pour des listes
/// entières (l'overshoot répété sur plusieurs items serait distrayant).
class BounceIn extends StatefulWidget {
  final Widget child;
  final Duration duration;

  const BounceIn({
    super.key,
    required this.child,
    this.duration = const Duration(milliseconds: 420),
  });

  @override
  State<BounceIn> createState() => _BounceInState();
}

class _BounceInState extends State<BounceIn>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;
  late final Animation<double> _scale;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(vsync: this, duration: widget.duration);
    _scale = Tween<double>(begin: 0.6, end: 1.0)
        .animate(CurvedAnimation(parent: _ctrl, curve: Curves.easeOutBack));
    _ctrl.forward();
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ScaleTransition(scale: _scale, child: widget.child);
  }
}
