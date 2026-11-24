import 'package:flutter_test/flutter_test.dart';

import 'package:az_express/screens/admin/admin_disputes_page.dart';
import 'package:az_express/screens/admin/admin_menu.dart';
import 'package:az_express/screens/admin/admin_stuck_alerts_page.dart';

// Rattachement préparé, désactivé par défaut (kShowOrderDisputeScreens) tant que les Cloud Functions
// adminOrderDisputeCF / adminConfirmDeliveryCF ne sont pas déployées et vérifiées.
Set<String> _ids(List<AdminMenuCategory> menu) =>
    {for (final c in menu) for (final i in c.items) i.id};

void main() {
  test('désactivé par défaut : aucune entrée litiges / commandes bloquées', () {
    expect(kShowOrderDisputeScreens, isFalse);
    final ids = _ids(buildAdminMenu(isSuper: true, permissions: const []));
    expect(ids, isNot(contains('disputes')));
    expect(ids, isNot(contains('stuck_alerts')));
  });

  test('activé : super-admin et sous-admin « commandes » les voient, les autres non', () {
    final superIds = _ids(buildAdminMenu(
        isSuper: true, permissions: const [], showOrderDisputes: true));
    expect(superIds, containsAll(['disputes', 'stuck_alerts']));

    final subIds = _ids(buildAdminMenu(
        isSuper: false, permissions: const ['commandes'], showOrderDisputes: true));
    expect(subIds, containsAll(['disputes', 'stuck_alerts']));

    final noPerm = _ids(buildAdminMenu(
        isSuper: false, permissions: const ['restaurants'], showOrderDisputes: true));
    expect(noPerm, isNot(contains('disputes')));
    expect(noPerm, isNot(contains('stuck_alerts')));
  });

  test('activé : les entrées ouvrent les bons écrans', () {
    final items = {
      for (final c in buildAdminMenu(
          isSuper: true, permissions: const [], showOrderDisputes: true))
        for (final i in c.items) i.id: i.page()
    };
    expect(items['disputes'], isA<AdminDisputesPage>());
    expect(items['stuck_alerts'], isA<AdminStuckAlertsPage>());
  });
}
