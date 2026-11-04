import 'dart:async';
import 'dart:io';

import 'package:cloud_functions/cloud_functions.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:az_express/services/partner_order_action_service.dart';
import 'package:az_express/widgets/app_button.dart';
import 'package:az_express/widgets/partner_v2_order_card.dart';

Map<String, dynamic> v2Order({
  String status = 'pending',
  String? sellerStatus,
  bool accepted = false,
  Map<String, dynamic>? extra,
}) =>
    {
      'amountsVersion': 2,
      'status': status,
      if (sellerStatus != null) 'sellerStatus': sellerStatus,
      if (accepted) 'partnerAcceptedAtMs': 1000,
      'paymentMethod': 'wallet',
      'productAmount': 5500,
      'deliveryFee': 500,
      'totalAmount': 6000,
      'budget': 500, // v2 : budget = frais de livraison, jamais les produits
      'description': 'Commande',
      'items': [
        {'id': 'a', 'name': 'Attiéké poisson', 'qty': 2, 'subtotal': 4000},
        {'id': 'b', 'name': 'Jus', 'qty': 1, 'subtotal': 1500},
      ],
      ...?extra,
    };

PartnerV2OrderView view(Map<String, dynamic> m) =>
    PartnerV2OrderView.fromMap('o1', m);

class Calls {
  final list = <(String, PartnerAction, String?)>[];
}

Future<void> pumpCard(
  WidgetTester tester,
  Map<String, dynamic> order,
  PartnerActionRunner runner,
) async {
  await tester.pumpWidget(MaterialApp(
    home: Scaffold(
      body: SingleChildScrollView(
        child: PartnerV2OrderCard(order: view(order), runner: runner),
      ),
    ),
  ));
}

PartnerActionResult ok(PartnerAction a,
        {String? seller, bool replay = false}) =>
    PartnerActionResult(
        action: a, message: 'OK serveur', sellerStatus: seller, replay: replay);

void main() {
  group('affichage d\'une commande v2', () {
    testWidgets(
        'produits, livraison et total séparés ; budget jamais présenté comme produits',
        (tester) async {
      await pumpCard(tester, v2Order(), (id, a, {reason}) async => ok(a));
      expect(find.text('Produits (pour vous)'), findsOneWidget);
      expect(find.text('5500 FCFA'), findsOneWidget);
      expect(find.text('Frais de livraison (livreur)'), findsOneWidget);
      expect(find.text('500 FCFA'), findsOneWidget);
      expect(find.text('Total payé par le client'), findsOneWidget);
      expect(find.text('6000 FCFA'), findsOneWidget);
      expect(find.text('2 × Attiéké poisson'), findsOneWidget);
      expect(find.text('4000 FCFA'), findsOneWidget);
      expect(find.text('À accepter'), findsOneWidget);
      expect(find.text('Livreur : après votre acceptation'), findsOneWidget);
      expect(find.text('Payée par wallet'), findsOneWidget);
    });

    testWidgets('montant absent : tiret, jamais un calcul ni le budget',
        (tester) async {
      final m = v2Order()..remove('productAmount');
      await pumpCard(tester, m, (id, a, {reason}) async => ok(a));
      expect(find.text('—'), findsOneWidget);
    });

    test('statuts de préparation et de livraison', () {
      expect(
          view(v2Order(sellerStatus: 'preparing', accepted: true))
              .preparationLabel,
          'En préparation');
      expect(
          view(v2Order(
                  sellerStatus: 'ready', accepted: true, status: 'accepted'))
              .preparationLabel,
          'Prête');
      expect(view(v2Order(accepted: true)).preparationLabel,
          'Acceptée, préparation à déclarer');
      expect(
          view(v2Order(status: 'cancelled', extra: {
            'partnerRefusal': {'reason': 'x'}
          })).preparationLabel,
          'Refusée');
      expect(view(v2Order(status: 'cancelled')).preparationLabel, 'Annulée');
      expect(view(v2Order(accepted: true)).deliveryLabel,
          'Recherche d\'un livreur');
      expect(
          view(v2Order(
                  status: 'accepted',
                  sellerStatus: 'preparing',
                  accepted: true))
              .deliveryLabel,
          'Livreur en route');
      expect(
          view(v2Order(
                  status: 'picked_up', sellerStatus: 'ready', accepted: true))
              .deliveryLabel,
          'En livraison');
      expect(
          view(v2Order(
                  status: 'delivered', sellerStatus: 'ready', accepted: true))
              .deliveryLabel,
          'Livrée');
    });

    testWidgets(
        'actions selon l\'état serveur : aucune sur prête, récupérée, livrée, annulée',
        (tester) async {
      Future<void> check(Map<String, dynamic> m,
          {required bool accept,
          required bool refuse,
          required bool ready}) async {
        await pumpCard(tester, m, (id, a, {reason}) async => ok(a));
        expect(find.widgetWithText(AppButton, 'Accepter et préparer'),
            accept ? findsOneWidget : findsNothing);
        expect(find.widgetWithText(AppButton, 'Refuser'),
            refuse ? findsOneWidget : findsNothing);
        expect(find.widgetWithText(AppButton, 'Marquer prête'),
            ready ? findsOneWidget : findsNothing);
      }

      await check(v2Order(), accept: true, refuse: true, ready: false);
      await check(v2Order(sellerStatus: 'preparing', accepted: true),
          accept: false, refuse: false, ready: true);
      await check(
          v2Order(sellerStatus: 'ready', accepted: true, status: 'accepted'),
          accept: false,
          refuse: false,
          ready: false);
      await check(
          v2Order(status: 'picked_up', sellerStatus: 'ready', accepted: true),
          accept: false,
          refuse: false,
          ready: false);
      await check(
          v2Order(status: 'delivered', sellerStatus: 'ready', accepted: true),
          accept: false,
          refuse: false,
          ready: false);
      await check(v2Order(status: 'cancelled'),
          accept: false, refuse: false, ready: false);
    });
  });

  group('actions via partnerOrderActionCF', () {
    testWidgets(
        '« Accepter et préparer » : explication, confirmation, une seule action startPreparation ; état inchangé avant le serveur',
        (tester) async {
      final calls = Calls();
      await pumpCard(tester, v2Order(), (id, a, {reason}) async {
        calls.list.add((id, a, reason));
        return ok(a, seller: 'preparing');
      });
      await tester.tap(find.widgetWithText(AppButton, 'Accepter et préparer'));
      await tester.pumpAndSettle();
      expect(find.textContaining('AZ Express recherche ensuite un livreur'),
          findsOneWidget);
      expect(find.textContaining('marquer'), findsOneWidget);
      expect(calls.list, isEmpty); // rien sans confirmation
      await tester
          .tap(find.widgetWithText(ElevatedButton, 'Accepter et préparer'));
      await tester.pumpAndSettle();
      expect(calls.list, [('o1', PartnerAction.startPreparation, null)]);
      expect(PartnerAction.startPreparation.wireName, 'startPreparation');
      // L'état affiché vient du flux, jamais du succès supposé : la carte n'a pas bougé.
      expect(find.text('À accepter'), findsOneWidget);
      expect(find.text('OK serveur'), findsOneWidget);
    });

    testWidgets('retour dans la confirmation : aucune action', (tester) async {
      final calls = Calls();
      await pumpCard(tester, v2Order(), (id, a, {reason}) async {
        calls.list.add((id, a, reason));
        return ok(a);
      });
      await tester.tap(find.widgetWithText(AppButton, 'Accepter et préparer'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Retour'));
      await tester.pumpAndSettle();
      expect(calls.list, isEmpty);
    });

    testWidgets(
        'préparation déclarée : message d\'aide puis « Marquer prête » → markReady',
        (tester) async {
      final calls = Calls();
      await pumpCard(
          tester,
          v2Order(
              sellerStatus: 'preparing',
              accepted: true,
              status: 'broadcast'), (id, a, {reason}) async {
        calls.list.add((id, a, reason));
        return ok(a, seller: 'ready');
      });
      expect(find.textContaining('AZ Express recherche un livreur'),
          findsOneWidget);
      expect(find.text('Recherche d\'un livreur'), findsOneWidget);
      await tester.tap(find.widgetWithText(AppButton, 'Marquer prête'));
      await tester.pumpAndSettle();
      expect(calls.list, [('o1', PartnerAction.markReady, null)]);
    });

    testWidgets('refus : motif facultatif transmis, action refusePartnerOrder',
        (tester) async {
      final calls = Calls();
      await pumpCard(tester, v2Order(), (id, a, {reason}) async {
        calls.list.add((id, a, reason));
        return ok(a);
      });
      await tester.tap(find.widgetWithText(AppButton, 'Refuser'));
      await tester.pumpAndSettle();
      expect(find.textContaining('remboursé intégralement'), findsOneWidget);
      await tester.enterText(find.byType(TextField), 'Rupture de stock');
      await tester.tap(find.widgetWithText(ElevatedButton, 'Refuser'));
      await tester.pumpAndSettle();
      expect(calls.list, [('o1', PartnerAction.refuse, 'Rupture de stock')]);
      expect(PartnerAction.refuse.wireName, 'refusePartnerOrder');
    });

    testWidgets('refus sans motif : accepté (le serveur ne l\'exige pas)',
        (tester) async {
      final calls = Calls();
      await pumpCard(tester, v2Order(), (id, a, {reason}) async {
        calls.list.add((id, a, reason));
        return ok(a);
      });
      await tester.tap(find.widgetWithText(AppButton, 'Refuser'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(ElevatedButton, 'Refuser'));
      await tester.pumpAndSettle();
      expect(calls.list.single.$2, PartnerAction.refuse);
    });

    testWidgets(
        'erreur réseau : message, aucun succès affiché, nouvelle tentative possible',
        (tester) async {
      var attempt = 0;
      await pumpCard(tester, v2Order(sellerStatus: 'preparing', accepted: true),
          (id, a, {reason}) async {
        attempt++;
        if (attempt == 1) {
          throw const PartnerActionException('NETWORK', '', retryable: true);
        }
        return ok(a, replay: true);
      });
      await tester.tap(find.widgetWithText(AppButton, 'Marquer prête'));
      await tester.pumpAndSettle();
      expect(find.textContaining('Connexion instable'), findsOneWidget);
      expect(find.text('OK serveur'), findsNothing);
      await tester.tap(find.widgetWithText(AppButton, 'Marquer prête'));
      await tester.pumpAndSettle();
      expect(attempt, 2);
      expect(find.textContaining('Connexion instable'), findsNothing);
      expect(find.text('Action déjà prise en compte.'), findsOneWidget);
    });

    testWidgets(
        'autorisation refusée / refus serveur : message du contrat, rien d\'affiché comme réussi',
        (tester) async {
      for (final c in [
        'ORDER_NOT_FOUND',
        'permission-denied',
        'MANAGEMENT_FROZEN',
        'PREPARATION_STARTED'
      ]) {
        await pumpCard(
            tester, v2Order(sellerStatus: 'preparing', accepted: true), (id, a,
                {reason}) async {
          throw PartnerActionException(c, '');
        });
        await tester.tap(find.widgetWithText(AppButton, 'Marquer prête'));
        await tester.pumpAndSettle();
        expect(find.textContaining(PartnerActionException(c, '').userMessage),
            findsOneWidget,
            reason: c);
        expect(find.text('OK serveur'), findsNothing);
      }
    });

    testWidgets(
        'double appui : une seule action pendant que la première est en cours',
        (tester) async {
      final gate = Completer<PartnerActionResult>();
      var count = 0;
      await pumpCard(tester, v2Order(sellerStatus: 'preparing', accepted: true),
          (id, a, {reason}) {
        count++;
        return gate.future;
      });
      final button = find.byType(AppButton);
      await tester.tap(button);
      await tester.pump();
      await tester.tap(button, warnIfMissed: false);
      await tester.pump();
      await tester.tap(button, warnIfMissed: false);
      await tester.pump();
      expect(count, 1);
      gate.complete(ok(PartnerAction.markReady, seller: 'ready'));
      await tester.pumpAndSettle();
      expect(count, 1);
    });
  });

  group('service partnerOrderActionCF', () {
    late List<Map<String, dynamic>> sent;
    setUp(() {
      sent = [];
    });

    test('requête : seulement orderId et action ; aucun montant ni prix',
        () async {
      PartnerOrderActionService.callFunction = (name, data) async {
        sent.add({'name': name, ...data});
        return {
          'success': true,
          'message': 'Préparation commencée',
          'data': {
            'orderId': 'o1',
            'sellerStatus': 'preparing',
            'replay': false
          }
        };
      };
      final r = await PartnerOrderActionService.run(
          orderId: 'o1',
          action: PartnerAction.startPreparation,
          reason: 'ignoré');
      expect(sent.single, {
        'name': 'partnerOrderActionCF',
        'orderId': 'o1',
        'action': 'startPreparation'
      });
      expect(r.sellerStatus, 'preparing');
      expect(r.replay, isFalse);
    });

    test('refus : le motif est transmis (rogné), absent s\'il est vide',
        () async {
      PartnerOrderActionService.callFunction = (name, data) async {
        sent.add({...data});
        return {
          'success': true,
          'message': 'Commande refusée et remboursée',
          'data': {'orderId': 'o1'}
        };
      };
      await PartnerOrderActionService.run(
          orderId: 'o1', action: PartnerAction.refuse, reason: '  Fermé  ');
      await PartnerOrderActionService.run(
          orderId: 'o1', action: PartnerAction.refuse, reason: '   ');
      expect(sent[0]['reason'], 'Fermé');
      expect(sent[1].containsKey('reason'), isFalse);
      expect(sent[0]['action'], 'refusePartnerOrder');
    });

    test('enveloppe d\'échec → exception avec le code serveur ; rejeu signalé',
        () async {
      PartnerOrderActionService.callFunction = (name, data) async => {
            'success': false,
            'error': 'PREPARATION_STARTED',
            'code': 'PREPARATION_STARTED',
            'message': 'x'
          };
      await expectLater(
          PartnerOrderActionService.run(
              orderId: 'o1', action: PartnerAction.refuse),
          throwsA(isA<PartnerActionException>()
              .having((e) => e.code, 'code', 'PREPARATION_STARTED')));
      PartnerOrderActionService.callFunction = (name, data) async => {
            'success': true,
            'message': 'Commande déjà prête',
            'data': {'sellerStatus': 'ready', 'replay': true}
          };
      expect(
          (await PartnerOrderActionService.run(
                  orderId: 'o1', action: PartnerAction.markReady))
              .replay,
          isTrue);
    });

    test(
        'erreurs réseau ou inattendues → NETWORK retryable ; refus d\'autorisation conservé',
        () async {
      PartnerOrderActionService.callFunction = (n, d) async =>
          throw FirebaseFunctionsException(message: 'x', code: 'unavailable');
      await expectLater(
          PartnerOrderActionService.run(
              orderId: 'o1', action: PartnerAction.markReady),
          throwsA(isA<PartnerActionException>()
              .having((e) => e.retryable, 'retryable', isTrue)));
      PartnerOrderActionService.callFunction =
          (n, d) async => throw StateError('boom');
      await expectLater(
          PartnerOrderActionService.run(
              orderId: 'o1', action: PartnerAction.markReady),
          throwsA(isA<PartnerActionException>()
              .having((e) => e.code, 'code', 'NETWORK')));
      PartnerOrderActionService.callFunction = (n, d) async =>
          throw FirebaseFunctionsException(
              message: 'no', code: 'permission-denied');
      await expectLater(
          PartnerOrderActionService.run(
              orderId: 'o1', action: PartnerAction.markReady),
          throwsA(isA<PartnerActionException>()
              .having((e) => e.retryable, 'retryable', isFalse)
              .having((e) => e.code, 'code', 'permission-denied')));
    });
  });

  group('compatibilité des commandes historiques', () {
    test(
        'isV2 : seule amountsVersion == 2 ; revenu = budget pour l\'historique, productAmount pour la v2',
        () {
      final legacy = {
        'status': 'delivered',
        'budget': 3500,
        'description': 'x'
      };
      expect(PartnerV2OrderView.isV2(legacy), isFalse);
      expect(PartnerV2OrderView.partnerRevenueOf(legacy), 3500);
      expect(
          PartnerV2OrderView.isV2({...legacy, 'amountsVersion': 1}), isFalse);
      final v2 = v2Order(status: 'delivered');
      expect(PartnerV2OrderView.isV2(v2), isTrue);
      expect(PartnerV2OrderView.partnerRevenueOf(v2),
          5500); // pas le budget (500 = frais de livraison)
      expect(PartnerV2OrderView.partnerRevenueOf({'amountsVersion': 2}), 0);
    });

    // L'écran complet dépend de Firestore (flux, index) et n'est pas montable ici : gardes statiques.
    test(
        'tableau de bord : branche v2 dédiée, aucune écriture Firestore dans la carte ni le service',
        () {
      final dash =
          File('lib/screens/restaurant/restaurant_owner_dashboard.dart')
              .readAsStringSync();
      expect(dash.contains('PartnerV2OrderView.isV2(d)'), isTrue);
      expect(dash.contains('PartnerV2OrderCard('), isTrue);
      // Le tile historique reste après la branche v2.
      expect(
          dash.indexOf("final status = d['status'] as String? ?? 'pending';"),
          greaterThan(dash.indexOf('PartnerV2OrderCard(')));
      for (final f in [
        'lib/widgets/partner_v2_order_card.dart',
        'lib/services/partner_order_action_service.dart',
      ]) {
        final src = File(f).readAsStringSync();
        for (final forbidden in [
          'cloud_firestore',
          'FirebaseFirestore',
          '.update(',
          '.set('
        ]) {
          expect(src.contains(forbidden), isFalse,
              reason: '$f ne doit pas contenir $forbidden');
        }
      }
    });
  });
}
