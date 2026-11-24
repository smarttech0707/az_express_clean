import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import '../theme/app_theme.dart';

/// Mention affichée près d'une durée ou d'une distance quand elles ne viennent
/// pas d'un itinéraire routier réel (repli en ligne droite, vitesse fixe).
///
/// POURQUOI : sans elle, une estimation à vol d'oiseau se lit comme le temps
/// d'arrivée réel du livreur.
class RouteEstimateNotice extends StatelessWidget {
  const RouteEstimateNotice({super.key});

  static const String message =
      'Estimation à vol d\'oiseau : itinéraire routier indisponible.';

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: message,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const ExcludeSemantics(
            child: Icon(Icons.info_outline_rounded,
                size: 14, color: AppColors.textMuted),
          ),
          const SizedBox(width: 6),
          Expanded(
            child: ExcludeSemantics(
              child: Text(
                message,
                style: GoogleFonts.urbanist(
                    fontSize: 12, color: AppColors.textMuted),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
