import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:az_express/models/delivery_zone.dart';
import 'package:az_express/models/order_model.dart';
import 'package:az_express/services/active_city_service.dart';
import 'package:az_express/services/delivery_order_service.dart';
import 'package:az_express/services/places_search_service.dart';
import 'package:az_express/web/pages/client/web_client_dashboard.dart';
import 'package:az_express/web/pages/client/web_delivery_page.dart';
import 'package:az_express/web/web_router.dart';

/// Page Web « Livraison Express ».
///
/// Aucun réseau, aucun Firebase : le store de persistance, le service de
/// villes, l'UID et la recherche d'adresses sont tous injectés.
class _MemoryStore implements DeliveryOrderStore {
  _MemoryStore({this.balance = 5000, this.failDispatch = false});

  int balance;
  final bool failDispatch;
  final submitted = <OrderModel>[];
  int dispatchCalls = 0;

  @override
  Future<int> walletBalance(String clientId) async => balance;

  @override
  Future<({String? name, String? phone})> clientProfile(String clientId) async =>
      (name: 'Client Test', phone: '0700000000');

  @override
  Future<void> debitWalletAndCreateOrder(
      {required OrderModel order, required int amount}) async {
    if (balance < amount) throw const InsufficientWalletException();
    balance -= amount;
    submitted.add(order);
  }

  @override
  Future<void> createOrderAndDispatch(OrderModel order,
      {bool alreadyCreated = false}) async {
    dispatchCalls++;
    if (failDispatch) throw Exception('backend indisponible');
    if (!alreadyCreated) submitted.add(order);
  }
}

/// Ville desservie, chargée sans Firestore via le `cityLoader` injectable.
ActiveCityService _cityService() => ActiveCityService(
      cityLoader: () async => [
        DeliveryZone.fromMap('abengourou', const {
          'name': 'Abengourou',
          'cityId': 'abengourou',
          'type': 'ville',
          'isActive': true,
          'isServiceable': true,
          // Exige par DeliveryZone.hasUsableGeometry — valeur reelle des
          // documents de production (verifie).
          'coordinateSource': 'own',
          'lat': 6.7297,
          'lng': -3.4964,
          'radiusKm': 30,
        }),
      ],
    );

PlaceSuggestion _suggestion(String name, double lat, double lng) =>
    PlaceSuggestion(
      placeId: name,
      description: '$name, Abengourou',
      mainText: name,
      secondaryText: 'Abengourou',
      latitude: lat,
      longitude: lng,
      source: 'test',
    );

Future<WebDeliveryPageState> _pump(
  WidgetTester tester, {
  required _MemoryStore store,
  String? uid = 'c1',
}) async {
  tester.view.physicalSize = const Size(1280, 2400);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  await tester.pumpWidget(MaterialApp(
    home: Scaffold(
      body: WebDeliveryPage(
        orderService:
            DeliveryOrderService(store: store, idGenerator: () => 'WEB1'),
        cityService: _cityService(),
        currentUid: () => uid,
        suggest: (q, _) async => [_suggestion('Cafétou', 6.74, -3.50)],
      ),
    ),
  ));
  await tester.pumpAndSettle();
  return tester.state<WebDeliveryPageState>(find.byType(WebDeliveryPage));
}

void main() {
  setUp(() {
    // Evite toute dependance de plateforme : ActiveCityService lit
    // SharedPreferences pour son override manuel de ville.
    SharedPreferences.setMockInitialValues({});
  });

  group('Route /app/commander', () {
    test('est déclarée et n\'est plus un service sans page', () {
      expect(clientAppRoutes, contains(clientDeliveryRoute));
      expect(clientDeliveryRoute, '/app/commander');
      // Elle reste une route privée : la protection /app* du routeur
      // s'applique (vérifiée dans web_client_navigation_test.dart).
      expect(clientDeliveryRoute.startsWith('/app'), isTrue);
      // Ce n'est pas une section à onglet : c'est une page à part entière.
      expect(clientSectionTabs.containsKey(clientDeliveryRoute), isFalse);
    });
  });

  group('Formulaire : validation', () {
    testWidgets('sans adresses, la soumission est refusée', (tester) async {
      final store = _MemoryStore();
      final state = await _pump(tester, store: store);
      expect(state.validate(), contains('point de départ'));
      await state.submit();
      expect(store.submitted, isEmpty);
    });

    testWidgets('destination manquante après un départ choisi',
        (tester) async {
      final state = await _pump(tester, store: _MemoryStore());
      state.debugSetPickup(_suggestion('Commerce', 6.73, -3.49));
      await tester.pump();
      expect(state.validate(), contains('destination'));
    });

    testWidgets('téléphone expéditeur invalide refusé', (tester) async {
      final state = await _pump(tester, store: _MemoryStore());
      state.debugSetPickup(_suggestion('Commerce', 6.73, -3.49));
      state.debugSetDestination(_suggestion('Cafétou', 6.74, -3.50));
      state.debugSetPhones(sender: '123', recipient: '0711111111');
      await tester.pump();
      expect(state.validate(), contains('expéditeur invalide'));
    });

    testWidgets('téléphone destinataire invalide refusé', (tester) async {
      final state = await _pump(tester, store: _MemoryStore());
      state.debugSetPickup(_suggestion('Commerce', 6.73, -3.49));
      state.debugSetDestination(_suggestion('Cafétou', 6.74, -3.50));
      state.debugSetPhones(sender: '0700000000', recipient: 'abc');
      await tester.pump();
      expect(state.validate(), contains('destinataire invalide'));
    });

    testWidgets('formulaire complet : plus aucune erreur', (tester) async {
      final state = await _pump(tester, store: _MemoryStore());
      state.debugSetPickup(_suggestion('Commerce', 6.73, -3.49));
      state.debugSetDestination(_suggestion('Cafétou', 6.74, -3.50));
      state.debugSetPhones(sender: '0700000000', recipient: '0711111111');
      await tester.pump();
      expect(state.validate(), isNull);
      // Prix issu de TarifService, jamais codé dans la page.
      expect(state.price, greaterThanOrEqualTo(500));
    });

    testWidgets('une suggestion sans coordonnées ne vaut pas une adresse',
        (tester) async {
      final state = await _pump(tester, store: _MemoryStore());
      state.debugSetPickup(const PlaceSuggestion(
        placeId: 'x',
        description: 'Sans coordonnées',
        mainText: 'Sans coordonnées',
        secondaryText: '',
        source: 'test',
      ));
      await tester.pump();
      expect(state.validate(), contains('point de départ'));
    });

    testWidgets('wallet : solde insuffisant détecté avant soumission',
        (tester) async {
      final state = await _pump(tester, store: _MemoryStore(balance: 100));
      state.debugSetPickup(_suggestion('Commerce', 6.73, -3.49));
      state.debugSetDestination(_suggestion('Cafétou', 6.74, -3.50));
      state.debugSetPhones(sender: '0700000000', recipient: '0711111111');
      state.debugSetPayment('wallet');
      await tester.pump();
      expect(state.validate(), contains('Solde insuffisant'));
    });
  });

  group('Création de commande', () {
    Future<WebDeliveryPageState> ready(
        WidgetTester tester, _MemoryStore store) async {
      final state = await _pump(tester, store: store);
      state.debugSetPickup(_suggestion('Commerce', 6.73, -3.49));
      state.debugSetDestination(_suggestion('Cafétou', 6.74, -3.50));
      state.debugSetPhones(sender: '0700000000', recipient: '0711111111');
      await tester.pump();
      return state;
    }

    testWidgets('succès : une commande au schéma attendu est créée',
        (tester) async {
      final store = _MemoryStore();
      final state = await ready(tester, store);
      await state.submit();
      await tester.pump();

      expect(store.submitted, hasLength(1));
      final order = store.submitted.single;
      expect(order.type, 'livraison');
      expect(order.status, 'pending');
      expect(order.clientId, 'c1');
      expect(order.driverId, isNull);
      expect(order.budget, greaterThanOrEqualTo(500));
      expect(order.latitude, 6.73);
      expect(order.destLat, 6.74);
      expect(order.recipientPhone, '0711111111');
      // Le dispatch réel est demandé (une seule fois).
      expect(store.dispatchCalls, 1);
    });

    testWidgets('double clic : une seule création', (tester) async {
      final store = _MemoryStore();
      final state = await ready(tester, store);
      // Deux appels concurrents, comme un double clic réel.
      final first = state.submit();
      final second = state.submit();
      await Future.wait([first, second]);
      await tester.pump();
      expect(store.submitted, hasLength(1),
          reason: 'le garde _submitting doit bloquer le second appel');
      expect(store.dispatchCalls, 1);
    });

    testWidgets('erreur backend : message affiché, aucune commande fantôme',
        (tester) async {
      final store = _MemoryStore(failDispatch: true);
      final state = await ready(tester, store);
      await state.submit();
      await tester.pump();
      expect(store.submitted, isEmpty);
      expect(
          find.textContaining('n\'a pas pu être créée'), findsOneWidget);
    });

    testWidgets('session perdue : refus explicite, aucun UID inventé',
        (tester) async {
      final store = _MemoryStore();
      final state = await _pump(tester, store: store, uid: null);
      state.debugSetPickup(_suggestion('Commerce', 6.73, -3.49));
      state.debugSetDestination(_suggestion('Cafétou', 6.74, -3.50));
      state.debugSetPhones(sender: '0700000000', recipient: '0711111111');
      await tester.pump();
      await state.submit();
      await tester.pump();
      expect(store.submitted, isEmpty);
      expect(find.textContaining('Session expirée'), findsOneWidget);
    });
  });
}
