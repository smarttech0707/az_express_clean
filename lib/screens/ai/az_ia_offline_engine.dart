// ═══════════════════════════════════════════════════════════════════════════
// Mode hors ligne AZ IA (Master Prompt 118) — quand azIaChat est injoignable
// (pas de réseau), un mini-moteur de FAQ/navigation strictement local répond
// à quelques questions simples plutôt que de laisser l'utilisateur face à un
// message d'erreur sec. Correspondance par mot-clé ASSUMÉE ici (contrairement
// à l'architecture de réponses structurées du Prompt 117, qui a supprimé les
// heuristiques de mots-clés pour le choix de CARTE en ligne) — ce sont deux
// besoins différents : hors ligne, il n'y a par définition aucune donnée
// serveur à interroger, donc un mini-moteur de correspondance locale est le
// seul mécanisme honnête possible, pas un contournement de la règle Prompt 117.
// ═══════════════════════════════════════════════════════════════════════════

class AzIaOfflineEngine {
  /// Retourne une réponse locale si le message correspond à une question
  /// simple déjà connue, sinon `null` (l'appelant doit alors afficher un
  /// message générique "hors ligne" plutôt qu'inventer une réponse).
  static String? tryAnswer(String message) {
    final m = message.toLowerCase().trim();
    if (m.isEmpty) return null;

    for (final entry in _faq) {
      if (entry.keywords.any((k) => m.contains(k))) {
        return entry.answer;
      }
    }
    return null;
  }
}

class _FaqEntry {
  final List<String> keywords;
  final String answer;
  const _FaqEntry(this.keywords, this.answer);
}

const _faq = <_FaqEntry>[
  _FaqEntry(
    ['horaire', 'heure d\'ouverture', 'ouvert jusqu'],
    "Je suis hors ligne, je ne peux pas vérifier les horaires en temps réel. En général, AZ Express livre jusqu'à 21h (au-delà, seulement dans un rayon de 10 km). Reconnecte-toi pour une réponse à jour.",
  ),
  _FaqEntry(
    ['contact', 'support', 'aide', 'problème', 'réclamation'],
    "Hors ligne, je ne peux pas créer de ticket de support. Dès que tu es reconnecté, dis-moi ton problème et je m'en occupe, ou utilise l'écran Support directement depuis le menu.",
  ),
  _FaqEntry(
    ['comment ça marche', 'comment commander', 'comment faire une commande'],
    "AZ Express fonctionne simplement : choisis un service (Livraison, Courses, Restaurant, Pharmacie...), indique ce dont tu as besoin, choisis ton paiement (wallet ou cash), et un livreur prend en charge ta commande. Reconnecte-toi pour que je puisse la créer directement avec toi.",
  ),
  _FaqEntry(
    ['wallet', 'solde', 'portefeuille'],
    "Je ne peux pas consulter ton solde hors ligne. Ouvre l'écran Wallet depuis le menu principal pour le voir, ou reconnecte-toi pour me demander directement.",
  ),
  _FaqEntry(
    ['commande', 'suivi', 'où en est'],
    "Je ne peux pas suivre tes commandes hors ligne. Ouvre l'écran \"Mes commandes\" depuis le menu, ou reconnecte-toi pour que je vérifie directement avec toi.",
  ),
  _FaqEntry(
    ['c\'est quoi az express', 'qui es-tu', 'que peux-tu faire'],
    "AZ Express est une super-application ivoirienne : livraison, courses, marketplace, immobilier, restaurants, pharmacies, E-Kbine et wallet — le tout accessible en me parlant. « Parlez. AZ s'occupe du reste. »",
  ),
];
