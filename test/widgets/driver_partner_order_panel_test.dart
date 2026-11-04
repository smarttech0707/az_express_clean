import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:az_express/models/order_model.dart';
import 'package:az_express/models/partner_v2_info.dart';
import 'package:az_express/widgets/driver_partner_order_panel.dart';

Map<String, dynamic> v2Map({
  String status = 'accepted',
  String? sellerStatus,
  String payment = 'cash',
  String sellerType = 'restaurant',
  Map<String, dynamic>? extra,
}) =>
    {
      'amountsVersion': 2,
      'sellerType': sellerType,
      'status': status,
      if (sellerStatus != null) 'sellerStatus': sellerStatus,
      'paymentMethod': payment,
      'productAmount': 5500,
      'deliveryFee': 500,
      'totalAmount': 6000,
      'budget': 500, // v2 : budget = frais de livraison
      'description': '🍽️ Chez Awa : 2x Attiéké (4000 FCFA)',
      'items': [
        {'id': 'a', 'name': 'Attiéké poisson', 'qty': 2, 'subtotal': 4000},
        {'id': 'b', 'name': 'Jus', 'qty': 1, 'subtotal': 1500},
      ],
      ...?extra,
    };

OrderModel orderOf(Map<String, dynamic> m) => OrderModel.fromMap('o1', m);

Future<void> pump(WidgetTester tester, OrderModel order, {int? gain = 400}) =>
    tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: SingleChildScrollView(
            child: DriverPartnerOrderPanel(order: order, estimatedGain: gain)),
      ),
    ));

void main() {
  group('affichage livreur', () {
    testWidgets(
        'commande v2 en préparation : état clair, produits listés, récupération déconseillée',
        (tester) async {
      final o = orderOf(v2Map(sellerStatus: 'preparing'));
      await pump(tester, o);
      expect(find.textContaining('En préparation — ne récupérez pas encore'),
          findsOneWidget);
      expect(find.text('2 × Attiéké poisson'), findsOneWidget);
      expect(find.text('1 × Jus'), findsOneWidget);
      expect(DriverPartnerPickup.canPickUp(o), isFalse);
    });

    testWidgets(
        'avant toute préparation : « En attente de préparation », récupération bloquée',
        (tester) async {
      final o = orderOf(v2Map());
      await pump(tester, o);
      expect(find.textContaining('En attente de préparation'), findsOneWidget);
      expect(DriverPartnerPickup.canPickUp(o), isFalse);
    });

    testWidgets(
        'commande v2 prête : « Prête à récupérer », récupération autorisée',
        (tester) async {
      final o = orderOf(v2Map(sellerStatus: 'ready'));
      await pump(tester, o);
      expect(find.textContaining('Prête à récupérer'), findsOneWidget);
      expect(find.textContaining('ne récupérez pas'), findsNothing);
      expect(DriverPartnerPickup.canPickUp(o), isTrue);
    });

    testWidgets('l\'état suit le flux : préparation → prête sans rien supposer',
        (tester) async {
      await pump(tester, orderOf(v2Map(sellerStatus: 'preparing')));
      expect(find.textContaining('ne récupérez pas'), findsOneWidget);
      await pump(tester, orderOf(v2Map(sellerStatus: 'ready')));
      expect(find.textContaining('ne récupérez pas'), findsNothing);
      expect(find.textContaining('Prête à récupérer'), findsOneWidget);
    });

    testWidgets(
        'commande récupérée (picked_up) : plus de bandeau de préparation',
        (tester) async {
      await pump(
          tester, orderOf(v2Map(status: 'picked_up', sellerStatus: 'ready')));
      expect(find.textContaining('Prête à récupérer'), findsNothing);
      expect(find.textContaining('ne récupérez pas'), findsNothing);
    });
  });

  group('QR/PIN et bouton de récupération', () {
    test(
        'libellé : bloqué en préparation (QR ou non), actif seulement après ready',
        () {
      final preparing = orderOf(v2Map(sellerStatus: 'preparing'));
      final ready = orderOf(v2Map(sellerStatus: 'ready'));
      for (final qr in [true, false]) {
        expect(DriverPartnerPickup.pickupButtonLabel(preparing, proofUi: qr),
            'En préparation — attendez le restaurant');
      }
      expect(DriverPartnerPickup.pickupButtonLabel(ready, proofUi: true),
          'Scanner le QR code / récupérer');
      expect(DriverPartnerPickup.pickupButtonLabel(ready, proofUi: false),
          'Colis récupéré');
    });

    // L'écran livreur dépend de Firebase (flux, scanner, GPS) et n'est pas montable ici : gardes statiques.
    test(
        'écran livreur : bouton désactivé avant ready, scanner atteignable seulement via la garde',
        () {
      final src =
          File('lib/screens/driver/driver_dashboard.dart').readAsStringSync();
      final compact = src.replaceAll(RegExp(r'\s+'), ' ');
      expect(compact.contains('!DriverPartnerPickup.canPickUp(order)) ? null'),
          isTrue);
      final guard = src.indexOf('Future<void> _guardedMainAction');
      final main = src.indexOf('Future<void> _mainAction');
      final scanner = src.indexOf('ProofScannerPage(');
      expect(guard, greaterThan(0));
      expect(main, greaterThan(guard));
      // Le scanner n'est construit que dans _mainAction, appelée après la vérification canPickUp de la garde.
      expect(scanner, greaterThan(main));
      final guardBody = src.substring(guard, main);
      expect(guardBody.contains('canPickUp'), isTrue);
      expect(guardBody.indexOf('canPickUp'),
          lessThan(guardBody.indexOf('_mainAction(')));
    });
  });

  group('montants', () {
    testWidgets(
        'cash : montants exacts et explication du partage encaissement / restaurant / livreur',
        (tester) async {
      await pump(tester, orderOf(v2Map()));
      expect(find.text('5500 FCFA'), findsOneWidget); // produits
      expect(find.text('500 FCFA'), findsOneWidget); // frais de livraison
      expect(find.text('6000 FCFA'), findsOneWidget); // total
      expect(find.text('400 FCFA'),
          findsOneWidget); // gain estimé fourni par l'appelant (frais − commission)
      expect(find.textContaining('encaissez 6000 FCFA'), findsOneWidget);
      expect(find.textContaining('5500 FCFA reviennent au restaurant'),
          findsOneWidget);
      expect(
          find.textContaining(
              '500 FCFA de frais de livraison sont votre rémunération brute'),
          findsOneWidget);
    });

    test(
        'le total n\'est jamais confondu avec le revenu du livreur : budget = frais, total = totalAmount',
        () {
      final o = orderOf(v2Map());
      expect(o.budget, 500);
      expect(o.partnerV2!.totalAmount, 6000);
      expect(o.partnerV2!.deliveryFee, 500);
      final b = DriverPartnerPickup.cashBreakdown(o.partnerV2!)!;
      expect((b.collect, b.toRestaurant, b.deliveryFee), (6000, 5500, 500));
    });

    testWidgets('wallet : montants affichés, rien à encaisser', (tester) async {
      await pump(
          tester, orderOf(v2Map(payment: 'wallet', sellerStatus: 'ready')));
      expect(find.text('5500 FCFA'), findsOneWidget);
      expect(find.text('500 FCFA'), findsOneWidget);
      expect(find.text('6000 FCFA'), findsOneWidget);
      expect(find.textContaining('Déjà payée par wallet'), findsOneWidget);
      expect(find.textContaining('encaissez 6000'), findsNothing);
    });

    testWidgets(
        'montant manquant : tiret et aucune explication chiffrée inventée',
        (tester) async {
      final m = v2Map()..remove('productAmount');
      await pump(tester, orderOf(m), gain: null);
      expect(find.text('—'), findsOneWidget);
      expect(find.textContaining('encaissez '), findsNothing);
      expect(DriverPartnerPickup.cashBreakdown(orderOf(m).partnerV2!), isNull);
    });
  });

  group('double appui, réseau, réponse tardive', () {
    test(
        'SingleFlight : deuxième appel ignoré pendant que le premier est en cours',
        () async {
      final flight = SingleFlight();
      final gate = Completer<void>();
      var runs = 0;
      final first = flight.run(() async {
        runs++;
        await gate.future;
      });
      expect(await flight.run(() async => runs++), isFalse);
      expect(await flight.run(() async => runs++), isFalse);
      expect(runs, 1);
      gate.complete();
      expect(await first, isTrue);
      expect(flight.busy, isFalse);
    });

    test(
        'erreur réseau : le verrou est libéré, une nouvelle tentative est possible',
        () async {
      final flight = SingleFlight();
      await expectLater(
          flight.run(() async => throw StateError('réseau')), throwsStateError);
      expect(flight.busy, isFalse);
      var done = false;
      expect(await flight.run(() async => done = true), isTrue);
      expect(done, isTrue);
    });

    test(
        'l\'écran n\'annonce aucune récupération : l\'échec de pickUpOrder affiche « non confirmée »',
        () {
      final src =
          File('lib/screens/driver/driver_dashboard.dart').readAsStringSync();
      expect(src.contains('Récupération non confirmée'), isTrue);
      expect(
          src.contains(
              '_mainActionFlight.run(() => _mainAction(order, isPickedUp))'),
          isTrue);
    });
  });

  group('compatibilité historique et absence d\'opération financière', () {
    test(
        'commande historique ou autre version : aucune info v2, récupération non bloquée',
        () {
      final legacy = {
        'status': 'accepted',
        'budget': 3500,
        'sellerType': 'restaurant',
        'description': 'x'
      };
      final marketplace = {
        'status': 'accepted',
        'budget': 500,
        'amountsVersion': 1,
        'productAmount': 3000,
        'sellerType': 'marketplace'
      };
      for (final m in [legacy, marketplace]) {
        final o = orderOf(m);
        expect(o.partnerV2, isNull);
        expect(DriverPartnerPickup.canPickUp(o), isTrue);
        expect(DriverPartnerPickup.pickupButtonLabel(o, proofUi: true),
            'Scanner le QR code / récupérer');
      }
      expect(orderOf(marketplace).productAmount,
          3000); // comportement Marketplace inchangé
      // Un type non partenaire n'est jamais pris pour une v2.
      expect(PartnerV2Info.tryParse({...v2Map(), 'sellerType': 'pharmacie'}),
          isNull);
    });

    testWidgets('commande historique : le panneau n\'affiche rien',
        (tester) async {
      await pump(tester,
          orderOf({'status': 'accepted', 'budget': 3500, 'description': 'x'}));
      expect(find.byType(Text), findsNothing);
    });

    test('boulangerie v2 : mêmes gardes que le restaurant', () {
      final o =
          orderOf(v2Map(sellerType: 'boulangerie', sellerStatus: 'preparing'));
      expect(o.partnerV2, isNotNull);
      expect(DriverPartnerPickup.canPickUp(o), isFalse);
    });

    test(
        'un changement de sellerStatus rend deux commandes différentes (le flux se rafraîchit)',
        () {
      expect(
          orderOf(v2Map(sellerStatus: 'preparing')) ==
              orderOf(v2Map(sellerStatus: 'ready')),
          isFalse);
      expect(
          orderOf(v2Map(sellerStatus: 'ready')) ==
              orderOf(v2Map(sellerStatus: 'ready')),
          isTrue);
    });

    test('toMap ne réécrit jamais les montants ni l\'état v2', () {
      final map = orderOf(v2Map(sellerStatus: 'ready')).toMap();
      for (final k in [
        'amountsVersion',
        'sellerStatus',
        'productAmount',
        'deliveryFee',
        'totalAmount',
        'partnerV2'
      ]) {
        expect(map.containsKey(k), isFalse, reason: k);
      }
    });

    test('nouveaux fichiers : aucune opération Firestore ni wallet directe',
        () {
      for (final f in [
        'lib/widgets/driver_partner_order_panel.dart',
        'lib/models/partner_v2_info.dart',
      ]) {
        final src = File(f).readAsStringSync();
        for (final forbidden in [
          'cloud_firestore',
          'FirebaseFirestore',
          '.update(',
          '.set(',
          'wallet:',
          "'wallet'",
          'runTransaction'
        ]) {
          expect(src.contains(forbidden), isFalse,
              reason: '$f ne doit pas contenir $forbidden');
        }
      }
      // Les changements de l'écran livreur n'ajoutent aucun appel de paiement : seules les actions existantes subsistent.
      final dash =
          File('lib/screens/driver/driver_dashboard.dart').readAsStringSync();
      final guard = dash.substring(
          dash.indexOf('Future<void> _guardedMainAction'),
          dash.indexOf('Future<void> _mainAction'));
      expect(guard.contains('wallet'), isFalse);
      expect(guard.contains('FirebaseFirestore'), isFalse);
    });
  });
}
