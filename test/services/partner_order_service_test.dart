import 'dart:io';

import 'package:cloud_functions/cloud_functions.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:az_express/services/partner_order_service.dart';
import 'package:az_express/widgets/partner_order_checkout.dart';

/// Faux serveur : même contrat que quotePartnerOrderCF / createPartnerOrderFromQuoteCF (prix relus ici, jamais lus
/// dans la requête ; rejeu d'un devis utilisé = même commande ; confirmedAmount exact exigé). Aucun accès réseau.
class FakePartnerServer {
  int wallet;
  int clock = 1000000;
  final menu = <String, int>{'a': 2000, 'b': 1500};
  int deliveryFee = 500;
  // 'v2' | 'closed' | 'notInPilot' | 'clientNotInPilot' | 'disabled'
  String mode = 'v2';
  final quotes = <String, Map<String, dynamic>>{};
  final orders = <String, Map<String, dynamic>>{};
  final calls = <Map<String, dynamic>>[];
  // Coupe de réseau simulée : la requête est TRAITÉE par le serveur mais la réponse est perdue.
  bool dropNextOrderResponse = false;
  bool failBeforeServer = false;
  int _seq = 0;

  FakePartnerServer({this.wallet = 20000});

  Map<String, dynamic> _fail(String code, String msg,
          [Map<String, dynamic> data = const {}]) =>
      {
        'success': false,
        'error': code,
        'code': code,
        'message': msg,
        'data': data
      };

  Future<Map<String, dynamic>> call(String name, Map<String, dynamic> d) async {
    calls.add({'name': name, ...d});
    if (failBeforeServer) {
      failBeforeServer = false;
      throw FirebaseFunctionsException(message: 'offline', code: 'unavailable');
    }
    if (mode == 'disabled') {
      return _fail('FEATURE_DISABLED', 'Fonction non activée');
    }
    if (mode == 'closed') {
      return _fail(
          'CREATION_CLOSED', 'Ces commandes sont momentanément indisponibles');
    }
    if (mode == 'notInPilot') {
      return _fail('PARTNER_NOT_IN_PILOT',
          'Ce partenaire n’accepte pas encore ce type de commande');
    }
    if (mode == 'clientNotInPilot') {
      return _fail('CLIENT_NOT_IN_PILOT',
          'Ce service n’est pas encore ouvert à votre compte');
    }
    if (mode == 'garbage') {
      return _fail('WEIRD_CODE', 'Configuration illisible');
    }
    if (name == 'quotePartnerOrderCF') return _quote(d);
    final res = _order(d);
    if (dropNextOrderResponse) {
      dropNextOrderResponse = false;
      throw FirebaseFunctionsException(
          message: 'timeout', code: 'deadline-exceeded');
    }
    return res;
  }

  int _product(List items) => items.fold(
      0, (s, it) => s + menu[(it as Map)['itemId']]! * (it['qty'] as int));

  Map<String, dynamic> _quote(Map<String, dynamic> d) {
    final items = d['items'] as List;
    final product = _product(items);
    final id = 'q${++_seq}';
    quotes[id] = {
      'items': items,
      'destination': d['destination'],
      'amount': product + deliveryFee,
      'status': 'open',
      'expiresAtMs': clock + 600000
    };
    return {
      'success': true,
      'data': {
        'quoteId': id,
        'sellerName': 'Chez Awa',
        'lines': [
          for (final it in items)
            {
              'itemId': (it as Map)['itemId'],
              'name': 'Plat ${it['itemId']}',
              'qty': it['qty'],
              'unitPrice': menu[it['itemId']],
              'subtotal': menu[it['itemId']]! * (it['qty'] as int),
            }
        ],
        'productAmount': product,
        'deliveryFee': deliveryFee,
        'total': product + deliveryFee,
        'expiresAtMs': clock + 600000,
      },
    };
  }

  Map<String, dynamic> _order(Map<String, dynamic> d) {
    final q = quotes[d['quoteId']];
    if (q == null) return _fail('QUOTE_NOT_FOUND', 'Devis introuvable');
    if (q['status'] == 'used') {
      return {
        'success': true,
        'message': 'Commande déjà créée',
        'data': {
          'orderId': q['orderId'],
          'charged': q['charged'],
          'replayed': true
        }
      };
    }
    if ((q['expiresAtMs'] as int) <= clock) {
      return _fail('QUOTE_EXPIRED', 'Devis expiré');
    }
    if (d['items'].toString() != q['items'].toString() ||
        d['destination'].toString() != q['destination'].toString()) {
      return _fail('QUOTE_MISMATCH', 'La commande ne correspond pas au devis');
    }
    final current = _product(q['items'] as List) + deliveryFee;
    final quoted = q['amount'] as int;
    if (current > quoted) {
      return _fail('PRICE_CHANGED', 'Le tarif a changé',
          {'quotedAmount': quoted, 'currentAmount': current});
    }
    if (d['confirmedAmount'] != current) {
      if (current < quoted && d['confirmedAmount'] == quoted) {
        return _fail('PRICE_CHANGED', 'Le tarif a baissé', {
          'quotedAmount': quoted,
          'currentAmount': current,
          'decreased': true
        });
      }
      return _fail(
          'AMOUNT_NOT_CONFIRMED', 'Montant non confirmé', {'amount': current});
    }
    if (d['paymentMethod'] == 'wallet' && wallet < current) {
      return _fail('SOLDE_INSUFFISANT', 'SOLDE_INSUFFISANT:$wallet:$current');
    }
    if (d['paymentMethod'] == 'wallet') wallet -= current;
    final orderId = 'o${++_seq}';
    orders[orderId] = {
      'totalAmount': current,
      'paymentMethod': d['paymentMethod'],
      'isPaid': d['paymentMethod'] == 'wallet'
    };
    q['status'] = 'used';
    q['orderId'] = orderId;
    q['charged'] = d['paymentMethod'] == 'wallet' ? current : 0;
    return {
      'success': true,
      'data': {
        'orderId': orderId,
        'charged': q['charged'],
        'productAmount': current - deliveryFee,
        'deliveryFee': deliveryFee,
        'totalAmount': current
      },
    };
  }
}

void main() {
  late FakePartnerServer server;
  late PartnerCheckout checkout;
  const cart = {
    'b': 1,
    'a': 2
  }; // produits : 2×2000 + 1500 = 5500, livraison 500, total 6000

  Future<({double lat, double lng})> locate() async =>
      (lat: 6.7299999, lng: -3.4800001);

  setUp(() {
    server = FakePartnerServer();
    checkout = PartnerCheckout();
    PartnerOrderService.callFunction = server.call;
    PartnerOrderService.nowMs = () => server.clock;
  });

  Future<PartnerQuote> prepare([Map<String, int> c = cart]) => checkout.prepare(
      sellerType: 'restaurant', sellerId: 'r1', cart: c, locate: locate);

  Future<PartnerOrderResult> confirm(PartnerQuote q, String method) =>
      checkout.confirm(
          quote: q,
          paymentMethod: method,
          deliveryAddress: 'Ma position actuelle');

  test(
      'devis réussi : produits, livraison et total viennent du serveur ; la requête ne contient aucun montant',
      () async {
    final q = await prepare();
    expect(q.productAmount, 5500);
    expect(q.deliveryFee, 500);
    expect(q.total, 6000);
    expect(q.lines.map((l) => l.subtotal), [4000, 1500]);
    final req = server.calls.single;
    expect(req['name'], 'quotePartnerOrderCF');
    expect(req.keys.toSet(),
        {'name', 'sellerType', 'sellerId', 'items', 'destination'});
    // Articles triés par identifiant, point arrondi comme le serveur le compare (5 décimales).
    expect(req['items'], [
      {'itemId': 'a', 'qty': 2},
      {'itemId': 'b', 'qty': 1}
    ]);
    expect(req['destination'], {'lat': 6.73, 'lng': -3.48});
  });

  test(
      'création : confirmedAmount = total du devis serveur, wallet débité du total exact, une commande',
      () async {
    final q = await prepare();
    final r = await confirm(q, 'wallet');
    final create = server.calls.last;
    expect(create['name'], 'createPartnerOrderFromQuoteCF');
    expect(create['confirmedAmount'], 6000);
    expect(
        create.containsKey('productAmount') ||
            create.containsKey('deliveryFee') ||
            create.containsKey('totalAmount'),
        isFalse);
    expect(r.charged, 6000);
    expect(r.totalAmount, 6000);
    expect(server.wallet, 14000);
    expect(server.orders.length, 1);
  });

  test('espèces : aucun débit, commande non payée', () async {
    await confirm(await prepare(), 'cash');
    expect(server.wallet, 20000);
    expect(server.orders.values.single['isPaid'], isFalse);
  });

  test(
      'prix relevé après le devis : PRICE_CHANGED, aucun débit, nouveau devis avec le nouveau total',
      () async {
    final q = await prepare();
    server.menu['a'] = 2200;
    await expectLater(
        confirm(q, 'wallet'),
        throwsA(isA<PartnerOrderException>()
            .having((e) => e.needsNewQuote, 'needsNewQuote', isTrue)
            .having((e) => e.code, 'code', 'PRICE_CHANGED')));
    expect(server.orders, isEmpty);
    expect(server.wallet, 20000);
    final fresh = await prepare();
    expect(fresh.quoteId, isNot(q.quoteId));
    expect(fresh.total, 6400);
  });

  test(
      'prix baissé après le devis : le montant ancien n\'est jamais débité sans nouvelle confirmation',
      () async {
    final q = await prepare();
    server.menu['a'] = 1800;
    await expectLater(
        confirm(q, 'wallet'),
        throwsA(isA<PartnerOrderException>()
            .having((e) => e.needsNewQuote, 'needsNewQuote', isTrue)));
    expect(server.wallet, 20000);
    expect((await prepare()).total, 5600);
  });

  test('solde insuffisant : code propre, aucun débit, aucune commande',
      () async {
    server.wallet = 100;
    final q = await prepare();
    await expectLater(
        confirm(q, 'wallet'),
        throwsA(isA<PartnerOrderException>()
            .having((e) => e.code, 'code', 'SOLDE_INSUFFISANT')));
    expect(server.orders, isEmpty);
    expect(server.wallet, 100);
  });

  test('création fermée : pas de repli historique, message explicite',
      () async {
    server.mode = 'closed';
    await expectLater(
        prepare(),
        throwsA(isA<PartnerOrderException>()
            .having((e) => e.creationClosed, 'creationClosed', isTrue)
            .having((e) => e.notInPilot, 'notInPilot', isFalse)));
  });

  test(
      'seul PARTNER_NOT_IN_PILOT autorise l’ancien parcours : FEATURE_DISABLED, code inconnu et réponse ambiguë ne le font pas',
      () async {
    server.mode = 'notInPilot';
    await expectLater(
        prepare(),
        throwsA(isA<PartnerOrderException>()
            .having((e) => e.notInPilot, 'notInPilot', isTrue)));
    for (final m in ['disabled', 'closed', 'garbage']) {
      server.mode = m;
      await expectLater(
          prepare(),
          throwsA(isA<PartnerOrderException>()
              .having((e) => e.notInPilot, 'notInPilot', isFalse)));
    }
  });

  test('CLIENT_NOT_IN_PILOT : message dédié, ni ancien parcours ni relance', () async {
    server.mode = 'clientNotInPilot';
    await expectLater(
        prepare(),
        throwsA(isA<PartnerOrderException>()
            .having((e) => e.clientNotInPilot, 'clientNotInPilot', isTrue)
            .having((e) => e.notInPilot, 'notInPilot', isFalse)
            .having((e) => e.retryable, 'retryable', isFalse)
            .having((e) => e.userMessage, 'userMessage',
                "Ce restaurant n'est pas encore disponible pour votre compte pendant la phase de test.")));
    expect(server.calls.length, 1);
    expect(server.orders, isEmpty);
    expect(server.wallet, 20000);
  });

  test('erreur réseau au devis : retryable, la nouvelle tentative fonctionne',
      () async {
    server.failBeforeServer = true;
    await expectLater(
        prepare(),
        throwsA(isA<PartnerOrderException>()
            .having((e) => e.retryable, 'retryable', isTrue)));
    expect((await prepare()).total, 6000);
  });

  test(
      'réponse perdue après traitement : renvoi avec la MÊME clé → même commande, un seul débit',
      () async {
    final q = await prepare();
    server.dropNextOrderResponse = true;
    await expectLater(
        confirm(q, 'wallet'),
        throwsA(isA<PartnerOrderException>()
            .having((e) => e.retryable, 'retryable', isTrue)));
    expect(server.wallet, 14000); // le serveur a bien traité
    expect(checkout.hasUnresolved, isTrue);
    final again = await prepare(); // même panier : même devis conservé
    expect(again.quoteId, q.quoteId);
    final r = await confirm(again, 'wallet');
    expect(r.replayed, isTrue);
    expect(server.orders.length, 1);
    expect(server.wallet, 14000);
  });

  test(
      'double appui (deux confirmations simultanées du même devis) : une seule commande, un seul débit',
      () async {
    final q = await prepare();
    final results = await Future.wait([
      confirm(q, 'wallet'),
      confirm(q, 'wallet').catchError((_) =>
          const PartnerOrderResult(orderId: '', charged: 0, replayed: false))
    ]);
    expect(server.orders.length, 1);
    expect(server.wallet, 14000);
    expect(results.where((r) => r.orderId == server.orders.keys.single).length,
        greaterThanOrEqualTo(1));
  });

  test(
      'panier modifié : nouveau devis ; mêmes choix : devis conservé et point de livraison identique',
      () async {
    final q1 = await prepare();
    var located = 0;
    final q2 = await checkout.prepare(
        sellerType: 'restaurant',
        sellerId: 'r1',
        cart: cart,
        locate: () async {
          located++;
          return (lat: 1.0, lng: 1.0);
        });
    expect(q2.quoteId, q1.quoteId);
    expect(located, 0);
    expect((await prepare({'a': 1})).quoteId, isNot(q1.quoteId));
  });

  test('devis périmé localement : nouveau devis demandé', () async {
    final q1 = await prepare();
    server.clock += 700000;
    expect((await prepare()).quoteId, isNot(q1.quoteId));
  });

  group('parcours écran (runPartnerCheckout)', () {
    Future<(PartnerCheckoutOutcome, List<String>)> pump(
      WidgetTester tester, {
      required Future<void> Function() interact,
      String method = 'wallet',
      int balance = 20000,
      Map<String, int> basket = cart,
    }) async {
      final messages = <String>[];
      late PartnerCheckoutOutcome outcome;
      await tester.pumpWidget(MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () async {
                outcome = await runPartnerCheckout(
                  context,
                  checkout: checkout,
                  sellerType: 'restaurant',
                  sellerId: 'r1',
                  cart: basket,
                  paymentMethod: method,
                  walletBalance: balance,
                  deliveryAddress: 'Ma position actuelle',
                  locate: locate,
                  notify: (m, e) => messages.add(m),
                );
              },
              child: const Text('go'),
            ),
          ),
        ),
      ));
      await tester.tap(find.text('go'));
      await tester.pumpAndSettle();
      await interact();
      return (outcome, messages);
    }

    testWidgets(
        'le client voit produits / livraison / total du serveur et peut revenir sans commande',
        (tester) async {
      final (outcome, _) = await pump(tester, interact: () async {
        expect(find.text('5500 FCFA'), findsOneWidget);
        expect(find.text('500 FCFA'), findsOneWidget);
        expect(find.text('6000 FCFA'), findsOneWidget);
        expect(find.text('Produits'), findsOneWidget);
        expect(find.text('Frais de livraison'), findsOneWidget);
        await tester.tap(find.text('Retour'));
        await tester.pumpAndSettle();
      });
      expect(outcome.status, PartnerCheckoutStatus.stopped);
      expect(server.orders, isEmpty);
      expect(server.wallet, 20000);
    });

    testWidgets('confirmation explicite : commande créée une seule fois',
        (tester) async {
      final (outcome, _) = await pump(tester, interact: () async {
        expect(
            server.calls
                .where((c) => c['name'] == 'createPartnerOrderFromQuoteCF'),
            isEmpty); // rien sans confirmation
        await tester.tap(find.text('Payer 6000 FCFA'));
        await tester.pumpAndSettle();
      });
      expect(outcome.status, PartnerCheckoutStatus.created);
      expect(outcome.total, 6000);
      expect(server.orders.length, 1);
      expect(server.wallet, 14000);
    });

    testWidgets(
        'prix modifié : le nouveau total est présenté et reconfirmé, jamais validé automatiquement',
        (tester) async {
      var step = 0;
      final (outcome, _) = await pump(tester, interact: () async {
        server.menu['a'] = 2200; // changement entre le devis et la confirmation
        await tester.tap(find.text('Payer 6000 FCFA'));
        await tester.pumpAndSettle();
        step = server.orders.length;
        expect(find.text('6400 FCFA'), findsWidgets); // nouveau devis affiché
        expect(find.text('Payer 6400 FCFA'), findsOneWidget);
        await tester.tap(find.text('Payer 6400 FCFA'));
        await tester.pumpAndSettle();
      });
      expect(step, 0); // aucune commande avant la seconde confirmation
      expect(outcome.status, PartnerCheckoutStatus.created);
      expect(server.wallet, 20000 - 6400);
      expect(server.orders.length, 1);
    });

    testWidgets(
        'solde insuffisant : message, aucune boîte de confirmation, aucune commande',
        (tester) async {
      final (outcome, messages) =
          await pump(tester, balance: 1000, interact: () async {});
      expect(outcome.status, PartnerCheckoutStatus.stopped);
      expect(messages.single, contains('Solde insuffisant'));
      expect(find.text('Confirmer le montant'), findsNothing);
      expect(server.orders, isEmpty);
    });

    testWidgets(
        'solde insuffisant côté serveur (solde local périmé) : message clair, aucun débit',
        (tester) async {
      server.wallet = 100;
      final (outcome, messages) = await pump(tester, interact: () async {
        await tester.tap(find.text('Payer 6000 FCFA'));
        await tester.pumpAndSettle();
      });
      expect(outcome.status, PartnerCheckoutStatus.stopped);
      expect(messages.single, 'Solde wallet insuffisant');
      expect(server.wallet, 100);
    });

    testWidgets(
        'création désactivée : arrêt avec message, jamais de repli sur le parcours historique',
        (tester) async {
      server.mode = 'closed';
      final (outcome, messages) = await pump(tester, interact: () async {});
      expect(outcome.status, PartnerCheckoutStatus.stopped);
      expect(messages.single, contains('momentanément indisponibles'));
    });

    testWidgets('restaurant pilote, création ouverte : devis puis commande v2',
        (tester) async {
      final (outcome, _) = await pump(tester, interact: () async {
        await tester.tap(find.text('Confirmer 6000 FCFA'));
        await tester.pumpAndSettle();
      }, method: 'cash');
      expect(outcome.status, PartnerCheckoutStatus.created);
      expect(server.orders.length, 1);
    });

    testWidgets(
        'restaurant hors pilote (PARTNER_NOT_IN_PILOT confirmé) : ancien parcours conservé, aucune commande v2',
        (tester) async {
      server.mode = 'notInPilot';
      final (outcome, messages) = await pump(tester, interact: () async {});
      expect(outcome.status, PartnerCheckoutStatus.useLegacy);
      expect(messages, isEmpty);
      expect(server.orders, isEmpty);
    });

    testWidgets(
        'CLIENT_NOT_IN_PILOT : message explicite, aucun repli historique, aucune commande, aucun débit, un seul appel',
        (tester) async {
      server.mode = 'clientNotInPilot';
      final (outcome, messages) = await pump(tester, interact: () async {});
      expect(outcome.status, PartnerCheckoutStatus.stopped);
      expect(messages, [
        "Ce restaurant n'est pas encore disponible pour votre compte pendant la phase de test."
      ]);
      expect(server.calls.length, 1);
      expect(server.orders, isEmpty);
      expect(server.wallet, 20000);
    });

    for (final m in ['disabled', 'garbage']) {
      testWidgets(
          'réponse « $m » (fonction désactivée / configuration illisible / code inconnu) : commande bloquée, aucun repli historique, aucun débit',
          (tester) async {
        server.mode = m;
        final (outcome, messages) = await pump(tester, interact: () async {});
        expect(outcome.status, PartnerCheckoutStatus.stopped);
        expect(messages.length, 1);
        expect(server.orders, isEmpty);
        expect(server.wallet, 20000);
      });
    }

    testWidgets(
        'erreur réseau au devis : commande bloquée (pas de repli historique), nouvelle tentative possible',
        (tester) async {
      server.failBeforeServer = true;
      final (first, messages) = await pump(tester, interact: () async {});
      expect(first.status, PartnerCheckoutStatus.stopped);
      expect(messages.single, contains('Connexion instable'));
      expect(server.orders, isEmpty);
      final (second, _) = await pump(tester, interact: () async {
        await tester.tap(find.text('Payer 6000 FCFA'));
        await tester.pumpAndSettle();
      });
      expect(second.status, PartnerCheckoutStatus.created);
      expect(server.orders.length, 1);
    });

    testWidgets('réponse de succès sans devis exploitable : commande bloquée',
        (tester) async {
      PartnerOrderService.callFunction = (name, data) async => {
            'success': true,
            'data': {'total': 'x'}
          };
      final (outcome, messages) = await pump(tester, interact: () async {});
      expect(outcome.status, PartnerCheckoutStatus.stopped);
      expect(messages, isNotEmpty);
    });

    testWidgets('erreur réseau puis nouvelle tentative : une seule commande',
        (tester) async {
      server.dropNextOrderResponse = true;
      final (first, messages) = await pump(tester, interact: () async {
        await tester.tap(find.text('Payer 6000 FCFA'));
        await tester.pumpAndSettle();
      });
      expect(first.status, PartnerCheckoutStatus.stopped);
      expect(messages.single, contains('Connexion instable'));
      expect(server.orders.length, 1); // traitée côté serveur, réponse perdue
      expect(checkout.hasUnresolved, isTrue);

      // Le client modifie son panier puis recommande : l'issue inconnue est d'abord retrouvée, pas de seconde commande.
      final (second, _) =
          await pump(tester, basket: const {'a': 1}, interact: () async {});
      expect(second.status, PartnerCheckoutStatus.created);
      expect(server.orders.length, 1);
      expect(server.wallet, 14000);
    });
  });

  group('écran restaurant', () {
    // L'écran dépend de Firebase (flux Firestore, GPS) : non montable ici. Gardes statiques sur le code de _order().
    String orderBody() {
      final src = File('lib/screens/restaurant/restaurant_menu.dart')
          .readAsStringSync();
      final start = src.indexOf('Future<void> _order() async {');
      final end =
          src.indexOf('Future<({double lat, double lng})> _locateClient()');
      expect(start, greaterThan(0));
      expect(end, greaterThan(start));
      return src.substring(start, end);
    }

    test(
        'le chemin v2 de _order() ne contient aucune écriture directe ni calcul de montant',
        () {
      final body = orderBody();
      for (final forbidden in [
        'runTransaction',
        'createOrder',
        "collection('orders')",
        "'wallet':",
        '_totalPrice',
        'OrderModel('
      ]) {
        expect(body.contains(forbidden), isFalse,
            reason: 'interdit dans _order(): $forbidden');
      }
      expect(body.contains('runPartnerCheckout'), isTrue);
    });

    test(
        'client anonyme ou absent : retour AVANT tout devis et sans ancien parcours ; l’ancien parcours n’est atteint que par useLegacy',
        () {
      final body = orderBody();
      final anon = body.indexOf('user == null || user.isAnonymous');
      final ret = body.indexOf('return;', anon);
      final run = body.indexOf('runPartnerCheckout');
      expect(anon, greaterThan(0));
      expect(ret, lessThan(run));
      expect(body.substring(anon, run).contains('legacy = true'), isFalse);
      expect(RegExp(r'legacy = true').allMatches(body).length, 1);
      expect(body.indexOf('legacy = true'),
          greaterThan(body.indexOf('PartnerCheckoutStatus.useLegacy')));
    });
  });
}
