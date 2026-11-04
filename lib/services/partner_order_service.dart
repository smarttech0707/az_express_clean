import 'dart:convert';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:flutter/foundation.dart';

/// Ligne d'un devis partenaire (Restaurant / Boulangerie). Tous les montants viennent du serveur.
class PartnerQuoteLine {
  final String itemId;
  final String name;
  final int qty;
  final int unitPrice;
  final int subtotal;
  const PartnerQuoteLine({
    required this.itemId,
    required this.name,
    required this.qty,
    required this.unitPrice,
    required this.subtotal,
  });
}

/// Devis officiel (quotePartnerOrderCF). Le montant affiché et confirmé par le client est TOUJOURS [total] :
/// l'appareil ne calcule jamais productAmount, deliveryFee ni total.
class PartnerQuote {
  final String quoteId;
  final String sellerType;
  final String sellerId;
  final String sellerName;
  final List<PartnerQuoteLine> lines;
  final int productAmount;
  final int deliveryFee;
  final int total;
  final int expiresAtMs;

  /// Choix exacts qui ont été devisés (articles triés + point de livraison arrondi) : la création les renvoie à
  /// l'identique, le serveur refuse toute différence (QUOTE_MISMATCH).
  final List<Map<String, dynamic>> items;
  final Map<String, double> destination;

  const PartnerQuote({
    required this.quoteId,
    required this.sellerType,
    required this.sellerId,
    required this.sellerName,
    required this.lines,
    required this.productAmount,
    required this.deliveryFee,
    required this.total,
    required this.expiresAtMs,
    required this.items,
    required this.destination,
  });

  bool isUsableAt(int nowMs, {int marginMs = 30000}) =>
      expiresAtMs - marginMs > nowMs;
}

class PartnerOrderResult {
  final String orderId;
  final int charged;
  final bool replayed;

  /// Montants définitifs renvoyés par le serveur (absents d'un rejeu).
  final int? totalAmount;
  const PartnerOrderResult(
      {required this.orderId,
      required this.charged,
      required this.replayed,
      this.totalAmount});
}

/// Refus serveur ou panne réseau. [retryable] : l'état de la commande est inconnu, réessayer avec le MÊME devis
/// est sûr (le serveur renvoie la commande déjà créée au lieu d'en créer une seconde).
class PartnerOrderException implements Exception {
  final String code;
  final String message;
  final Map<String, dynamic> data;
  final bool retryable;
  const PartnerOrderException(this.code, this.message,
      {this.data = const {}, this.retryable = false});

  /// Le devis n'est plus valable : un nouveau devis (donc une nouvelle confirmation) est nécessaire.
  bool get needsNewQuote =>
      code == 'QUOTE_EXPIRED' ||
      code == 'PRICE_CHANGED' ||
      code == 'AMOUNT_NOT_CONFIRMED' ||
      code == 'QUOTE_MISMATCH';

  /// Le serveur a confirmé que ce partenaire est HORS pilote (liste pilote lue côté serveur ; le client ne peut pas la lire).
  /// C'est la SEULE réponse qui autorise l'ancien parcours. FEATURE_DISABLED, erreur réseau, réponse inconnue ou ambiguë ne
  /// prouvent rien (un pilote peut être concerné) : ils bloquent la commande. Sans effet financier : rien n'est débité au devis.
  bool get notInPilot => code == 'PARTNER_NOT_IN_PILOT';

  /// Création volontairement fermée (arrêt d'urgence ou pilote suspendu) : jamais de repli sur l'ancien parcours.
  bool get creationClosed => code == 'CREATION_CLOSED';

  String get userMessage {
    switch (code) {
      case 'NETWORK':
        return 'Connexion instable : votre commande n\'est pas confirmée. Réessayez, aucun double débit n\'est possible.';
      case 'QUOTE_EXPIRED':
        return 'Le devis a expiré. Un nouveau montant va vous être proposé.';
      case 'PRICE_CHANGED':
        return 'Le tarif a changé. Un nouveau montant va vous être proposé.';
      case 'AMOUNT_NOT_CONFIRMED':
      case 'QUOTE_MISMATCH':
        return 'Le montant a été recalculé. Merci de le confirmer à nouveau.';
      case 'CREATION_CLOSED':
        return 'Les commandes sont momentanément indisponibles. Réessayez plus tard.';
      case 'SOLDE_INSUFFISANT':
        return 'Solde wallet insuffisant';
      case 'PARTNER_CLOSED':
        return 'Ce restaurant est actuellement fermé.';
      case 'PARTNER_UNAVAILABLE':
        return 'Ce restaurant n\'est pas disponible pour le moment.';
      case 'ITEM_UNAVAILABLE':
        return 'Un article de votre panier n\'est plus disponible. Retirez-le puis réessayez.';
      case 'OUTSIDE_SERVICE':
      case 'OUT_OF_SERVICE_AREA':
        return 'Votre position est hors de la zone de livraison.';
      case 'unauthenticated':
        return 'Connectez-vous à votre compte pour commander.';
      default:
        return message.isNotEmpty
            ? message
            : 'Opération impossible, réessayez.';
    }
  }

  @override
  String toString() => 'PartnerOrderException($code)';
}

/// Commandes Restaurant / Boulangerie version 2 : devis puis commande créés côté serveur (pas de débit wallet ni
/// d'écriture `orders` depuis l'appareil). Réutilisable pour la boulangerie via [sellerType].
class PartnerOrderService {
  static final _functions =
      FirebaseFunctions.instanceFor(region: 'europe-west1');

  /// Appel d'une Cloud Function renvoyant l'enveloppe {success, error, message, data, code}. Remplaçable dans les tests.
  @visibleForTesting
  static Future<Map<String, dynamic>> Function(
          String name, Map<String, dynamic> data) callFunction =
      (name, data) async {
    final res = await _functions.httpsCallable(name).call(data);
    return Map<String, dynamic>.from(res.data as Map);
  };

  @visibleForTesting
  static int Function() nowMs = () => DateTime.now().millisecondsSinceEpoch;

  static Future<Map<String, dynamic>> _call(
      String name, Map<String, dynamic> data) async {
    try {
      return await callFunction(name, data);
    } on FirebaseFunctionsException catch (e) {
      const network = {
        'unavailable',
        'deadline-exceeded',
        'internal',
        'unknown',
        'cancelled',
        'aborted'
      };
      if (network.contains(e.code)) {
        throw const PartnerOrderException('NETWORK', '', retryable: true);
      }
      throw PartnerOrderException(e.code, e.message ?? '');
    } on PartnerOrderException {
      rethrow;
    } catch (_) {
      // Coupure avant la réponse : on ignore si le serveur a traité l'appel.
      throw const PartnerOrderException('NETWORK', '', retryable: true);
    }
  }

  static Map<String, dynamic> _dataOf(Map<String, dynamic> map) {
    if (map['success'] == true) {
      return map['data'] is Map
          ? Map<String, dynamic>.from(map['data'] as Map)
          : <String, dynamic>{};
    }
    final err = map['code'] ?? map['error'];
    final message = (map['message'] as String?) ?? '';
    final data = map['data'] is Map
        ? Map<String, dynamic>.from(map['data'] as Map)
        : <String, dynamic>{};
    // Le serveur encode « SOLDE_INSUFFISANT:<solde>:<total> » dans le message : on garde le code seul.
    if (message.startsWith('SOLDE_INSUFFISANT')) {
      throw PartnerOrderException('SOLDE_INSUFFISANT', '', data: data);
    }
    throw PartnerOrderException(err is String ? err : 'ERREUR', message,
        data: data);
  }

  static double _round5(double v) => (v * 1e5).round() / 1e5;

  /// Articles au format serveur, triés par identifiant (le serveur compare le tableau tel quel).
  static List<Map<String, dynamic>> canonicalItems(Map<String, int> cart) {
    final entries = cart.entries.where((e) => e.value > 0).toList()
      ..sort((a, b) => a.key.compareTo(b.key));
    return [
      for (final e in entries) {'itemId': e.key, 'qty': e.value}
    ];
  }

  /// [cart] : uniquement des identifiants d'articles et des quantités — jamais un prix ni un montant.
  static Future<PartnerQuote> requestQuote({
    required String sellerType,
    required String sellerId,
    required Map<String, int> cart,
    required double latitude,
    required double longitude,
  }) async {
    final items = canonicalItems(cart);
    final destination = {'lat': _round5(latitude), 'lng': _round5(longitude)};
    final d = _dataOf(await _call('quotePartnerOrderCF', {
      'sellerType': sellerType,
      'sellerId': sellerId,
      'items': items,
      'destination': destination,
    }));
    final lines = (d['lines'] as List? ?? const [])
        .whereType<Map>()
        .map((l) => PartnerQuoteLine(
              itemId: '${l['itemId']}',
              name: '${l['name']}',
              qty: (l['qty'] as num? ?? 0).toInt(),
              unitPrice: (l['unitPrice'] as num? ?? 0).toInt(),
              subtotal: (l['subtotal'] as num? ?? 0).toInt(),
            ));
    return PartnerQuote(
      quoteId: d['quoteId'] as String,
      sellerType: sellerType,
      sellerId: sellerId,
      sellerName: (d['sellerName'] as String?) ?? '',
      lines: lines.toList(),
      productAmount: (d['productAmount'] as num).toInt(),
      deliveryFee: (d['deliveryFee'] as num).toInt(),
      total: (d['total'] as num).toInt(),
      expiresAtMs: (d['expiresAtMs'] as num).toInt(),
      items: items,
      destination: {'lat': destination['lat']!, 'lng': destination['lng']!},
    );
  }

  /// Crée la commande (et débite le wallet en une transaction serveur). L'identifiant du devis sert de clé
  /// d'idempotence : le renvoyer après une coupure réseau retrouve la même commande, sans second débit.
  static Future<PartnerOrderResult> placeOrder({
    required PartnerQuote quote,
    required String paymentMethod,
    required String deliveryAddress,
    String deliveryCoordinateSource = 'gps',
    String? notes,
  }) async {
    final d = _dataOf(await _call('createPartnerOrderFromQuoteCF', {
      'quoteId': quote.quoteId,
      'paymentMethod': paymentMethod,
      'sellerType': quote.sellerType,
      'sellerId': quote.sellerId,
      'items': quote.items,
      'destination': quote.destination,
      'deliveryAddress': deliveryAddress,
      'deliveryCoordinateSource': deliveryCoordinateSource,
      if (notes != null && notes.isNotEmpty) 'notes': notes,
      'confirmedAmount': quote.total,
    }));
    return PartnerOrderResult(
      orderId: d['orderId'] as String,
      charged: (d['charged'] as num? ?? 0).toInt(),
      replayed: d['replayed'] == true,
      totalAmount: (d['totalAmount'] as num?)?.toInt(),
    );
  }
}

/// Commande envoyée dont l'issue est inconnue (coupure réseau) : tant qu'elle n'est pas résolue, aucune autre commande
/// n'est créée par cet écran, pour qu'un panier modifié ne double pas une commande peut-être déjà passée.
class _Unresolved {
  final PartnerQuote quote;
  final String paymentMethod;
  final String deliveryAddress;
  const _Unresolved(this.quote, this.paymentMethod, this.deliveryAddress);
}

/// Mémoire d'un écran : conserve le devis en cours pour que la reprise après coupure réseau (ou un second appui)
/// réutilise la MÊME clé, et ne redemande un devis que si le panier a changé ou si le devis est périmé.
class PartnerCheckout {
  PartnerQuote? _quote;
  String? _signature;
  _Unresolved? _unresolved;

  PartnerQuote? get pending => _quote;

  /// Une commande est peut-être déjà créée côté serveur : il faut d'abord la retrouver ([resolveUnresolved]).
  bool get hasUnresolved => _unresolved != null;

  String _sign(String sellerType, String sellerId, Map<String, int> cart) =>
      jsonEncode(
          [sellerType, sellerId, PartnerOrderService.canonicalItems(cart)]);

  /// [locate] n'est appelé que lorsqu'un nouveau devis est nécessaire : le point de livraison reste donc identique
  /// pour toutes les reprises d'un même devis (pas de GPS qui bouge entre deux tentatives).
  Future<PartnerQuote> prepare({
    required String sellerType,
    required String sellerId,
    required Map<String, int> cart,
    required Future<({double lat, double lng})> Function() locate,
  }) async {
    final sig = _sign(sellerType, sellerId, cart);
    final q = _quote;
    if (q != null &&
        _signature == sig &&
        q.isUsableAt(PartnerOrderService.nowMs())) {
      return q;
    }
    final point = await locate();
    final fresh = await PartnerOrderService.requestQuote(
      sellerType: sellerType,
      sellerId: sellerId,
      cart: cart,
      latitude: point.lat,
      longitude: point.lng,
    );
    _quote = fresh;
    _signature = sig;
    return fresh;
  }

  /// Commande confirmée par le client. Un refus qui rend le devis caduc l'oublie ; une panne réseau le garde ET
  /// mémorise la commande comme « issue inconnue ».
  Future<PartnerOrderResult> confirm({
    required PartnerQuote quote,
    required String paymentMethod,
    required String deliveryAddress,
  }) async {
    try {
      final r = await PartnerOrderService.placeOrder(
          quote: quote,
          paymentMethod: paymentMethod,
          deliveryAddress: deliveryAddress);
      reset();
      return r;
    } on PartnerOrderException catch (e) {
      if (e.retryable) {
        _unresolved = _Unresolved(quote, paymentMethod, deliveryAddress);
      } else {
        reset();
      }
      rethrow;
    }
  }

  /// Renvoie la commande d'issue inconnue avec le MÊME devis (rejeu sûr). Retourne null s'il n'y en a pas.
  /// Une réponse de refus non réseau clôt la question (le serveur n'a rien créé) ; une nouvelle panne la conserve.
  Future<PartnerOrderResult?> resolveUnresolved() async {
    final u = _unresolved;
    if (u == null) return null;
    return confirm(
        quote: u.quote,
        paymentMethod: u.paymentMethod,
        deliveryAddress: u.deliveryAddress);
  }

  void reset() {
    _quote = null;
    _signature = null;
    _unresolved = null;
  }
}
