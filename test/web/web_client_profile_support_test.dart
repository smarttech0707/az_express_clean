import 'package:flutter_test/flutter_test.dart';

import 'package:az_express/web/pages/client/web_client_dashboard.dart';
import 'package:az_express/web/web_router.dart';
import 'package:az_express/services/auth_service.dart';
import 'package:az_express/screens/support/support_screen.dart'
    show buildSupportTicketData;
import 'package:az_express/ekbine/ek_constants.dart' show ekStatusLabels;

/// Phase 2 — Profil client, Support, Historique (espace client Web).
///
/// Comme pour `web_delivery_page_test.dart` et `admin_auth_service_test.dart`,
/// on teste ici la logique PURE (statuts, validations, forme des documents)
/// sans Firebase : les écrans qui écrivent directement dans Firestore
/// (`_ProfileTab`, `_OrdersTab`, `WebClientSupportTab`) suivent exactement le
/// même schéma que leurs équivalents mobiles (`profil_client.dart`,
/// `suivi_commande.dart`, `support_screen.dart`), qui n'ont eux-mêmes aucun
/// test unitaire sur leurs écritures Firestore — les tester nécessiterait une
/// dépendance supplémentaire (fake Firestore) non présente dans ce projet.
/// Ces parcours doivent être vérifiés manuellement (voir rapport de phase).
void main() {
  group('1. Statuts de commandes : aucun statut inventé', () {
    test('toutes les clés de orderStatusLabels sont des statuts réels de orders', () {
      // Référence : CLAUDE.md — « pending → broadcast/assigned → accepted
      // → picked_up → delivered, ou cancelled ». Aucune clé ici ne doit
      // sortir de cet ensemble.
      const realStatuses = {
        'pending', 'broadcast', 'assigned', 'accepted', 'picked_up',
        'delivered', 'cancelled',
      };
      expect(orderStatusLabels.keys.toSet(), realStatuses);
    });

    test('un statut inconnu a une couleur de repli, jamais une exception', () {
      expect(() => orderStatusColor('statut_inexistant'), returnsNormally);
    });

    test('delivered et cancelled ont des couleurs distinctes', () {
      expect(orderStatusColor('delivered') == orderStatusColor('cancelled'),
          isFalse);
    });
  });

  group('2. Icône par type de commande', () {
    test('un type connu renvoie une icône dédiée, pas toujours la même', () {
      final restaurant = orderTypeIcon({'sellerType': 'restaurant'});
      final pharmacie = orderTypeIcon({'sellerType': 'pharmacie'});
      final livraison = orderTypeIcon({'type': 'livraison'});
      expect(restaurant, isNot(livraison));
      expect(pharmacie, isNot(livraison));
    });

    test('aucune donnée de type ne lève jamais d\'exception', () {
      expect(() => orderTypeIcon(<String, dynamic>{}), returnsNormally);
    });
  });

  group('3. Nouvelle section Support : câblage de navigation', () {
    test('/app/support est déclarée comme une SECTION, pas un service sans page',
        () {
      expect(clientSectionTabs.containsKey('/app/support'), isTrue);
      expect(clientServiceRoutes.contains('/app/support'), isFalse);
    });

    test('/app/support existe comme route déclarée (GoRoute)', () {
      expect(clientAppRoutes, contains('/app/support'));
    });

    test('clientPathForTab(4) renvoie bien /app/support', () {
      expect(clientPathForTab(4), '/app/support');
    });
  });

  group('4. Validation des champs du profil (réutilisation AuthService)', () {
    test('un mot de passe trop court est refusé avant tout appel réseau', () {
      expect(AuthService.validatePassword('123'), isNotNull);
    });

    test('un mot de passe valide (maj + chiffre + 8 car.) ne renvoie aucune erreur',
        () {
      expect(AuthService.validatePassword('Motdepasse123'), isNull);
    });

    test('un email sans @ est invalide', () {
      expect(AuthService.isValidEmail('pasdemail'), isFalse);
    });

    test('un email valide est accepté', () {
      expect(AuthService.isValidEmail('client@example.com'), isTrue);
    });

    test('isValidPhone rejette une chaîne vide', () {
      expect(AuthService.isValidPhone(''), isFalse);
    });
  });

  group('5. Forme du ticket de support créé depuis le Web', () {
    test(
        'buildSupportTicketData produit exactement le même document que côté mobile '
        '(status open, userId, premier message)', () {
      final data = buildSupportTicketData(
        userId: 'uid123',
        subject: 'Problème de livraison',
        message: 'Ma commande est en retard',
        category: 'Livraison',
        createdAt: 'TIMESTAMP_PLACEHOLDER',
      );
      expect(data['userId'], 'uid123');
      expect(data['status'], 'open',
          reason:
              'Les règles Firestore exigent status == open à la création (firestore.rules:1422)');
      expect(data['subject'], 'Problème de livraison');
      expect(data['category'], 'Livraison');
      expect(data['messages'], isA<List>());
      expect((data['messages'] as List).length, 1);
      expect((data['messages'] as List).first['sender'], 'user');
      expect(data['screenshotUrl'], isNull);
    });

    test('une capture d\'écran optionnelle est bien transmise si fournie', () {
      final data = buildSupportTicketData(
        userId: 'uid123',
        subject: 'Bug',
        message: 'Ça plante',
        category: 'Autre',
        createdAt: 'TIMESTAMP_PLACEHOLDER',
        screenshotUrl: 'https://example.com/shot.jpg',
      );
      expect(data['screenshotUrl'], 'https://example.com/shot.jpg');
    });
  });

  group('6. Statuts E-Kbine (historique) : réutilisation exacte, rien d\'inventé',
      () {
    test('les statuts E-Kbine affichés sur le Web viennent de ek_constants.dart',
        () {
      expect(ekStatusLabels['completed'], isNotNull);
      expect(ekStatusLabels['cancelled'], isNotNull);
      expect(ekStatusLabels['disputed'], isNotNull);
    });
  });
}
