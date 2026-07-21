import 'package:flutter/material.dart';

/// Animation d'apparition (fondu + glissement léger) pour les listes et
/// cartes (Master Prompt 124, Parties 4/6/8) — même principe que
/// `_AnimatedEntrance` déjà utilisé dans `az_ia_chat_screen.dart`, extrait
/// ici en widget public réutilisable pour ne pas dupliquer ce petit bloc
/// dans chaque écran qui en a besoin.
///
/// [index] permet un effet décalé ("stagger") quand utilisé dans un
/// `ListView.builder`/`GridView.builder` — chaque élément apparaît un peu
/// après le précédent plutôt que tous en même temps.
class FadeSlideIn extends StatefulWidget {
  final Widget child;
  final int index;
  final Duration baseDelay;
  final Duration duration;

  const FadeSlideIn({
    super.key,
    required this.child,
    this.index = 0,
    this.baseDelay = const Duration(milliseconds: 40),
    this.duration = const Duration(milliseconds: 280),
  });

  @override
  State<FadeSlideIn> createState() => _FadeSlideInState();
}

class _FadeSlideInState extends State<FadeSlideIn> with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl = AnimationController(vsync: this, duration: widget.duration);
  late final Animation<double> _fade = CurvedAnimation(parent: _ctrl, curve: Curves.easeOutCubic);
  late final Animation<Offset> _slide = Tween(begin: const Offset(0, 0.08), end: Offset.zero)
      .animate(CurvedAnimation(parent: _ctrl, curve: Curves.easeOutCubic));

  @override
  void initState() {
    super.initState();
    // Plafonné à 8 éléments de décalage — au-delà, l'attente cumulée
    // deviendrait perceptible plutôt qu'élégante sur une longue liste.
    final delay = widget.baseDelay * widget.index.clamp(0, 8);
    if (delay == Duration.zero) {
      _ctrl.forward();
    } else {
      Future.delayed(delay, () {
        if (mounted) _ctrl.forward();
      });
    }
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
      child: SlideTransition(position: _slide, child: widget.child),
    );
  }
}
