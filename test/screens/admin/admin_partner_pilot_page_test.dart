import 'dart:async';
import 'dart:io';

import 'package:cloud_functions/cloud_functions.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:az_express/screens/admin/admin_menu.dart';
import 'package:az_express/screens/admin/admin_partner_pilot_page.dart';
import 'package:az_express/services/partner_orders_config_service.dart';
import 'package:az_express/widgets/app_button.dart';

// Mission 7E-2 — outil de pilotage du pilote Restaurant/Boulangerie v2. Chaque changement passe par l'action serveur
// setPartnerOrdersConfig ; l'écran n'affiche jamais un état supposé (seul le document relu fait foi).

class Call {
  final int expectedVersion;
  final Map<String, dynamic> patch;
  final String reason;
  Call(this.expectedVersion, this.patch, this.reason);
}

PilotConfigRunner recorder(List<Call> calls, {Future<void> Function()? result}) =>
    ({required expectedVersion, required patch, required reason}) async {
      calls.add(Call(expectedVersion, patch, reason));
      if (result != null) await result();
      return PartnerOrdersConfig.fromDoc({...patch, 'version': expectedVersion + 1});
    };

Map<String, dynamic> doc({
  List<String> pilots = const [],
  bool open = false,
  bool frozen = false,
  int version = 3,
}) =>
    {
      'pilotPartnerIds': pilots,
      'creationOpen': open,
      'managementFrozen': frozen,
      'version': version,
      'updatedAtMs': 1700000000000,
      'lastChange': {'reason': 'Préparation du pilote'},
    };

Finder button(String label) => find.widgetWithText(AppButton, label);

Future<void> pump(WidgetTester tester, Stream<Map<String, dynamic>?> source, PilotConfigRunner runner) async {
  tester.view.physicalSize = const Size(900, 3000);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(MaterialApp(home: AdminPartnerPilotPage(source: () => source, runner: runner)));
  await tester.pump();
}

Future<void> confirmWith(WidgetTester tester, String reason, {bool settle = true}) async {
  await tester.enterText(find.byType(TextField).last, reason);
  await tester.tap(find.widgetWithText(ElevatedButton, 'Confirmer'));
  // Un appel en cours affiche un indicateur animé : pas de pumpAndSettle tant qu'il n'est pas terminé.
  if (settle) {
    await tester.pumpAndSettle();
  } else {
    await tester.pump(const Duration(milliseconds: 300));
  }
}

void main() {
  tearDown(() => PartnerOrdersConfigService.callFunction = (n, d) async => {});

  group('état initial : tout est fermé, rien ne s\'ouvre seul', () {
    testWidgets('document absent : création fermée, aucun gel, aucun pilote, version 0, aucun appel', (tester) async {
      final calls = <Call>[];
      await pump(tester, Stream.value(null), recorder(calls));
      expect(find.text('FERMÉE'), findsOneWidget);
      expect(find.text('Aucun gel'), findsOneWidget);
      expect(find.byKey(const ValueKey('no-pilots')), findsOneWidget);
      expect(find.textContaining('Version 0'), findsOneWidget);
      expect(find.textContaining('rien ne s’ouvre automatiquement'), findsOneWidget);
      expect(calls, isEmpty);
    });

    test('lecture prudente : seul le booléen true ouvre ou gèle ; valeurs invalides ignorées', () {
      final c = PartnerOrdersConfig.fromDoc({
        'creationOpen': 'true',
        'managementFrozen': 1,
        'version': -2,
        'pilotPartnerIds': ['ok_1', 'a/b', 42, ''],
      });
      expect([c.creationOpen, c.managementFrozen, c.version], [false, false, 0]);
      expect(c.pilotPartnerIds, ['ok_1']);
      expect(PartnerOrdersConfig.fromDoc(null).creationOpen, isFalse);
      expect(PartnerOrdersConfig.fromDoc({'creationOpen': true}).creationOpen, isTrue);
    });
  });

  group('ouverture, fermeture, gel', () {
    testWidgets('ouvrir la création : justification exigée, version affichée envoyée, aucun changement optimiste', (tester) async {
      final calls = <Call>[];
      final stream = StreamController<Map<String, dynamic>?>();
      addTearDown(stream.close);
      await pump(tester, stream.stream, recorder(calls));
      stream.add(doc(pilots: ['resto1']));
      await tester.pumpAndSettle();
      await tester.tap(button('Ouvrir la création'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField).last, 'court');
      await tester.tap(find.widgetWithText(ElevatedButton, 'Confirmer'));
      await tester.pumpAndSettle();
      expect(find.text('Justification de 10 à 300 caractères.'), findsOneWidget);
      expect(calls, isEmpty);
      await confirmWith(tester, 'Ouverture du pilote pour le premier restaurant');
      expect(calls.single.expectedVersion, 3);
      expect(calls.single.patch, {'creationOpen': true});
      expect(calls.single.reason, 'Ouverture du pilote pour le premier restaurant');
      // Le serveur a répondu, mais l'état affiché vient du document relu : toujours FERMÉE tant que le flux n'a pas changé.
      expect(find.text('FERMÉE'), findsOneWidget);
      stream.add(doc(pilots: ['resto1'], open: true, version: 4));
      await tester.pumpAndSettle();
      expect(find.text('OUVERTE'), findsOneWidget);
    });

    testWidgets('fermer la création : justification d\'urgence préremplie, patch creationOpen=false', (tester) async {
      final calls = <Call>[];
      await pump(tester, Stream.value(doc(pilots: ['resto1'], open: true)), recorder(calls));
      await tester.pumpAndSettle();
      expect(find.text('OUVERTE'), findsOneWidget);
      await tester.tap(button('Fermer la création'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(ElevatedButton, 'Confirmer')); // motif prérempli, modifiable
      await tester.pumpAndSettle();
      expect(calls.single.patch, {'creationOpen': false});
      expect(calls.single.reason, 'Fermeture du pilote');
    });

    testWidgets('gel d\'urgence : activation puis levée', (tester) async {
      final calls = <Call>[];
      final stream = StreamController<Map<String, dynamic>?>();
      addTearDown(stream.close);
      await pump(tester, stream.stream, recorder(calls));
      stream.add(doc());
      await tester.pumpAndSettle();
      await tester.tap(button('Activer le gel d’urgence'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(ElevatedButton, 'Confirmer'));
      await tester.pumpAndSettle();
      expect(calls.single.patch, {'managementFrozen': true});
      expect(find.text('Aucun gel'), findsOneWidget); // pas de changement optimiste
      stream.add(doc(frozen: true, version: 4));
      await tester.pumpAndSettle();
      expect(find.text('GEL ACTIF'), findsOneWidget);
      await tester.tap(button('Lever le gel'));
      await tester.pumpAndSettle();
      await confirmWith(tester, 'Incident traité, reprise de la gestion');
      expect(calls.last.patch, {'managementFrozen': false});
      expect(calls.last.expectedVersion, 4);
    });

    testWidgets('ajout et retrait de restaurants pilotes : liste complète envoyée, identifiants contrôlés', (tester) async {
      final calls = <Call>[];
      await pump(tester, Stream.value(doc(pilots: ['aaa'])), recorder(calls));
      await tester.pumpAndSettle();
      for (final bad in ['a/b', '', 'aaa']) {
        await tester.enterText(find.byType(TextField), bad);
        await tester.tap(button('Ajouter ce restaurant'));
        await tester.pumpAndSettle();
        expect(find.byType(AlertDialog), findsNothing, reason: bad);
      }
      expect(calls, isEmpty);
      await tester.enterText(find.byType(TextField), '  resto_2 ');
      await tester.tap(button('Ajouter ce restaurant'));
      await tester.pumpAndSettle();
      await confirmWith(tester, 'Ajout du deuxième restaurant pilote');
      expect(calls.single.patch, {'pilotPartnerIds': ['aaa', 'resto_2']});
      await tester.tap(find.widgetWithText(TextButton, 'Retirer'));
      await tester.pumpAndSettle();
      await confirmWith(tester, 'Retrait du restaurant pilote');
      expect(calls.last.patch, {'pilotPartnerIds': <String>[]});
    });
  });

  group('erreurs et verrous', () {
    Future<void> openOnce(WidgetTester tester, PilotConfigRunner runner) async {
      await pump(tester, Stream.value(doc()), runner);
      await tester.pumpAndSettle();
      await tester.tap(button('Ouvrir la création'));
      await tester.pumpAndSettle();
      await confirmWith(tester, 'Ouverture du pilote pour test');
    }

    testWidgets('conflit de version : message clair, rien d\'annoncé', (tester) async {
      await openOnce(tester, ({required expectedVersion, required patch, required reason}) async {
        throw const PartnerOrdersConfigException('CONFIG_CONFLICT', 'serveur');
      });
      expect(find.textContaining('a changé entre-temps'), findsOneWidget);
      expect(find.textContaining('Configuration enregistrée'), findsNothing);
    });

    testWidgets('utilisateur non super-administrateur : refus serveur affiché', (tester) async {
      await openOnce(tester, ({required expectedVersion, required patch, required reason}) async {
        throw const PartnerOrdersConfigException('permission-denied', '');
      });
      expect(find.text('Réservé à l’administrateur principal.'), findsOneWidget);
      expect(find.text('FERMÉE'), findsOneWidget);
    });

    testWidgets('erreur réseau : modification non confirmée, aucun succès annoncé', (tester) async {
      await openOnce(tester, ({required expectedVersion, required patch, required reason}) async {
        throw const PartnerOrdersConfigException('NETWORK', '', retryable: true);
      });
      expect(find.textContaining('Connexion instable'), findsOneWidget);
      expect(find.textContaining('Configuration enregistrée'), findsNothing);
    });

    testWidgets('double appui : une seule requête pendant que la première est en cours', (tester) async {
      final calls = <Call>[];
      final gate = Completer<void>();
      await pump(tester, Stream.value(doc()), recorder(calls, result: () => gate.future));
      await tester.pumpAndSettle();
      await tester.tap(button('Ouvrir la création'));
      await tester.pumpAndSettle();
      await confirmWith(tester, 'Ouverture du pilote pour test', settle: false);
      expect(calls.length, 1);
      // Pendant l'appel, les boutons sont désactivés.
      final buttons = tester.widgetList<AppButton>(find.byType(AppButton));
      expect(buttons, isNotEmpty);
      expect(buttons.every((b) => b.onPressed == null), isTrue);
      gate.complete();
      await tester.pumpAndSettle();
      expect(calls.length, 1);
    });
  });

  group('contrat du service et sécurité', () {
    test('appelle partnerOrderActionCF/setPartnerOrdersConfig avec patch, version et justification rognée', () async {
      final sent = <Map<String, dynamic>>[];
      PartnerOrdersConfigService.callFunction = (n, d) async {
        expect(n, 'partnerOrderActionCF');
        sent.add({...d});
        return {
          'success': true,
          'message': 'Configuration mise à jour',
          'data': {
            'config': {'pilotPartnerIds': ['r1'], 'creationOpen': true, 'managementFrozen': false, 'version': 4},
          },
        };
      };
      final c = await PartnerOrdersConfigService.update(
          expectedVersion: 3, patch: {'creationOpen': true}, reason: '  Ouverture du pilote  ');
      expect(sent.single, {
        'action': 'setPartnerOrdersConfig',
        'patch': {'creationOpen': true},
        'expectedVersion': 3,
        'reason': 'Ouverture du pilote',
      });
      expect([c.version, c.creationOpen], [4, true]);
      expect(c.pilotPartnerIds, ['r1']);
    });

    test('refus serveur et erreurs de réseau convertis', () async {
      Future<PartnerOrdersConfigException> failWith(Object Function() make, {Map<String, dynamic>? envelope}) async {
        PartnerOrdersConfigService.callFunction = (n, d) async {
          if (envelope != null) return envelope;
          throw make();
        };
        try {
          await PartnerOrdersConfigService.update(expectedVersion: 0, patch: {'creationOpen': true}, reason: 'Ouverture du pilote');
        } on PartnerOrdersConfigException catch (e) {
          return e;
        }
        fail('une exception était attendue');
      }

      final conflict = await failWith(() => 0, envelope: {'success': false, 'code': 'CONFIG_CONFLICT', 'message': 'x'});
      expect(conflict.code, 'CONFIG_CONFLICT');
      final invalid = await failWith(() => 0, envelope: {'success': false, 'code': 'INVALID_CONFIG', 'message': 'Liste de partenaires pilotes invalide'});
      expect(invalid.userMessage, 'Liste de partenaires pilotes invalide');
      final denied = await failWith(() => FirebaseFunctionsException(code: 'permission-denied', message: 'Réservé'));
      expect(denied.code, 'permission-denied');
      final net = await failWith(() => FirebaseFunctionsException(code: 'unavailable', message: ''));
      expect((net.code, net.retryable), ('NETWORK', true));
      final lost = await failWith(() => StateError('coupure'));
      expect(lost.retryable, isTrue);
    });

    test('aucune écriture Firestore directe dans l\'écran ni le service ; lecture seule du document', () {
      for (final f in ['lib/screens/admin/admin_partner_pilot_page.dart', 'lib/services/partner_orders_config_service.dart']) {
        final src = File(f).readAsStringSync();
        for (final forbidden in ['.set(', '.delete(', 'runTransaction', 'WriteBatch', "'wallet'", 'wallet:']) {
          expect(src.contains(forbidden), isFalse, reason: '$f ne doit pas contenir $forbidden');
        }
        // Aucun .update() sur un document Firestore (l'appel PartnerOrdersConfigService.update passe par la Cloud Function).
        expect(RegExp(r'\.doc\([^)]*\)\s*\.(set|update|delete)\(').hasMatch(src), isFalse, reason: f);
        expect(src.contains('cloud_firestore') && f.contains('services'), isFalse);
      }
      final page = File('lib/screens/admin/admin_partner_pilot_page.dart').readAsStringSync();
      expect(page.contains('.snapshots()'), isTrue);
      expect(page.contains("'partnerOrdersV2'"), isTrue); // lecture du seul document de configuration
    });

    test('menu : les deux outils sont réservés au super-administrateur', () {
      Set<String> ids(bool isSuper, List<String> perms) =>
          {for (final c in buildAdminMenu(isSuper: isSuper, permissions: perms)) for (final i in c.items) i.id};
      expect(ids(true, const []), containsAll(['partner_pilot', 'cash_reviews']));
      final sub = ids(false, const ['commandes', 'cash_marchand', 'recharges', 'gains', 'restaurants']);
      expect(sub, isNot(contains('partner_pilot')));
      expect(sub, isNot(contains('cash_reviews')));
    });
  });
}
