import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

// Contrôle statique M2 : chaque tableau de bord de rôle mobile appelle la version minimale. Un nouveau tableau de bord
// doit soit appeler `showMinVersionDialogIfNeeded`, soit être listé ici avec la raison de l'exclusion.
void main() {
  const covered = {
    'lib/screens/driver/driver_dashboard.dart': 'minVersionRoleDriver',
    'lib/screens/client/client_dashboard.dart': 'minVersionRoleClient',
    'lib/screens/restaurant/restaurant_owner_dashboard.dart': 'minVersionRoleRestaurant',
    'lib/screens/seller/seller_dashboard.dart': 'minVersionRoleSeller',
    'lib/screens/boulangerie/boulangerie_dashboard.dart': 'minVersionRoleBoulangerie',
    'lib/screens/pharmacie/pharmacie_dashboard.dart': 'minVersionRolePharmacie',
    'lib/screens/artisan/artisan_dashboard.dart': 'minVersionRoleArtisan',
    'lib/screens/fleet/fleet_dashboard.dart': 'minVersionRoleFleet',
    'lib/screens/immobilier/agent_dashboard_screen.dart': 'minVersionRoleImmobilier',
    'lib/ekbine/screens/ek_agent_dashboard.dart': 'minVersionRoleEkbine',
    'lib/screens/admin/admin_dashboard.dart': 'minVersionRoleAdmin',
  };

  // Exclus volontairement (non couverts à ce stade, voir docs/ACCOUNT_DELETION_M2_MIN_VERSION.md).
  const excluded = {
    'lib/screens/admin/admin_ai_dashboard.dart': 'sous-écran admin, atteint uniquement via AdminDashboard (admin_menu.dart)',
    'lib/screens/admin/admin_security_dashboard.dart': 'sous-écran admin, atteint uniquement via AdminDashboard (admin_menu.dart)',
    'lib/web/pages/admin/web_admin_dashboard.dart': 'web : se met à jour au déploiement, build 0 = jamais bloqué',
    'lib/web/pages/client/web_client_dashboard.dart': 'web : se met à jour au déploiement, build 0 = jamais bloqué',
    'lib/screens/main_dashboard.dart': 'conteneur de navigation du client (couvert via client_dashboard)',
  };

  test('chaque rôle couvert appelle showMinVersionDialogIfNeeded avec sa constante', () {
    covered.forEach((path, constant) {
      final src = File(path).readAsStringSync();
      expect(src.contains('showMinVersionDialogIfNeeded'), isTrue, reason: path);
      expect(src.contains(constant), isTrue, reason: '$path → $constant');
    });
  });

  test('les constantes de rôle sont uniques et définies', () {
    final dlg = File('lib/widgets/min_version_dialog.dart').readAsStringSync();
    final values = RegExp(r"const minVersionRole\w+ = '(\w+)';").allMatches(dlg).map((m) => m.group(1)).toList();
    expect(values.toSet().length, values.length);
    for (final c in covered.values) {
      expect(dlg.contains('const $c ='), isTrue, reason: c);
    }
  });

  test('aucun nouveau tableau de bord *_dashboard.dart ne passe inaperçu', () {
    final found = Directory('lib')
        .listSync(recursive: true)
        .whereType<File>()
        .map((f) => f.path.replaceAll('\\', '/'))
        .where((p) => p.endsWith('_dashboard.dart') || p.endsWith('agent_dashboard_screen.dart'))
        .toSet();
    final known = {...covered.keys, ...excluded.keys};
    expect(found.difference(known), isEmpty, reason: 'tableaux de bord ni couverts ni exclus');
  });
}
