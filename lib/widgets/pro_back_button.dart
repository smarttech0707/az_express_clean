import 'package:flutter/material.dart';

/// Flèche de retour des écrans de connexion « Espace Professionnel » qui n'ont
/// pas d'`AppBar` (dégradé plein écran) : sans elle, seul le bouton Retour
/// système permettait de revenir au portail. Masquée quand il n'y a rien où
/// revenir (écran racine), pour ne jamais proposer une flèche sans effet.
class ProBackButton extends StatelessWidget {
  const ProBackButton({super.key, this.color = Colors.white});

  /// Blanc sur les fonds colorés ; à adapter sur un fond clair.
  final Color color;

  @override
  Widget build(BuildContext context) {
    if (!Navigator.canPop(context)) return const SizedBox.shrink();
    return IconButton(
      icon: const Icon(Icons.arrow_back_rounded),
      color: color,
      tooltip: 'Retour',
      onPressed: () => Navigator.maybePop(context),
    );
  }
}

/// Ajoute la flèche de retour au-dessus d'un état transitoire ou d'erreur
/// (chargement, reprise de session, « introuvable », connexion requise) rendu
/// dans un `Scaffold` sans `AppBar`. Ces états n'ont aucune navigation propre :
/// sans cette flèche, un réseau lent ou une erreur bloquait l'utilisateur
/// (seul le bouton Retour système restait). À n'utiliser que sur un écran
/// poussé, jamais sur un onglet : la flèche quitte l'écran entier.
class BackOverlay extends StatelessWidget {
  const BackOverlay({super.key, required this.child, this.color});

  final Widget child;

  /// Couleur de la flèche ; par défaut celle du texte du thème (clair/sombre).
  final Color? color;

  @override
  Widget build(BuildContext context) {
    return Stack(
      fit: StackFit.expand,
      children: [
        child,
        SafeArea(
          child: Align(
            alignment: Alignment.topLeft,
            child: Padding(
              padding: const EdgeInsets.only(top: 4, left: 4),
              child: ProBackButton(
                color: color ?? Theme.of(context).colorScheme.onSurface,
              ),
            ),
          ),
        ),
      ],
    );
  }
}
