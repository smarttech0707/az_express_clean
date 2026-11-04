import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:az_express/services/min_version_service.dart';
import 'package:az_express/widgets/min_version_dialog.dart';

// Mission 7E-4 — version minimale des rôles restaurateur et client : désactivée par défaut, rappel sans enforce,
// blocage seulement avec enforce:true ; le rôle livreur n'est pas touché.

typedef VersionResult = ({MinVersionStatus status, String? message});

Future<void> pumpWith(WidgetTester tester, Future<VersionResult> Function(String) check,
    {String role = 'restaurant'}) async {
  await tester.pumpWidget(MaterialApp(
    home: Builder(
      builder: (context) => Scaffold(
        body: TextButton(
          onPressed: () => showMinVersionDialogIfNeeded(context, role,
              blockedMessage: 'Installez la dernière version.', check: check),
          child: const Text('go'),
        ),
      ),
    ),
  ));
  await tester.tap(find.text('go'));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('sans configuration (ok) : aucune invite', (tester) async {
    String? asked;
    await pumpWith(tester, (r) async {
      asked = r;
      return (status: MinVersionStatus.ok, message: null);
    });
    expect(asked, 'restaurant');
    expect(find.byType(AlertDialog), findsNothing);
  });

  testWidgets('version ancienne sans enforce : rappel avec « Plus tard »', (tester) async {
    await pumpWith(tester, (_) async => (status: MinVersionStatus.updateRecommended, message: null), role: 'client');
    expect(find.text('Mise à jour disponible'), findsOneWidget);
    expect(find.text('Une nouvelle version est disponible.'), findsOneWidget);
    await tester.tap(find.text('Plus tard'));
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsNothing);
  });

  testWidgets('enforce:true : invite bloquante, sans « Plus tard », message du rôle ou du serveur', (tester) async {
    await pumpWith(tester, (_) async => (status: MinVersionStatus.updateRequired, message: null));
    expect(find.text('Installez la dernière version.'), findsOneWidget);
    expect(find.text('Plus tard'), findsNothing);
    await tester.tapAt(const Offset(2, 2)); // hors de la boîte : ne ferme pas
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsOneWidget);
  });

  testWidgets('message serveur prioritaire', (tester) async {
    await pumpWith(tester, (_) async => (status: MinVersionStatus.updateRecommended, message: 'Version 1.0.10 requise'));
    expect(find.text('Version 1.0.10 requise'), findsOneWidget);
  });

  test('la décision reste celle de MinVersionService.evaluate pour les nouveaux rôles', () {
    expect(MinVersionService.evaluate(null, 11), MinVersionStatus.ok); // aucune entrée pour le rôle
    expect(MinVersionService.evaluate({'minBuild': 11}, 10), MinVersionStatus.updateRecommended);
    expect(MinVersionService.evaluate({'minBuild': 11, 'enforce': true}, 10), MinVersionStatus.updateRequired);
    expect(MinVersionService.evaluate({'minBuild': 11, 'enforce': true}, 0), MinVersionStatus.ok); // build inconnu
    expect(MinVersionService.evaluate({'minBuild': 11, 'enforce': true}, 11), MinVersionStatus.ok);
  });

  test('câblage : restaurateur et client appellent le contrôle ; livreur inchangé ; aucune écriture', () {
    final resto = File('lib/screens/restaurant/restaurant_owner_dashboard.dart').readAsStringSync();
    final client = File('lib/screens/client/client_dashboard.dart').readAsStringSync();
    final driver = File('lib/screens/driver/driver_dashboard.dart').readAsStringSync();
    expect(resto.contains('showMinVersionDialogIfNeeded(\n        context, minVersionRoleRestaurant') ||
        resto.contains('minVersionRoleRestaurant'), isTrue);
    expect(client.contains('minVersionRoleClient'), isTrue);
    expect(driver.contains("MinVersionService().check('driver')"), isTrue);
    final svc = File('lib/services/min_version_service.dart').readAsStringSync();
    final dlg = File('lib/widgets/min_version_dialog.dart').readAsStringSync();
    for (final forbidden in ['.set(', '.update(', '.delete(', 'httpsCallable']) {
      expect(svc.contains(forbidden) || dlg.contains(forbidden), isFalse, reason: forbidden);
    }
  });
}
