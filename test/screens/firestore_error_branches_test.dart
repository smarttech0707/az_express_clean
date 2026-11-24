import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Garde-fou structurel : les écrans listés ci-dessous alimentent une liste
/// depuis Firestore. Sans branche `hasError`, un flux en échec (index
/// composite manquant, permissions, réseau) retombe sur `snap.data ?? []`
/// et s'affiche comme une liste VIDE — indiscernable d'une absence réelle de
/// données, ce qui a déjà causé plusieurs incidents en production.
///
/// Un test d'émulateur ne peut pas couvrir ce défaut (l'émulateur crée les
/// index à la volée et ne reproduit donc pas l'échec), et un test de widget
/// complet exigerait de simuler Firestore, absent des dépendances de ce
/// projet. Ce contrôle sur les sources échouera dès que quelqu'un retirera
/// une de ces branches — c'est précisément la régression à empêcher.
void main() {
  /// Fichier -> nombre minimum de branches `hasError` attendues.
  const guarded = <String, int>{
    'lib/screens/seller/seller_dashboard.dart': 3,
    'lib/screens/restaurant/restaurant_owner_dashboard.dart': 2,
    'lib/screens/client/boulangerie_order_page.dart': 1,
    'lib/screens/client/boulangeries_list.dart': 1,
    'lib/screens/admin/admin_services_page.dart': 1,
    'lib/screens/admin/admin_simple_services_page.dart': 1,
    'lib/screens/client/service_providers_page.dart': 2,
  };

  guarded.forEach((path, expected) {
    test('$path conserve ses branches hasError', () {
      final file = File(path);
      expect(file.existsSync(), isTrue, reason: '$path introuvable');
      final source = file.readAsStringSync();
      final count = RegExp(r'\.hasError').allMatches(source).length;
      expect(count, greaterThanOrEqualTo(expected),
          reason: '$path : $count branche(s) hasError trouvée(s), '
              '$expected attendue(s). Un flux Firestore en échec y serait '
              'à nouveau présenté comme une liste vide.');
    });
  });

  test('les branches d\'erreur n\'exposent aucun détail technique Firebase',
      () {
    // Un message affiché à l'utilisateur ne doit pas fuiter un code interne.
    // Les lignes `import` sont exclues : `cloud_firestore` y est légitime et
    // n'est jamais rendu à l'écran.
    const forbidden = [
      'FAILED_PRECONDITION',
      'PERMISSION_DENIED',
      'requires an index',
      r'${snap.error}',
      r'${snapshot.error}',
    ];
    for (final path in guarded.keys) {
      final source = File(path)
          .readAsLinesSync()
          .where((line) => !line.trimLeft().startsWith('import '))
          .join('\n');
      for (final token in forbidden) {
        expect(source.contains(token), isFalse,
            reason: '$path expose « $token » à l\'utilisateur');
      }
    }
  });
}
