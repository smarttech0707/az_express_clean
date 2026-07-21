import 'package:flutter_test/flutter_test.dart';
import 'package:az_express/services/voice/voice_text_processor.dart';

/// Master Prompt 127 (Partie 12) — teste réellement des dizaines de
/// phrases représentatives de chaque module de l'app (livraison, courses,
/// wallet, immobilier, pharmacie, restaurant, taxi/E-Kbine), plus le
/// nettoyage générique et les 2 corrections explicitement demandées par le
/// prompt (« café tout » → « Cafétou », « ekbin » → « E-Kbine »).
void main() {
  group('VoiceTextProcessor.clean — nettoyage générique (Partie 3)', () {
    test('supprime les espaces multiples', () {
      expect(VoiceTextProcessor.clean('je   veux    un  colis'),
          'je veux un colis');
    });

    test('supprime les répétitions immédiates du même mot (bégaiement)', () {
      expect(VoiceTextProcessor.clean('je je veux un colis colis'),
          'je veux un colis');
    });

    test('supprime les mots de remplissage isolés (euh, hum, bah)', () {
      expect(VoiceTextProcessor.clean('euh je veux hum une pharmacie bah ouverte'),
          'je veux une pharmacie ouverte');
    });

    test('ne casse jamais un vrai mot contenant "euh"/"ben" en sous-chaîne', () {
      // "chauffeur" contient "euh", "benoit" contient "ben" — ne doivent
      // jamais être retirés puisqu'ils ne sont pas des mots isolés.
      expect(VoiceTextProcessor.clean('appelle le chauffeur de benoit'),
          'appelle le chauffeur de benoit');
    });

    test('collapse la ponctuation répétée', () {
      expect(VoiceTextProcessor.clean('où est mon livreur??'),
          'où est mon livreur?');
    });

    test('texte vide reste vide', () {
      expect(VoiceTextProcessor.clean('   '), '');
    });
  });

  group('VoiceTextProcessor.correctBusinessTerms — corrections exactes (Partie 5)', () {
    test('"café tout" → "Cafétou" (exemple explicite du prompt)', () {
      final r = VoiceTextProcessor.correctBusinessTerms('livre ça à café tout');
      expect(r.text, contains('Cafétou'));
      expect(r.exactCorrections, isNotEmpty);
      expect(r.fuzzyMatches, isEmpty);
    });

    test('"ekbin" → "E-Kbine" (exemple explicite du prompt)', () {
      final r = VoiceTextProcessor.correctBusinessTerms('je veux commander un ekbin');
      expect(r.text, contains('E-Kbine'));
    });

    test('"e kbine" (variante avec espace) → "E-Kbine"', () {
      final r = VoiceTextProcessor.correctBusinessTerms('appelle un e kbine');
      expect(r.text, contains('E-Kbine'));
    });

    test('"jasa"/"jassa" → "Djassa" (nom réel du module Marketplace)', () {
      expect(VoiceTextProcessor.correctBusinessTerms('cherche sur jasa').text,
          contains('Djassa'));
      expect(VoiceTextProcessor.correctBusinessTerms('cherche sur jassa').text,
          contains('Djassa'));
    });

    test('"aben gourou" → "Abengourou"', () {
      expect(VoiceTextProcessor.correctBusinessTerms('je suis à aben gourou').text,
          contains('Abengourou'));
    });

    test('"ouave" → "Wave", "oranje money" → "Orange Money"', () {
      expect(VoiceTextProcessor.correctBusinessTerms('paye avec ouave').text,
          contains('Wave'));
      expect(VoiceTextProcessor.correctBusinessTerms('paye avec oranje money').text,
          contains('Orange Money'));
    });

    test('ne modifie jamais un texte qui ne contient aucun terme connu', () {
      const phrase = 'quel temps fait-il aujourd\'hui';
      final r = VoiceTextProcessor.correctBusinessTerms(phrase);
      expect(r.text, phrase);
      expect(r.exactCorrections, isEmpty);
      expect(r.fuzzyMatches, isEmpty);
    });
  });

  group('VoiceTextProcessor.correctBusinessTerms — corrections floues (Partie 9)', () {
    test('une variante proche mais jamais listée déclenche une correction FLOUE, pas silencieuse', () {
      // "Pokoukro" mal transcrit en "Poukoukro" (inversion) — à distance 1,
      // jamais explicitement listé dans le dictionnaire de corrections
      // exactes : doit remonter en fuzzyMatches, pas être appliqué tout seul.
      final r = VoiceTextProcessor.correctBusinessTerms('livraison à poukokro');
      expect(r.fuzzyMatches, isNotEmpty);
    });

    test('un terme déjà exactement correct ne déclenche aucune correction floue', () {
      final r = VoiceTextProcessor.correctBusinessTerms('livraison à Cafétou');
      expect(r.fuzzyMatches, isEmpty);
      expect(r.exactCorrections, isEmpty);
    });

    test('les mots courts (<4 caractères) ne déclenchent jamais de correction floue (trop de faux positifs)', () {
      final r = VoiceTextProcessor.correctBusinessTerms('je vais au taxi');
      expect(r.fuzzyMatches, isEmpty);
    });
  });

  group('VoiceTextProcessor.process — pipeline complet, phrases réalistes par module (Partie 12)', () {
    final cases = <String, List<String>>{
      'Livraison': [
        'envoie un colis chez ma soeur à café tout',
        'je veux un livreur pour aller au plateau',
        'où est mon livreur',
      ],
      'Courses': [
        'va acheter deux sacs de riz et trois bouteilles d eau',
        'ajoute aussi du sucre',
      ],
      'Wallet': [
        'recharge mon wallet avec ouave',
        'quel est le solde de mon wallet',
        'paye avec oranje money',
      ],
      'Immobilier': [
        'je veux une maison à louer à baoule kro',
        'trouve moi un studio meuble',
      ],
      'Pharmacie': [
        'trouve une pharmacie ouverte à aben gourou',
        'commande des medicaments à la pharmacie',
      ],
      'Restaurant': [
        'commande un poulet braise',
        'trouve un restaurant ouvert au chateau',
      ],
      'Taxi / E-Kbine': [
        'appelle un ekbin pour aller au commerce',
        'je veux un e kbine maintenant',
      ],
      'AZ IA / général': [
        'bonjour az ia comment vas tu',
        'quel temps fait il aujourd hui',
      ],
    };

    for (final entry in cases.entries) {
      for (final phrase in entry.value) {
        test('${entry.key} — "$phrase" ne plante jamais et retourne un texte non vide', () {
          final r = VoiceTextProcessor.process(phrase);
          expect(r.text, isNotEmpty);
        });
      }
    }

    test('la pile complète (clean + correction) transforme un cas combiné réaliste', () {
      final r = VoiceTextProcessor.process('euh je je veux euh un ekbin pour aller à café tout');
      expect(r.text, contains('E-Kbine'));
      expect(r.text, contains('Cafétou'));
      expect(r.text, isNot(contains('euh')));
      expect(r.text, isNot(contains('je je')));
    });
  });
}
