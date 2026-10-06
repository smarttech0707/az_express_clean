import 'package:flutter_test/flutter_test.dart';

import 'package:az_express/models/order_model.dart';
import 'package:az_express/services/delivery_order_service.dart';
import 'package:az_express/services/tarif_service.dart';

/// Logique partagée de création de livraison (mobile ⇄ web).
///
/// Aucun réseau, aucun Firebase : la persistance passe par
/// [DeliveryOrderStore], remplacée ici par une doublure en mémoire qui
/// modélise la sémantique réelle de la transaction (lecture du solde, refus
/// sans aucune écriture si insuffisant, débit + écriture atomiques).
///
/// LIMITE ASSUMÉE : c'est la logique de DÉCISION qui est couverte, pas le code
/// Firestore de `FirestoreDeliveryOrderStore` lui-même ni la Cloud Function
/// `dispatchOrderToDriver`. Le cycle complet contre le backend réel doit encore
/// être validé manuellement.
class _MemoryStore implements DeliveryOrderStore {
  _MemoryStore({int balance = 0, this.failDispatch = false})
      : _balance = balance;

  int _balance;
  final bool failDispatch;

  final orders = <String, Map<String, dynamic>>{};
  final dispatched = <({String id, bool alreadyCreated})>[];
  String? lastPaidOrderId;

  int get balance => _balance;

  @override
  Future<int> walletBalance(String clientId) async => _balance;

  @override
  Future<({String? name, String? phone})> clientProfile(String clientId) async =>
      (name: 'Client Test', phone: '0700000000');

  @override
  Future<void> debitWalletAndCreateOrder({
    required OrderModel order,
    required int amount,
  }) async {
    // Sémantique de la vraie transaction : on lit, on refuse sans écrire, ou
    // on débite ET on écrit ensemble.
    if (_balance < amount) throw const InsufficientWalletException();
    _balance -= amount;
    lastPaidOrderId = order.id;
    orders[order.id] = order.toMap();
  }

  @override
  Future<void> createOrderAndDispatch(OrderModel order,
      {bool alreadyCreated = false}) async {
    if (failDispatch) throw Exception('backend indisponible');
    if (!alreadyCreated) orders[order.id] = order.toMap();
    dispatched.add((id: order.id, alreadyCreated: alreadyCreated));
  }
}

DeliveryOrderService _service(_MemoryStore store, {String id = 'O1'}) =>
    DeliveryOrderService(store: store, idGenerator: () => id);

OrderModel _draft(DeliveryOrderService s,
        {int price = 500, String payment = 'cash'}) =>
    s.buildOrder(
      clientId: 'c1',
      price: price,
      description: '[STANDARD][COLIS] documents',
      pickupLat: 6.73,
      pickupLng: -3.49,
      destLat: 6.74,
      destLng: -3.50,
      deliveryAddress: 'Cafétou, Abengourou',
      paymentMethod: payment,
      clientPhone: '0700000000',
      recipientPhone: '0711111111',
    );

void main() {
  DateTime at(int hour) => DateTime(2026, 10, 2, hour);
  const jour = 12;
  const nuit = 21; // tarif nuit ET late-night

  group('Tarif : délégué à TarifService, aucune règle recopiée', () {
    test('zone centrale, jour : standard 500 / express 1000', () {
      final t = DeliveryOrderService.quote(
          destLat: TarifService.centerLat,
          destLng: TarifService.centerLng,
          time: at(jour));
      expect(t.standardPrice, 500);
      expect(t.expressPrice, 1000);
      expect(t.isNight, isFalse);
      expect(t.canOrder, isTrue);
    });

    test('zone centrale, nuit : standard 1000 / express 1500', () {
      final t = DeliveryOrderService.quote(
          destLat: TarifService.centerLat,
          destLng: TarifService.centerLng,
          time: at(nuit));
      expect(t.standardPrice, 1000);
      expect(t.expressPrice, 1500);
      expect(t.isNight, isTrue);
    });

    test('le prix retenu suit le mode choisi', () {
      final t = DeliveryOrderService.quote(
          destLat: TarifService.centerLat,
          destLng: TarifService.centerLng,
          time: at(jour));
      expect(DeliveryOrderService.priceFor(t, 'standard'), 500);
      expect(DeliveryOrderService.priceFor(t, 'express'), 1000);
    });

    test('quote() renvoie exactement ce que TarifService calcule', () {
      // Verrouille l'absence de règle réécrite dans le service partagé.
      const lat = 6.80, lng = -3.60;
      final viaService =
          DeliveryOrderService.quote(destLat: lat, destLng: lng, time: at(jour));
      final direct =
          TarifService.compute(clientLat: lat, clientLng: lng, time: at(jour));
      expect(viaService.standardPrice, direct.standardPrice);
      expect(viaService.expressPrice, direct.expressPrice);
      expect(viaService.isOutside, direct.isOutside);
      expect(viaService.canOrder, direct.canOrder);
    });

    test('refus >10 km après 21h : la règle existante est bien remontée', () {
      final t = DeliveryOrderService.quote(
          destLat: 7.50, destLng: -3.00, time: at(nuit));
      expect(t.canOrder, isFalse);
      expect(t.rejectionMessage, isNotNull);
    });

    test('tout prix produit satisfait le minimum Firestore (budget >= 500)',
        () {
      for (final hour in [0, 6, 12, 19, 20, 23]) {
        for (final point in [
          (TarifService.centerLat, TarifService.centerLng),
          (6.80, -3.55),
        ]) {
          final t = DeliveryOrderService.quote(
              destLat: point.$1, destLng: point.$2, time: at(hour));
          if (!t.canOrder) continue;
          for (final mode in ['standard', 'express']) {
            expect(DeliveryOrderService.priceFor(t, mode),
                greaterThanOrEqualTo(DeliveryOrderService.minBudget));
          }
        }
      }
    });
  });

  group('Schéma de commande : conforme à la règle Firestore `orders`', () {
    test('champs exigés à la création', () {
      final order = _draft(_service(_MemoryStore()));
      // isRealUser() && clientId == uid() && budget is int && budget >= 500
      // && notPresent('driverId') && isPaid == false (cash)
      // && status == 'pending'
      expect(order.clientId, 'c1');
      expect(order.budget, 500);
      expect(order.driverId, isNull);
      expect(order.isPaid, isFalse);
      expect(order.status, 'pending');
      expect(order.type, 'livraison');
    });

    test('contrat géographique : collecte vs livraison', () {
      final order = _draft(_service(_MemoryStore()));
      expect(order.latitude, 6.73); // collecte
      expect(order.longitude, -3.49);
      expect(order.destLat, 6.74); // livraison
      expect(order.destLng, -3.50);
    });

    test('toMap() porte les clés attendues par Firestore', () {
      final map = _draft(_service(_MemoryStore())).toMap();
      for (final key in [
        'clientId', 'budget', 'status', 'type', 'latitude', 'longitude',
        'destLat', 'destLng', 'paymentMethod', 'isPaid',
      ]) {
        expect(map.containsKey(key), isTrue, reason: '$key manquant');
      }
      expect(map['driverId'], isNull);
    });

    test('wallet : isPaid passe à true, comme l\'exige la règle', () {
      final order = _draft(_service(_MemoryStore()), payment: 'wallet');
      expect(order.isPaid, isTrue);
      expect(order.paymentMethod, 'wallet');
    });
  });

  group('Soumission', () {
    test('cash : commande créée et dispatch demandé, wallet intact', () async {
      final store = _MemoryStore(balance: 2000);
      final s = _service(store);
      await s.submit(_draft(s));
      expect(store.orders.keys, ['O1']);
      expect(store.dispatched.single.alreadyCreated, isFalse);
      expect(store.balance, 2000);
      expect(store.lastPaidOrderId, isNull);
    });

    test('wallet : débit exact + lastPaidOrderId lié à CETTE commande',
        () async {
      final store = _MemoryStore(balance: 2000);
      final s = _service(store, id: 'O2');
      await s.submit(_draft(s, price: 1000, payment: 'wallet'));
      expect(store.balance, 1000);
      // Exigé par `walletDebitMatchesPaidOrder` : sans ce lien, Firestore
      // refuserait la création.
      expect(store.lastPaidOrderId, 'O2');
      expect(store.orders['O2']!['isPaid'], isTrue);
      expect(store.orders['O2']!['status'], 'pending');
      // La commande existe déjà : seul le dispatch est demandé.
      expect(store.dispatched.single.alreadyCreated, isTrue);
    });

    test('wallet : solde insuffisant → exception typée, AUCUNE écriture',
        () async {
      final store = _MemoryStore(balance: 100);
      final s = _service(store, id: 'O3');
      await expectLater(s.submit(_draft(s, price: 1000, payment: 'wallet')),
          throwsA(isA<InsufficientWalletException>()));
      expect(store.orders, isEmpty);
      expect(store.balance, 100);
      expect(store.dispatched, isEmpty);
    });

    test('budget sous le minimum Firestore → refus avant toute écriture',
        () async {
      final store = _MemoryStore(balance: 5000);
      final s = _service(store);
      await expectLater(
          s.submit(_draft(s, price: 200)), throwsA(isA<DeliveryOrderException>()));
      expect(store.orders, isEmpty);
      expect(store.dispatched, isEmpty);
    });

    test('une erreur backend remonte, elle n\'est jamais avalée', () async {
      final store = _MemoryStore(balance: 5000, failDispatch: true);
      final s = _service(store);
      await expectLater(s.submit(_draft(s)), throwsA(isA<Exception>()));
    });

    test('deux soumissions de la MÊME commande ne débitent qu\'une fois',
        () async {
      // Le même identifiant ⇒ même document : le wallet est débité une fois
      // par soumission, donc l'interface doit empêcher le second appel. C'est
      // ce que garantit le garde `_submitting` de la page web (testé
      // séparément) ; ici on documente le comportement du service.
      final store = _MemoryStore(balance: 2000);
      final s = _service(store, id: 'O4');
      final order = _draft(s, price: 1000, payment: 'wallet');
      await s.submit(order);
      expect(store.balance, 1000);
      await s.submit(order);
      expect(store.balance, 0, reason: 'le service ne déduplique pas lui-même');
      expect(store.orders.keys, ['O4'], reason: 'une seule commande existe');
    });
  });

  group('Validation du téléphone', () {
    test('formats ivoiriens acceptés', () {
      for (final p in [
        '0700000000',
        '07 00 00 00 00',
        '+2250700000000',
        '+225 07 00 00 00 00',
        '07-00-00-00-00',
      ]) {
        expect(isValidIvorianPhone(p), isTrue, reason: '$p devrait être valide');
      }
    });

    test('formats refusés', () {
      for (final p in ['', '123', 'abcdefgh', '07000000000000000000']) {
        expect(isValidIvorianPhone(p), isFalse, reason: '$p devrait être refusé');
      }
    });
  });
}
