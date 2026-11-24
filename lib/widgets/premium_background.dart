import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

/// LOT 2/3 Premium V1 — fond racine premium. Applique
/// `AppGradients.premiumBackground(brightness)` (déjà défini au LOT 1) UNE
/// SEULE FOIS sur le conteneur racine d'un écran, avec en option une
/// texture extrêmement discrète (grille de points statique, jamais animée).
///
/// Contraintes de performance respectées (téléphone Android d'entrée de
/// gamme) :
/// - aucun `BackdropFilter`, aucun blur ;
/// - aucun shader, aucune image ;
/// - la texture est peinte une seule fois via un `CustomPainter` statique,
///   mis en cache par un `RepaintBoundary` (`shouldRepaint` ne redessine
///   que si la luminosité change) — pas de `repeat()`/animation.
///
/// Destiné à être posé une seule fois par écran (jamais carte par carte —
/// voir la consigne explicite du brief) : `Scaffold(body: PremiumBackground(
/// child: ...))`.
class PremiumBackground extends StatelessWidget {
  final Widget child;

  /// Désactive la texture de points si `false` (le dégradé reste
  /// appliqué) — utile pour un écran qui a déjà son propre contenu dense.
  final bool texture;

  const PremiumBackground({
    super.key,
    required this.child,
    this.texture = true,
  });

  @override
  Widget build(BuildContext context) {
    final brightness = Theme.of(context).brightness;
    return Container(
      decoration: BoxDecoration(
        gradient: AppGradients.premiumBackground(brightness),
      ),
      child: Stack(
        children: [
          if (texture)
            Positioned.fill(
              child: RepaintBoundary(
                child: CustomPaint(
                  painter: _PremiumTexturePainter(brightness),
                ),
              ),
            ),
          Positioned.fill(child: child),
        ],
      ),
    );
  }
}

/// Grille de points très discrète — jamais redessinée sauf changement de
/// luminosité ou de taille (comportement par défaut de `CustomPaint`).
class _PremiumTexturePainter extends CustomPainter {
  final Brightness brightness;

  const _PremiumTexturePainter(this.brightness);

  static const double _spacing = 28;
  static const double _dotRadius = 0.8;

  @override
  void paint(Canvas canvas, Size size) {
    final isDark = brightness == Brightness.dark;
    final paint = Paint()
      ..color = (isDark ? Colors.white : Colors.black)
          .withValues(alpha: isDark ? 0.038 : 0.032);

    for (double y = _spacing / 2; y < size.height; y += _spacing) {
      for (double x = _spacing / 2; x < size.width; x += _spacing) {
        canvas.drawCircle(Offset(x, y), _dotRadius, paint);
      }
    }
  }

  @override
  bool shouldRepaint(covariant _PremiumTexturePainter oldDelegate) =>
      oldDelegate.brightness != brightness;
}
