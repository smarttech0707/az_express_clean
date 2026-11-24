import 'dart:io';

import 'package:az_express/services/delivery_quote_service.dart';

/// Faux serveur reproduisant le CONTRAT de quoteDeliveryCF / createOrderFromQuoteCF
/// (mêmes codes de retour que functions/deliveryQuote.js) pour tester le client
/// sans réseau. Il compte les appels et les débits.
class FakeQuoteServer implements DeliveryQuoteGateway {
  int wallet;
  int officialStandard = 500;
  int officialExpress = 1000;
  int ttlMs = 600000;
  DateTime Function() now;

  final Map<String, Map<String, dynamic>> quotes = {};
  final Map<String, Map<String, dynamic>> orders = {};
  int quoteCalls = 0;
  int createCalls = 0;
  int debits = 0;
  int seq = 0;

  /// Nombre d'appels `createOrderFromQuoteCF` dont la réponse est « perdue »
  /// APRÈS exécution côté serveur (le serveur a créé la commande, pas le client).
  int loseResponsesAfterExecution = 0;

  /// Erreurs réseau avant exécution.
  int failBeforeExecution = 0;

  FakeQuoteServer({this.wallet = 5000, DateTime Function()? clock})
      : now = clock ?? DateTime.now;

  int priceFor(String mode) =>
      mode == 'express' ? officialExpress : officialStandard;

  @override
  Future<Map<String, dynamic>> call(
      String name, Map<String, dynamic> p) async {
    if (name == 'quoteDeliveryCF') {
      quoteCalls++;
      final mode = p['mode'] as String;
      final id = 'q${++seq}';
      final exp = now().add(Duration(milliseconds: ttlMs));
      quotes[id] = {
        'status': 'open',
        'amount': priceFor(mode),
        'mode': mode,
        'service': p['serviceType'],
        'dest': p['destination'],
        'pickup': p['pickup'],
        'expiresAtMs': exp.millisecondsSinceEpoch,
      };
      return {
        'success': true,
        'data': {
          'quoteId': id,
          'amount': priceFor(mode),
          'expiresAtMs': exp.millisecondsSinceEpoch,
          'tariffVersion': 1,
          'isNight': false,
        },
      };
    }
    createCalls++;
    if (failBeforeExecution > 0) {
      failBeforeExecution--;
      throw const SocketException('hors ligne');
    }
    final res = _create(p);
    if (loseResponsesAfterExecution > 0) {
      loseResponsesAfterExecution--;
      throw const SocketException('réponse perdue');
    }
    return res;
  }

  Map<String, dynamic> _fail(String code, [Map<String, dynamic>? data]) => {
        'success': false,
        'code': code,
        'error': code,
        'message': code,
        'data': data,
      };

  Map<String, dynamic> _create(Map<String, dynamic> p) {
    final q = quotes[p['quoteId']];
    if (q == null) return _fail('QUOTE_NOT_FOUND');
    if (q['status'] == 'used') {
      final o = orders[q['orderId']]!;
      return {
        'success': true,
        'data': {'orderId': q['orderId'], 'charged': o['charged'], 'replayed': true},
      };
    }
    if (!['wallet', 'cash'].contains(p['paymentMethod'])) {
      return _fail('PAYMENT_METHOD_UNSUPPORTED');
    }
    if ((q['expiresAtMs'] as int) <= now().millisecondsSinceEpoch) {
      return _fail('QUOTE_EXPIRED');
    }
    if (p['mode'] != q['mode'] ||
        p['serviceType'] != q['service'] ||
        p['destination']['lat'] != q['dest']['lat'] ||
        p['destination']['lng'] != q['dest']['lng']) {
      return _fail('QUOTE_MISMATCH');
    }
    final current = priceFor(q['mode'] as String);
    if (current > (q['amount'] as int)) {
      return _fail('PRICE_CHANGED',
          {'quotedAmount': q['amount'], 'currentAmount': current});
    }
    final fee = current < (q['amount'] as int) ? current : q['amount'] as int;
    final shopping = (p['shoppingBudget'] as int?) ?? 0;
    final total = fee + shopping;
    if (p['paymentMethod'] == 'wallet') {
      if (wallet < total) return _fail('SOLDE_INSUFFISANT');
      wallet -= total;
      debits++;
    }
    final id = 'o${++seq}';
    orders[id] = {'charged': p['paymentMethod'] == 'wallet' ? total : 0, 'fee': fee};
    q['status'] = 'used';
    q['orderId'] = id;
    return {
      'success': true,
      'data': {'orderId': id, 'charged': orders[id]!['charged']},
    };
  }
}
