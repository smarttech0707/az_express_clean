import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:az_express/models/cash_remittance_view.dart';
import 'package:az_express/services/partner_cash_service.dart';
import 'package:az_express/widgets/app_button.dart';
import 'package:az_express/widgets/cash_remittance_panel.dart';
import 'package:az_express/screens/driver/driver_cash_remittance_page.dart';

import 'cash_remittance_panel_test.dart'
    show Call, cashOrder, okResult, pumpPanel, recorder, view;

// Mission 7D-6 — intégration Flutter de cashPayment : déclaration du livreur après livraison, examen super-admin,
// affichage prudent (déclaration ≠ preuve, aucun montant encaissé inventé), compatibilité historique.

Map<String, dynamic> payment(String status, String verification,
        {String? reason, Map<String, dynamic>? review}) =>
    {
      'status': status,
      'verification': verification,
      if (reason != null) 'reason': reason,
      if (review != null) 'review': review,
    };

final paid = payment('confirmed', 'not_required');
final unknown = payment('unknown', 'not_required');
final pending = payment('non_payment_declared', 'pending_review',
    reason: 'Le client est parti sans payer');
final confirmedUnpaid = payment('non_payment_declared', 'confirmed_unpaid',
    reason: 'Le client est parti sans payer',
    review: {'justification': 'Appel du client : aveu de non-paiement'});
final refuted = payment('non_payment_declared', 'refuted',
    reason: 'Le client est parti sans payer',
    review: {'justification': 'Le restaurant a reçu le paiement en direct'});

const reasonOk = 'Le client est parti sans payer';
const justifOk = 'Appel du client et du livreur, versions comparées';

Finder button(String label) => find.widgetWithText(AppButton, label);

void main() {
  tearDown(() => PartnerCashService.callFunction = (n, d) async => {});

  group('1-2. affichage : paiement déclaré encaissé / non-paiement déclaré', () {
    testWidgets('livraison payée : déclaration du livreur, jamais une preuve ; aucun signalement proposé', (tester) async {
      final order = cashOrder(cashPayment: paid);
      expect(view(order).payment, CashPaymentState.declaredPaid);
      await pumpPanel(tester, order, CashRole.driver, recorder([]));
      expect(find.textContaining('déclaré encaissé par le livreur'), findsOneWidget);
      expect(find.textContaining('non vérifiée'), findsOneWidget);
      expect(find.text('Total encaissé auprès du client'), findsOneWidget);
      expect(button('Signaler un non-paiement'), findsNothing);
      expect(find.textContaining('THÉORIQUE'), findsNothing);
    });

    testWidgets('livraison non payée : montant THÉORIQUE, motif du livreur, signalement déjà fait, examen côté admin', (tester) async {
      final order = cashOrder(isPaid: false, cashPayment: pending);
      await pumpPanel(tester, order, CashRole.driver, recorder([]));
      expect(find.textContaining('Non-paiement déclaré par le livreur'), findsOneWidget);
      expect(find.textContaining('en attente d’examen'), findsOneWidget);
      expect(find.text('Motif du livreur : Le client est parti sans payer'), findsOneWidget);
      expect(find.text('Dû au restaurant (théorique)'), findsOneWidget);
      expect(find.text('5500 FCFA'), findsWidgets); // le dû n'est pas effacé
      expect(find.textContaining('Montant encaissé'), findsNothing);
      expect(button('Signaler un non-paiement'), findsNothing);
      expect(button('Examiner le non-paiement'), findsNothing); // réservé à l'administration
      await pumpPanel(tester, order, CashRole.admin, recorder([]));
      expect(button('Examiner le non-paiement'), findsOneWidget);
    });
  });

  group('7-8. paiement inconnu et incident en examen', () {
    testWidgets('paiement inconnu : ni « payé » ni « non payé » ; montants théoriques ; signalement possible', (tester) async {
      for (final o in [cashOrder(isPaid: false), cashOrder(isPaid: false, cashPayment: unknown)]) {
        expect(view(o).payment, CashPaymentState.unknown);
        await pumpPanel(tester, o, CashRole.driver, recorder([]));
        expect(find.textContaining('non renseigné'), findsWidgets);
        expect(find.textContaining('Non-paiement'), findsNothing);
        expect(find.textContaining('déclaré encaissé'), findsNothing);
        expect(find.text('Total à encaisser (théorique)'), findsOneWidget);
        expect(button('Signaler un non-paiement'), findsOneWidget);
      }
    });

    testWidgets('incident en examen, confirmé et infirmé : libellés distincts, le dû reste affiché', (tester) async {
      final labels = {
        'en attente d’examen': cashOrder(isPaid: false, cashPayment: pending),
        'Non-paiement confirmé par l’administration': cashOrder(isPaid: false, cashPayment: confirmedUnpaid),
        'Signalement de non-paiement infirmé': cashOrder(cashPayment: refuted),
      };
      for (final e in labels.entries) {
        await pumpPanel(tester, e.value, CashRole.admin, recorder([]));
        expect(find.textContaining(e.key), findsOneWidget, reason: e.key);
        expect(find.text('5500 FCFA'), findsWidgets);
      }
      await pumpPanel(tester, labels.values.elementAt(1), CashRole.admin, recorder([]));
      expect(find.textContaining('Examen : Appel du client'), findsOneWidget);
      // Seul un non-paiement EN ATTENTE s'examine ; un examen ne se rejoue pas depuis l'interface.
      expect(button('Examiner le non-paiement'), findsNothing);
      // Examiner n'est jamais confondu avec régulariser : la décision de reversement reste proposée.
      expect(button('Régulariser'), findsOneWidget);
    });
  });

  group('3-6. signalement du livreur après livraison', () {
    Future<void> open(WidgetTester tester, CashActionRunner runner) async {
      await pumpPanel(tester, cashOrder(isPaid: false, cashPayment: unknown), CashRole.driver, runner);
      await tester.tap(button('Signaler un non-paiement'));
      await tester.pumpAndSettle();
    }

    testWidgets('3. motif valide : declareCashNonPayment avec le motif rogné, boîte fermée, vérification annoncée', (tester) async {
      final calls = <Call>[];
      await open(tester, recorder(calls));
      await tester.enterText(find.byType(TextField), '  $reasonOk  ');
      await tester.tap(find.widgetWithText(ElevatedButton, 'Signaler'));
      await tester.pumpAndSettle();
      expect((calls.single.action, calls.single.reason), (CashAction.declareNonPayment, reasonOk));
      expect(calls.single.amount, isNull);
      expect(find.byType(NonPaymentReportDialog), findsNothing);
      expect(find.textContaining('vérification administrative en attente'), findsOneWidget);
    });

    testWidgets('4. motif invalide (trop court) : refusé avant tout envoi', (tester) async {
      final calls = <Call>[];
      await open(tester, recorder(calls));
      await tester.enterText(find.byType(TextField), 'court');
      await tester.tap(find.widgetWithText(ElevatedButton, 'Signaler'));
      await tester.pumpAndSettle();
      expect(find.text('Motif de 10 à 300 caractères.'), findsOneWidget);
      expect(calls, isEmpty);
      expect(find.byType(NonPaymentReportDialog), findsOneWidget);
    });

    testWidgets('5. double appui : une seule requête tant que la première est en cours', (tester) async {
      final calls = <Call>[];
      final gate = Completer<void>();
      await open(tester, recorder(calls, result: () async {
        await gate.future;
        return okResult(CashAction.declareNonPayment);
      }));
      await tester.enterText(find.byType(TextField), reasonOk);
      final submit = find.widgetWithText(ElevatedButton, 'Signaler');
      await tester.tap(submit);
      await tester.pump();
      await tester.tap(find.byType(ElevatedButton).last, warnIfMissed: false);
      await tester.pump();
      expect(calls.length, 1);
      gate.complete();
      await tester.pumpAndSettle();
      expect(calls.length, 1);
    });

    testWidgets('6. erreur réseau : message, boîte conservée, aucun succès annoncé, nouvelle tentative possible', (tester) async {
      var attempts = 0;
      final calls = <Call>[];
      await open(tester, recorder(calls, result: () async {
        attempts++;
        if (attempts == 1) throw const CashActionException('NETWORK', '', retryable: true);
        return okResult(CashAction.declareNonPayment);
      }));
      await tester.enterText(find.byType(TextField), reasonOk);
      await tester.tap(find.widgetWithText(ElevatedButton, 'Signaler'));
      await tester.pumpAndSettle();
      expect(find.textContaining('Connexion instable'), findsOneWidget);
      expect(find.byType(NonPaymentReportDialog), findsOneWidget);
      expect(find.textContaining('vérification administrative en attente'), findsNothing);
      await tester.tap(find.widgetWithText(ElevatedButton, 'Signaler'));
      await tester.pumpAndSettle();
      expect(calls.length, 2);
      expect(calls.last.reason, reasonOk);
      expect(find.byType(NonPaymentReportDialog), findsNothing);
    });

    testWidgets('erreur serveur (déjà déclaré payé) : message du serveur affiché dans la boîte', (tester) async {
      await open(tester, (id, a, {amount, reason, requestId, finalAmount, justification, decision}) async {
        throw const CashActionException('PAYMENT_ALREADY_DECLARED_PAID', '');
      });
      await tester.enterText(find.byType(TextField), reasonOk);
      await tester.tap(find.widgetWithText(ElevatedButton, 'Signaler'));
      await tester.pumpAndSettle();
      expect(find.textContaining('déclaré le paiement reçu'), findsOneWidget);
    });

    testWidgets('« Plus tard » : rien n\'est envoyé', (tester) async {
      final calls = <Call>[];
      await open(tester, recorder(calls));
      await tester.tap(find.text('Plus tard'));
      await tester.pumpAndSettle();
      expect(calls, isEmpty);
    });
  });

  group('9-10. décision du super-administrateur', () {
    Future<void> openReview(WidgetTester tester, CashActionRunner runner) async {
      await pumpPanel(tester, cashOrder(isPaid: false, cashPayment: pending), CashRole.admin, runner);
      await tester.tap(button('Examiner le non-paiement'));
      await tester.pumpAndSettle();
    }

    Future<void> submit(WidgetTester tester, String justification, {bool refute = false}) async {
      if (refute) {
        await tester.tap(find.byKey(const ValueKey('review-refute')));
        await tester.pump();
      }
      await tester.enterText(find.byType(TextField), justification);
      await tester.tap(find.text('Continuer'));
      await tester.pumpAndSettle();
    }

    testWidgets('justification trop courte refusée ; confirmation explicite ; reviewCashNonPayment (jamais resolve)', (tester) async {
      final calls = <Call>[];
      await openReview(tester, recorder(calls));
      await submit(tester, 'court');
      expect(find.text('Justification de 10 à 500 caractères.'), findsOneWidget);
      expect(calls, isEmpty);
      await submit(tester, justifOk);
      // Confirmation explicite : rien n'est envoyé avant elle, et elle précise que le reversement n'est pas réglé.
      expect(calls, isEmpty);
      expect(find.textContaining('ne règle PAS le reversement'), findsOneWidget);
      await tester.tap(find.widgetWithText(ElevatedButton, 'Confirmer le non-paiement'));
      await tester.pumpAndSettle();
      final c = calls.single;
      expect(c.action, CashAction.reviewNonPayment);
      expect(c.decision, 'confirm_unpaid');
      expect(c.justification, justifOk);
      expect(c.requestId!.length, inInclusiveRange(16, 128));
      expect([c.amount, c.finalAmount, c.reason], [null, null, null]); // aucun montant : le dû n'est pas touché
    });

    testWidgets('infirmer le signalement : decision refute', (tester) async {
      final calls = <Call>[];
      await openReview(tester, recorder(calls));
      await submit(tester, justifOk, refute: true);
      expect(find.textContaining('circuit normal de reversement continue'), findsOneWidget);
      await tester.tap(find.widgetWithText(ElevatedButton, 'Infirmer le signalement'));
      await tester.pumpAndSettle();
      expect((calls.single.action, calls.single.decision), (CashAction.reviewNonPayment, 'refute'));
    });

    testWidgets('annuler à la confirmation : aucun envoi', (tester) async {
      final calls = <Call>[];
      await openReview(tester, recorder(calls));
      await submit(tester, justifOk);
      await tester.tap(find.text('Retour'));
      await tester.pumpAndSettle();
      expect(calls, isEmpty);
    });

    testWidgets('refus serveur (non super-administrateur) : message, aucun changement optimiste', (tester) async {
      await openReview(tester, (id, a, {amount, reason, requestId, finalAmount, justification, decision}) async {
        throw const CashActionException('permission-denied', '');
      });
      await submit(tester, justifOk);
      await tester.tap(find.widgetWithText(ElevatedButton, 'Confirmer le non-paiement'));
      await tester.pumpAndSettle();
      expect(find.textContaining('autorisation requise'), findsOneWidget);
      // L'état affiché vient du flux : il reste « en attente ».
      expect(find.textContaining('en attente d’examen'), findsOneWidget);
    });

    testWidgets('10. rejeu idempotent : coupure → « Réessayer » rejoue le MÊME requestId (UUID v4), jamais recréé', (tester) async {
      final calls = <Call>[];
      var attempts = 0;
      await openReview(tester, recorder(calls, result: () async {
        attempts++;
        if (attempts < 3) throw const CashActionException('NETWORK', '', retryable: true);
        return okResult(CashAction.reviewNonPayment, replay: true);
      }));
      await submit(tester, justifOk);
      await tester.tap(find.widgetWithText(ElevatedButton, 'Confirmer le non-paiement'));
      await tester.pumpAndSettle();
      expect(find.textContaining('Connexion instable'), findsOneWidget);
      // Issue inconnue : la décision reste en attente, pas de nouvelle saisie possible, retry ou abandon explicite.
      expect(button('Examiner le non-paiement'), findsNothing);
      expect(button('Réessayer la décision'), findsOneWidget);
      expect(button('Abandonner la décision'), findsOneWidget);
      await tester.tap(button('Réessayer la décision'));
      await tester.pumpAndSettle();
      await tester.tap(button('Réessayer la décision'));
      await tester.pumpAndSettle();
      expect(calls.length, 3);
      expect(calls.map((c) => c.requestId).toSet().length, 1);
      expect(calls.first.requestId, matches(RegExp(r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$')));
      expect(calls.every((c) => c.decision == 'confirm_unpaid' && c.justification == justifOk), isTrue);
      expect(find.text('Action déjà prise en compte.'), findsOneWidget);
      // Issue connue (rejeu) : l'identifiant est libéré.
      expect(button('Réessayer la décision'), findsNothing);
      expect(button('Examiner le non-paiement'), findsOneWidget);
    });

    testWidgets('nouvelle décision indépendante, même texte : NOUVEL identifiant (après succès, refus ou abandon)', (tester) async {
      final calls = <Call>[];
      var attempts = 0;
      await openReview(tester, recorder(calls, result: () async {
        attempts++;
        if (attempts == 2) throw const CashActionException('PAYMENT_ALREADY_REVIEWED', '');
        if (attempts == 3) throw const CashActionException('NETWORK', '', retryable: true);
        return okResult(CashAction.reviewNonPayment);
      }));
      Future<void> decide() async {
        await submit(tester, justifOk);
        await tester.tap(find.widgetWithText(ElevatedButton, 'Confirmer le non-paiement'));
        await tester.pumpAndSettle();
      }

      await decide(); // 1 : succès → libéré
      await tester.tap(button('Examiner le non-paiement'));
      await tester.pumpAndSettle();
      await decide(); // 2 : refus serveur (issue connue) → libéré
      expect(find.textContaining('déjà été examiné'), findsOneWidget);
      await tester.tap(button('Examiner le non-paiement'));
      await tester.pumpAndSettle();
      await decide(); // 3 : coupure → conservé
      await tester.tap(button('Abandonner la décision'));
      await tester.pumpAndSettle();
      await tester.tap(button('Examiner le non-paiement'));
      await tester.pumpAndSettle();
      await decide(); // 4 : après abandon explicite
      expect(calls.length, 4);
      expect(calls.map((c) => c.requestId).toSet().length, 4, reason: 'un identifiant par tentative logique');
    });

    testWidgets('erreur réseau APRÈS réussite serveur : aucun faux succès ; le flux montre l\'examen → plus rien à rejouer', (tester) async {
      final order = ValueNotifier<Map<String, dynamic>>(cashOrder(isPaid: false, cashPayment: pending));
      final calls = <Call>[];
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: ValueListenableBuilder<Map<String, dynamic>>(
              valueListenable: order,
              builder: (_, o, __) => CashRemittancePanel(
                orderId: 'o1',
                view: view(o),
                role: CashRole.admin,
                runner: recorder(calls, result: () async {
                  // Le serveur a enregistré la décision, mais la réponse est perdue.
                  throw const CashActionException('NETWORK', '', retryable: true);
                }),
              ),
            ),
          ),
        ),
      ));
      await tester.tap(button('Examiner le non-paiement'));
      await tester.pumpAndSettle();
      await submit(tester, justifOk);
      await tester.tap(find.widgetWithText(ElevatedButton, 'Confirmer le non-paiement'));
      await tester.pumpAndSettle();
      expect(find.textContaining('Connexion instable'), findsOneWidget);
      expect(find.text('Action déjà prise en compte.'), findsNothing);
      expect(find.text('OK serveur'), findsNothing);
      expect(find.textContaining('en attente d’examen'), findsOneWidget); // état réel : pas de changement optimiste
      expect(button('Réessayer la décision'), findsOneWidget);
      // Le flux Firestore reflète enfin l'examen.
      order.value = cashOrder(isPaid: false, cashPayment: confirmedUnpaid);
      await tester.pumpAndSettle();
      expect(find.textContaining('Non-paiement confirmé par l’administration'), findsOneWidget);
      expect(button('Réessayer la décision'), findsNothing);
      expect(button('Examiner le non-paiement'), findsNothing);
      expect(calls.length, 1);
    });
  });

  group('1. rappel persistant : page « Espèces à reverser »', () {
    Map<String, dynamic> row(Map<String, dynamic>? cp, {bool isPaid = false}) =>
        {...cashOrder(isPaid: isPaid, cashPayment: cp), 'sellerName': 'Chez Test', 'driverId': 'd1', 'merchantCashSettled': false};

    // Simule Firestore : une fenêtre de [limit] documents ordonnés par identifiant, comme une requête sans orderBy.
    CashOrdersSource fakeFirestore(Map<String, Map<String, dynamic>> docs) => (driverId, limit) {
          final ids = docs.keys.toList()..sort();
          return Stream.value([for (final id in ids.take(limit)) (id: id, data: docs[id]!)]);
        };

    testWidgets('livraison v2 non payée (unknown) : retrouvée après fermeture et réouverture, avec son bouton', (tester) async {
      final docs = {'o1': row(unknown)};
      for (var i = 0; i < 2; i++) {
        await tester.pumpWidget(MaterialApp(home: DriverCashRemittancePage(driverId: 'd1', source: fakeFirestore(docs))));
        await tester.pumpAndSettle();
        expect(find.text('Chez Test'), findsOneWidget, reason: 'ouverture $i');
        expect(button('Signaler un non-paiement'), findsOneWidget);
        expect(find.textContaining('non renseigné'), findsWidgets);
        // Fermeture de l'application (écran détruit), puis réouverture : seul le flux serveur fait foi, rien en local.
        await tester.pumpWidget(const MaterialApp(home: SizedBox()));
      }
    });

    testWidgets('v2 antérieure à cashPayment (isPaid:false, sans champ) : aussi retrouvée comme inconnue', (tester) async {
      await tester.pumpWidget(MaterialApp(home: DriverCashRemittancePage(driverId: 'd1', source: fakeFirestore({'o1': row(null)}))));
      await tester.pumpAndSettle();
      expect(button('Signaler un non-paiement'), findsOneWidget);
    });

    testWidgets('commande ancienne hors de la première fenêtre : « Afficher plus » la retrouve', (tester) async {
      tester.view.physicalSize = const Size(800, 6000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final docs = {
        'a1': row(paid, isPaid: true),
        'a2': row(paid, isPaid: true),
        'z9': {...row(unknown), 'sellerName': 'Ancien resto'},
      };
      await tester.pumpWidget(MaterialApp(
        home: DriverCashRemittancePage(driverId: 'd1', source: fakeFirestore(docs), pageSize: 2),
      ));
      await tester.pumpAndSettle();
      expect(find.text('Ancien resto'), findsNothing); // hors fenêtre
      expect(find.text('Afficher plus de commandes'), findsOneWidget); // jamais silencieusement perdue
      await tester.tap(find.text('Afficher plus de commandes'));
      await tester.pumpAndSettle();
      expect(find.text('Ancien resto'), findsOneWidget);
      expect(find.text('Afficher plus de commandes'), findsNothing);
    });

    testWidgets('aucune commande : message vide ; erreur de flux : état d\'erreur, pas de spinner infini', (tester) async {
      await tester.pumpWidget(MaterialApp(home: DriverCashRemittancePage(driverId: 'd1', source: fakeFirestore({}))));
      await tester.pumpAndSettle();
      expect(find.text('Aucun reversement en attente.'), findsOneWidget);
      await tester.pumpWidget(MaterialApp(
        home: DriverCashRemittancePage(key: const ValueKey('erreur'), driverId: 'd1', source: (d, l) => Stream.error(StateError('réseau'))),
      ));
      await tester.pumpAndSettle();
      expect(find.byType(CircularProgressIndicator), findsNothing);
      expect(find.textContaining('Impossible de charger'), findsOneWidget);
    });

    testWidgets('signalement depuis la page : rien d\'annoncé avant la réponse serveur ; l\'état vient ensuite du flux', (tester) async {
      final stream = StreamController<List<CashOrderRow>>();
      addTearDown(stream.close);
      final gate = Completer<void>();
      final sent = <Map<String, dynamic>>[];
      PartnerCashService.callFunction = (n, d) async {
        sent.add({...d});
        await gate.future;
        return {'success': true, 'message': 'OK', 'data': {'replay': false}};
      };
      await tester.pumpWidget(MaterialApp(
        home: DriverCashRemittancePage(driverId: 'd1', source: (d, l) => stream.stream),
      ));
      stream.add([(id: 'o1', data: row(unknown))]);
      await tester.pumpAndSettle();
      await tester.tap(button('Signaler un non-paiement'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), reasonOk);
      await tester.tap(find.widgetWithText(ElevatedButton, 'Signaler'));
      await tester.pump();
      expect(sent.length, 1);
      expect(find.textContaining('Non-paiement signalé'), findsNothing); // la réponse n'est pas arrivée
      gate.complete();
      await tester.pumpAndSettle();
      expect(find.textContaining('Non-paiement signalé'), findsOneWidget);
      // Tant que le flux n'a pas changé, l'état affiché reste l'état réel (inconnu)…
      expect(find.textContaining('non renseigné'), findsWidgets);
      // …puis le flux Firestore met à jour l'affichage.
      stream.add([(id: 'o1', data: row(pending))]);
      await tester.pumpAndSettle();
      expect(find.textContaining('Non-paiement déclaré par le livreur'), findsOneWidget);
      expect(button('Signaler un non-paiement'), findsNothing);
    });

    test('requête : égalités seulement (aucun index composite), v2 en espèces, aucune persistance locale', () {
      final src = File('lib/screens/driver/driver_cash_remittance_page.dart').readAsStringSync();
      for (final f in ["'amountsVersion', isEqualTo: 2", "'paymentMethod', isEqualTo: 'cash'", "'merchantCashSettled', isEqualTo: false"]) {
        expect(src.contains(f), isTrue, reason: f);
      }
      expect(src.contains('.orderBy('), isFalse);
      for (final forbidden in ['SharedPreferences', 'shared_preferences', 'FlutterSecureStorage', 'File(', 'hive', 'sqflite']) {
        expect(src.contains(forbidden), isFalse, reason: forbidden);
      }
      final dash = File('lib/screens/driver/driver_dashboard.dart').readAsStringSync();
      expect(dash.contains('DriverCashRemittancePage(driverId: widget.driverId)'), isTrue); // toujours accessible
    });
  });

  group('contrat du service', () {
    test('paramètres exacts : declareCashNonPayment {reason} et reviewCashNonPayment {requestId, decision, justification}', () async {
      final sent = <Map<String, dynamic>>[];
      PartnerCashService.callFunction = (n, d) async {
        expect(n, 'partnerOrderActionCF');
        sent.add({...d});
        return {
          'success': true,
          'message': 'OK',
          'data': {'replay': true, 'payment': {'status': 'non_payment_declared'}},
        };
      };
      final a = await PartnerCashService.run(orderId: 'o1', action: CashAction.declareNonPayment, reason: ' $reasonOk ');
      expect(a.replay, isTrue);
      await PartnerCashService.run(
          orderId: 'o1',
          action: CashAction.reviewNonPayment,
          requestId: 'review-request-0001',
          decision: 'confirm_unpaid',
          justification: ' $justifOk ');
      expect(sent[0], {'orderId': 'o1', 'action': 'declareCashNonPayment', 'reason': reasonOk});
      expect(sent[1], {
        'orderId': 'o1',
        'action': 'reviewCashNonPayment',
        'requestId': 'review-request-0001',
        'decision': 'confirm_unpaid',
        'justification': justifOk,
      });
    });

    test('codes serveur 7D-5 : messages clairs', () {
      for (final code in ['PAYMENT_ALREADY_DECLARED_PAID', 'NO_NON_PAYMENT_DECLARED', 'PAYMENT_ALREADY_REVIEWED', 'INVALID_DECISION']) {
        expect(CashActionException(code, '').userMessage, isNot(contains(code)), reason: code);
        expect(CashActionException(code, '').userMessage.length, greaterThan(15));
      }
    });
  });

  group('11. compatibilité historique', () {
    test('sans cashPayment : isPaid:true = déclaré encaissé ; sinon INCONNU, jamais « non payé »', () {
      expect(view(cashOrder()).payment, CashPaymentState.declaredPaid);
      expect(view(cashOrder(isPaid: false)).payment, CashPaymentState.unknown);
      final noFlag = Map<String, dynamic>.from(cashOrder())..remove('isPaid');
      expect(view(noFlag).payment, CashPaymentState.unknown);
      expect(view(noFlag).unpaidReported, isFalse);
      expect(view(cashOrder(isPaid: false)).canReportNonPayment, isTrue);
    });

    test('cashPayment illisible : repli historique sur isPaid ; statut inconnu : traité comme inconnu', () {
      final bad = {...cashOrder(isPaid: false), 'cashPayment': 'x'};
      expect(CashRemittanceView.tryParse(bad)!.payment, CashPaymentState.unknown);
      expect(view(cashOrder(cashPayment: payment('autre', 'x'))).payment, CashPaymentState.unknown);
    });

    test('v1 et wallet : aucun suivi, aucune action cash', () {
      expect(CashRemittanceView.tryParse(cashOrder(amountsVersion: 1, cashPayment: pending)), isNull);
      expect(CashRemittanceView.tryParse(cashOrder(payment: 'wallet', cashPayment: pending)), isNull);
    });

    test('non-paiement : états, signalement impossible une fois déclaré, clos ou déclaré payé', () {
      expect(view(cashOrder(cashPayment: pending)).payment, CashPaymentState.nonPaymentPending);
      expect(view(cashOrder(cashPayment: confirmedUnpaid)).payment, CashPaymentState.nonPaymentConfirmed);
      expect(view(cashOrder(cashPayment: refuted)).payment, CashPaymentState.nonPaymentRefuted);
      expect(view(cashOrder(cashPayment: pending)).canReviewPayment, isTrue);
      expect(view(cashOrder(cashPayment: refuted)).canReviewPayment, isFalse);
      expect(view(cashOrder(cashPayment: paid)).canReportNonPayment, isFalse);
      expect(view(cashOrder(cashPayment: pending)).canReportNonPayment, isFalse);
      expect(view(cashOrder(isPaid: false, status: 'resolved', finalAmount: 0)).canReportNonPayment, isFalse);
    });

    testWidgets('parcours de reversement et de contestation conservés avec un non-paiement déclaré', (tester) async {
      final calls = <Call>[];
      await pumpPanel(tester, cashOrder(isPaid: false, cashPayment: pending), CashRole.driver, recorder(calls));
      expect(button('Déclarer un reversement'), findsOneWidget);
      expect(button('Contester'), findsOneWidget);
    });
  });

  group('12. aucune écriture financière directe', () {
    test('le panneau, le service et le modèle n\'écrivent ni Firestore ni wallet ; l\'examen n\'appelle pas resolve', () {
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
      final panel = File('lib/widgets/cash_remittance_panel.dart').readAsStringSync();
      final review = panel.substring(panel.indexOf('Future<void> _reviewPayment()'), panel.indexOf('Future<bool> _confirm('));
      expect(review.contains('CashAction.resolve'), isFalse);
      expect(review.contains('finalAmount'), isFalse);
    });

    test('tableau de bord livreur : v2 non payée → aucune déclaration à la livraison, signalement APRÈS confirmation serveur', () {
      final src = File('lib/screens/driver/driver_dashboard.dart').readAsStringSync();
      final compact = src.replaceAll(RegExp(r'\s+'), ' ');
      expect(compact.contains('final bool? markPaid = v2Unpaid ? null :'), isTrue);
      final delivered = compact.indexOf('markCashPaid: markPaid,');
      final reported = compact.indexOf('NonPaymentReportDialog(');
      expect(delivered, greaterThan(0));
      expect(reported, greaterThan(delivered)); // jamais avant la confirmation serveur de la livraison
      // reportFakeOrder (refusé par les règles) n'est plus jamais appelé pour une v2.
      expect(compact.contains('if (!v2Unpaid && !clientPaid &&'), isTrue);
      expect(compact.contains('await _firestore .reportFakeOrder(order.clientId!); legacyReported = true;'), isTrue);
      // L'envoi de markCashPaid est omis (et non faux) pour la v2 non payée.
      final service = File('lib/services/firestore_service.dart').readAsStringSync().replaceAll(RegExp(r'\s+'), ' ');
      expect(service.contains("if (markCashPaid != null) 'markCashPaid': markCashPaid,"), isTrue);
    });
  });
}
