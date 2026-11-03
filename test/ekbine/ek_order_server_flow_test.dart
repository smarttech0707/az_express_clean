import 'package:cloud_functions/cloud_functions.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:az_express/ekbine/providers/ek_provider.dart';
import 'package:az_express/ekbine/services/ek_service.dart';

/// Faux serveur E-Kbine : reproduit le contrat de ekCreateOrderCF / ekCancelOrderCF (idempotence par clé,
/// remboursement unique, refus d'une commande exécutée). La logique serveur elle-même est prouvée dans
/// functions/test/ekbineOrders.test.js et sur l'émulateur ; ici on prouve le comportement du CLIENT : même clé
/// réutilisée après une coupure, aucun second appel pendant un envoi, messages d'erreur.
class FakeServer {
  final Map<String, String> orderByKey = {};
  final Map<String, String> status = {};
  int wallet = 5000;
  int debits = 0;
  int refunds = 0;
  final List<String> keysSeen = [];
  final List<String> calls = [];
  bool dropResponseOnce = false; // le serveur traite, mais la réponse n'arrive pas
  Map<String, dynamic>? forcedCreateAnswer;
  Object? failOnceWith; // exception levée avant tout effet serveur

  Future<Map<String, dynamic>> call(String name, Map<String, dynamic> data) async {
    calls.add(name);
    if (failOnceWith != null) {
      final e = failOnceWith!;
      failOnceWith = null;
      throw e;
    }
    if (name == 'ekCreateOrderCF') return _create(data);
    if (name == 'ekCancelOrderCF') return _cancel(data);
    throw StateError('appel inattendu $name');
  }

  Map<String, dynamic> _create(Map<String, dynamic> d) {
    final key = d['idempotencyKey'] as String;
    keysSeen.add(key);
    if (forcedCreateAnswer != null) return forcedCreateAnswer!;
    var already = true;
    var id = orderByKey[key];
    if (id == null) {
      final amount = d['amount'] as int;
      if (d['paymentMethod'] == 'wallet' && wallet < amount) {
        return {'success': false, 'code': 'INSUFFICIENT_BALANCE', 'message': 'Solde insuffisant dans votre wallet', 'data': null};
      }
      already = false;
      id = 'ek_${(orderByKey.length + 1).toString().padLeft(24, '0')}';
      orderByKey[key] = id;
      status[id] = 'pending';
      if (d['paymentMethod'] == 'wallet') {
        wallet -= amount;
        debits++;
      }
    }
    if (dropResponseOnce) {
      dropResponseOnce = false;
      throw FirebaseFunctionsException(message: 'réseau coupé', code: 'unavailable');
    }
    return {'success': true, 'message': 'ok', 'data': {'orderId': id, 'alreadyDone': already}};
  }

  Map<String, dynamic> _cancel(Map<String, dynamic> d) {
    final id = d['orderId'] as String;
    final st = status[id];
    if (st == 'cancelled') return {'success': true, 'message': 'Commande déjà annulée', 'data': {'alreadyDone': true}};
    if (st != 'pending' && st != 'awaiting_deposit') {
      return {'success': false, 'code': 'ORDER_NOT_CANCELLABLE', 'message': 'Cette commande est déjà en cours d\'exécution et ne peut plus être annulée', 'data': null};
    }
    if (dropResponseOnce) {
      dropResponseOnce = false;
      status[id] = 'cancelled';
      wallet += 1000;
      refunds++;
      throw FirebaseFunctionsException(message: 'réseau coupé', code: 'deadline-exceeded');
    }
    status[id] = 'cancelled';
    wallet += 1000;
    refunds++;
    return {'success': true, 'message': 'Commande annulée', 'data': {'alreadyDone': false}};
  }
}

final _idPattern = RegExp(r'^(ek_[0-9a-f]{24}|[A-Za-z0-9]{20})$');

Future<String?> place(EkProvider p, {int amount = 1000, String method = 'wallet'}) => p.placeOrder(
      clientId: 'c1',
      clientName: 'Client',
      clientPhone: '0700000000',
      operator: 'orange',
      serviceId: 'credit',
      serviceLabel: 'Crédit Orange',
      beneficiaryNumber: '0700000000',
      amount: amount,
      paymentMethod: method,
    );

void main() {
  late FakeServer server;
  late EkProvider provider;

  setUp(() {
    server = FakeServer();
    EkService.callFunction = server.call;
    provider = EkProvider();
  });

  group('création', () {
    test('création réussie : identifiant serveur reconnu par le formulaire, un seul débit', () async {
      final r = await place(provider);
      expect(_idPattern.hasMatch(r!), isTrue);
      expect(server.debits, 1);
      expect(server.wallet, 4000);
    });

    test('double validation : le second appui pendant l\'envoi n\'atteint pas le serveur', () async {
      final first = place(provider);
      final second = await place(provider);
      expect(_idPattern.hasMatch(second!), isFalse);
      expect(second, contains('déjà en cours'));
      final id = await first;
      expect(_idPattern.hasMatch(id!), isTrue);
      expect(server.calls.length, 1);
      expect(server.debits, 1);
    });

    test('coupure réseau APRÈS création serveur : message, puis réessai = même commande, ni 2e débit ni 2e commande', () async {
      server.dropResponseOnce = true;
      final cut = await place(provider);
      expect(_idPattern.hasMatch(cut!), isFalse, reason: 'jamais un faux identifiant');
      expect(cut, contains('sans risque de double paiement'));
      expect(server.debits, 1, reason: 'le serveur avait déjà débité');

      final retry = await place(provider);
      expect(_idPattern.hasMatch(retry!), isTrue, reason: 'commande déjà créée récupérée');
      expect(server.keysSeen.toSet().length, 1, reason: 'même clé d\'idempotence réutilisée');
      expect(server.orderByKey.length, 1);
      expect(server.debits, 1);
      expect(server.wallet, 4000);
    });

    test('coupure AVANT le serveur : réessai sûr avec la même clé, un seul débit à la fin', () async {
      server.failOnceWith = FirebaseFunctionsException(message: 'hors ligne', code: 'unavailable');
      expect(_idPattern.hasMatch((await place(provider))!), isFalse);
      expect(server.debits, 0);
      expect(_idPattern.hasMatch((await place(provider))!), isTrue);
      expect(server.debits, 1);
    });

    test('erreur réseau inconnue (non Firebase) : message de réessai sans risque', () async {
      server.failOnceWith = Exception('socket');
      final r = await place(provider);
      expect(r, contains('sans risque de double paiement'));
      expect(_idPattern.hasMatch((await place(provider))!), isTrue);
      expect(server.debits, 1);
    });

    test('paiement non confirmé / refus métier : aucune commande, nouvelle clé au prochain essai', () async {
      server.forcedCreateAnswer = {
        'success': false, 'code': 'PAYMENT_NOT_CONFIRMED', 'message': 'Paiement non confirmé', 'data': null,
      };
      final r = await place(provider, method: 'orange_money');
      expect(r, 'Paiement non confirmé');
      expect(server.orderByKey, isEmpty);
      expect(server.debits, 0);
      server.forcedCreateAnswer = null;
      await place(provider, method: 'orange_money');
      expect(server.keysSeen.toSet().length, 2, reason: 'un refus définitif termine la tentative');
    });

    test('solde insuffisant : message serveur, aucun débit', () async {
      server.wallet = 100;
      final r = await place(provider);
      expect(r, 'Solde insuffisant dans votre wallet');
      expect(server.debits, 0);
    });

    test('refus définitif du serveur (permission) : message du serveur, nouvelle clé ensuite', () async {
      server.failOnceWith = FirebaseFunctionsException(message: 'Compte indisponible', code: 'permission-denied');
      expect(await place(provider), 'Compte indisponible');
      await place(provider);
      expect(server.keysSeen.toSet().length, 1, reason: 'le premier appel n\'a pas atteint la logique de création');
      expect(server.debits, 1);
    });

    test('commande modifiée entre deux essais : nouvelle intention, nouvelle clé', () async {
      server.dropResponseOnce = true;
      await place(provider, amount: 1000);
      await place(provider, amount: 2000);
      expect(server.keysSeen.toSet().length, 2);
    });
  });

  group('annulation', () {
    Future<String> created() async => (await place(provider))!;

    test('annulation réussie : remboursement unique', () async {
      final id = await created();
      expect(await EkService.cancelOrder(id, 'erreur'), isNull);
      expect(server.refunds, 1);
      expect(server.wallet, 5000);
    });

    test('erreur réseau pendant l\'annulation : message, puis réessai sans second remboursement', () async {
      final id = await created();
      server.dropResponseOnce = true;
      final cut = await EkService.cancelOrder(id, 'x');
      expect(cut, ekCancelNetworkMessage);
      expect(server.refunds, 1, reason: 'le serveur avait déjà remboursé');
      expect(await EkService.cancelOrder(id, 'x'), isNull, reason: 'déjà annulée = succès idempotent');
      expect(server.refunds, 1);
      expect(server.wallet, 5000);
    });

    test('coupure avant le serveur : message de réessai, aucun effet', () async {
      final id = await created();
      server.failOnceWith = FirebaseFunctionsException(message: 'hors ligne', code: 'unavailable');
      expect(await EkService.cancelOrder(id, 'x'), ekCancelNetworkMessage);
      expect(server.refunds, 0);
    });

    test('commande déjà annulée : succès, pas de remboursement supplémentaire', () async {
      final id = await created();
      await EkService.cancelOrder(id, 'x');
      expect(await EkService.cancelOrder(id, 'x'), isNull);
      expect(server.refunds, 1);
    });

    test('commande déjà exécutée : refus affiché, aucun remboursement', () async {
      final id = await created();
      server.status[id] = 'in_progress';
      final r = await EkService.cancelOrder(id, 'x');
      expect(r, contains('déjà en cours d\'exécution'));
      expect(server.refunds, 0);
      expect(server.wallet, 4000);
    });

    test('refus d\'autorisation du serveur : message du serveur', () async {
      server.failOnceWith = FirebaseFunctionsException(message: 'Non autorisé', code: 'permission-denied');
      expect(await EkService.cancelOrder('ek_x', 'x'), 'Non autorisé');
    });
  });
}
