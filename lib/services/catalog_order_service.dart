import 'dart:convert';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:flutter/foundation.dart';

/// Plafonds provisoires AFFICHÉS à l'écran (aide à la saisie). Le serveur reste seul juge : voir `catalogTariff.js`.
class CatalogUiLimits {
  static const blanchisserieMaxKg = 30;
  static const eauMaxPerProduct = 20;
  static const eauMaxCasiers = 5;
  static const eauMaxBasketFcfa = 50000;
}

class CatalogQuoteLine {
  final String label;
  final int amount;
  const CatalogQuoteLine(this.label, this.amount);
}

/// Devis officiel calculé par le serveur (quoteCatalogCF). Le montant affiché au client est TOUJOURS [total].
class CatalogQuote {
  final String quoteId;
  final String service;
  final int budget;
  final int shoppingBudget;
  final int total;
  final int expiresAtMs;
  final List<CatalogQuoteLine> lines;
  const CatalogQuote({
    required this.quoteId,
    required this.service,
    required this.budget,
    required this.shoppingBudget,
    required this.total,
    required this.expiresAtMs,
    required this.lines,
  });

  bool isUsableAt(int nowMs, {int marginMs = 30000}) => expiresAtMs - marginMs > nowMs;
}

class CatalogOrderResult {
  final String orderId;
  final int charged;
  final bool replayed;
  const CatalogOrderResult({required this.orderId, required this.charged, required this.replayed});
}

/// Refus serveur ou panne réseau. [retryable] : l'état de la commande est inconnu, réessayer avec le MÊME devis
/// est sûr (le serveur renvoie la commande déjà créée au lieu d'en créer une seconde).
class CatalogException implements Exception {
  final String code;
  final String message;
  final Map<String, dynamic> data;
  final bool retryable;
  const CatalogException(this.code, this.message, {this.data = const {}, this.retryable = false});

  /// Le devis n'est plus valable : un nouveau devis (et une nouvelle confirmation) est nécessaire.
  bool get needsNewQuote => code == 'QUOTE_EXPIRED' || code == 'PRICE_CHANGED' || code == 'QUOTE_MISMATCH';

  String get userMessage {
    switch (code) {
      case 'NETWORK':
        return 'Connexion instable : votre commande n\'est pas confirmée. Réessayez, aucun double débit n\'est possible.';
      case 'QUOTE_EXPIRED':
        return 'Le devis a expiré. Un nouveau montant va vous être proposé.';
      case 'PRICE_CHANGED':
        return 'Le tarif a changé. Un nouveau montant va vous être proposé.';
      case 'SOLDE_INSUFFISANT':
        return 'Solde wallet insuffisant';
      case 'BASKET_TOO_HEAVY':
        return 'Panier trop lourd pour une livraison à moto : retirez des articles (ou des casiers).';
      default:
        return message.isNotEmpty ? message : 'Opération impossible, réessayez.';
    }
  }

  @override
  String toString() => 'CatalogException($code)';
}

/// Colis, Blanchisserie, Eau & Boissons : devis puis commande créés côté serveur.
class CatalogOrderService {
  static final _functions = FirebaseFunctions.instanceFor(region: 'europe-west1');

  /// Appel d'une Cloud Function renvoyant l'enveloppe {success, error, message, data, code}. Remplaçable dans les tests.
  @visibleForTesting
  static Future<Map<String, dynamic>> Function(String name, Map<String, dynamic> data) callFunction =
      (name, data) async {
    final res = await _functions.httpsCallable(name).call(data);
    return Map<String, dynamic>.from(res.data as Map);
  };

  @visibleForTesting
  static int Function() nowMs = () => DateTime.now().millisecondsSinceEpoch;

  static Future<Map<String, dynamic>> _call(String name, Map<String, dynamic> data) async {
    try {
      return await callFunction(name, data);
    } on FirebaseFunctionsException catch (e) {
      const network = {'unavailable', 'deadline-exceeded', 'internal', 'unknown', 'cancelled', 'aborted'};
      if (network.contains(e.code)) {
        throw const CatalogException('NETWORK', '', retryable: true);
      }
      throw CatalogException(e.code, e.message ?? '');
    } on CatalogException {
      rethrow;
    } catch (_) {
      // Coupure avant la réponse : on ignore si le serveur a traité l'appel.
      throw const CatalogException('NETWORK', '', retryable: true);
    }
  }

  static Map<String, dynamic> _dataOf(Map<String, dynamic> map) {
    if (map['success'] == true) {
      return map['data'] is Map ? Map<String, dynamic>.from(map['data'] as Map) : <String, dynamic>{};
    }
    final err = map['code'] ?? map['error'];
    throw CatalogException(
      err is String ? err : 'ERREUR',
      (map['message'] as String?) ?? '',
      data: map['data'] is Map ? Map<String, dynamic>.from(map['data'] as Map) : const {},
    );
  }

  /// [choices] : uniquement des choix (type, kilos, produits/quantités) — jamais un montant.
  static Future<CatalogQuote> requestQuote(String service, Map<String, dynamic> choices) async {
    final d = _dataOf(await _call('quoteCatalogCF', {...choices, 'service': service}));
    final lines = (d['lines'] as List? ?? const [])
        .whereType<Map>()
        .map((l) => CatalogQuoteLine('${l['label']}', (l['amount'] as num? ?? 0).toInt()))
        .toList();
    return CatalogQuote(
      quoteId: d['quoteId'] as String,
      service: service,
      budget: (d['budget'] as num).toInt(),
      shoppingBudget: (d['shoppingBudget'] as num? ?? 0).toInt(),
      total: (d['total'] as num).toInt(),
      expiresAtMs: (d['expiresAtMs'] as num).toInt(),
      lines: lines,
    );
  }

  /// Crée la commande (et débite le wallet en une transaction serveur). L'identifiant du devis sert de clé
  /// d'idempotence : le renvoyer après une coupure réseau retrouve la même commande, sans second débit.
  static Future<CatalogOrderResult> placeOrder({
    required CatalogQuote quote,
    required String paymentMethod,
    required Map<String, dynamic> choices,
    required Map<String, dynamic> details,
  }) async {
    final d = _dataOf(await _call('createCatalogOrderFromQuoteCF', {
      ...choices,
      ...details,
      'service': quote.service,
      'quoteId': quote.quoteId,
      'paymentMethod': paymentMethod,
      'confirmedAmount': quote.total,
    }));
    return CatalogOrderResult(
      orderId: d['orderId'] as String,
      charged: (d['charged'] as num? ?? 0).toInt(),
      replayed: d['replayed'] == true,
    );
  }
}

/// Mémoire d'un écran : conserve le devis en cours pour que la reprise après coupure réseau (ou un second appui)
/// réutilise la MÊME clé, et ne redemande un devis que si les choix ont changé ou si le devis est périmé.
class CatalogCheckout {
  CatalogQuote? _quote;
  String? _signature;

  CatalogQuote? get pending => _quote;

  String _sign(String service, Map<String, dynamic> choices) => jsonEncode([service, choices]);

  Future<CatalogQuote> prepare(String service, Map<String, dynamic> choices) async {
    final sig = _sign(service, choices);
    final q = _quote;
    if (q != null && _signature == sig && q.isUsableAt(CatalogOrderService.nowMs())) return q;
    final fresh = await CatalogOrderService.requestQuote(service, choices);
    _quote = fresh;
    _signature = sig;
    return fresh;
  }

  /// Commande confirmée par le client. Un refus qui rend le devis caduc l'oublie ; une panne réseau le garde.
  Future<CatalogOrderResult> confirm({
    required CatalogQuote quote,
    required String paymentMethod,
    required Map<String, dynamic> choices,
    required Map<String, dynamic> details,
  }) async {
    try {
      final r = await CatalogOrderService.placeOrder(
          quote: quote, paymentMethod: paymentMethod, choices: choices, details: details);
      reset();
      return r;
    } on CatalogException catch (e) {
      if (!e.retryable) reset();
      rethrow;
    }
  }

  void reset() {
    _quote = null;
    _signature = null;
  }
}
