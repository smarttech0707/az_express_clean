import 'package:flutter_test/flutter_test.dart';

import 'package:az_express/screens/admin/admin_pharmacie_requests_page.dart';

/// Approbation pharmacie — régression du 2026-10-05.
///
/// Le batch d'approbation écrivait `'password': data['password'] ?? ''` dans le
/// document `pharmacies`. `firestore.rules` rejette tout batch admin contenant
/// ne serait-ce que la CLÉ `password`/`accessCode`
/// (`!request.resource.data.keys().hasAny([...])`) — la valeur, toujours vide
/// ici, n'y changeait rien. Résultat : aucune pharmacie ne pouvait être
/// approuvée, et l'échec était TOTALEMENT muet (pas de try/catch, et
/// `onApprove: () => onApprove(...)` est un `VoidCallback` non attendu, donc
/// l'exception partait en erreur asynchrone non observée).
///
/// Ces tests portent sur les deux décisions pures extraites du widget : le
/// contenu du document écrit, et le message rendu à l'admin. Aucun Firestore,
/// aucun réseau. Le refus des clés interdites par les rules elles-mêmes est
/// verrouillé séparément dans `rules-tests/firestore.rules.test.js`.
void main() {
  const request = <String, dynamic>{
    'ownerName': 'Kone Awa',
    'pharmacieName': 'Pharmacie Gabriel',
    'phone': '0700000000',
    'address': 'Quartier Commerce, Abengourou',
    'lat': 6.7273,
    'lng': -3.4961,
    'status': 'pending',
  };

  Map<String, dynamic> build([Map<String, dynamic>? override]) =>
      buildApprovedPharmacieDoc(
        override ?? request,
        latitude: 6.7273,
        longitude: -3.4961,
        createdAt: 'SERVER_TIMESTAMP',
      );

  group('Document pharmacie créé à l\'approbation', () {
    test('aucune clé `password`, quelle que soit la demande', () {
      expect(build().containsKey('password'), isFalse);
      // Même si une demande en transportait une un jour (ce n'est pas le cas
      // aujourd'hui : pharmacie_register.dart n'envoie pas de mot de passe),
      // elle ne doit jamais être recopiée dans `pharmacies`.
      expect(
        build({...request, 'password': 'secret123'}).containsKey('password'),
        isFalse,
      );
      expect(
        build({...request, 'password': ''}).containsKey('password'),
        isFalse,
        reason: 'la clé vide suffisait à faire rejeter le batch',
      );
    });

    test('aucune clé `accessCode`, quelle que soit la demande', () {
      expect(build().containsKey('accessCode'), isFalse);
      expect(
        build({...request, 'accessCode': '1234'}).containsKey('accessCode'),
        isFalse,
      );
    });

    test('aucune autre clé que les champs légitimes attendus', () {
      // Verrou plus fort que les deux tests ci-dessus : toute clé ajoutée au
      // payload doit être un choix explicite, pas un effet de bord d'une
      // recopie de la demande.
      expect(
        build().keys.toSet(),
        {
          'name',
          'ownerName',
          'phone',
          'address',
          'lat',
          'lng',
          'isActive',
          'isOpen',
          'mustChangePassword',
          'createdAt',
        },
      );
    });

    test('les données légitimes de la demande sont conservées', () {
      final doc = build();
      expect(doc['name'], 'Pharmacie Gabriel');
      expect(doc['ownerName'], 'Kone Awa');
      expect(doc['phone'], '0700000000');
      expect(doc['address'], 'Quartier Commerce, Abengourou');
      expect(doc['lat'], 6.7273);
      expect(doc['lng'], -3.4961);
      expect(doc['isActive'], isTrue);
      expect(doc['isOpen'], isFalse);
      expect(doc['mustChangePassword'], isFalse);
      expect(doc['createdAt'], 'SERVER_TIMESTAMP');
    });

    test('coordonnées validées : jamais celles brutes de la demande', () {
      // `_approve` passe les coordonnées déjà validées par
      // PartnerLocationValidator, pas `data['lat']`/`data['lng']` bruts.
      final doc = buildApprovedPharmacieDoc(
        {...request, 'lat': 0, 'lng': 0},
        latitude: 7.1,
        longitude: -3.2,
        createdAt: 'SERVER_TIMESTAMP',
      );
      expect(doc['lat'], 7.1);
      expect(doc['lng'], -3.2);
    });

    test('demande incomplète : champs vides plutôt que null', () {
      final doc = buildApprovedPharmacieDoc(
        const {},
        latitude: 7.1,
        longitude: -3.2,
        createdAt: 'SERVER_TIMESTAMP',
      );
      expect(doc['name'], '');
      expect(doc['ownerName'], '');
      expect(doc['phone'], '');
      expect(doc['address'], '');
      expect(doc.containsKey('password'), isFalse);
      expect(doc.containsKey('accessCode'), isFalse);
    });
  });

  group('Message rendu à l\'admin', () {
    test('succès Firestore → message de succès', () {
      final feedback = pharmacieApprovalFeedback(
        error: null,
        pharmacieName: 'Pharmacie Gabriel',
      );
      expect(feedback.isSuccess, isTrue);
      expect(feedback.message, 'Pharmacie Gabriel approuvée !');
    });

    test('échec Firestore → JAMAIS un message de succès', () {
      for (final error in <Object>[
        Exception('permission-denied'),
        StateError('offline'),
        'erreur brute',
      ]) {
        final feedback = pharmacieApprovalFeedback(
          error: error,
          pharmacieName: 'Pharmacie Gabriel',
        );
        expect(feedback.isSuccess, isFalse, reason: 'échec $error');
        expect(feedback.message, isNot(contains('approuvée')));
        expect(feedback.message, contains('impossible'));
      }
    });

    test('le message d\'échec ne divulgue aucun détail technique', () {
      // Le détail part dans debugPrint, jamais à l'écran : un message
      // Firestore brut pourrait contenir un chemin de document ou une règle.
      final feedback = pharmacieApprovalFeedback(
        error: Exception(
            'PERMISSION_DENIED: pharmacies/abc123 password hasAny'),
        pharmacieName: 'Pharmacie Gabriel',
      );
      expect(feedback.message, isNot(contains('PERMISSION_DENIED')));
      expect(feedback.message, isNot(contains('pharmacies/')));
      expect(feedback.message, isNot(contains('password')));
    });

    test('nom manquant : message d\'échec inchangé, succès dégradé proprement',
        () {
      expect(
        pharmacieApprovalFeedback(error: null, pharmacieName: '').message,
        ' approuvée !',
        reason: '_approve passe un libellé de repli, voir l\'appelant',
      );
      expect(
        pharmacieApprovalFeedback(error: Exception('x'), pharmacieName: '')
            .isSuccess,
        isFalse,
      );
    });
  });
}
