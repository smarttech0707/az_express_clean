import 'dart:async';

import 'package:az_express/models/order_model.dart';
import 'package:az_express/services/delivery_quote_service.dart';
import 'package:az_express/services/pending_quote_store.dart';
import 'package:az_express/services/quoted_checkout.dart';
import 'package:az_express/widgets/quote_confirmation_dialog.dart';
import 'package:az_express/widgets/quoted_checkout_runner.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fake_quote_server.dart';

QuoteRequest req({String mode = 'standard'}) => QuoteRequest(
      serviceType: 'livraison',
      mode: mode,
      pickupLat: 6.7290,
      pickupLng: -3.4950,
      destLat: 6.7310,
      destLng: -3.4925,
    );

DeliveryQuoteService svc(FakeQuoteServer s, {Set<String>? payments}) =>
    DeliveryQuoteService(
        gateway: s,
        clock: () => s.now(),
        retryDelay: Duration.zero,
        allowedPayments: payments ?? const {'wallet'});

Future<QuotedCheckoutResult> go(
  QuotedCheckout c, {
  String uid = 'u1',
  String pay = 'wallet',
  DeliveryQuote? resume,
  ConfirmQuote? confirm,
}) =>
    c.run(
      uid: uid,
      request: req(),
      paymentMethod: pay,
      walletBalance: 5000,
      confirm: confirm ?? (q, {previousAmount}) async => true,
      resume: resume,
    );

OrderModel draft() => OrderModel(
      id: 'draft',
      description: 'd',
      budget: 500,
      status: 'pending',
      latitude: 6.7,
      longitude: -3.4,
      type: 'livraison',
      clientId: 'u1',
      paymentMethod: 'wallet',
    );

void main() {
  group('configuration par défaut (aucun build publié ne change)', () {
    test('drapeaux inactifs, espèces bloquées, wallet seul', () {
      expect(QuotedOrderConfig.enabled, isFalse);
      expect(QuotedOrderConfig.cashEnabled, isFalse);
      expect(QuotedOrderConfig.supportedPayments, {'wallet'});
      expect(QuotedOrderConfig.previewProject, 'az-express-preprod');
    });

    test('garde de projet : seule la préproduction est acceptée, jamais la production',
        () {
      expect(QuotedOrderConfig.projectAllowed('az-express-preprod'), isTrue);
      expect(QuotedOrderConfig.projectAllowed('az-express-b0469'), isFalse);
      expect(QuotedOrderConfig.projectAllowed('az-express-clean'), isFalse);
      expect(QuotedOrderConfig.projectAllowed(''), isFalse);
      expect(QuotedOrderConfig.projectAllowed(null), isFalse);
    });

    test('mauvais projet détecté par la passerelle : aucune commande, rien débité',
        () async {
      final wrong = _WrongProjectGateway();
      final service = DeliveryQuoteService(
          gateway: wrong, retryDelay: Duration.zero);
      final q = DeliveryQuote(
          quoteId: 'q1',
          amount: 500,
          expiresAt: DateTime.now().add(const Duration(minutes: 5)),
          request: req());
      final o = await service.createOrder(
          quote: q,
          acceptedAmount: 500,
          paymentMethod: 'wallet',
          walletBalance: 5000);
      expect(
          o,
          isA<QuotedOrderRefused>()
              .having((x) => x.code, 'code', 'WRONG_PROJECT'));
      expect(wrong.calls, 1);
      expect(wrong.reachedServer, isFalse);
    });

    test('espèces refusées avant tout appel tant que non validées', () async {
      final s = FakeQuoteServer();
      final service = DeliveryQuoteService(
          gateway: s, clock: () => s.now(), retryDelay: Duration.zero);
      final q = await service.requestQuote(req());
      final o = await service.createOrder(
          quote: q,
          acceptedAmount: q.amount,
          paymentMethod: 'cash',
          walletBalance: 5000);
      expect(
          o,
          isA<QuotedOrderRefused>()
              .having((x) => x.code, 'code', 'PAYMENT_METHOD_UNSUPPORTED'));
      expect(s.createCalls, 0);
    });
  });

  group('redémarrage, réouverture, changement de compte', () {
    Future<(FakeQuoteServer, MemoryPendingQuoteStore)> lostEverywhere() async {
      final s = FakeQuoteServer()..loseResponsesAfterExecution = 3;
      final store = MemoryPendingQuoteStore();
      final r = await go(QuotedCheckout(svc(s), store: store));
      expect(r, isA<CheckoutUncertain>());
      expect(s.debits, 1, reason: 'le serveur a exécuté, le client ne le sait pas');
      expect(await store.load('u1'), isNotNull, reason: 'tentative mémorisée');
      return (s, store);
    }

    test('redémarrage : nouveau devis refusé tant que la tentative n\'est pas vérifiée',
        () async {
      final (s, store) = await lostEverywhere();
      final restarted = QuotedCheckout(svc(s), store: store); // nouvelle instance
      final r = await go(restarted);
      expect(r,
          isA<CheckoutFailed>().having((f) => f.code, 'code', 'PENDING_ORDER_UNRESOLVED'));
      expect(s.quoteCalls, 1, reason: 'aucun second devis');
      expect(s.debits, 1);
    });

    test('redémarrage puis vérification : même commande retrouvée, aucun second débit',
        () async {
      final (s, store) = await lostEverywhere();
      final restarted = QuotedCheckout(svc(s), store: store);
      final r = await restarted.recover('u1');
      expect(r, isA<CheckoutCreated>().having((c) => c.replayed, 'replayed', isTrue));
      expect(s.debits, 1);
      expect(s.orders.length, 1);
      expect(s.wallet, 4500);
      expect(await store.load('u1'), isNull);
    });

    test('devis expiré entre-temps : la commande déjà créée est quand même retrouvée',
        () async {
      var t = DateTime.utc(2026, 11, 2, 12);
      final s = FakeQuoteServer(clock: () => t)..loseResponsesAfterExecution = 3;
      final store = MemoryPendingQuoteStore();
      await go(QuotedCheckout(svc(s), store: store));
      t = t.add(const Duration(hours: 2));
      final r = await QuotedCheckout(svc(s), store: store).recover('u1');
      expect(r, isA<CheckoutCreated>());
      expect(s.debits, 1);
    });

    test('appel jamais arrivé au serveur et devis expiré : aucune commande, tentative effacée, nouveau devis possible',
        () async {
      var t = DateTime.utc(2026, 11, 2, 12);
      final s = FakeQuoteServer(clock: () => t)..failBeforeExecution = 3;
      final store = MemoryPendingQuoteStore();
      final first = await go(QuotedCheckout(svc(s), store: store));
      expect(first, isA<CheckoutUncertain>());
      expect(s.debits, 0);
      t = t.add(const Duration(hours: 2));
      final c = QuotedCheckout(svc(s), store: store);
      expect(await c.recover('u1'), isNull);
      expect(await store.load('u1'), isNull);
      final again = await go(c);
      expect(again, isA<CheckoutCreated>());
      expect(s.debits, 1);
      expect(s.orders.length, 1);
    });

    test('vérification impossible (réseau) : tentative conservée, toujours bloqué',
        () async {
      final (s, store) = await lostEverywhere();
      s.failBeforeExecution = 3;
      final c = QuotedCheckout(svc(s), store: store);
      expect(await c.recover('u1'), isA<CheckoutUncertain>());
      expect(await store.load('u1'), isNotNull);
      expect(await go(c),
          isA<CheckoutFailed>().having((f) => f.code, 'code', 'PENDING_ORDER_UNRESOLVED'));
    });

    test('changement de compte : la tentative de u1 ne bloque ni ne fuit vers u2',
        () async {
      final (s, store) = await lostEverywhere();
      final c = QuotedCheckout(svc(s), store: store);
      expect(await c.pending('u2'), isNull);
      expect(await c.recover('u2'), isNull);
      expect(await store.load('u1'), isNotNull);
    });

    test('commande réussie : rien n\'est conservé', () async {
      final s = FakeQuoteServer();
      final store = MemoryPendingQuoteStore();
      expect(await go(QuotedCheckout(svc(s), store: store)), isA<CheckoutCreated>());
      expect(await store.load('u1'), isNull);
    });

    test('annulation à la confirmation : rien n\'est conservé', () async {
      final s = FakeQuoteServer();
      final store = MemoryPendingQuoteStore();
      final r = await go(QuotedCheckout(svc(s), store: store),
          confirm: (q, {previousAmount}) async => false);
      expect(r, isA<CheckoutCancelled>());
      expect(await store.load('u1'), isNull);
      expect(s.createCalls, 0);
    });

    test('stockage défaillant : la commande aboutit quand même', () async {
      final s = FakeQuoteServer();
      final r = await go(QuotedCheckout(svc(s), store: _BrokenStore()));
      expect(r, isA<CheckoutCreated>());
      expect(s.debits, 1);
    });
  });

  group('verrou anti double commande', () {
    test('deuxième exécution pendant la confirmation : refusée, un seul débit',
        () async {
      final s = FakeQuoteServer();
      final c = QuotedCheckout(svc(s), store: MemoryPendingQuoteStore());
      final gate = Completer<bool>();
      final first = go(c, confirm: (q, {previousAmount}) => gate.future);
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);
      final second = await go(c);
      expect(second,
          isA<CheckoutFailed>().having((f) => f.code, 'code', 'CHECKOUT_BUSY'));
      gate.complete(true);
      expect(await first, isA<CheckoutCreated>());
      expect(s.debits, 1);
      expect(s.orders.length, 1);
    });
  });

  group('persistance locale', () {
    test('aller-retour JSON complet', () async {
      final s = FakeQuoteServer();
      final q = await svc(s).requestQuote(req(mode: 'express'));
      final p = PendingQuote(
          uid: 'u1',
          quote: q,
          paymentMethod: 'wallet',
          shoppingBudget: 700,
          orderFields: const {'description': 'liste'});
      final back = PendingQuote.fromJson(p.toJson())!;
      expect(back.quote.quoteId, q.quoteId);
      expect(back.quote.amount, 1000);
      expect(back.quote.request.mode, 'express');
      expect(back.quote.request.sameAs(q.request), isTrue);
      expect(back.shoppingBudget, 700);
      expect(back.orderFields['description'], 'liste');
    });

    test('SharedPreferences : une clé par compte, données illisibles ignorées',
        () async {
      SharedPreferences.setMockInitialValues({'pending_quote_bad': '{pas du json'});
      final store = SharedPrefsPendingQuoteStore();
      final s = FakeQuoteServer();
      final q = await svc(s).requestQuote(req());
      await store.save(PendingQuote(uid: 'a', quote: q, paymentMethod: 'wallet'));
      expect((await store.load('a'))!.quote.quoteId, q.quoteId);
      expect(await store.load('b'), isNull);
      expect(await store.load('bad'), isNull);
      await store.clear('a');
      expect(await store.load('a'), isNull);
    });
  });

  group('boîtes de dialogue', () {
    Future<void> open(WidgetTester t, DeliveryQuote q,
        {int shopping = 0, int? previous, void Function(bool)? onResult}) async {
      await t.pumpWidget(MaterialApp(
        home: Builder(
          builder: (ctx) => Scaffold(
            body: Center(
              child: ElevatedButton(
                key: const Key('open'),
                onPressed: () async {
                  final ok = await showQuoteConfirmation(ctx,
                      quote: q,
                      paymentLabel: 'Wallet AZ',
                      shoppingBudget: shopping,
                      previousAmount: previous);
                  onResult?.call(ok);
                },
                child: const Text('go'),
              ),
            ),
          ),
        ),
      ));
      await t.tap(find.byKey(const Key('open')));
      await t.pumpAndSettle();
    }

    Future<DeliveryQuote> quote({String mode = 'standard'}) =>
        svc(FakeQuoteServer()..officialExpress = 1500).requestQuote(req(mode: mode));

    testWidgets('affiche le prix officiel, Confirmer renvoie vrai', (t) async {
      bool? res;
      await open(t, await quote(), onResult: (v) => res = v);
      expect(find.byKey(const Key('quote-amount')), findsOneWidget);
      expect(find.text('500 FCFA'), findsOneWidget);
      expect(find.textContaining('Standard'), findsOneWidget);
      expect(find.byKey(const Key('quote-price-changed')), findsNothing);
      await t.tap(find.byKey(const Key('quote-confirm')));
      await t.pumpAndSettle();
      expect(res, isTrue);
    });

    testWidgets('Annuler renvoie faux', (t) async {
      bool? res;
      await open(t, await quote(), onResult: (v) => res = v);
      await t.tap(find.byKey(const Key('quote-cancel')));
      await t.pumpAndSettle();
      expect(res, isFalse);
    });

    testWidgets('tarif changé : ancien et nouveau prix, rien débité', (t) async {
      await open(t, await quote(mode: 'express'), previous: 500);
      expect(find.byKey(const Key('quote-price-changed')), findsOneWidget);
      expect(find.textContaining('Ancien prix : 500 FCFA'), findsOneWidget);
      expect(find.textContaining('Nouveau prix : 1500 FCFA'), findsOneWidget);
      expect(find.textContaining('Rien n\'a été débité'), findsOneWidget);
    });

    testWidgets('budget d\'achat : total = livraison + budget', (t) async {
      await open(t, await quote(), shopping: 2000);
      expect(find.text('Total : 2500 FCFA'), findsOneWidget);
    });

    Future<void> host(WidgetTester t, Future<void> Function(BuildContext) run) async {
      await t.pumpWidget(MaterialApp(
        home: Builder(
          builder: (ctx) => Scaffold(
            body: ElevatedButton(
                key: const Key('start'), onPressed: () => run(ctx), child: const Text('go')),
          ),
        ),
      ));
    }

    testWidgets('réponse perdue : « Vérifier » retrouve la commande, un seul débit',
        (t) async {
      final s = FakeQuoteServer()..loseResponsesAfterExecution = 3;
      final c = QuotedCheckout(svc(s), store: MemoryPendingQuoteStore());
      QuotedCheckoutResult? res;
      await host(t, (ctx) async {
        res = await runQuotedCheckoutWithUi(ctx,
            checkout: c,
            uid: 'u1',
            request: req(),
            paymentMethod: 'wallet',
            walletBalance: 5000,
            draft: draft());
      });
      await t.tap(find.byKey(const Key('start')));
      await t.pumpAndSettle();
      await t.tap(find.byKey(const Key('quote-confirm')));
      await t.pumpAndSettle();
      expect(find.byKey(const Key('quote-uncertain')), findsOneWidget);
      await t.tap(find.byKey(const Key('quote-retry')));
      await t.pumpAndSettle();
      expect(res, isA<CheckoutCreated>().having((x) => x.replayed, 'replayed', isTrue));
      expect(s.debits, 1);
      expect(s.orders.length, 1);
    });

    testWidgets('« Fermer » puis écran rouvert : vérification demandée avant tout nouveau devis',
        (t) async {
      final s = FakeQuoteServer()..loseResponsesAfterExecution = 3;
      final store = MemoryPendingQuoteStore();
      QuotedCheckoutResult? res;
      QuotedCheckout fresh() => QuotedCheckout(svc(s), store: store);
      await host(t, (ctx) async {
        res = await runQuotedCheckoutWithUi(ctx,
            checkout: fresh(),
            uid: 'u1',
            request: req(),
            paymentMethod: 'wallet',
            walletBalance: 5000,
            draft: draft());
      });
      await t.tap(find.byKey(const Key('start')));
      await t.pumpAndSettle();
      await t.tap(find.byKey(const Key('quote-confirm')));
      await t.pumpAndSettle();
      await t.tap(find.byKey(const Key('quote-close')));
      await t.pumpAndSettle();
      expect(res, isA<CheckoutUncertain>());
      expect(s.quoteCalls, 1);

      // L'écran est rouvert (nouvelle instance, même stockage) : vérification d'abord.
      await t.tap(find.byKey(const Key('start')));
      await t.pumpAndSettle();
      expect(find.byKey(const Key('quote-uncertain')), findsOneWidget);
      expect(find.byKey(const Key('quote-confirmation')), findsNothing);
      await t.tap(find.byKey(const Key('quote-retry')));
      await t.pumpAndSettle();
      expect(res, isA<CheckoutCreated>());
      expect(s.quoteCalls, 1, reason: 'aucun nouveau devis');
      expect(s.debits, 1);
    });

    testWidgets('« Fermer » sur la vérification : aucune commande, aucun appel',
        (t) async {
      final s = FakeQuoteServer()..loseResponsesAfterExecution = 3;
      final store = MemoryPendingQuoteStore();
      await t.runAsync(() => QuotedCheckout(svc(s), store: store).run(
          uid: 'u1',
          request: req(),
          paymentMethod: 'wallet',
          walletBalance: 5000,
          confirm: (q, {previousAmount}) async => true));
      final calls = s.createCalls;
      QuotedCheckoutResult? res;
      await host(t, (ctx) async {
        res = await runQuotedCheckoutWithUi(ctx,
            checkout: QuotedCheckout(svc(s), store: store),
            uid: 'u1',
            request: req(),
            paymentMethod: 'wallet',
            walletBalance: 5000,
            draft: draft());
      });
      await t.tap(find.byKey(const Key('start')));
      await t.pumpAndSettle();
      await t.tap(find.byKey(const Key('quote-close')));
      await t.pumpAndSettle();
      expect(res, isA<CheckoutCancelled>());
      expect(s.createCalls, calls);
      expect(await store.load('u1'), isNotNull);
    });
  });
}

/// Simule CloudDeliveryQuoteGateway face à une application Firebase de production.
class _WrongProjectGateway implements DeliveryQuoteGateway {
  int calls = 0;
  bool reachedServer = false;
  @override
  Future<Map<String, dynamic>> call(
      String name, Map<String, dynamic> payload) async {
    calls++;
    if (!QuotedOrderConfig.projectAllowed('az-express-b0469')) {
      throw const DeliveryQuoteException('WRONG_PROJECT', 'mauvais projet');
    }
    reachedServer = true;
    return {};
  }
}

class _BrokenStore implements PendingQuoteStore {
  @override
  Future<PendingQuote?> load(String uid) async => throw StateError('disque');
  @override
  Future<void> save(PendingQuote pending) async => throw StateError('disque');
  @override
  Future<void> clear(String uid) async => throw StateError('disque');
}
