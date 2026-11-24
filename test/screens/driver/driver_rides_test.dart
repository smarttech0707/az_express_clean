import 'dart:async';
import 'dart:io';

import 'package:cloud_firestore/cloud_firestore.dart' show Timestamp;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:az_express/screens/driver/driver_rides_logic.dart';
import 'package:az_express/screens/driver/driver_rides_page.dart';
import 'package:az_express/screens/driver/driver_rides_service.dart';

DriverRide ride(String id,
        {String status = 'delivered',
        String? cancelReason,
        int budget = 500,
        String? pickup = 'Marché',
        String? dest = 'Gare'}) =>
    DriverRide(
      id: id,
      status: status,
      budget: budget,
      description: '',
      paymentMethod: 'cash',
      createdAt: DateTime(2026, 10, 31, 9, 5),
      cancelReason: cancelReason,
      pickupAddress: pickup,
      deliveryAddress: dest,
    );

class _FakeService extends DriverRidesService {
  _FakeService({this.live, this.pages = const [], this.failFirst = false})
      : super(driverId: 'd1');

  final Stream<List<DriverRide>>? live;
  final List<DriverRidesBatch> pages;
  bool failFirst;
  final List<Object?> cursors = [];
  final List<DriverRideTab> tabsQueried = [];

  @override
  Stream<List<DriverRide>> watchInProgress() => live ?? Stream.value(const []);

  @override
  Future<DriverRidesBatch> fetchPage(
      DriverRideTab tab, Object? cursor, int limit) async {
    tabsQueried.add(tab);
    cursors.add(cursor);
    if (failFirst) {
      failFirst = false;
      throw Exception('réseau');
    }
    final i = cursors.length - 1;
    return pages[i.clamp(0, pages.length - 1)];
  }
}

Widget _app(Widget child) => MaterialApp(home: child);

// La fin d'un chargement asynchrone survient après l'image tirée : un dernier pump() l'affiche.
Future<void> settle(WidgetTester t) async {
  await t.pump(const Duration(milliseconds: 100));
  await t.pump(const Duration(milliseconds: 500));
  await t.pump();
}

void main() {
  group('classification et statuts réels', () {
    test('statuts réels Firestore → nature de la course', () {
      expect(ride('a', status: 'assigned').kind, DriverRideKind.proposed);
      expect(ride('a', status: 'accepted').kind, DriverRideKind.inProgress);
      expect(ride('a', status: 'picked_up').kind, DriverRideKind.inProgress);
      expect(ride('a', status: 'delivered').kind, DriverRideKind.delivered);
      expect(ride('a', status: 'cancelled').kind, DriverRideKind.cancelled);
      expect(ride('a', status: 'inconnu').kind, DriverRideKind.other);
    });

    test('une expiration automatique n\'est jamais présentée comme un refus ni une annulation', () {
      final expired = ride('a', status: 'cancelled', cancelReason: 'no_driver_found');
      expect(expired.kind, DriverRideKind.expired);
      expect(expired.statusLabelOverride, 'Expirée (aucun livreur)');
      expect(expired.statusLabelOverride!.toLowerCase().contains('refus'), isFalse);
      // Une annulation ordinaire garde le libellé « Annulée » du vocabulaire partagé.
      expect(ride('a', status: 'cancelled', cancelReason: 'client').statusLabelOverride, isNull);
      expect(ride('a', status: 'cancelled').statusLabelOverride, isNull);
    });

    test('une proposition n\'est pas « Acceptée » ; un statut inconnu garde son libellé brut', () {
      expect(ride('a', status: 'assigned').statusLabelOverride, 'Proposée');
      expect(ride('a', status: 'zzz').statusLabelOverride, 'zzz');
    });

    test('statuts interrogés par onglet ; Refusées n\'a aucune requête', () {
      expect(statusesForTab(DriverRideTab.inProgress), ['accepted', 'picked_up']);
      expect(statusesForTab(DriverRideTab.delivered), ['delivered']);
      expect(statusesForTab(DriverRideTab.cancelled), ['cancelled']);
      expect(statusesForTab(DriverRideTab.all), isNull);
      expect(() => statusesForTab(DriverRideTab.refused), throwsArgumentError);
    });

    test('fromMap : montant lu tel quel, adresses vides ignorées, dates converties', () {
      final r = DriverRide.fromMap('abcdef1234', {
        'status': 'delivered',
        'budget': 500,
        'pickupAddress': '  ',
        'deliveryAddress': 'Gare',
        'createdAt': Timestamp.fromDate(DateTime(2026, 10, 31, 8, 0)),
        'paymentMethod': 'wallet',
      });
      expect(r.budget, 500);
      expect(r.pickupAddress, isNull);
      expect(r.deliveryAddress, 'Gare');
      expect(r.createdAt, isNotNull);
      expect(r.shortId, 'ABCDEF12');
      // Champs absents / mal typés : pas d'exception.
      final bad = DriverRide.fromMap('x', {'budget': 'abc', 'status': null});
      expect(bad.budget, 0);
      expect(bad.status, '');
    });
  });

  group('gain : uniquement une source fiable', () {
    test('un seul crédit égal au montant attendu → gain connu', () {
      expect(reliableEarnings([(orderId: 'o1', amount: 500)], expected: {'o1': 500}), {'o1': 500});
    });
    test('crédits multiples, absents, nuls, non entiers, ou différents du montant attendu → pas de gain', () {
      final m = reliableEarnings([
        (orderId: 'dup', amount: 500),
        (orderId: 'dup', amount: 500),
        (orderId: 'zero', amount: 0),
        (orderId: 'neg', amount: -5),
        (orderId: 'str', amount: '500'),
        (orderId: 'dbl', amount: 500.5),
        (orderId: 'null', amount: null),
        (orderId: 'forged', amount: 99999), // journal inscriptible par le livreur : montant ≠ budget
        (orderId: 'unexpected', amount: 500), // course non éligible (pas dans expected)
        (orderId: 'ok', amount: 500),
      ], expected: {
        'dup': 500, 'zero': 500, 'neg': 500, 'str': 500, 'dbl': 500, 'null': 500, 'forged': 500, 'ok': 500,
      });
      expect(m, {'ok': 500});
    });
    test('aucun crédit → aucun gain (rien n\'est calculé à partir du budget)', () {
      expect(reliableEarnings(const [], expected: {'o1': 500}), isEmpty);
    });
    test('montant attendu : seulement une course livrée, sans budget d\'achat, au budget positif', () {
      expect(expectedCredit(ride('a')), 500);
      expect(expectedCredit(ride('a', status: 'accepted')), isNull);
      expect(expectedCredit(ride('a', status: 'cancelled')), isNull);
      expect(expectedCredit(ride('a', budget: 0)), isNull);
      final withShopping = DriverRide.fromMap('s', {'status': 'delivered', 'budget': 500, 'shoppingBudget': 3000});
      expect(expectedCredit(withShopping), isNull); // crédit = budget + avance : pas un gain
    });
  });

  group('formats', () {
    test('date, montant, paiement', () {
      expect(formatRideDateTime(DateTime(2026, 1, 2, 3, 4)), '02/01/2026 à 03:04');
      expect(formatRideDateTime(null), 'Date inconnue');
      expect(formatFcfa(500), '500 FCFA');
      expect(formatFcfa(12500), '12 500 FCFA');
      expect(paymentLabel('cash'), 'Espèces');
      expect(paymentLabel('wallet'), 'Portefeuille');
      expect(paymentLabel(''), 'Non renseigné');
    });
  });

  group('pagination (contrôleur)', () {
    DriverRidesBatch batch(List<String> ids, {bool more = false, Object? cursor}) =>
        DriverRidesBatch(rides: [for (final i in ids) ride(i)], hasMore: more, cursor: cursor);

    test('charge page par page sans tout charger, s\'arrête quand il n\'y a plus rien', () async {
      final calls = <(Object?, int)>[];
      final pages = [
        batch(['1', '2'], more: true, cursor: 'c2'),
        batch(['3'], more: false, cursor: 'c3'),
      ];
      final c = DriverRidesController((cursor, limit) async {
        calls.add((cursor, limit));
        return pages[calls.length - 1];
      }, pageSize: 2);
      await c.loadMore();
      expect(c.rides.map((r) => r.id), ['1', '2']);
      expect(c.hasMore, isTrue);
      await c.loadMore();
      expect(c.rides.map((r) => r.id), ['1', '2', '3']);
      expect(c.hasMore, isFalse);
      await c.loadMore(); // plus de page : aucun appel
      expect(calls, [(null, 2), ('c2', 2)]);
    });

    test('pas de doublon si une page répète un document', () async {
      final pages = [batch(['1', '2'], more: true, cursor: 'c'), batch(['2', '3'])];
      var n = 0;
      final c = DriverRidesController((_, __) async => pages[n++], pageSize: 2);
      await c.loadMore();
      await c.loadMore();
      expect(c.rides.map((r) => r.id), ['1', '2', '3']);
    });

    test('deux chargements simultanés = une seule requête', () async {
      var n = 0;
      final gate = Completer<DriverRidesBatch>();
      final c = DriverRidesController((_, __) {
        n++;
        return gate.future;
      });
      final a = c.loadMore();
      final b = c.loadMore();
      gate.complete(batch(['1']));
      await Future.wait([a, b]);
      expect(n, 1);
    });

    test('liste vide : état vide, pas d\'erreur', () async {
      final c = DriverRidesController((_, __) async => batch(const []));
      await c.loadMore();
      expect(c.isEmpty, isTrue);
      expect(c.error, isNull);
    });

    test('erreur puis nouvel essai ; les pages déjà chargées sont conservées', () async {
      var n = 0;
      final c = DriverRidesController((_, __) async {
        n++;
        if (n == 2) throw Exception('réseau');
        return n == 1 ? batch(['1'], more: true, cursor: 'c') : batch(['2']);
      }, pageSize: 1);
      await c.loadMore();
      await c.loadMore();
      expect(c.error, isNotNull);
      expect(c.rides.map((r) => r.id), ['1']);
      await c.loadMore();
      expect(c.error, isNull);
      expect(c.rides.map((r) => r.id), ['1', '2']);
    });

    test('actualisation : repart de zéro et ignore une réponse périmée', () async {
      final slow = Completer<DriverRidesBatch>();
      var n = 0;
      final c = DriverRidesController((_, __) {
        n++;
        return n == 1 ? slow.future : Future.value(batch(['new']));
      });
      final first = c.loadMore();
      await c.refresh();
      slow.complete(batch(['stale']));
      await first;
      expect(c.rides.map((r) => r.id), ['new']);
    });
  });

  group('écrans', () {
    testWidgets('5 onglets ; Refusées : message explicatif, aucune donnée inventée, aucune requête', (tester) async {
      final service = _FakeService();
      await tester.pumpWidget(_app(DriverRidesPage(driverId: 'd1', service: service)));
      await settle(tester);
      for (final label in ['En cours', 'Terminées', 'Refusées', 'Annulées', 'Toutes']) {
        expect(find.text(label), findsWidgets, reason: label);
      }
      await tester.ensureVisible(find.widgetWithText(Tab, 'Refusées'));
      await tester.tap(find.widgetWithText(Tab, 'Refusées'));
      await settle(tester);
      expect(find.textContaining('bientôt disponible'), findsOneWidget);
      expect(find.textContaining('avant ne'), findsOneWidget);
      expect(service.tabsQueried.contains(DriverRideTab.refused), isFalse);
    });

    testWidgets('onglet vide : écran vide explicite', (tester) async {
      final service = _FakeService(pages: [const DriverRidesBatch(rides: [], hasMore: false)]);
      await tester.pumpWidget(_app(DriverRidesPage(driverId: 'd1', service: service)));
      await settle(tester);
      expect(find.text('Aucune course en cours'), findsOneWidget);
      await tester.ensureVisible(find.widgetWithText(Tab, 'Terminées'));
      await tester.tap(find.widgetWithText(Tab, 'Terminées'));
      await settle(tester);
      expect(find.text('Aucune course terminée'), findsOneWidget);
    });

    testWidgets('liste : date, numéro, adresses, montant, statut, gain « — » sans source fiable', (tester) async {
      final service = _FakeService(
        pages: [
          DriverRidesBatch(
            rides: [ride('abc12345xyz'), ride('zzz99999xyz', status: 'cancelled', cancelReason: 'no_driver_found')],
            hasMore: false,
            earnings: const {'abc12345xyz': 400},
          ),
        ],
      );
      await tester.pumpWidget(_app(DriverRidesPage(driverId: 'd1', service: service)));
      await settle(tester);
      await tester.ensureVisible(find.widgetWithText(Tab, 'Toutes'));
      await tester.tap(find.widgetWithText(Tab, 'Toutes'));
      await settle(tester);
      expect(find.text('N° ABC12345'), findsOneWidget);
      expect(find.text('31/10/2026 à 09:05'), findsNWidgets(2));
      expect(find.text('Gain : 400 FCFA'), findsOneWidget);
      expect(find.text('Gain : —'), findsOneWidget);
      expect(find.text('Expirée (aucun livreur)'), findsOneWidget);
      expect(find.text('Course : 500 FCFA'), findsNWidgets(2));
    });

    testWidgets('erreur : message + bouton Réessayer, pas de spinner infini', (tester) async {
      final service = _FakeService(
        pages: [DriverRidesBatch(rides: [ride('abc12345xyz')], hasMore: false)],
        failFirst: true,
      );
      await tester.pumpWidget(_app(DriverRidesPage(driverId: 'd1', service: service)));
      await settle(tester);
      await tester.ensureVisible(find.widgetWithText(Tab, 'Toutes'));
      await tester.tap(find.widgetWithText(Tab, 'Toutes'));
      await settle(tester);
      expect(find.text('Impossible de charger vos courses.'), findsOneWidget);
      expect(find.byType(CircularProgressIndicator), findsNothing);
      await tester.tap(find.text('Réessayer'));
      await settle(tester);
      expect(find.text('N° ABC12345'), findsOneWidget);
    });

    testWidgets('flux « en cours » : erreur de flux gérée', (tester) async {
      final service = _FakeService(live: Stream<List<DriverRide>>.error('permission-denied'));
      await tester.pumpWidget(_app(DriverRidesPage(driverId: 'd1', service: service)));
      await settle(tester);
      expect(find.text('Impossible de charger vos courses en cours.'), findsOneWidget);
    });

    testWidgets('détail : expiration expliquée comme « pas un refus », gain inconnu = —', (tester) async {
      await tester.pumpWidget(_app(DriverRideDetailPage(
        ride: ride('abc12345xyz', status: 'cancelled', cancelReason: 'no_driver_found'),
      )));
      await settle(tester);
      expect(find.textContaining('Ce n\'est pas un refus'), findsOneWidget);
      expect(find.text('abc12345xyz'), findsOneWidget);
      expect(find.text('—'), findsOneWidget);
    });

    testWidgets('petit écran Android 320x568 : aucune erreur de débordement', (tester) async {
      tester.view.physicalSize = const Size(320 * 2, 568 * 2);
      tester.view.devicePixelRatio = 2;
      addTearDown(tester.view.reset);
      final service = _FakeService(pages: [
        DriverRidesBatch(
          rides: [ride('abc12345xyz', pickup: 'Quartier résidentiel très très long nom de rue', dest: 'Boulevard de la République, Abengourou centre-ville, près du marché')],
          hasMore: false,
        ),
      ]);
      await tester.pumpWidget(_app(DriverRidesPage(driverId: 'd1', service: service)));
      await settle(tester);
      await tester.ensureVisible(find.widgetWithText(Tab, 'Toutes'));
      await tester.tap(find.widgetWithText(Tab, 'Toutes'));
      await settle(tester);
      expect(tester.takeException(), isNull);
    });
  });

  group('accès aux données du livreur', () {
    final src = File('lib/screens/driver/driver_rides_service.dart').readAsStringSync();
    test('toutes les requêtes sont bornées au livreur courant, lecture seule', () {
      expect(src.contains("where('driverId', isEqualTo: driverId)"), isTrue);
      expect(RegExp(r"\.(set|update|delete)\(|runTransaction|batch\(").hasMatch(src), isFalse);
      expect(src.contains("doc(driverId)"), isTrue);
      // Les gains viennent du portefeuille du livreur, jamais d'une collection admin.
      expect(src.contains("'commissions'"), isFalse);
    });
    test('pagination par curseur et limite explicite', () {
      expect(src.contains('startAfterDocument'), isTrue);
      expect(src.contains('.limit('), isTrue);
    });
  });
}
