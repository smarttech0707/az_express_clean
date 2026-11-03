import 'dart:async';
import 'dart:io';

import 'package:cloud_functions/cloud_functions.dart';

/// Devis officiel de livraison (Cloud Functions `quoteDeliveryCF` /
/// `createOrderFromQuoteCF`).
///
/// POURQUOI : jusqu'ici le téléphone calculait le prix (TarifService) et la
/// distance, et les règles Firestore n'imposaient qu'un plancher de 500 FCFA.
/// Un client modifié pouvait donc commander au prix qu'il voulait. Avec le
/// devis, le serveur calcule le tarif (heure serveur, barème officiel, distance
/// bornée) et la commande est créée dans UNE transaction serveur qui débite le
/// wallet : le client ne fournit plus jamais le montant.
///
/// Ce fichier ne contient AUCUNE règle tarifaire. Il est inactif tant que
/// [QuotedOrderConfig.enabled] est faux (défaut) : les parcours actuels restent
/// inchangés.

/// Active le parcours « devis ». `--dart-define=AZ_QUOTED_ORDERS=true`.
/// Faux par défaut : aucun build publié ne change de comportement.
class QuotedOrderConfig {
  QuotedOrderConfig._();
  static const bool _flag =
      bool.fromEnvironment('AZ_QUOTED_ORDERS', defaultValue: false);
  static const bool _cashFlag =
      bool.fromEnvironment('AZ_QUOTED_CASH', defaultValue: false);
  static const String _project = String.fromEnvironment('FIREBASE_PROJECT_ID');

  /// Seul projet où le parcours devis peut s'activer. La production n'y figure
  /// PAS : même avec le drapeau, un build de production reste sur l'ancien
  /// parcours tant que cette garde n'est pas élargie par une décision explicite.
  static const String previewProject = 'az-express-preprod';

  static const bool enabled = _flag && _project == previewProject;

  /// Garde d'exécution : sur Android, `duplicate-app` est toléré au démarrage, donc
  /// l'application Firebase RÉELLEMENT initialisée vient de `google-services.json`
  /// et non des options Dart. Si ce fichier était celui de la production, les
  /// defines de préproduction ne suffiraient pas : on vérifie le projet effectif
  /// avant tout appel du parcours devis.
  static bool projectAllowed(String? effectiveProjectId) =>
      effectiveProjectId == previewProject;

  /// Espèces : bloquées tant que `createOrderFromQuoteCF` n'a pas été validé en
  /// préproduction pour ce moyen de paiement (`--dart-define=AZ_QUOTED_CASH=true`).
  static const bool cashEnabled = enabled && _cashFlag;

  /// Services et moyens de paiement réellement gérés par le serveur. Mobile
  /// money (orange_money, mtn_money, wave) reste sur l'ancien parcours.
  static const supportedServices = {'livraison', 'courses'};
  static Set<String> get supportedPayments =>
      cashEnabled ? const {'cash', 'wallet'} : const {'wallet'};

  /// Parcours devis possible pour ce client et ce paiement ? Un compte anonyme
  /// n'a pas de document `clients/{uid}` : il reste sur l'ancien parcours.
  static bool eligible({
    required bool isAnonymous,
    required String service,
    required String paymentMethod,
  }) =>
      enabled &&
      !isAnonymous &&
      supportedServices.contains(service) &&
      supportedPayments.contains(paymentMethod);
}

/// Demande de devis : tout ce que le serveur lie au devis.
class QuoteRequest {
  const QuoteRequest({
    required this.serviceType,
    required this.mode,
    required this.pickupLat,
    required this.pickupLng,
    required this.destLat,
    required this.destLng,
    this.routeDistanceKm,
  });

  final String serviceType; // 'livraison' | 'courses'
  final String mode; // 'standard' | 'express'
  final double pickupLat;
  final double pickupLng;
  final double destLat;
  final double destLng;

  /// Distance routière annoncée par le téléphone : INDICATIVE. Le serveur la
  /// borne entre le vol d'oiseau et ×1,6 et ne s'y fie jamais seul.
  final double? routeDistanceKm;

  Map<String, dynamic> toPayload() => {
        'serviceType': serviceType,
        'mode': mode,
        'pickup': {'lat': pickupLat, 'lng': pickupLng},
        'destination': {'lat': destLat, 'lng': destLng},
        if (routeDistanceKm != null && routeDistanceKm! > 0)
          'routeDistanceKm': routeDistanceKm,
      };

  Map<String, dynamic> toStorage() => {
        'serviceType': serviceType,
        'mode': mode,
        'pickupLat': pickupLat,
        'pickupLng': pickupLng,
        'destLat': destLat,
        'destLng': destLng,
        'routeDistanceKm': routeDistanceKm,
      };

  factory QuoteRequest.fromStorage(Map<String, dynamic> j) => QuoteRequest(
        serviceType: j['serviceType'] as String,
        mode: j['mode'] as String,
        pickupLat: (j['pickupLat'] as num).toDouble(),
        pickupLng: (j['pickupLng'] as num).toDouble(),
        destLat: (j['destLat'] as num).toDouble(),
        destLng: (j['destLng'] as num).toDouble(),
        routeDistanceKm: (j['routeDistanceKm'] as num?)?.toDouble(),
      );

  /// Même devis ? (destination, départ, service, mode identiques à 1e-5°,
  /// l'arrondi appliqué par le serveur.)
  bool sameAs(QuoteRequest o) =>
      serviceType == o.serviceType &&
      mode == o.mode &&
      _r(pickupLat) == _r(o.pickupLat) &&
      _r(pickupLng) == _r(o.pickupLng) &&
      _r(destLat) == _r(o.destLat) &&
      _r(destLng) == _r(o.destLng);

  static int _r(double v) => (v * 1e5).round();
}

/// Devis reçu du serveur.
class DeliveryQuote {
  const DeliveryQuote({
    required this.quoteId,
    required this.amount,
    required this.expiresAt,
    required this.request,
    this.tariffVersion,
    this.isNight = false,
  });

  final String quoteId;

  /// Montant OFFICIEL des frais de livraison (FCFA), calculé par le serveur.
  final int amount;
  final DateTime expiresAt;
  final QuoteRequest request;
  final int? tariffVersion;
  final bool isNight;

  /// Marge de sécurité : on ne tente pas un devis qui expire dans < 10 s
  /// (le serveur le refuserait de toute façon).
  bool isExpired(DateTime now) =>
      !now.isBefore(expiresAt.subtract(const Duration(seconds: 10)));
}

/// Refus ou échec technique d'un appel serveur.
class DeliveryQuoteException implements Exception {
  const DeliveryQuoteException(this.code, this.message);
  final String code;
  final String message;
  @override
  String toString() => 'DeliveryQuoteException($code): $message';
}

/// Résultat d'une tentative de création de commande par devis.
sealed class QuotedOrderOutcome {
  const QuotedOrderOutcome();
}

class QuotedOrderCreated extends QuotedOrderOutcome {
  const QuotedOrderCreated(this.orderId, this.charged, {this.replayed = false});
  final String orderId;
  final int charged;

  /// Vrai si le serveur a retrouvé une commande déjà créée pour ce devis
  /// (réponse précédente perdue) : aucun nouveau débit.
  final bool replayed;
}

/// Le tarif a augmenté entre le devis et le paiement : RIEN n'a été débité.
class QuotedOrderPriceChanged extends QuotedOrderOutcome {
  const QuotedOrderPriceChanged(this.quotedAmount, this.currentAmount);
  final int quotedAmount;
  final int currentAmount;
}

/// Refus définitif ou réessayable après nouveau devis (QUOTE_EXPIRED,
/// SOLDE_INSUFFISANT, QUOTE_MISMATCH, OUTSIDE_SERVICE...). Rien n'est débité.
class QuotedOrderRefused extends QuotedOrderOutcome {
  const QuotedOrderRefused(this.code, this.message);
  final String code;
  final String message;
}

/// Réponse inconnue (réseau perdu après plusieurs essais) : la commande a peut-
/// être été créée. Renvoyer le MÊME devis est sans danger (rejeu idempotent).
class QuotedOrderUncertain extends QuotedOrderOutcome {
  const QuotedOrderUncertain(this.quoteId);
  final String quoteId;
}

/// Accès réseau aux deux fonctions. Abstrait pour les tests.
abstract class DeliveryQuoteGateway {
  Future<Map<String, dynamic>> call(String name, Map<String, dynamic> payload);
}

class CloudDeliveryQuoteGateway implements DeliveryQuoteGateway {
  CloudDeliveryQuoteGateway({FirebaseFunctions? functions})
      : _injected = functions;
  final FirebaseFunctions? _injected;

  // Paresseux : l'écran construit ce service même quand le drapeau est inactif
  // (et dans les tests sans Firebase) ; Firebase n'est touché qu'au premier appel.
  FirebaseFunctions get _functions =>
      _injected ?? FirebaseFunctions.instanceFor(region: 'europe-west1');

  @override
  Future<Map<String, dynamic>> call(
      String name, Map<String, dynamic> payload) async {
    final fns = _functions;
    if (!QuotedOrderConfig.projectAllowed(fns.app.options.projectId)) {
      throw const DeliveryQuoteException('WRONG_PROJECT',
          'Cette version de test n\'est pas reliée au projet de préproduction');
    }
    final res = await fns
        .httpsCallable(name,
            options: HttpsCallableOptions(timeout: const Duration(seconds: 30)))
        .call<dynamic>(payload);
    return _deepMap(res.data);
  }

  static Map<String, dynamic> _deepMap(dynamic v) {
    if (v is! Map) return <String, dynamic>{};
    return v.map((k, val) => MapEntry(
        k.toString(), val is Map ? _deepMap(val) : val));
  }
}

/// Erreurs transitoires : le même appel peut être rejoué sans risque car
/// `createOrderFromQuoteCF` est idempotent par devis.
bool isTransientQuoteError(Object e) {
  if (e is FirebaseFunctionsException) {
    return const {'unavailable', 'deadline-exceeded', 'internal', 'unknown'}
        .contains(e.code);
  }
  return e is SocketException || e is TimeoutException;
}

class DeliveryQuoteService {
  DeliveryQuoteService({
    DeliveryQuoteGateway? gateway,
    DateTime Function()? clock,
    this.maxAttempts = 3,
    this.retryDelay = const Duration(milliseconds: 700),
    Set<String>? allowedPayments,
  })  : _gateway = gateway ?? CloudDeliveryQuoteGateway(),
        _clock = clock ?? DateTime.now,
        _allowedPayments = allowedPayments;

  final DeliveryQuoteGateway _gateway;
  final Set<String>? _allowedPayments;
  Set<String> get allowedPayments =>
      _allowedPayments ?? QuotedOrderConfig.supportedPayments;
  final DateTime Function() _clock;
  final int maxAttempts;
  final Duration retryDelay;

  // Anti double-tap : un seul appel de création en vol par devis.
  final Map<String, Future<QuotedOrderOutcome>> _inFlight = {};

  /// Demande un devis officiel. Le montant vient du serveur.
  Future<DeliveryQuote> requestQuote(QuoteRequest request) async {
    Map<String, dynamic> res;
    try {
      res = await _withRetry(
          () => _gateway.call('quoteDeliveryCF', request.toPayload()));
    } on FirebaseFunctionsException catch (e) {
      throw DeliveryQuoteException(e.code, e.message ?? 'Devis indisponible');
    }
    if (res['success'] != true) {
      throw DeliveryQuoteException(
          (res['code'] ?? res['error'] ?? 'QUOTE_FAILED').toString(),
          (res['message'] ?? 'Devis indisponible').toString());
    }
    final data = (res['data'] as Map?)?.cast<String, dynamic>() ?? const {};
    final amount = data['amount'];
    final id = data['quoteId'];
    final exp = data['expiresAtMs'];
    if (amount is! int || amount < 500 || id is! String || exp is! num) {
      throw const DeliveryQuoteException(
          'QUOTE_INVALID', 'Réponse de devis invalide');
    }
    return DeliveryQuote(
      quoteId: id,
      amount: amount,
      expiresAt: DateTime.fromMillisecondsSinceEpoch(exp.toInt(), isUtc: true),
      request: request,
      tariffVersion: (data['tariffVersion'] as num?)?.toInt(),
      isNight: data['isNight'] == true,
    );
  }

  /// Crée la commande à partir d'un devis que le client a ACCEPTÉ.
  ///
  /// [acceptedAmount] est le montant que l'utilisateur a vu et confirmé : il
  /// doit égaler le devis (sinon on refuse avant tout appel). Le serveur
  /// refuse de débiter plus que le devis (PRICE_CHANGED, rien débité).
  Future<QuotedOrderOutcome> createOrder({
    required DeliveryQuote quote,
    required int acceptedAmount,
    required String paymentMethod,
    required int walletBalance,
    int shoppingBudget = 0,
    Map<String, dynamic> orderFields = const {},

    /// Reprise d'un devis déjà tenté (réponse perdue, redémarrage) : on saute les
    /// contrôles locaux d'expiration et de solde, le serveur seul tranche (rejeu
    /// d'une commande déjà créée, sinon refus). Aucun débit sans le serveur.
    bool recovery = false,
  }) {
    final running = _inFlight[quote.quoteId];
    if (running != null) return running; // double clic : même résultat, un seul appel
    final future = _create(quote, acceptedAmount, paymentMethod, walletBalance,
            shoppingBudget, orderFields, recovery)
        .whenComplete(() {
      // Bloc (pas flèche) : remove() renvoie le future lui-même, ce qui le ferait s'attendre.
      _inFlight.remove(quote.quoteId);
    });
    _inFlight[quote.quoteId] = future;
    return future;
  }

  Future<QuotedOrderOutcome> _create(
      DeliveryQuote quote,
      int acceptedAmount,
      String paymentMethod,
      int walletBalance,
      int shoppingBudget,
      Map<String, dynamic> orderFields,
      bool recovery) async {
    if (acceptedAmount != quote.amount) {
      return const QuotedOrderRefused(
          'AMOUNT_NOT_CONFIRMED', 'Le prix confirmé ne correspond pas au devis');
    }
    if (!allowedPayments.contains(paymentMethod)) {
      return const QuotedOrderRefused('PAYMENT_METHOD_UNSUPPORTED',
          'Ce mode de paiement n\'est pas disponible pour ce parcours');
    }
    if (shoppingBudget < 0) {
      return const QuotedOrderRefused(
          'INVALID_BUDGET', 'Budget d\'achat invalide');
    }
    if (!recovery && quote.isExpired(_clock())) {
      return const QuotedOrderRefused(
          'QUOTE_EXPIRED', 'Le devis a expiré, un nouveau prix va être demandé');
    }
    if (!recovery &&
        paymentMethod == 'wallet' &&
        walletBalance < quote.amount + shoppingBudget) {
      return QuotedOrderRefused('SOLDE_INSUFFISANT',
          'Solde insuffisant ($walletBalance FCFA)');
    }

    final r = quote.request;
    final payload = <String, dynamic>{
      'quoteId': quote.quoteId,
      'serviceType': r.serviceType,
      'mode': r.mode,
      'pickup': {'lat': r.pickupLat, 'lng': r.pickupLng},
      'destination': {'lat': r.destLat, 'lng': r.destLng},
      'paymentMethod': paymentMethod,
      'confirmedAmount': acceptedAmount,
      if (shoppingBudget > 0) 'shoppingBudget': shoppingBudget,
      'order': orderFields,
    };

    Map<String, dynamic> res;
    try {
      res = await _withRetry(
          () => _gateway.call('createOrderFromQuoteCF', payload));
    } on DeliveryQuoteException catch (e) {
      // Refus local (ex. mauvais projet) : l'appel n'est pas parti, rien n'est débité.
      return QuotedOrderRefused(e.code, e.message);
    } catch (e) {
      if (isTransientQuoteError(e)) return QuotedOrderUncertain(quote.quoteId);
      if (e is FirebaseFunctionsException) {
        return QuotedOrderRefused(e.code, e.message ?? 'Commande refusée');
      }
      rethrow;
    }

    if (res['success'] == true) {
      final d = (res['data'] as Map?)?.cast<String, dynamic>() ?? const {};
      final id = d['orderId'];
      if (id is! String) {
        return QuotedOrderUncertain(quote.quoteId);
      }
      return QuotedOrderCreated(id, (d['charged'] as num?)?.toInt() ?? 0,
          replayed: d['replayed'] == true);
    }
    final code = (res['code'] ?? res['error'] ?? 'ORDER_REFUSED').toString();
    if (code == 'PRICE_CHANGED') {
      final d = (res['data'] as Map?)?.cast<String, dynamic>() ?? const {};
      return QuotedOrderPriceChanged((d['quotedAmount'] as num?)?.toInt() ?? quote.amount,
          (d['currentAmount'] as num?)?.toInt() ?? 0);
    }
    return QuotedOrderRefused(
        code, (res['message'] ?? 'Commande refusée').toString());
  }

  Future<T> _withRetry<T>(Future<T> Function() op) async {
    Object? last;
    for (var i = 0; i < maxAttempts; i++) {
      try {
        return await op();
      } catch (e) {
        last = e;
        if (!isTransientQuoteError(e) || i == maxAttempts - 1) rethrow;
        await Future<void>.delayed(retryDelay);
      }
    }
    throw last!; // inatteignable
  }
}
