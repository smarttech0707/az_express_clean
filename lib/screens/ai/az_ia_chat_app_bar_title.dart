import 'package:flutter/material.dart';

import '../../theme/az_ia_theme.dart';
import '../../widgets/az_ia/az_ia_logo.dart';

/// Titre de l'AppBar du chat AZ IA : logo + « AZ IA » / « Assistant AZ Express ».
///
/// Correctif responsive. L'ancienne version plaçait une `Column` de largeur
/// intrinsèque non contrainte dans un `Row(mainAxisSize: MainAxisSize.min)` ;
/// sur écran étroit (≈ ≤ 360 dp, ou avec une taille d'affichage/police système
/// agrandie), la partie texte ne pouvait pas rétrécir et débordait à droite
/// dans la zone des `actions` de l'AppBar (« A RenderFlex overflowed … on the
/// right »). Ici la partie texte est `Flexible` et tronquée en ellipse :
/// aucun changement visible tant que le texte tient (écrans larges), pas de
/// débordement quand il ne tient pas.
class AzIaChatAppBarTitle extends StatelessWidget {
  const AzIaChatAppBarTitle({super.key});

  @override
  Widget build(BuildContext context) {
    return const Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        AzIaLogo(size: 38, variant: AzIaLogoVariant.avatar),
        SizedBox(width: 10),
        Flexible(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('AZ IA',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
              Text('Assistant AZ Express',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style:
                      TextStyle(fontSize: 11, color: AzIaTheme.textSecondary)),
            ],
          ),
        ),
      ],
    );
  }
}
