import 'az_voice_dictionary.dart';

/// Master Prompt 127 (Parties 3/5/9) — nettoie et corrige le texte issu de
/// la reconnaissance vocale AVANT qu'il ne soit envoyé à AZ IA
/// (`azIaChat`, inchangé). C'est une couche 100% cliente : aucune Cloud
/// Function, aucune donnée métier touchée — seulement du texte.
///
/// Deux étapes distinctes, volontairement séparées :
/// 1. [clean] — nettoyage générique (répétitions, espaces, ponctuation
///    parasite), sans connaissance du vocabulaire AZ Express.
/// 2. [correctBusinessTerms] — correction dirigée par le dictionnaire
///    métier (`AzVoiceDictionary`), qui distingue les corrections EXACTES
///    (paires déjà connues, ex. "café tout" → "Cafétou" — appliquées
///    silencieusement) des corrections FLOUES (distance de Levenshtein sur
///    un mot isolé, ex. une variante jamais vue explicitement) — ces
///    dernières ne sont jamais appliquées silencieusement (voir Partie 9,
///    « ne jamais inventer ») : l'appelant (`az_ia_chat_screen.dart`) les
///    utilise pour décider d'afficher une confirmation avant d'envoyer.
class VoiceCorrectionResult {
  final String text;
  final List<String> exactCorrections;
  final List<VoiceFuzzyMatch> fuzzyMatches;

  const VoiceCorrectionResult({
    required this.text,
    required this.exactCorrections,
    required this.fuzzyMatches,
  });

  bool get hasFuzzyMatch => fuzzyMatches.isNotEmpty;
}

class VoiceFuzzyMatch {
  final String original;
  final String suggestion;
  const VoiceFuzzyMatch(this.original, this.suggestion);

  @override
  String toString() => '$original→$suggestion';

  @override
  bool operator ==(Object other) =>
      other is VoiceFuzzyMatch &&
      other.original == original &&
      other.suggestion == suggestion;

  @override
  int get hashCode => Object.hash(original, suggestion);
}

class VoiceTextProcessor {
  VoiceTextProcessor._();

  // Mots de remplissage/hésitation français les plus courants — retirés
  // uniquement s'ils apparaissent comme un mot isolé (jamais à l'intérieur
  // d'un autre mot), pour ne jamais couper un vrai mot par erreur.
  static const _fillerWords = {
    'euh',
    'heu',
    'hum',
    'hmm',
    'ben',
    'bah',
    'genre',
    'quoi',
  };

  /// Étape 1 (Partie 3) — nettoyage générique, sans dictionnaire métier.
  static String clean(String raw) {
    var text = raw.trim();
    if (text.isEmpty) return text;

    // Espaces multiples → un seul espace.
    text = text.replaceAll(RegExp(r'\s+'), ' ');

    // Ponctuation répétée (rare avec autoPunctuation:false, mais possible
    // sur certains moteurs/résultats partiels) → un seul signe. `replaceAll`
    // (contrairement à `replaceAllMapped`) n'interprète jamais `$1` comme
    // une référence de groupe — seulement `replaceAllMapped` donne accès
    // au `Match` pour reconstruire le remplacement.
    text = text.replaceAllMapped(
      RegExp(r'([.,!?;:])\1+'),
      (m) => m.group(1)!,
    );

    // Répétitions immédiates du même mot (bégaiement/redite du moteur ASR),
    // insensible à la casse — "je je veux" → "je veux", "le le livreur" →
    // "le livreur". Ne touche jamais à des répétitions volontaires
    // séparées par d'autres mots.
    text = text.replaceAllMapped(
      RegExp(r'\b(\w+)(\s+\1\b)+', caseSensitive: false),
      (m) => m.group(1)!,
    );

    // Mots de remplissage isolés.
    final words = text.split(' ');
    final kept = <String>[];
    for (final w in words) {
      final bare =
          w.toLowerCase().replaceAll(RegExp(r'[^\wàâäéèêëïîôöùûüç]'), '');
      if (_fillerWords.contains(bare)) continue;
      kept.add(w);
    }
    text = kept.join(' ').trim();
    text = text.replaceAll(RegExp(r'\s+'), ' ');

    return text;
  }

  static String _stripAccents(String s) {
    const from = 'àâäéèêëïîôöùûüçÀÂÄÉÈÊËÏÎÔÖÙÛÜÇ';
    const to = 'aaaeeeeiioouuucAAAEEEEIIOOUUUC';
    final buf = StringBuffer();
    for (final ch in s.split('')) {
      final idx = from.indexOf(ch);
      buf.write(idx == -1 ? ch : to[idx]);
    }
    return buf.toString();
  }

  static String _normalizeKey(String s) => _stripAccents(s.toLowerCase())
      .replaceAll(RegExp(r'[^\w\s]'), '')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();

  /// Distance de Levenshtein classique (nombre minimal d'insertions/
  /// suppressions/substitutions pour passer de [a] à [b]).
  static int _levenshtein(String a, String b) {
    if (a == b) return 0;
    if (a.isEmpty) return b.length;
    if (b.isEmpty) return a.length;
    var prev = List<int>.generate(b.length + 1, (j) => j);
    for (var i = 1; i <= a.length; i++) {
      final curr = List<int>.filled(b.length + 1, 0);
      curr[0] = i;
      for (var j = 1; j <= b.length; j++) {
        final cost = a[i - 1] == b[j - 1] ? 0 : 1;
        curr[j] = [
          curr[j - 1] + 1,
          prev[j] + 1,
          prev[j - 1] + cost,
        ].reduce((x, y) => x < y ? x : y);
      }
      prev = curr;
    }
    return prev[b.length];
  }

  /// Étape 2 (Parties 4/5/9) — applique le dictionnaire métier sur un texte
  /// déjà nettoyé par [clean]. Recherche les clés à plusieurs mots en
  /// premier (plus spécifiques), normalisées sans accent/casse pour la
  /// comparaison uniquement — le texte de sortie utilise toujours la forme
  /// canonique correctement accentuée du dictionnaire, jamais une version
  /// dégradée.
  static VoiceCorrectionResult correctBusinessTerms(String text) {
    if (text.isEmpty) {
      return const VoiceCorrectionResult(
          text: '', exactCorrections: [], fuzzyMatches: []);
    }

    final exact = <String>[];
    var working = text;

    // Corrections exactes multi-mots d'abord (les plus longues clés
    // d'abord, pour que "café tout" ne soit pas court-circuité par une
    // règle plus courte).
    final sortedKeys = AzVoiceDictionary.corrections.keys.toList()
      ..sort((a, b) => b.length.compareTo(a.length));

    for (final key in sortedKeys) {
      final canonical = AzVoiceDictionary.corrections[key]!;
      final pattern = RegExp(
        r'\b' + RegExp.escape(key).replaceAll(r'\ ', r'\s+') + r'\b',
        caseSensitive: false,
      );
      // Comparaison sur la version normalisée (sans accent) du texte
      // courant pour matcher les clés qui, elles, sont déjà sans accent.
      final normalizedWorking = _stripAccents(working);
      if (pattern.hasMatch(normalizedWorking)) {
        // Remplace dans le texte réel (avec accents) en se basant sur les
        // positions trouvées dans la version normalisée — les deux chaînes
        // ont la même longueur/segmentation en mots car _stripAccents ne
        // change jamais le nombre de caractères. Si le mot était déjà
        // exactement la forme canonique (ex. "Cafétou" déjà bien
        // transcrit), aucun remplacement n'a lieu et ce n'est jamais
        // compté comme une correction.
        final result = _replaceIgnoringAccents(working, pattern, canonical);
        working = result.text;
        if (result.changed) exact.add('$key→$canonical');
      }
    }

    // Corrections floues (un seul mot, jamais silencieuses) — seulement
    // sur les mots qui ne correspondent déjà exactement à aucun terme
    // connu, pour ne jamais "corriger" un mot déjà correct.
    final fuzzy = <VoiceFuzzyMatch>[];
    final tokens = working.split(' ');
    for (var i = 0; i < tokens.length; i++) {
      final raw = tokens[i];
      final bare = raw.replaceAll(RegExp(r'[^\wàâäéèêëïîôöùûüç-]'), '');
      if (bare.length < 4) continue; // mots trop courts = trop de faux positifs
      final normalized = _normalizeKey(bare);
      if (AzVoiceDictionary.knownTerms
          .any((t) => _normalizeKey(t) == normalized)) {
        continue; // déjà exact, rien à corriger
      }
      String? bestTerm;
      var bestDist = 999;
      for (final term in AzVoiceDictionary.knownTerms) {
        if (term.contains(' '))
          continue; // termes composés hors fuzzy single-mot
        final termNorm = _normalizeKey(term);
        // Seuil resserré : à distance 2 sur un terme de 6-7 lettres, un mot
        // français courant et sans rapport (ex. "livre") finissait par
        // matcher "Livreur" — un faux positif. Distance 2 n'est autorisée
        // que sur des termes plus longs (8+), où le risque de collision
        // avec un mot générique redevient faible.
        final maxDist = termNorm.length <= 7 ? 1 : 2;
        final dist = _levenshtein(normalized, termNorm);
        if (dist <= maxDist && dist < bestDist) {
          bestDist = dist;
          bestTerm = term;
        }
      }
      if (bestTerm != null) {
        fuzzy.add(VoiceFuzzyMatch(raw, bestTerm));
      }
    }

    return VoiceCorrectionResult(
        text: working, exactCorrections: exact, fuzzyMatches: fuzzy);
  }

  /// Remplace les occurrences de [pattern] (déjà calculé sur la version
  /// sans accent) directement dans [source] (avec accents) — les deux
  /// versions ayant la même longueur caractère-par-caractère, les indices
  /// de correspondance restent valides d'une version à l'autre. Un match
  /// déjà identique au remplacement (mot déjà correctement transcrit) est
  /// laissé tel quel et ne compte pas comme un changement.
  static ({String text, bool changed}) _replaceIgnoringAccents(
      String source, RegExp pattern, String replacement) {
    final normalized = _stripAccents(source);
    final matches = pattern.allMatches(normalized).toList();
    if (matches.isEmpty) return (text: source, changed: false);
    final buf = StringBuffer();
    var last = 0;
    var changed = false;
    for (final m in matches) {
      buf.write(source.substring(last, m.start));
      final original = source.substring(m.start, m.end);
      if (original == replacement) {
        buf.write(original);
      } else {
        buf.write(replacement);
        changed = true;
      }
      last = m.end;
    }
    buf.write(source.substring(last));
    return (text: buf.toString(), changed: changed);
  }

  /// Pipeline complet (clean + correction) — point d'entrée unique utilisé
  /// par l'écran de chat.
  static VoiceCorrectionResult process(String raw) {
    final cleaned = clean(raw);
    return correctBusinessTerms(cleaned);
  }
}
