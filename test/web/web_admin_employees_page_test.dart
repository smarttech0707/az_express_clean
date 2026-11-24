import 'package:flutter_test/flutter_test.dart';

import 'package:az_express/web/pages/admin/web_admin_employees_page.dart';

/// Phase 2 — Bureau Web : gestion des employés/sous-administrateurs.
///
/// Tests purs sur `filterEmployees` (recherche + filtre par permission),
/// sans Firebase ni montage de widget — même approche que
/// `filterAndSortArtisans` (web_artisans_page.dart).
void main() {
  final employees = [
    {
      'name': 'Awa Koné',
      'email': 'awa@example.com',
      'permissions': ['livreurs', 'commandes'],
    },
    {
      'name': 'Jean Bamba',
      'email': 'jean.bamba@example.com',
      'permissions': ['support'],
    },
    {
      'name': 'Fatou Diallo',
      'email': 'fatou@example.com',
      'permissions': ['livreurs', 'support'],
    },
  ];

  group('1. Recherche par nom ou email', () {
    test('sans filtre, tous les employés sont retournés', () {
      expect(filterEmployees(employees).length, 3);
    });

    test('filtre par nom, insensible à la casse', () {
      final result = filterEmployees(employees, query: 'AWA');
      expect(result.map((e) => e['name']), ['Awa Koné']);
    });

    test('filtre par email', () {
      final result = filterEmployees(employees, query: 'jean.bamba');
      expect(result.map((e) => e['name']), ['Jean Bamba']);
    });

    test('aucune correspondance renvoie une liste vide, jamais une exception',
        () {
      expect(filterEmployees(employees, query: 'inexistant'), isEmpty);
    });
  });

  group('2. Filtre par permission', () {
    test('ne garde que les employés portant la permission choisie', () {
      final result = filterEmployees(employees, permission: 'support');
      expect(result.map((e) => e['name']), ['Jean Bamba', 'Fatou Diallo']);
    });

    test('permission null = aucun filtre de permission', () {
      expect(filterEmployees(employees, permission: null).length, 3);
    });
  });

  group('3. Recherche et permission combinées', () {
    test('les deux filtres s\'appliquent ensemble (ET logique)', () {
      final result =
          filterEmployees(employees, query: 'fatou', permission: 'support');
      expect(result.map((e) => e['name']), ['Fatou Diallo']);
    });

    test('un employé sans la permission est exclu même si le nom correspond',
        () {
      final result =
          filterEmployees(employees, query: 'awa', permission: 'support');
      expect(result, isEmpty);
    });
  });

  group('4. Robustesse', () {
    test('une liste vide ne lève jamais d\'exception', () {
      expect(filterEmployees(const []), isEmpty);
    });

    test('un employé sans champ "permissions" est traité comme sans aucune',
        () {
      final result = filterEmployees(
        [
          {'name': 'Sans Permissions', 'email': 'x@example.com'},
        ],
        permission: 'support',
      );
      expect(result, isEmpty);
    });
  });
}
