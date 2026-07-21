import 'package:flutter/services.dart';

/// Master Prompt 126 (Partie 15) — point d'entrée unique pour tout retour
/// haptique de l'app. Avant cette passe, chaque widget (`ScaleButton`,
/// `TapEffect`, boutons ad hoc dans les écrans) appelait `HapticFeedback.*`
/// directement, avec des choix parfois différents pour un même type
/// d'interaction. `AppHaptics` centralise ces choix nommés par intention
/// (pas par méthode native) pour que tout nouveau code appelle
/// `AppHaptics.tap()`/`.success()`/... plutôt que de deviner quelle méthode
/// `HapticFeedback` utiliser.
///
/// `HapticFeedback.vibrate()` reste le choix pour `tap()` — déjà documenté
/// (Prompt 116/124) comme un choix délibéré de compatibilité matérielle
/// (fonctionne sur les appareils Android d'entrée de gamme sans moteur à
/// amplitude variable) ; ne pas le remplacer par `lightImpact()` sans
/// preuve que ça régresse sur ce type d'appareil.
class AppHaptics {
  AppHaptics._();

  /// Appui standard sur un bouton/carte/item de liste.
  static void tap() => HapticFeedback.vibrate();

  /// Sélection dans un groupe (onglet, chip, radio, switch).
  static void selection() => HapticFeedback.selectionClick();

  /// Action réussie (paiement confirmé, commande créée, message envoyé).
  static void success() => HapticFeedback.mediumImpact();

  /// Erreur/échec (paiement refusé, validation de formulaire).
  static void error() => HapticFeedback.heavyImpact();

  /// Avertissement (confirmation destructrice, solde faible).
  static void warning() => HapticFeedback.mediumImpact();
}
