/// Master Prompt 127 (Partie 4) — dictionnaire métier AZ Express pour la
/// correction automatique de la reconnaissance vocale.
///
/// Toutes les entrées sont des termes RÉELS déjà utilisés ailleurs dans
/// l'app (jamais inventés) : les 19 zones réelles d'Abengourou déjà
/// codées en dur dans `admin_zones_page.dart` (`_initialZones`), les
/// modules réels de l'app (Livraison/Courses/Wallet/Marketplace-Djassa/
/// Immobilier/E-Kbine/Boutique/Restaurant/Pharmacie/Boulangerie) et les
/// 4 opérateurs de paiement mobile réellement intégrés via FeexPay (Wave/
/// Orange Money/MTN Money/Moov Money, voir `feexpayOperatorCode()` côté
/// serveur).
///
/// Chaque entrée associe une variante de mauvaise reconnaissance
/// plausible (erreurs typiques d'un moteur ASR français : accents
/// perdus, mots composés séparés, "b"/"p" confondus, terminaisons
/// avalées) à la forme canonique réelle. Ce ne sont pas des données
/// métier inventées — seulement des anticipations d'erreurs de
/// transcription sur des mots déjà réels.
class AzVoiceDictionary {
  AzVoiceDictionary._();

  /// Clé = variante mal reconnue, normalisée (minuscules, sans accents,
  /// espaces simples) → valeur = forme canonique à afficher/envoyer.
  /// Les clés à plusieurs mots sont recherchées en priorité (plus longues
  /// d'abord) avant les clés à un seul mot.
  static const Map<String, String> corrections = {
    // ── Cafétou (exemple donné explicitement par le prompt) ──────────────
    'cafe tout': 'Cafétou',
    'caf etout': 'Cafétou',
    'cafetou': 'Cafétou',
    'cafe toux': 'Cafétou',

    // ── E-Kbine (exemple donné explicitement par le prompt) ──────────────
    'ekbin': 'E-Kbine',
    'ekbine': 'E-Kbine',
    'e kbine': 'E-Kbine',
    'e cabine': 'E-Kbine',
    'e kabine': 'E-Kbine',
    'ecabine': 'E-Kbine',
    'aile kbine': 'E-Kbine',

    // ── Djassa (nom réel du module Marketplace) ──────────────────────────
    'jasa': 'Djassa',
    'jassa': 'Djassa',
    'le jasa': 'Djassa',
    'dou jasa': 'Djassa',

    // ── Zones réelles d'Abengourou (admin_zones_page.dart:_initialZones) ─
    'aben gourou': 'Abengourou',
    'abin gourou': 'Abengourou',
    'aban gourou': 'Abengourou',
    'poukoukro': 'Pokoukro',
    'baoule kro': 'Baoulékro',
    'baoulekro': 'Baoulékro',
    'chateau': 'Château',
    'yakasse feyasse': 'Yakassé-Feyassé',
    'yakasse': 'Yakassé-Feyassé',
    'sanka diokro': 'Sankadiokro',
    'sankadiokro': 'Sankadiokro',
    'amelekia': 'Amélékia',
    'assakra': 'Assakra',
    'zamaka': 'Zamaka',
    'apprompronou': 'Apprompronou',
    'kodjinan': 'Kodjinan',
    'niable': 'Niablé',
    'aniassue': 'Aniassué',
    'zinzenou': 'Zinzenou',

    // ── Paiement mobile (4 opérateurs réellement intégrés via FeexPay) ───
    'ouave': 'Wave',
    'wev': 'Wave',
    'oranje money': 'Orange Money',
    'oranje monnaie': 'Orange Money',
    'orange monnaie': 'Orange Money',
    'aime te aine': 'MTN',
    'emeteaine': 'MTN',
    'mouv money': 'Moov Money',
    'mouve money': 'Moov Money',

    // ── Vocabulaire métier générique ──────────────────────────────────────
    'ouallette': 'wallet',
    'oualaite': 'wallet',
    'oualette': 'wallet',
  };

  /// Termes canoniques (vocabulaire métier réel) utilisés pour la
  /// correction approximative (distance de Levenshtein) sur un seul mot —
  /// distincte des corrections exactes ci-dessus, marquée comme "floue"
  /// (voir `VoiceCorrectionResult.fuzzyMatches`) pour déclencher une
  /// confirmation plutôt qu'une correction silencieuse (Partie 9).
  static const List<String> knownTerms = [
    'Abengourou',
    'Commerce',
    'Château',
    'Baoulékro',
    'Cafétou',
    'Plateau',
    'Pokoukro',
    'Résidentiel',
    'Administratif',
    'Niablé',
    'Amélékia',
    'Sankadiokro',
    'Zinzenou',
    'Yakassé-Feyassé',
    'Aniassué',
    'Kodjinan',
    'Zamaka',
    'Assakra',
    'Apprompronou',
    'Livraison',
    'Courses',
    'Wallet',
    'Djassa',
    'Immobilier',
    'E-Kbine',
    'Boutique',
    'Restaurant',
    'Pharmacie',
    'Boulangerie',
    'Livreur',
    'Colis',
    'Wave',
    'MTN',
    'Moov Money',
    'Orange Money',
  ];
}
