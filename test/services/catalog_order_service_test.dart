import 'package:cloud_functions/cloud_functions.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:az_express/services/catalog_order_service.dart';
import 'package:az_express/widgets/catalog_quote_dialog.dart';

/// Faux serveur : même contrat que quoteCatalogCF / createCatalogOrderFromQuoteCF (prix calculés ici, jamais lus
/// dans la requête ; rejeu d'un devis utilisé = même commande). Aucun accès réseau ni Firebase.
class FakeCatalogServer {
  int wallet;
  int clock = 1000000;
  final quotes = <String, Map<String, dynamic>>{};
  final orders = <String, Map<String, dynamic>>{};
  final calls = <Map<String, dynamic>>[];
  int priceBump = 0;
  // Coupe de réseau simulée : la requête est TRAITÉE par le serveur mais la réponse est perdue.
  bool dropNextOrderResponse = false;
  bool failBeforeServer = false;
  int _seq = 0;

  FakeCatalogServer({this.wallet = 10000});

  static const _colis = {
    'Colis standard': 500, 'Cadeau emballé': 700, 'Document / Enveloppe': 300, 'Gros colis': 1000,
  };
  static const _eau = {'eau_500': 200, 'casier_eau': 3500, 'coca_33': 500, 'energie': 800};

  Map<String, dynamic> _fail(String code, String msg, [Map<String, dynamic> data = const {}]) =>
      {'success': false, 'error': code, 'code': code, 'message': msg, 'data': data};

  Future<Map<String, dynamic>> call(String name, Map<String, dynamic> d) async {
    calls.add({'name': name, ...d});
    if (failBeforeServer) {
      failBeforeServer = false;
      throw FirebaseFunctionsException(message: 'offline', code: 'unavailable');
    }
    if (name == 'quoteCatalogCF') return _quote(d);
    final res = _order(d);
    if (dropNextOrderResponse) {
      dropNextOrderResponse = false;
      throw FirebaseFunctionsException(message: 'timeout', code: 'deadline-exceeded');
    }
    return res;
  }

  Map<String, dynamic> _quote(Map<String, dynamic> d) {
    var budget = 0, shopping = 0;
    final lines = <Map<String, dynamic>>[];
    switch (d['service']) {
      case 'colis':
        final base = _colis[d['colisType']];
        if (base == null) return _fail('INVALID_ITEM', 'Type de colis invalide');
        budget = base + (d['fragile'] == true ? 200 : 0);
        lines.add({'label': d['colisType'], 'amount': budget});
        break;
      case 'blanchisserie':
        final q = d['quantity'];
        if (q is! int || q < 1) return _fail('INVALID_QUANTITY', 'Quantité invalide');
        if (q > 30) return _fail('QUANTITY_TOO_HIGH', 'Maximum 30 kg par commande');
        budget = q * 1000;
        lines.add({'label': '${d['serviceType']} — $q kg', 'amount': budget});
        break;
      case 'eau_boissons':
        for (final it in (d['items'] as List)) {
          final qty = it['qty'] as int;
          if (qty > 20 || (it['id'] == 'casier_eau' && qty > 5)) {
            return _fail('QUANTITY_TOO_HIGH', 'Quantité trop élevée');
          }
          shopping += qty * _eau[it['id']]!;
        }
        if (shopping > 50000) return _fail('BASKET_TOO_HIGH', 'Panier limité à 50000 FCFA');
        budget = 500;
        lines.add({'label': 'Livraison', 'amount': 500});
        break;
      default:
        return _fail('SERVICE_NOT_SUPPORTED', 'Service non pris en charge');
    }
    final id = 'q${++_seq}';
    final total = budget + shopping;
    quotes[id] = {
      'service': d['service'], 'params': Map<String, dynamic>.from(d)..remove('service'),
      'amount': total, 'status': 'open', 'expiresAtMs': clock + 600000,
    };
    return {
      'success': true,
      'data': {
        'quoteId': id, 'budget': budget, 'shoppingBudget': shopping, 'total': total,
        'lines': lines, 'expiresAtMs': clock + 600000,
      },
    };
  }

  Map<String, dynamic> _order(Map<String, dynamic> d) {
    final q = quotes[d['quoteId']];
    if (q == null) return _fail('QUOTE_NOT_FOUND', 'Devis introuvable');
    if (q['status'] == 'used') {
      return {'success': true, 'data': {'orderId': q['orderId'], 'charged': q['charged'], 'replayed': true}};
    }
    if ((q['expiresAtMs'] as int) <= clock) return _fail('QUOTE_EXPIRED', 'Devis expiré');
    final current = (q['amount'] as int) + priceBump;
    if (current > (q['amount'] as int)) {
      return _fail('PRICE_CHANGED', 'Le tarif a changé', {'quotedAmount': q['amount'], 'currentAmount': current});
    }
    final total = q['amount'] as int;
    if (d['paymentMethod'] == 'wallet' && wallet < total) return _fail('SOLDE_INSUFFISANT', 'SOLDE_INSUFFISANT');
    if (d['paymentMethod'] == 'wallet') wallet -= total;
    final orderId = 'o${++_seq}';
    orders[orderId] = {
      'service': q['service'], 'budget': total, 'paymentMethod': d['paymentMethod'],
      'isPaid': d['paymentMethod'] == 'wallet', // espèces : jamais marqué payé
    };
    q['status'] = 'used';
    q['orderId'] = orderId;
    q['charged'] = d['paymentMethod'] == 'wallet' ? total : 0;
    return {'success': true, 'data': {'orderId': orderId, 'charged': q['charged']}};
  }
}

void main() {
  late FakeCatalogServer server;
  late CatalogCheckout checkout;

  setUp(() {
    server = FakeCatalogServer();
    checkout = CatalogCheckout();
    CatalogOrderService.callFunction = server.call;
    CatalogOrderService.nowMs = () => server.clock;
  });

  const colisChoices = {'colisType': 'Colis standard', 'fragile': false};
  const colisDetails = {'recipientName': 'Kouassi', 'recipientAddress': 'Quartier test'};

  Future<CatalogOrderResult> order(String method, Map<String, dynamic> choices,
      {String service = 'colis', Map<String, dynamic> details = colisDetails}) async {
    final q = await checkout.prepare(service, choices);
    return checkout.confirm(quote: q, paymentMethod: method, choices: choices, details: details);
  }

  test('commande normale : le montant vient du serveur et la requête ne contient aucun prix', () async {
    final q = await checkout.prepare('colis', colisChoices);
    expect(q.total, 500);
    final r = await checkout.confirm(quote: q, paymentMethod: 'wallet', choices: colisChoices, details: colisDetails);
    expect(r.charged, 500);
    expect(server.wallet, 9500);
    for (final c in server.calls) {
      for (final k in ['budget', 'shoppingBudget', 'total', 'amount', 'price', 'isPaid']) {
        expect(c.containsKey(k), isFalse, reason: '${c['name']} ne doit pas envoyer $k');
      }
    }
    expect(server.calls.last['confirmedAmount'], 500);
  });

  test('Document / Enveloppe : 300 FCFA, commande wallet débitée de 300', () async {
    final r = await order('wallet', {'colisType': 'Document / Enveloppe', 'fragile': false});
    expect(r.charged, 300);
    expect(server.wallet, 9700);
  });

  test('prix manipulé côté serveur : montant relevé → PRICE_CHANGED, aucun débit, nouveau devis requis', () async {
    final q = await checkout.prepare('colis', colisChoices);
    server.priceBump = 200;
    await expectLater(
      checkout.confirm(quote: q, paymentMethod: 'wallet', choices: colisChoices, details: colisDetails),
      throwsA(isA<CatalogException>().having((e) => e.needsNewQuote, 'needsNewQuote', isTrue)),
    );
    expect(server.wallet, 10000);
    expect(checkout.pending, isNull);
  });

  test('quantités au-dessus des plafonds et panier > 50 000 : refusés par le serveur, sans commande', () async {
    final cases = <List<dynamic>>[
      ['blanchisserie', {'serviceType': 'Pressing', 'quantity': 31}, 'QUANTITY_TOO_HIGH'],
      ['eau_boissons', {'items': [{'id': 'eau_500', 'qty': 21}]}, 'QUANTITY_TOO_HIGH'],
      ['eau_boissons', {'items': [{'id': 'casier_eau', 'qty': 6}]}, 'QUANTITY_TOO_HIGH'],
    ];
    for (final c in cases) {
      try {
        await checkout.prepare(c[0] as String, c[1] as Map<String, dynamic>);
        fail('devait être refusé');
      } on CatalogException catch (e) {
        expect(e.code, anyOf(c[2] as String, 'INVALID_ITEM'));
        expect(e.retryable, isFalse);
      }
    }
    expect(server.orders, isEmpty);
    expect(server.wallet, 10000);
  });

  test('panier à 3 casiers + articles dépassant 50 000 FCFA → BASKET_TOO_HIGH', () async {
    // 5 casiers (17 500) + 20 énergisants (16 000) + 20 cocas (10 000) + 20 eaux (4 000) = 47 500 → accepté ;
    // le plafond se déclenche au-delà.
    final items = [
      {'id': 'casier_eau', 'qty': 5}, {'id': 'energie', 'qty': 20}, {'id': 'coca_33', 'qty': 20}, {'id': 'eau_500', 'qty': 20},
    ];
    expect((await checkout.prepare('eau_boissons', {'items': items})).total, 48000);
    server.quotes.clear();
    checkout.reset();
    await expectLater(
      checkout.prepare('eau_boissons', {'items': [...items, {'id': 'casier_eau', 'qty': 5}]}),
      throwsA(isA<CatalogException>().having((e) => e.code, 'code', 'BASKET_TOO_HIGH')),
    );
  });

  test('devis expiré : refusé sans débit ; localement périmé → nouveau devis demandé', () async {
    final q = await checkout.prepare('colis', colisChoices);
    server.clock += 700000;
    await expectLater(
      checkout.confirm(quote: q, paymentMethod: 'wallet', choices: colisChoices, details: colisDetails),
      throwsA(isA<CatalogException>().having((e) => e.code, 'code', 'QUOTE_EXPIRED')),
    );
    expect(server.wallet, 10000);
    final q2 = await checkout.prepare('colis', colisChoices);
    expect(q2.quoteId, isNot(q.quoteId));
    // Devis proche de l'expiration : jamais réutilisé côté application.
    server.clock += 590000;
    expect((await checkout.prepare('colis', colisChoices)).quoteId, isNot(q2.quoteId));
  });

  test('double validation : le même devis confirmé deux fois → une seule commande, un seul débit', () async {
    final q = await checkout.prepare('colis', colisChoices);
    final a = await CatalogOrderService.placeOrder(quote: q, paymentMethod: 'wallet', choices: colisChoices, details: colisDetails);
    final b = await CatalogOrderService.placeOrder(quote: q, paymentMethod: 'wallet', choices: colisChoices, details: colisDetails);
    expect(b.orderId, a.orderId);
    expect(b.replayed, isTrue);
    expect(server.orders.length, 1);
    expect(server.wallet, 9500);
  });

  test('coupure réseau après traitement serveur : réessai avec la MÊME clé → même commande, aucun second débit', () async {
    final q = await checkout.prepare('colis', colisChoices);
    server.dropNextOrderResponse = true;
    CatalogException? failure;
    try {
      await checkout.confirm(quote: q, paymentMethod: 'wallet', choices: colisChoices, details: colisDetails);
    } on CatalogException catch (e) {
      failure = e;
    }
    expect(failure?.code, 'NETWORK');
    expect(failure?.retryable, isTrue);
    expect(server.wallet, 9500, reason: 'le serveur a traité la commande une fois');
    // Le devis en cours est conservé : la reprise réutilise le même identifiant.
    final again = await checkout.prepare('colis', colisChoices);
    expect(again.quoteId, q.quoteId);
    final r = await checkout.confirm(quote: again, paymentMethod: 'wallet', choices: colisChoices, details: colisDetails);
    expect(r.replayed, isTrue);
    expect(server.orders.length, 1);
    expect(server.wallet, 9500);
  });

  test('coupure avant d\'atteindre le serveur : réessai sans effet double', () async {
    final q = await checkout.prepare('colis', colisChoices);
    server.failBeforeServer = true;
    await expectLater(
      checkout.confirm(quote: q, paymentMethod: 'wallet', choices: colisChoices, details: colisDetails),
      throwsA(isA<CatalogException>().having((e) => e.retryable, 'retryable', isTrue)),
    );
    expect(server.orders, isEmpty);
    final r = await checkout.confirm(quote: q, paymentMethod: 'wallet', choices: colisChoices, details: colisDetails);
    expect(r.replayed, isFalse);
    expect(server.orders.length, 1);
    expect(server.wallet, 9500);
  });

  test('espèces : aucun débit et la commande n\'est jamais marquée payée', () async {
    final r = await order('cash', colisChoices);
    expect(r.charged, 0);
    expect(server.wallet, 10000);
    expect(server.orders[r.orderId]!['isPaid'], isFalse);
  });

  test('wallet : commande marquée payée, solde insuffisant → refus sans commande', () async {
    final r = await order('wallet', {'serviceType': 'Pressing', 'quantity': 2}, service: 'blanchisserie');
    expect(server.orders[r.orderId]!['isPaid'], isTrue);
    expect(server.wallet, 8000);
    server.wallet = 100;
    await expectLater(
      order('wallet', colisChoices),
      throwsA(isA<CatalogException>().having((e) => e.code, 'code', 'SOLDE_INSUFFISANT')),
    );
    expect(server.orders.length, 1);
  });

  test('changement de choix : nouveau devis ; mêmes choix : devis conservé', () async {
    final a = await checkout.prepare('colis', colisChoices);
    expect((await checkout.prepare('colis', colisChoices)).quoteId, a.quoteId);
    final b = await checkout.prepare('colis', {'colisType': 'Gros colis', 'fragile': false});
    expect(b.quoteId, isNot(a.quoteId));
    expect(b.total, 1000);
  });

  group('parcours écran (runCatalogCheckout)', () {
    Future<(bool, List<String>)> pump(WidgetTester tester, {required Future<void> Function() interact, String method = 'wallet', int balance = 10000}) async {
      final messages = <String>[];
      var result = false;
      await tester.pumpWidget(MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () async {
                result = await runCatalogCheckout(
                  context,
                  checkout: checkout,
                  service: 'colis',
                  paymentMethod: method,
                  walletBalance: balance,
                  choices: colisChoices,
                  details: colisDetails,
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
      return (result, messages);
    }

    testWidgets('le client voit le montant calculé par le serveur et peut revenir en arrière sans commande', (tester) async {
      final (result, _) = await pump(tester, interact: () async {
        expect(find.text('500 FCFA'), findsWidgets);
        await tester.tap(find.text('Retour'));
        await tester.pumpAndSettle();
      });
      expect(result, isFalse);
      expect(server.orders, isEmpty);
      expect(server.wallet, 10000);
    });

    testWidgets('confirmation : commande créée une seule fois', (tester) async {
      final (result, _) = await pump(tester, interact: () async {
        await tester.tap(find.text('Payer 500 FCFA'));
        await tester.pumpAndSettle();
      });
      expect(result, isTrue);
      expect(server.orders.length, 1);
      expect(server.wallet, 9500);
    });

    testWidgets('tarif relevé entre-temps : nouvelle confirmation avec le nouveau montant, jamais de débit silencieux', (tester) async {
      var step = 0;
      final (result, _) = await pump(tester, interact: () async {
        server.priceBump = 200; // le tarif monte après l'affichage du premier devis
        await tester.tap(find.text('Payer 500 FCFA'));
        await tester.pumpAndSettle();
        // Deuxième boîte : le serveur propose un nouveau devis (même tarif de base) avec avertissement.
        expect(find.textContaining('Le tarif a changé'), findsOneWidget);
        step++;
        server.priceBump = 0;
        await tester.tap(find.text('Retour'));
        await tester.pumpAndSettle();
      });
      expect(step, 1);
      expect(result, isFalse);
      expect(server.orders, isEmpty);
      expect(server.wallet, 10000);
    });

    testWidgets('solde insuffisant : message, aucune boîte de confirmation, aucune commande', (tester) async {
      final (result, messages) = await pump(tester, balance: 100, interact: () async {});
      expect(result, isFalse);
      expect(messages.single, contains('Solde insuffisant'));
      expect(find.text('Confirmer le montant'), findsNothing);
      expect(server.orders, isEmpty);
    });

    testWidgets('espèces : mention du règlement au livreur, commande non payée', (tester) async {
      final (result, _) = await pump(tester, method: 'cash', interact: () async {
        expect(find.text('À régler en espèces au livreur.'), findsOneWidget);
        await tester.tap(find.text('Confirmer'));
        await tester.pumpAndSettle();
      });
      expect(result, isTrue);
      expect(server.orders.values.single['isPaid'], isFalse);
      expect(server.wallet, 10000);
    });
  });
}
