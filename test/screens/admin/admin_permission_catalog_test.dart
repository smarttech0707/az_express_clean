import 'package:flutter_test/flutter_test.dart';

import 'package:az_express/screens/admin/admin_permission_catalog.dart';
import 'package:az_express/screens/admin/admin_mfa_security.dart';

/// Parité du catalogue de permissions affiché dans l'interface de gestion
/// des employés (mobile `_kSections`, recopié en public dans
/// `admin_permission_catalog.dart`) avec la liste officielle
/// `adminPermissionKeys` (elle-même miroir de `PERMISSION_KEYS` côté
/// fonctions et de `adminPermissionsKnown` dans `firestore.rules`).
void main() {
  group('1. Aucune clé inventée, aucun doublon', () {
    test('toutes les clés du catalogue existent dans adminPermissionKeys',
        () {
      for (final entry in adminPermissionCatalog) {
        expect(adminPermissionKeys.contains(entry.$1), isTrue,
            reason: entry.$1);
      }
    });

    test('aucun doublon de clé dans le catalogue', () {
      final keys = adminPermissionCatalog.map((e) => e.$1).toList();
      expect(keys.toSet().length, keys.length);
    });

    test('aucun libellé vide', () {
      for (final entry in adminPermissionCatalog) {
        expect(entry.$2.trim(), isNotEmpty, reason: entry.$1);
      }
    });
  });

  group('2. auto_moto reste volontairement absent de l\'interface', () {
    test('le catalogue ne propose pas auto_moto (réservé au super-admin)',
        () {
      expect(adminPermissionCatalog.map((e) => e.$1).contains('auto_moto'),
          isFalse);
    });

    test('la seule différence avec adminPermissionKeys est auto_moto', () {
      final catalogKeys = adminPermissionCatalog.map((e) => e.$1).toSet();
      final missing = adminPermissionKeys.difference(catalogKeys);
      expect(missing, {'auto_moto'});
    });
  });

  group('3. adminPermissionLabel', () {
    test('retrouve le libellé d\'une clé connue', () {
      expect(adminPermissionLabel('livreurs'), 'Livreurs');
    });

    test('retombe sur la clé elle-même si inconnue (jamais d\'exception)',
        () {
      expect(adminPermissionLabel('clef_obsolete'), 'clef_obsolete');
    });
  });

  group('4. Catégories : partition exacte du catalogue, aucune clé perdue '
      'ou dupliquée', () {
    test('l\'union des catégories couvre exactement le catalogue', () {
      final fromCategories = <String>{
        for (final cat in adminPermissionCategories) ...cat.keys,
      };
      final fromCatalog = adminPermissionCatalog.map((e) => e.$1).toSet();
      expect(fromCategories, fromCatalog);
    });

    test('aucune clé n\'apparaît dans deux catégories à la fois', () {
      final seen = <String>{};
      for (final cat in adminPermissionCategories) {
        for (final key in cat.keys) {
          expect(seen.contains(key), isFalse,
              reason: '$key apparaît dans plusieurs catégories');
          seen.add(key);
        }
      }
    });

    test('aucune catégorie vide', () {
      for (final cat in adminPermissionCategories) {
        expect(cat.keys, isNotEmpty, reason: cat.label);
      }
    });
  });

  group('5. togglePermission', () {
    test('ajoute une clé absente', () {
      expect(togglePermission({}, 'livreurs'), {'livreurs'});
    });

    test('retire une clé déjà présente', () {
      expect(togglePermission({'livreurs', 'sos'}, 'livreurs'), {'sos'});
    });

    test('ne modifie jamais l\'ensemble reçu en entrée (immutabilité)', () {
      final original = {'livreurs'};
      togglePermission(original, 'sos');
      expect(original, {'livreurs'});
    });
  });

  group('6. Sélection globale', () {
    test('selectAllPermissions couvre exactement le catalogue', () {
      expect(selectAllPermissions(),
          adminPermissionCatalog.map((e) => e.$1).toSet());
    });

    test('deselectAllPermissions est vide', () {
      expect(deselectAllPermissions(), isEmpty);
    });

    test('la sélection globale ne contient jamais auto_moto', () {
      expect(selectAllPermissions().contains('auto_moto'), isFalse);
    });
  });

  group('7. Sélection par catégorie', () {
    final livraisons = adminPermissionCategories
        .firstWhere((c) => c.label == 'Livraisons et livreurs');

    test('sélectionne toute la catégorie si elle n\'est pas déjà complète',
        () {
      final result = toggleCategorySelection({}, livraisons);
      expect(result, livraisons.keys.toSet());
    });

    test('désélectionne toute la catégorie si elle est déjà complète', () {
      final full = livraisons.keys.toSet();
      expect(toggleCategorySelection(full, livraisons), isEmpty);
    });

    test('une sélection partielle devient une sélection complète (jamais '
        'un état partiel après l\'action)', () {
      final partial = {livraisons.keys.first};
      final result = toggleCategorySelection(partial, livraisons);
      expect(result, livraisons.keys.toSet());
    });

    test('ne touche pas aux permissions des autres catégories', () {
      final other = adminPermissionCategories
          .firstWhere((c) => c.label == 'E-Kbine')
          .keys
          .toSet();
      final result = toggleCategorySelection(other, livraisons);
      expect(result, {...other, ...livraisons.keys});
    });
  });

  group('8. summarizeSelectedPermissions', () {
    test('aucune sélection', () {
      expect(summarizeSelectedPermissions({}), 'Aucune permission sélectionnée');
    });

    test('regroupe par catégorie avec un compte par catégorie', () {
      final summary =
          summarizeSelectedPermissions({'livreurs', 'commandes', 'carte'});
      expect(summary, contains('Livraisons et livreurs (1)'));
      expect(summary, contains('Commandes (2)'));
    });

    test('une catégorie sans aucune permission sélectionnée n\'apparaît pas',
        () {
      final summary = summarizeSelectedPermissions({'livreurs'});
      expect(summary, isNot(contains('E-Kbine')));
    });
  });
}
