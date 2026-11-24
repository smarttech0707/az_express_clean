import 'package:flutter_test/flutter_test.dart';
import 'package:az_express/web/web_client_auth.dart';

/// Connexion client Web — email OU numéro.
///
/// Verrouille la résolution d'identifiant, qui détermine l'identité Firebase
/// utilisée. Aucun réseau, aucun Firebase : `resolveLoginEmail` et
/// `technicalEmailForPhone` sont des fonctions pures.
void main() {
  group('Compatibilité des comptes EXISTANTS (connexion par numéro)', () {
    test('un numéro produit exactement l\'email technique historique', () {
      // Expression d'origine de register()/login() :
      // '${phone.replaceAll(' ', '')}@azexpress.ci'
      expect(WebClientAuth.resolveLoginEmail('0700000000'),
          '0700000000@azexpress.ci');
      expect(WebClientAuth.resolveLoginEmail('07 00 00 00 00'),
          '0700000000@azexpress.ci');
    });

    test('la normalisation reste limitée aux espaces — aucun compte perdu', () {
      // Un nettoyage plus agressif (tirets, points) calculerait un email
      // différent de celui des comptes déjà créés : ce test échouerait si
      // quelqu'un durcissait la normalisation sans migration.
      expect(WebClientAuth.resolveLoginEmail('07-00-00-00-00'),
          '07-00-00-00-00@azexpress.ci');
      expect(WebClientAuth.resolveLoginEmail('+225 07 00 00 00 00'),
          '+2250700000000@azexpress.ci');
    });

    test('register et login calculent le MÊME email pour un numéro', () {
      const phone = '07 11 22 33 44';
      expect(WebClientAuth.resolveLoginEmail(phone),
          WebClientAuth.technicalEmailForPhone(phone.trim()));
    });
  });

  group('Connexion par EMAIL réel (ce qui était impossible)', () {
    test('un email est utilisé tel quel, sans suffixe ajouté', () {
      // Avant le correctif : 'jean@gmail.com' devenait
      // 'jean@gmail.com@azexpress.ci' → compte introuvable.
      expect(WebClientAuth.resolveLoginEmail('jean@gmail.com'),
          'jean@gmail.com');
      expect(WebClientAuth.resolveLoginEmail('jean@gmail.com'),
          isNot(contains('@azexpress.ci')));
    });

    test('email normalisé : espaces autour et casse', () {
      expect(WebClientAuth.resolveLoginEmail('  Jean.Dupont@Gmail.COM  '),
          'jean.dupont@gmail.com');
    });

    test('un email technique déjà complet n\'est pas re-suffixé', () {
      expect(WebClientAuth.resolveLoginEmail('0700000000@azexpress.ci'),
          '0700000000@azexpress.ci');
      // Cas des comptes créés côté mobile (domaine technique différent) :
      // l'utilisateur peut les saisir directement, sans altération.
      expect(WebClientAuth.resolveLoginEmail('0700000000@azexpress.app'),
          '0700000000@azexpress.app');
    });
  });

  group('Le discriminant est la présence de « @ »', () {
    test('tout identifiant sans @ est traité comme un numéro', () {
      for (final input in ['0700000000', '2250700000000', '070000']) {
        expect(WebClientAuth.resolveLoginEmail(input),
            endsWith('@azexpress.ci'),
            reason: '$input ne contient pas @ : c\'est un numéro');
      }
    });

    test('tout identifiant avec @ est traité comme un email', () {
      for (final input in ['a@b.c', 'client@azexpress.ci']) {
        expect(WebClientAuth.resolveLoginEmail(input), input,
            reason: '$input contient @ : c\'est un email');
      }
    });
  });
}
