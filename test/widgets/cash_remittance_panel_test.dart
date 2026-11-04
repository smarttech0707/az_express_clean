import 'dart:async';
import 'dart:io';

import 'package:cloud_functions/cloud_functions.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:az_express/models/cash_remittance_view.dart';
import 'package:az_express/services/partner_cash_service.dart';
import 'package:az_express/widgets/app_button.dart';
import 'package:az_express/widgets/cash_remittance_panel.dart';
import 'package:az_express/widgets/partner_v2_order_card.dart';

/// Commande v2 livrée en espèces : produits 5500, livraison 500, total 6000 → dû au restaurant 5500.
Map<String, dynamic> cashOrder({
  String status = 'pending',
  int? handedOver,
  int? confirmed,
  int? finalAmount,
  String payment = 'cash',
  bool isPaid = true,
  int amountsVersion = 2,
  Map<String, dynamic>? dispute,
  Map<String, dynamic>? cashPayment,
}) =>
    {
      'amountsVersion': amountsVersion,
      'status': 'delivered',
      'paymentMethod': payment,
      'productAmount': 5500,
      'deliveryFee': 500,
      'totalAmount': 6000,
      'isPaid': isPaid,
      'sellerStatus': 'ready',
      if (cashPayment != null) 'cashPayment': cashPayment,
      'cashRemittance': {
        'status': status,
        'amountDue': 5500,
        'amountHandedOver': handedOver,
        if (confirmed != null) 'amountConfirmed': confirmed,
        if (finalAmount != null) 'resolution': {'finalAmount': finalAmount},
        if (dispute != null) 'dispute': dispute,
      },
    };

CashRemittanceView view(Map<String, dynamic> m) => CashRemittanceView.tryParse(m)!;

class Call {
  final CashAction action;
  final int? amount;
  final String? reason;
  final String? requestId;
  final int? finalAmount;
  final String? justification;
  final String? decision;
  Call(this.action, this.amount, this.reason, this.requestId, this.finalAmount, this.justification, [this.decision]);
}

CashActionResult okResult(CashAction a, {bool replay = false}) =>
    CashActionResult(action: a, message: 'OK serveur', replay: replay);

Future<void> pumpPanel(
  WidgetTester tester,
  Map<String, dynamic> order,
  CashRole role,
  CashActionRunner runner,
) =>
    tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: SingleChildScrollView(
          child: CashRemittancePanel(orderId: 'o1', view: view(order), role: role, totalCollected: 6000, runner: runner),
        ),
      ),
    ));

CashActionRunner recorder(List<Call> calls, {Future<CashActionResult> Function()? result}) =>
    (orderId, action, {amount, reason, requestId, finalAmount, justification, decision}) async {
      calls.add(Call(action, amount, reason, requestId, finalAmount, justification, decision));
      if (result != null) return await result();
      return okResult(action);
    };

void main() {
  group('lecture du suivi (CashRemittanceView)', () {
    test('seules les commandes v2 en espèces avec un suivi valide sont concernées', () {
      expect(CashRemittanceView.tryParse(cashOrder()), isNotNull);
      expect(CashRemittanceView.tryParse(cashOrder(payment: 'wallet')), isNull);
      expect(CashRemittanceView.tryParse(cashOrder(amountsVersion: 1)), isNull);
      expect(CashRemittanceView.tryParse({'status': 'delivered', 'paymentMethod': 'cash', 'budget': 3500}), isNull);
      expect(CashRemittanceView.tryParse({...cashOrder(), 'cashRemittance': {'status': 'pending'}}), isNull);
    });

    test('états, montants et reste dû', () {
      final pending = view(cashOrder());
      expect((pending.due, pending.outstanding, pending.handedOver), (5500, 5500, null));
      expect(pending.statusLabel, 'Aucun reversement déclaré');
      final declared = view(cashOrder(status: 'declared', handedOver: 3000));
      expect(declared.handedOver, 3000);
      expect(declared.confirmed, 0);
      expect(declared.outstanding, 5500); // une déclaration n'est jamais une confirmation
      expect(declared.closed, isFalse);
      final partial = view(cashOrder(status: 'confirmed', handedOver: 3000, confirmed: 3000));
      expect(partial.outstanding, 2500);
      expect(partial.closed, isFalse);
      expect(partial.statusLabel, contains('2500'));
      expect(partial.statusLabel, isNot(contains('intégralement')));
      final full = view(cashOrder(status: 'confirmed', handedOver: 5500, confirmed: 5500));
      expect((full.closed, full.outstanding, full.statusLabel), (true, 0, 'Réglé intégralement'));
    });

    test('régularisation avec reliquat : clos mais jamais présenté comme un règlement intégral', () {
      final v = view(cashOrder(status: 'resolved', confirmed: 0, finalAmount: 3000));
      expect(v.closed, isTrue);
      expect(v.outstanding, 2500);
      expect(v.closedWithShortfall, isTrue);
      expect(v.statusLabel, contains('reliquat de 2500 FCFA non réglé'));
      expect(v.statusLabel, isNot(contains('Réglé intégralement')));
      expect(view(cashOrder(status: 'resolved', finalAmount: 5500)).closedWithShortfall, isFalse);
    });
  });

  group('livreur : déclaration', () {
    testWidgets('montants affichés puis déclaration avec confirmation explicite ; aucun envoi sans confirmation', (tester) async {
      final calls = <Call>[];
      await pumpPanel(tester, cashOrder(), CashRole.driver, recorder(calls));
      expect(find.text('6000 FCFA'), findsOneWidget); // total encaissé
      expect(find.text('Total encaissé auprès du client'), findsOneWidget);
      expect(find.text('5500 FCFA'), findsWidgets); // dû au restaurant
      await tester.tap(find.widgetWithText(AppButton, 'Déclarer un reversement'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), '3000');
      await tester.tap(find.text('Continuer'));
      await tester.pumpAndSettle();
      expect(find.textContaining('Vous déclarez avoir remis 3000 FCFA'), findsOneWidget);
      expect(find.textContaining('ne règle pas la commande'), findsOneWidget);
      expect(find.textContaining('Il restera 2500 FCFA'), findsOneWidget);
      expect(calls, isEmpty);
      await tester.tap(find.text('Retour'));
      await tester.pumpAndSettle();
      expect(calls, isEmpty);
      await tester.tap(find.widgetWithText(AppButton, 'Déclarer un reversement'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), '3000');
      await tester.tap(find.text('Continuer'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Déclarer 3000 FCFA'));
      await tester.pumpAndSettle();
      expect(calls.length, 1);
      expect((calls.single.action, calls.single.amount), (CashAction.declare, 3000));
      expect(CashAction.declare.wireName, 'declareCashHandover');
      // La déclaration n'est jamais une confirmation : l'état affiché ne change que par le flux Firestore.
      expect(find.text('Aucun reversement déclaré'), findsOneWidget);
      expect(find.text('OK serveur'), findsOneWidget);
    });

    testWidgets('montant invalide refusé avant envoi (au-dessus du dû, nul, déjà confirmé)', (tester) async {
      final calls = <Call>[];
      await pumpPanel(tester, cashOrder(status: 'confirmed', handedOver: 3000, confirmed: 3000), CashRole.driver, recorder(calls));
      for (final bad in ['6000', '0', '3000', 'abc']) {
        await tester.tap(find.widgetWithText(AppButton, 'Déclarer un reversement'));
        await tester.pumpAndSettle();
        await tester.enterText(find.byType(TextField), bad);
        await tester.tap(find.text('Continuer'));
        await tester.pumpAndSettle();
        expect(find.textContaining('Montant entier requis'), findsOneWidget, reason: bad);
        await tester.tap(find.text('Retour'));
        await tester.pumpAndSettle();
      }
      expect(calls, isEmpty);
    });

    testWidgets('pas d\'action quand le dossier est clos, contesté ou régularisé', (tester) async {
      for (final o in [
        cashOrder(status: 'confirmed', handedOver: 5500, confirmed: 5500),
        cashOrder(status: 'disputed', handedOver: 3000, dispute: {'reason': 'Montant contesté ici', 'byRole': 'partner'}),
        cashOrder(status: 'resolved', finalAmount: 3000),
      ]) {
        await pumpPanel(tester, o, CashRole.driver, recorder([]));
        expect(find.widgetWithText(AppButton, 'Déclarer un reversement'), findsNothing);
      }
    });
  });

  group('restaurateur : confirmation et contestation', () {
    testWidgets('reversement partiel : prévenu qu\'il restera un dû, jamais présenté comme intégral', (tester) async {
      final calls = <Call>[];
      await pumpPanel(tester, cashOrder(status: 'declared', handedOver: 3000), CashRole.partner, recorder(calls));
      expect(find.textContaining('Remise déclarée par le livreur'), findsOneWidget);
      await tester.tap(find.widgetWithText(AppButton, 'Confirmer la réception'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), '3000');
      await tester.tap(find.text('Continuer'));
      await tester.pumpAndSettle();
      expect(find.textContaining('Le règlement sera PARTIEL : il restera 2500 FCFA dus'), findsOneWidget);
      expect(find.textContaining('réglée intégralement'), findsNothing);
      await tester.tap(find.text('Confirmer 3000 FCFA'));
      await tester.pumpAndSettle();
      expect((calls.single.action, calls.single.amount), (CashAction.confirm, 3000));
      expect(CashAction.confirm.wireName, 'confirmCashRemittance');
    });

    testWidgets('confirmation du dû complet : annoncée comme intégrale', (tester) async {
      final calls = <Call>[];
      await pumpPanel(tester, cashOrder(status: 'declared', handedOver: 5500), CashRole.partner, recorder(calls));
      await tester.tap(find.widgetWithText(AppButton, 'Confirmer la réception'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), '5500');
      await tester.tap(find.text('Continuer'));
      await tester.pumpAndSettle();
      expect(find.textContaining('réglée intégralement'), findsOneWidget);
      await tester.tap(find.text('Confirmer 5500 FCFA'));
      await tester.pumpAndSettle();
      expect(calls.single.amount, 5500);
    });

    testWidgets('aucune confirmation automatique : le montant doit être saisi', (tester) async {
      final calls = <Call>[];
      await pumpPanel(tester, cashOrder(status: 'declared', handedOver: 5500), CashRole.partner, recorder(calls));
      await tester.tap(find.widgetWithText(AppButton, 'Confirmer la réception'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Continuer')); // champ vide
      await tester.pumpAndSettle();
      expect(find.textContaining('Montant entier requis'), findsOneWidget);
      expect(calls, isEmpty);
    });

    testWidgets('contestation : motif de 10 caractères minimum puis action disputeCashRemittance', (tester) async {
      final calls = <Call>[];
      await pumpPanel(tester, cashOrder(status: 'declared', handedOver: 5500), CashRole.partner, recorder(calls));
      await tester.tap(find.widgetWithText(AppButton, 'Contester'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'court');
      await tester.tap(find.widgetWithText(ElevatedButton, 'Contester'));
      await tester.pumpAndSettle();
      expect(find.text('Entre 10 et 300 caractères.'), findsOneWidget);
      expect(calls, isEmpty);
      await tester.enterText(find.byType(TextField), 'Je n\'ai reçu que 3000 FCFA');
      await tester.tap(find.widgetWithText(ElevatedButton, 'Contester'));
      await tester.pumpAndSettle();
      expect(calls, isEmpty); // confirmation explicite requise
      await tester.tap(find.widgetWithText(ElevatedButton, 'Contester'));
      await tester.pumpAndSettle();
      expect((calls.single.action, calls.single.reason), (CashAction.dispute, 'Je n\'ai reçu que 3000 FCFA'));
      expect(CashAction.dispute.wireName, 'disputeCashRemittance');
    });

    testWidgets('reliquat visible : reste dû affiché, pas de « réglé » après confirmation partielle', (tester) async {
      await pumpPanel(tester, cashOrder(status: 'confirmed', handedOver: 3000, confirmed: 3000), CashRole.partner, recorder([]));
      expect(find.text('2500 FCFA'), findsOneWidget);
      expect(find.textContaining('Réglé partiellement — il reste 2500 FCFA'), findsOneWidget);
      expect(find.text('Réglé intégralement'), findsNothing);
      expect(find.widgetWithText(AppButton, 'Confirmer la réception'), findsOneWidget); // le reliquat peut encore être confirmé
    });

    testWidgets('litige : motif affiché, plus de confirmation ni de contestation', (tester) async {
      await pumpPanel(
          tester,
          cashOrder(status: 'disputed', handedOver: 3000, dispute: {'reason': 'Je n\'ai reçu que 2000 FCFA', 'byRole': 'partner'}),
          CashRole.partner,
          recorder([]));
      expect(find.textContaining('Contesté'), findsOneWidget);
      expect(find.textContaining('Je n\'ai reçu que 2000 FCFA'), findsOneWidget);
      expect(find.widgetWithText(AppButton, 'Confirmer la réception'), findsNothing);
      expect(find.widgetWithText(AppButton, 'Contester'), findsNothing);
    });
  });

  group('administration : décision serveur', () {
    testWidgets('litige : paramètres exigés (montant final, justification), aperçu du reliquat, requestId idempotent', (tester) async {
      final calls = <Call>[];
      await pumpPanel(
          tester,
          cashOrder(status: 'disputed', handedOver: 3000, dispute: {'reason': 'Montant contesté ici', 'byRole': 'partner'}),
          CashRole.admin,
          recorder(calls));
      await tester.tap(find.widgetWithText(AppButton, 'Trancher le litige'));
      await tester.pumpAndSettle();
      // Paramètres incomplets : refus local, aucun envoi.
      await tester.enterText(find.byType(TextField).at(0), '9999');
      await tester.enterText(find.byType(TextField).at(1), 'trop court');
      await tester.tap(find.text('Continuer'));
      await tester.pumpAndSettle();
      expect(find.textContaining('entre 0 et 5500'), findsOneWidget);
      expect(find.textContaining('10 à 500'), findsWidgets);
      expect(calls, isEmpty);
      await tester.enterText(find.byType(TextField).at(0), '3000');
      await tester.enterText(find.byType(TextField).at(1), 'Vérifié avec le restaurant et le livreur');
      await tester.tap(find.text('Continuer'));
      await tester.pumpAndSettle();
      expect(find.textContaining('Reliquat arrêté : 2500 FCFA'), findsOneWidget);
      expect(calls, isEmpty);
      await tester.tap(find.text('Valider la décision'));
      await tester.pumpAndSettle();
      final c = calls.single;
      expect((c.action, c.finalAmount, c.justification), (CashAction.resolve, 3000, 'Vérifié avec le restaurant et le livreur'));
      expect(c.requestId!.length, inInclusiveRange(16, 128));
      expect(CashAction.resolve.wireName, 'resolveCashRemittance');
    });

    testWidgets('rejeu après coupure réseau : même requestId pour les mêmes paramètres, nouveau pour des paramètres modifiés',
        (tester) async {
      final calls = <Call>[];
      var fail = true;
      await pumpPanel(
          tester,
          cashOrder(status: 'disputed', handedOver: 3000, dispute: {'reason': 'Montant contesté ici', 'byRole': 'driver'}),
          CashRole.admin,
          recorder(calls, result: () async {
            if (fail) {
              fail = false;
              throw const CashActionException('NETWORK', '', retryable: true);
            }
            return okResult(CashAction.resolve, replay: true);
          }));
      Future<void> decide(String amount, String justification) async {
        await tester.tap(find.widgetWithText(AppButton, 'Trancher le litige'));
        await tester.pumpAndSettle();
        await tester.enterText(find.byType(TextField).at(0), amount);
        await tester.enterText(find.byType(TextField).at(1), justification);
        await tester.tap(find.text('Continuer'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Valider la décision'));
        await tester.pumpAndSettle();
      }

      await decide('3000', 'Décision après vérification');
      expect(find.textContaining('Connexion instable'), findsOneWidget);
      await decide('3000', 'Décision après vérification');
      expect(calls.length, 2);
      expect(calls[1].requestId, calls[0].requestId); // rejeu idempotent
      await decide('2000', 'Décision après vérification');
      expect(calls[2].requestId, isNot(calls[0].requestId)); // paramètres modifiés : nouvelle décision
    });

    testWidgets('dossier clos : aucune décision proposée', (tester) async {
      await pumpPanel(tester, cashOrder(status: 'resolved', finalAmount: 3000), CashRole.admin, recorder([]));
      expect(find.widgetWithText(AppButton, 'Régulariser'), findsNothing);
      expect(find.widgetWithText(AppButton, 'Trancher le litige'), findsNothing);
      expect(find.textContaining('reliquat de 2500 FCFA non réglé'), findsOneWidget);
    });

    testWidgets('refus d\'autorisation du serveur (non super-administrateur) : message, rien d\'annoncé', (tester) async {
      await pumpPanel(tester, cashOrder(status: 'declared', handedOver: 3000), CashRole.admin,
          (orderId, action, {amount, reason, requestId, finalAmount, justification, decision}) async {
        throw const CashActionException('permission-denied', '');
      });
      await tester.tap(find.widgetWithText(AppButton, 'Régulariser'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField).at(0), '3000');
      await tester.enterText(find.byType(TextField).at(1), 'Régularisation après contrôle');
      await tester.tap(find.text('Continuer'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Valider la décision'));
      await tester.pumpAndSettle();
      expect(find.textContaining('n\'avez pas l\'autorisation requise'), findsOneWidget);
      expect(find.text('OK serveur'), findsNothing);
    });
  });

  group('double appui et réseau', () {
    testWidgets('double appui : une seule déclaration pendant que la première est en cours', (tester) async {
      final gate = Completer<CashActionResult>();
      final calls = <Call>[];
      await pumpPanel(tester, cashOrder(), CashRole.driver, recorder(calls, result: () => gate.future));
      await tester.tap(find.widgetWithText(AppButton, 'Déclarer un reversement'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), '5500');
      await tester.tap(find.text('Continuer'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Déclarer 5500 FCFA'));
      await tester.pump();
      await tester.tap(find.byType(AppButton).first, warnIfMissed: false);
      await tester.pump();
      await tester.tap(find.byType(AppButton).first, warnIfMissed: false);
      await tester.pump();
      expect(calls.length, 1);
      gate.complete(okResult(CashAction.declare));
      await tester.pumpAndSettle();
      expect(calls.length, 1);
    });

    testWidgets('erreur réseau : message, aucun succès annoncé, nouvelle tentative possible', (tester) async {
      var fail = true;
      final calls = <Call>[];
      await pumpPanel(tester, cashOrder(), CashRole.driver, recorder(calls, result: () async {
        if (fail) {
          fail = false;
          throw const CashActionException('NETWORK', '', retryable: true);
        }
        return okResult(CashAction.declare, replay: true);
      }));
      Future<void> declare() async {
        await tester.tap(find.widgetWithText(AppButton, 'Déclarer un reversement'));
        await tester.pumpAndSettle();
        await tester.enterText(find.byType(TextField), '5500');
        await tester.tap(find.text('Continuer'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Déclarer 5500 FCFA'));
        await tester.pumpAndSettle();
      }

      await declare();
      expect(find.textContaining('Connexion instable'), findsOneWidget);
      expect(find.text('OK serveur'), findsNothing);
      await declare();
      expect(calls.length, 2);
      expect(find.textContaining('Connexion instable'), findsNothing);
      expect(find.text('Action déjà prise en compte.'), findsOneWidget);
    });
  });

  group('service partnerOrderActionCF (reversements)', () {
    late List<Map<String, dynamic>> sent;
    setUp(() => sent = []);

    Future<Map<String, dynamic>> ok(String name, Map<String, dynamic> data) async {
      sent.add({...data});
      return {'success': true, 'message': 'Remise déclarée', 'data': {'orderId': 'o1', 'replay': false}};
    }

    test('contrat des paramètres par action', () async {
      PartnerCashService.callFunction = ok;
      await PartnerCashService.run(orderId: 'o1', action: CashAction.declare, amount: 3000);
      await PartnerCashService.run(orderId: 'o1', action: CashAction.confirm, amount: 5500);
      await PartnerCashService.run(orderId: 'o1', action: CashAction.dispute, reason: '  Motif de désaccord  ');
      await PartnerCashService.run(
          orderId: 'o1', action: CashAction.resolve, requestId: 'req-0123456789abcdef', finalAmount: 3000, justification: ' Vérifié ok ok ');
      expect(sent[0], {'orderId': 'o1', 'action': 'declareCashHandover', 'amount': 3000});
      expect(sent[1], {'orderId': 'o1', 'action': 'confirmCashRemittance', 'amount': 5500});
      expect(sent[2], {'orderId': 'o1', 'action': 'disputeCashRemittance', 'reason': 'Motif de désaccord'});
      expect(sent[3], {
        'orderId': 'o1',
        'action': 'resolveCashRemittance',
        'requestId': 'req-0123456789abcdef',
        'finalAmount': 3000,
        'justification': 'Vérifié ok ok',
      });
    });

    test('codes serveur, rejeu et réseau', () async {
      PartnerCashService.callFunction = (n, d) async =>
          {'success': false, 'error': 'CASH_DISPUTED', 'code': 'CASH_DISPUTED', 'message': 'x'};
      await expectLater(PartnerCashService.run(orderId: 'o1', action: CashAction.declare, amount: 1),
          throwsA(isA<CashActionException>().having((e) => e.code, 'code', 'CASH_DISPUTED')));
      PartnerCashService.callFunction = (n, d) async => {'success': true, 'message': 'Réception déjà confirmée', 'data': {'replay': true}};
      expect((await PartnerCashService.run(orderId: 'o1', action: CashAction.confirm, amount: 1)).replay, isTrue);
      PartnerCashService.callFunction = (n, d) async => throw FirebaseFunctionsException(message: 'x', code: 'deadline-exceeded');
      await expectLater(PartnerCashService.run(orderId: 'o1', action: CashAction.declare, amount: 1),
          throwsA(isA<CashActionException>().having((e) => e.retryable, 'retryable', isTrue)));
      PartnerCashService.callFunction = (n, d) async => throw FirebaseFunctionsException(message: 'no', code: 'permission-denied');
      await expectLater(PartnerCashService.run(orderId: 'o1', action: CashAction.resolve, requestId: 'x' * 16, finalAmount: 0, justification: 'y' * 10),
          throwsA(isA<CashActionException>().having((e) => e.code, 'code', 'permission-denied')));
    });
  });

  group('carte restaurateur, wallet exclu, historique', () {
    Future<void> pumpCard(WidgetTester tester, Map<String, dynamic> order, List<Call> calls) => tester.pumpWidget(MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: PartnerV2OrderCard(
                order: PartnerV2OrderView.fromMap('o1', order),
                runner: (id, a, {reason}) async => throw StateError('aucune action de préparation attendue'),
                cashRunner: recorder(calls),
              ),
            ),
          ),
        ));

    testWidgets('commande livrée en espèces : le restaurateur voit le suivi et peut confirmer ou contester', (tester) async {
      await pumpCard(tester, {...cashOrder(status: 'declared', handedOver: 3000), 'items': []}, []);
      expect(find.text('Espèces dues au restaurant'), findsOneWidget);
      expect(find.widgetWithText(AppButton, 'Confirmer la réception'), findsOneWidget);
      expect(find.widgetWithText(AppButton, 'Contester'), findsOneWidget);
      // Aucune action de préparation sur une commande livrée.
      expect(find.widgetWithText(AppButton, 'Accepter et préparer'), findsNothing);
    });

    testWidgets('commande wallet : aucun reversement', (tester) async {
      await pumpCard(tester, {...cashOrder(payment: 'wallet'), 'items': []}, []);
      expect(find.text('Espèces dues au restaurant'), findsNothing);
    });

    test('commande historique ou v1 : aucun suivi de reversement', () {
      expect(PartnerV2OrderView.fromMap('o', {'status': 'delivered', 'budget': 3000, 'paymentMethod': 'cash'}).cash, isNull);
      expect(CashRemittanceView.tryParse(cashOrder(amountsVersion: 1)), isNull);
    });

    // Les écrans livreur/admin dépendent de Firestore (flux) et ne sont pas montables ici : gardes statiques.
    test('page livreur : seules les v2 en espèces non closes, requête sans index composite', () {
      final src = File('lib/screens/driver/driver_cash_remittance_page.dart').readAsStringSync();
      expect(src.contains('CashRemittanceView.tryParse(r.data)'), isTrue);
      expect(src.contains("'merchantCashSettled', isEqualTo: false"), isTrue);
      expect(src.contains('.orderBy('), isFalse);
      expect(src.contains('.update('), isFalse);
      expect(src.contains('.set('), isFalse);
    });

    test('écran admin : plus aucune écriture directe de merchantCashSettled pour une v2', () {
      final src = File('lib/screens/admin/admin_cash_settlement_page.dart').readAsStringSync();
      final compact = src.replaceAll(RegExp(r'\s+'), ' ');
      // La garde v2 précède l'écriture directe historique.
      final guard = compact.indexOf("raw['amountsVersion'] == 2");
      final write = compact.indexOf("'merchantCashSettled': true");
      expect(guard, greaterThan(0));
      expect(write, greaterThan(guard));
      // Les commandes v2 passent par la fiche dédiée, sans bouton « Marquer réglé ».
      expect(compact.contains("if (data['amountsVersion'] == 2) { return _V2CashTile("), isTrue);
      final tile = src.substring(src.indexOf('class _V2CashTile'));
      expect(tile.contains('Marquer réglé'), isFalse);
      expect(tile.contains('.update('), isFalse);
      expect(tile.contains('CashRole.admin'), isTrue);
      // Parcours historique conservé.
      expect(src.contains('Marquer réglé'), isTrue);
    });

    test('aucune opération financière directe dans les nouveaux fichiers', () {
      for (final f in [
        'lib/widgets/cash_remittance_panel.dart',
        'lib/services/partner_cash_service.dart',
        'lib/models/cash_remittance_view.dart',
      ]) {
        final src = File(f).readAsStringSync();
        for (final forbidden in ['cloud_firestore', 'FirebaseFirestore', '.update(', '.set(', 'runTransaction', "'wallet'", 'wallet:']) {
          expect(src.contains(forbidden), isFalse, reason: '$f ne doit pas contenir $forbidden');
        }
      }
    });

    test('signalement « non payé » : échec non bloquant, la livraison confirmée n\'est plus présentée comme un échec', () {
      final src = File('lib/screens/driver/driver_dashboard.dart').readAsStringSync();
      final compact = src.replaceAll(RegExp(r'\s+'), ' ');
      // Parcours historique : le succès n'est annoncé que si l'appel a réellement abouti ; jamais pour une v2.
      expect(compact.contains('await _firestore .reportFakeOrder(order.clientId!); legacyReported = true; } catch (_) {}'), isTrue);
      expect(compact.contains('if (!v2Unpaid && !clientPaid &&'), isTrue);
      expect(compact.contains('NonPaymentReportDialog('), isTrue);
    });
  });

  group('7D-4-S : « Non payé » et contestation du livreur', () {
    testWidgets('non-paiement signalé : avertissement, montant THÉORIQUE, aucun montant encaissé inventé', (tester) async {
      final order = cashOrder(isPaid: false, cashPayment: {
        'status': 'non_payment_declared',
        'verification': 'pending_review',
        'reason': 'Client parti sans payer',
      });
      expect(view(order).unpaidReported, isTrue);
      for (final role in [CashRole.driver, CashRole.partner, CashRole.admin]) {
        await pumpPanel(tester, order, role, recorder([]));
        expect(find.textContaining('Non-paiement déclaré'), findsOneWidget, reason: '$role');
        expect(find.textContaining('THÉORIQUE'), findsOneWidget, reason: '$role');
        expect(find.text('Dû au restaurant (théorique)'), findsOneWidget, reason: '$role');
        expect(find.text('5500 FCFA'), findsWidgets); // la dette n'est pas effacée
      }
      await pumpPanel(tester, order, CashRole.driver, recorder([]));
      expect(find.text('Total à encaisser (théorique)'), findsOneWidget);
      expect(find.text('Total encaissé auprès du client'), findsNothing);
      // Aucune ligne « montant encaissé » : le serveur n'en fournit pas. Seul l'avertissement évoque l'encaissement inconnu.
      expect(find.textContaining('Montant encaissé'), findsNothing);
      expect(find.textContaining('n’est pas connue'), findsOneWidget);
      // La déclaration du livreur reste possible (elle ne règle rien) : le dû théorique n'est pas supprimé.
      expect(find.widgetWithText(AppButton, 'Déclarer un reversement'), findsOneWidget);
    });

    testWidgets('paiement confirmé : aucun avertissement, libellé « encaissé »', (tester) async {
      await pumpPanel(tester, cashOrder(), CashRole.driver, recorder([]));
      expect(find.textContaining('Non-paiement'), findsNothing);
      expect(find.text('Total encaissé auprès du client'), findsOneWidget);
    });

    testWidgets('non payé + litige ou reliquat : jamais de règlement intégral affiché', (tester) async {
      await pumpPanel(
          tester,
          cashOrder(isPaid: false, status: 'disputed', handedOver: 0, dispute: {'reason': 'Client parti sans payer', 'byRole': 'driver'}),
          CashRole.admin,
          recorder([]));
      expect(find.textContaining('Contesté'), findsOneWidget);
      expect(find.text('Réglé intégralement'), findsNothing);
      expect(find.text('5500 FCFA'), findsWidgets);
      await pumpPanel(tester, cashOrder(isPaid: false, status: 'resolved', finalAmount: 0), CashRole.admin, recorder([]));
      expect(find.textContaining('reliquat de 5500 FCFA non réglé'), findsOneWidget);
      expect(find.text('Réglé intégralement'), findsNothing);
    });

    testWidgets('contestation livreur : motif trop court refusé, confirmation explicite, puis disputeCashRemittance', (tester) async {
      final calls = <Call>[];
      await pumpPanel(tester, cashOrder(isPaid: false), CashRole.driver, recorder(calls));
      await tester.tap(find.widgetWithText(AppButton, 'Contester'));
      await tester.pumpAndSettle();
      // Le champ plafonne la saisie à 300 caractères (maxLength) ; seul le motif trop court est à refuser.
      await tester.enterText(find.byType(TextField), 'court');
      await tester.tap(find.widgetWithText(ElevatedButton, 'Contester'));
      await tester.pumpAndSettle();
      expect(find.text('Entre 10 et 300 caractères.'), findsOneWidget);
      expect(calls, isEmpty);
      await tester.enterText(find.byType(TextField), '  Le client est parti sans payer  ');
      await tester.tap(find.widgetWithText(ElevatedButton, 'Contester'));
      await tester.pumpAndSettle();
      expect(find.textContaining('Aucun montant n’est modifié'), findsOneWidget);
      expect(calls, isEmpty);
      // Retour de la confirmation : toujours rien d'envoyé.
      await tester.tap(find.text('Retour'));
      await tester.pumpAndSettle();
      expect(calls, isEmpty);
      await tester.tap(find.widgetWithText(AppButton, 'Contester'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'Le client est parti sans payer');
      await tester.tap(find.widgetWithText(ElevatedButton, 'Contester'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(ElevatedButton, 'Contester'));
      await tester.pumpAndSettle();
      expect((calls.single.action, calls.single.reason), (CashAction.dispute, 'Le client est parti sans payer'));
      expect(calls.single.amount, isNull);
      // Aucun changement optimiste : l'état affiché ne change que par le flux Firestore.
      expect(find.text('Aucun reversement déclaré'), findsOneWidget);
      expect(find.text('OK serveur'), findsOneWidget);
    });

    testWidgets('contestation livreur : double appui = une seule requête', (tester) async {
      final gate = Completer<CashActionResult>();
      final calls = <Call>[];
      await pumpPanel(tester, cashOrder(), CashRole.driver, recorder(calls, result: () => gate.future));
      await tester.tap(find.widgetWithText(AppButton, 'Contester'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'Montant réellement dû erroné');
      await tester.tap(find.widgetWithText(ElevatedButton, 'Contester'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(ElevatedButton, 'Contester'));
      await tester.pump();
      for (var i = 0; i < 3; i++) {
        await tester.tap(find.byType(AppButton).last, warnIfMissed: false);
        await tester.pump();
      }
      expect(calls.length, 1);
      gate.complete(okResult(CashAction.dispute));
      await tester.pumpAndSettle();
      expect(calls.length, 1);
    });

    testWidgets('contestation livreur : erreur réseau affichée, aucun succès, nouvelle tentative possible', (tester) async {
      var fail = true;
      final calls = <Call>[];
      await pumpPanel(tester, cashOrder(), CashRole.driver, recorder(calls, result: () async {
        if (fail) {
          fail = false;
          throw const CashActionException('NETWORK', '', retryable: true);
        }
        return okResult(CashAction.dispute);
      }));
      Future<void> contest() async {
        await tester.tap(find.widgetWithText(AppButton, 'Contester'));
        await tester.pumpAndSettle();
        await tester.enterText(find.byType(TextField), 'Montant réellement dû erroné');
        await tester.tap(find.widgetWithText(ElevatedButton, 'Contester'));
        await tester.pumpAndSettle();
        await tester.tap(find.widgetWithText(ElevatedButton, 'Contester'));
        await tester.pumpAndSettle();
      }

      await contest();
      expect(find.textContaining('Connexion instable'), findsOneWidget);
      expect(find.text('OK serveur'), findsNothing);
      await contest();
      expect(calls.length, 2);
      expect(find.textContaining('Connexion instable'), findsNothing);
    });

    testWidgets('erreurs serveur de contestation : message clair (déjà clos, refus)', (tester) async {
      await pumpPanel(tester, cashOrder(), CashRole.driver,
          (orderId, action, {amount, reason, requestId, finalAmount, justification, decision}) async {
        throw const CashActionException('CASH_ALREADY_FINAL', '');
      });
      await tester.tap(find.widgetWithText(AppButton, 'Contester'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'Montant réellement dû erroné');
      await tester.tap(find.widgetWithText(ElevatedButton, 'Contester'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(ElevatedButton, 'Contester'));
      await tester.pumpAndSettle();
      expect(find.text('OK serveur'), findsNothing);
      expect(find.textContaining('clos'), findsWidgets);
    });

    testWidgets('livreur : plus de contestation quand le dossier est déjà contesté ou clos', (tester) async {
      for (final o in [
        cashOrder(status: 'disputed', handedOver: 0, dispute: {'reason': 'Désaccord de montant', 'byRole': 'driver'}),
        cashOrder(status: 'confirmed', handedOver: 5500, confirmed: 5500),
        cashOrder(status: 'resolved', finalAmount: 0),
      ]) {
        await pumpPanel(tester, o, CashRole.driver, recorder([]));
        expect(find.widgetWithText(AppButton, 'Contester'), findsNothing);
      }
    });

    test('contrat serveur : motif transmis rogné, sans montant, sans écriture directe', () async {
      final sent = <Map<String, dynamic>>[];
      PartnerCashService.callFunction = (n, d) async {
        sent.add({...d});
        return {'success': true, 'message': 'Désaccord signalé', 'data': {'replay': false}};
      };
      await PartnerCashService.run(orderId: 'o1', action: CashAction.dispute, reason: ' Le client n\'a pas payé ');
      expect(sent.single, {'orderId': 'o1', 'action': 'disputeCashRemittance', 'reason': 'Le client n\'a pas payé'});
    });

    test('compatibilité historique : sans cashPayment ni isPaid, une v2 cash est INCONNUE (jamais « non payée ») ; v1 et wallet hors périmètre', () {
      final noFlag = Map<String, dynamic>.from(cashOrder())..remove('isPaid');
      expect(CashRemittanceView.tryParse(noFlag)!.payment, CashPaymentState.unknown);
      expect(CashRemittanceView.tryParse(noFlag)!.unpaidReported, isFalse);
      expect(CashRemittanceView.tryParse(noFlag)!.amountsTheoretical, isTrue);
      expect(CashRemittanceView.tryParse(cashOrder(amountsVersion: 1, isPaid: false)), isNull);
      expect(CashRemittanceView.tryParse(cashOrder(payment: 'wallet', isPaid: false)), isNull);
    });

    test('aucune modification financière directe : page livreur sans avertissement dupliqué, panneau sans Firestore', () {
      final page = File('lib/screens/driver/driver_cash_remittance_page.dart').readAsStringSync();
      expect(page.contains('isPaid'), isFalse); // l'avertissement vit désormais dans le panneau
      final panel = File('lib/widgets/cash_remittance_panel.dart').readAsStringSync();
      expect(panel.contains('cloud_firestore'), isFalse);
      expect(panel.contains('CashAction.dispute'), isTrue);
    });
  });
}
