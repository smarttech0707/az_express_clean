import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:uuid/uuid.dart';

import '../models/order_model.dart';
import 'active_city_service.dart';
import 'firestore_service.dart';
import 'tarif_service.dart';

/// Création d'une commande de LIVRAISON — logique métier partagée
/// mobile ⇄ web.
///
/// POURQUOI CE FICHIER : la construction de la commande et le débit wallet
/// vivaient uniquement dans `livraison_screen.dart`, enfermés dans un
/// `StatefulWidget` de 2842 lignes. Les réimplémenter pour le web aurait
/// dupliqué un chemin FINANCIER — deux transactions wallet à maintenir en
/// parallèle. Tout est donc extrait ici, et l'écran mobile appelle ce service.
///
/// Les règles tarifaires ne sont PAS reprises ici : `quote()` délègue
/// entièrement à [TarifService], qui reste la source unique (port Node
/// fidèle : `functions/tarifService.js`).
/// Persistance dont [DeliveryOrderService] a besoin.
///
/// Abstraction volontairement étroite : elle permet de tester la logique de
/// décision avec une doublure en mémoire (même convention que les doublures
/// écrites à la main dans `functions/test/`), sans ajouter de dépendance de
/// test ni toucher au réseau.
abstract class DeliveryOrderStore {
  Future<int> walletBalance(String clientId);

  Future<({String? name, String? phone})> clientProfile(String clientId);

  /// Débite le wallet ET écrit la commande dans UNE SEULE transaction.
  ///
  /// Doit lever [InsufficientWalletException] si le solde est insuffisant, et
  /// ne rien écrire dans ce cas.
  Future<void> debitWalletAndCreateOrder({
    required OrderModel order,
    required int amount,
  });

  /// Crée la commande (si nécessaire) puis déclenche la recherche de livreur.
  Future<void> createOrderAndDispatch(OrderModel order,
      {bool alreadyCreated = false});
}

/// Implémentation réelle : Firestore + [FirestoreService] (donc la Cloud
/// Function `dispatchOrderToDriver`). Aucune logique de décision ici.
class FirestoreDeliveryOrderStore implements DeliveryOrderStore {
  FirebaseFirestore get _db => FirebaseFirestore.instance;

  @override
  Future<int> walletBalance(String clientId) async {
    final snap = await _db.collection('clients').doc(clientId).get();
    return (snap.data()?['wallet'] as num?)?.toInt() ?? 0;
  }

  @override
  Future<({String? name, String? phone})> clientProfile(String clientId) async {
    try {
      final snap = await _db.collection('clients').doc(clientId).get();
      return (
        name: snap.data()?['name'] as String?,
        phone: snap.data()?['phone'] as String?,
      );
    } catch (_) {
      return (name: null, phone: null);
    }
  }

  @override
  Future<void> debitWalletAndCreateOrder({
    required OrderModel order,
    required int amount,
  }) async {
    final clientRef = _db.collection('clients').doc(order.clientId);
    final orderRef = _db.collection('orders').doc(order.id);
    await _db.runTransaction((tx) async {
      final snap = await tx.get(clientRef);
      final balance = (snap.data()?['wallet'] as num?)?.toInt() ?? 0;
      if (balance < amount) throw const InsufficientWalletException();
      // LOT 6 SECURITY : lie ce débit précis à CETTE commande (règle Firestore
      // `walletDebitMatchesPaidOrder`) — empêche qu'un même débit ne serve à
      // valider plusieurs commandes.
      tx.update(clientRef, {
        'wallet': balance - amount,
        'lastPaidOrderId': order.id,
      });
      tx.set(orderRef, order.toMap());
    });
  }

  @override
  Future<void> createOrderAndDispatch(OrderModel order,
          {bool alreadyCreated = false}) =>
      FirestoreService().createOrder(order, alreadyCreated: alreadyCreated);
}

class DeliveryOrderService {
  final DeliveryOrderStore _store;
  final String Function() _idGenerator;

  DeliveryOrderService({
    DeliveryOrderStore? store,
    String Function()? idGenerator,
  })  : _store = store ?? FirestoreDeliveryOrderStore(),
        _idGenerator = idGenerator ?? (() => const Uuid().v4());

  /// Montant minimal accepté par la règle Firestore `orders` (`budget >= 500`).
  /// Reproduit ici uniquement pour échouer tôt, avec un message clair, plutôt
  /// qu'un `permission-denied` opaque. La règle serveur reste l'autorité.
  static const minBudget = 500;

  /// Tarif applicable, délégué à [TarifService] — aucune règle dupliquée.
  ///
  /// [routeDistanceKm] : distance routière réelle si disponible. Le web ne la
  /// fournit pas (l'API Directions de Google n'est pas appelable depuis un
  /// navigateur à cause du CORS, et chaque appel est facturé) : `null` fait
  /// alors retomber [TarifService] sur la distance à vol d'oiseau depuis le
  /// centre, exactement comme le mobile lorsqu'aucun itinéraire n'est encore
  /// calculé.
  static TarifResult quote({
    required double destLat,
    required double destLng,
    double? routeDistanceKm,
    DateTime? time,
  }) {
    return TarifService.compute(
      clientLat: destLat,
      clientLng: destLng,
      routeDistanceKm:
          (routeDistanceKm != null && routeDistanceKm > 0) ? routeDistanceKm : null,
      time: time,
    );
  }

  /// Prix retenu pour un mode de livraison. Même sélection que le mobile
  /// (`_selectedPrice`).
  static int priceFor(TarifResult tarif, String deliveryMode) =>
      deliveryMode == 'express' ? tarif.expressPrice : tarif.standardPrice;

  /// Construit la commande, sans rien écrire.
  ///
  /// Reproduit à l'identique le document créé par l'écran mobile : `type`
  /// `'livraison'`, `status` `'pending'`, `latitude`/`longitude` = point de
  /// COLLECTE et `destLat`/`destLng` = point de LIVRAISON (contrat
  /// géographique documenté dans [OrderModel]), `isPaid` vrai uniquement pour
  /// un paiement wallet.
  OrderModel buildOrder({
    required String clientId,
    required int price,
    required String description,
    required double pickupLat,
    required double pickupLng,
    required double destLat,
    required double destLng,
    required String deliveryAddress,
    String deliveryMode = 'standard',
    String paymentMethod = 'cash',
    int shoppingBudget = 0,
    String? orderId,
    String? clientName,
    String? clientPhone,
    String? pickupAddress,
    String? pickupContactName,
    String? pickupContactPhone,
    String? recipientName,
    String? recipientPhone,
    String? pickupCityId,
    String? deliveryCityId,
    String? pickupZoneId,
    String? deliveryZoneId,
    String? pickupCoordinateSource,
    String? deliveryCoordinateSource,
    String? gpsDetectedCityId,
    String? activeCityId,
    String? citySelectionSource,
    String? cityResolutionStatus,
  }) {
    return OrderModel(
      id: orderId ?? _idGenerator(),
      description: description,
      budget: price,
      shoppingBudget: shoppingBudget,
      status: 'pending',
      latitude: pickupLat,
      longitude: pickupLng,
      deliveryAddress: deliveryAddress,
      destLat: destLat,
      destLng: destLng,
      type: 'livraison',
      clientId: clientId,
      clientName: clientName,
      clientPhone: clientPhone,
      pickupAddress: pickupAddress,
      paymentMethod: paymentMethod,
      // La règle Firestore n'autorise `isPaid: true` à la création que pour un
      // paiement wallet accompagné du débit lié (voir `submit`).
      isPaid: paymentMethod == 'wallet',
      forSelf: true,
      deliveryMode: deliveryMode,
      pickupContactName: pickupContactName,
      pickupContactPhone: pickupContactPhone,
      recipientName: recipientName,
      recipientPhone: recipientPhone,
      pickupCityId: pickupCityId,
      deliveryCityId: deliveryCityId,
      pickupZoneId: pickupZoneId,
      deliveryZoneId: deliveryZoneId,
      pickupCoordinateSource: pickupCoordinateSource,
      deliveryCoordinateSource: deliveryCoordinateSource,
      gpsDetectedCityId: gpsDetectedCityId,
      activeCityId: activeCityId,
      citySelectionSource: citySelectionSource,
      cityResolutionStatus: cityResolutionStatus,
    );
  }

  /// Écrit la commande et déclenche la recherche de livreur.
  ///
  /// Deux chemins, strictement ceux du mobile :
  ///   - **cash** : simple création (`isPaid: false`) ;
  ///   - **wallet** : transaction Firestore unique qui débite le client ET
  ///     écrit `lastPaidOrderId` — exigé par la règle
  ///     `walletDebitMatchesPaidOrder`, qui empêche qu'un même débit valide
  ///     plusieurs commandes.
  ///
  /// Le dispatch passe par [FirestoreService.createOrder], donc par la Cloud
  /// Function `dispatchOrderToDriver` : aucune logique d'attribution n'est
  /// réimplémentée, et son échec ne fait jamais échouer la commande.
  Future<void> submit(OrderModel order) async {
    if (order.budget < minBudget) {
      throw DeliveryOrderException(
          'Montant de livraison invalide (${order.budget} FCFA).');
    }
    if (order.paymentMethod != 'wallet') {
      await _store.createOrderAndDispatch(order);
      return;
    }
    await _store.debitWalletAndCreateOrder(
      order: order,
      amount: order.budget + order.shoppingBudget,
    );
    // La commande existe déjà : on ne demande plus que le dispatch.
    await _store.createOrderAndDispatch(order, alreadyCreated: true);
  }

  /// Solde wallet du client, pour afficher et vérifier avant soumission.
  Future<int> walletBalance(String clientId) => _store.walletBalance(clientId);

  /// Profil minimal du client (nom/téléphone), repris du document `clients`
  /// comme le fait l'écran mobile — jamais fourni par l'interface.
  Future<({String? name, String? phone})> clientProfile(String clientId) =>
      _store.clientProfile(clientId);

  /// Zone de livraison d'un point, via le service de villes existant.
  Future<String?> resolveZoneId(
    ActiveCityService cityService, {
    required double latitude,
    required double longitude,
  }) async {
    try {
      final zone = await cityService.resolveZone(
        latitude: latitude,
        longitude: longitude,
      );
      return zone?.id;
    } catch (_) {
      return null;
    }
  }
}

/// Erreur métier de création de livraison, porteuse d'un message affichable.
class DeliveryOrderException implements Exception {
  final String message;
  const DeliveryOrderException(this.message);
  @override
  String toString() => message;
}

/// Solde wallet insuffisant — distinguée pour que l'interface puisse proposer
/// une recharge plutôt qu'afficher une erreur générique.
class InsufficientWalletException extends DeliveryOrderException {
  const InsufficientWalletException() : super('Solde insuffisant');
}

/// Validation d'un numéro de téléphone ivoirien, alignée sur ce que le serveur
/// accepte déjà (`initiateFeexPayPayment` / `initiateWithdrawal` :
/// `^\+?\d{8,15}$` après suppression des séparateurs).
bool isValidIvorianPhone(String raw) {
  final digits = raw.replaceAll(RegExp(r'[\s.\-()]'), '');
  return RegExp(r'^\+?\d{8,15}$').hasMatch(digits);
}
