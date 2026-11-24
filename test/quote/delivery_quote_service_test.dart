import 'dart:io';

import 'package:az_express/models/order_model.dart';
import 'package:az_express/services/delivery_quote_service.dart';
import 'package:az_express/services/pending_quote_store.dart';
import 'package:az_express/services/quoted_checkout.dart';
import 'package:az_express/services/quoted_order_finalizer.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fake_quote_server.dart';

QuoteRequest req({String mode = 'standard', double destLat = 6.7310}) =>
    QuoteRequest(
      serviceType: 'livraison',
      mode: mode,
      pickupLat: 6.7290,
      pickupLng: -3.4950,
      destLat: destLat,
      destLng: -3.4925,
      routeDistanceKm: 0.01, // falsifiée : le serveur décide
    );

DeliveryQuoteService svc(FakeQuoteServer s) => DeliveryQuoteService(
    gateway: s,
    clock: () => s.now(),
    retryDelay: Duration.zero,
    allowedPayments: const {'wallet', 'cash'});

class _Canned implements DeliveryQuoteGateway {
  _Canned(this.reply);
  final Map<String, dynamic> reply;
  @override
  Future<Map<String, dynamic>> call(
          String name, Map<String, dynamic> payload) async =>
      reply;
}

void main() {
  group('affichage du devis officiel', () {
    test('le prix vient du serveur, pas du téléphone', () async {
      final s = FakeQuoteServer()..officialStandard = 500;
      final q = await svc(s).requestQuote(req());
      expect(q.amount, 500);
      expect(q.quoteId, isNotEmpty);
      expect(q.expiresAt.isAfter(s.now()), isTrue);
      expect(q.request.mode, 'standard');
    });

    test('réponse de devis invalide (montant < 500) refusée', () async {
      final bad = _Canned({
        'success': true,
        'data': {'quoteId': 'x', 'amount': 1, 'expiresAtMs': 1}
      });
      expect(DeliveryQuoteService(gateway: bad).requestQuote(req()),
          throwsA(isA<DeliveryQuoteException>()));
    });

    test('refus serveur (hors zone) → exception avec code', () async {
      final r = _Canned(
          {'success': false, 'code': 'OUTSIDE_SERVICE', 'message': 'hors zone'});
      expect(
          DeliveryQuoteService(gateway: r).requestQuote(req()),
          throwsA(isA<DeliveryQuoteException>()
              .having((e) => e.code, 'code', 'OUTSIDE_SERVICE')));
    });
  });

  group('confirmation et création', () {
    test('confirmation → un seul débit du montant officiel', () async {
      final s = FakeQuoteServer(wallet: 5000);
      final r = await QuotedCheckout(svc(s), store: MemoryPendingQuoteStore()).run(
        uid: 'u1',
        request: req(),
        paymentMethod: 'wallet',
        walletBalance: 5000,
        confirm: (q, {previousAmount}) async =>
            q.amount == 500 && previousAmount == null,
      );
      expect(r, isA<CheckoutCreated>());
      expect(s.wallet, 4500);
      expect(s.debits, 1);
    });

    test('annulation avant confirmation : aucun appel de création, aucun débit',
        () async {
      final s = FakeQuoteServer();
      final r = await QuotedCheckout(svc(s), store: MemoryPendingQuoteStore()).run(
        uid: 'u1',
        request: req(),
        paymentMethod: 'wallet',
        walletBalance: 5000,
        confirm: (q, {previousAmount}) async => false,
      );
      expect(r, isA<CheckoutCancelled>());
      expect(s.createCalls, 0);
      expect(s.wallet, 5000);
    });

    test('le montant confirmé doit égaler le devis (sinon aucun appel)',
        () async {
      final s = FakeQuoteServer();
      final q = await svc(s).requestQuote(req());
      final o = await svc(s).createOrder(
          quote: q,
          acceptedAmount: q.amount - 100,
          paymentMethod: 'wallet',
          walletBalance: 5000);
      expect(
          o,
          isA<QuotedOrderRefused>()
              .having((x) => x.code, 'code', 'AMOUNT_NOT_CONFIRMED'));
      expect(s.createCalls, 0);
    });

    test('solde insuffisant : refus local, aucun appel (livraison + budget)',
        () async {
      final s = FakeQuoteServer(wallet: 1200);
      final q = await svc(s).requestQuote(req());
      final o = await svc(s).createOrder(
          quote: q,
          acceptedAmount: q.amount,
          paymentMethod: 'wallet',
          walletBalance: 1200,
          shoppingBudget: 1000);
      expect(
          o,
          isA<QuotedOrderRefused>()
              .having((x) => x.code, 'code', 'SOLDE_INSUFFISANT'));
      expect(s.createCalls, 0);
      expect(s.wallet, 1200);
    });

    test('espèces : commande créée, aucun débit wallet', () async {
      final s = FakeQuoteServer();
      final r = await QuotedCheckout(svc(s), store: MemoryPendingQuoteStore()).run(
        uid: 'u1',
        request: req(),
        paymentMethod: 'cash',
        walletBalance: 0,
        confirm: (q, {previousAmount}) async => true,
      );
      expect(r, isA<CheckoutCreated>().having((c) => c.charged, 'charged', 0));
      expect(s.debits, 0);
    });

    test('budget d\'achat : débité en plus, jamais transformé en prix imposé',
        () async {
      final s = FakeQuoteServer(wallet: 5000);
      final r = await QuotedCheckout(svc(s), store: MemoryPendingQuoteStore()).run(
        uid: 'u1',
        request: req(),
        paymentMethod: 'wallet',
        walletBalance: 5000,
        shoppingBudget: 2000,
        confirm: (q, {previousAmount}) async => true,
      );
      expect(r, isA<CheckoutCreated>().having((c) => c.charged, 'charged', 2500));
      expect(s.wallet, 2500);
    });

    test('mobile money non pris en charge : refus avant tout appel', () async {
      final s = FakeQuoteServer();
      final q = await svc(s).requestQuote(req());
      final o = await svc(s).createOrder(
          quote: q,
          acceptedAmount: q.amount,
          paymentMethod: 'orange_money',
          walletBalance: 5000);
      expect(
          o,
          isA<QuotedOrderRefused>()
              .having((x) => x.code, 'code', 'PAYMENT_METHOD_UNSUPPORTED'));
      expect(s.createCalls, 0);
    });
  });

  group('double clic et réponse perdue', () {
    test('double clic : un seul appel serveur, même résultat', () async {
      final s = FakeQuoteServer();
      final service = svc(s);
      final q = await service.requestQuote(req());
      final a = service.createOrder(
          quote: q,
          acceptedAmount: q.amount,
          paymentMethod: 'wallet',
          walletBalance: 5000);
      final b = service.createOrder(
          quote: q,
          acceptedAmount: q.amount,
          paymentMethod: 'wallet',
          walletBalance: 5000);
      final ra = await a;
      final rb = await b;
      expect(s.createCalls, 1);
      expect(s.debits, 1);
      expect((ra as QuotedOrderCreated).orderId,
          (rb as QuotedOrderCreated).orderId);
    });

    test('réponse perdue puis nouvel essai automatique : rejeu, un seul débit',
        () async {
      final s = FakeQuoteServer()..loseResponsesAfterExecution = 1;
      final r = await QuotedCheckout(svc(s), store: MemoryPendingQuoteStore()).run(
        uid: 'u1',
        request: req(),
        paymentMethod: 'wallet',
        walletBalance: 5000,
        confirm: (q, {previousAmount}) async => true,
      );
      expect(r,
          isA<CheckoutCreated>().having((c) => c.replayed, 'replayed', isTrue));
      expect(s.createCalls, 2);
      expect(s.debits, 1);
      expect(s.wallet, 4500);
      expect(s.orders.length, 1);
    });

    test('réseau coupé sur tous les essais : inconnu, puis reprise sans débit',
        () async {
      final s = FakeQuoteServer()..loseResponsesAfterExecution = 3;
      final checkout = QuotedCheckout(svc(s), store: MemoryPendingQuoteStore());
      final first = await checkout.run(
        uid: 'u1',
        request: req(),
        paymentMethod: 'wallet',
        walletBalance: 5000,
        confirm: (q, {previousAmount}) async => true,
      );
      expect(first, isA<CheckoutUncertain>());
      expect(s.debits, 1, reason: 'le serveur a exécuté la 1re fois');
      final again = await checkout.run(
        uid: 'u1',
        request: req(),
        paymentMethod: 'wallet',
        walletBalance: 5000,
        confirm: (q, {previousAmount}) async =>
            fail('pas de nouvelle confirmation'),
        resume: (first as CheckoutUncertain).quote,
      );
      expect(again,
          isA<CheckoutCreated>().having((c) => c.replayed, 'replayed', isTrue));
      expect(s.debits, 1);
      expect(s.orders.length, 1);
      expect(s.quoteCalls, 1, reason: 'même devis, pas de nouveau devis');
    });

    test('erreur réseau avant exécution : nouvel essai, un seul débit',
        () async {
      final s = FakeQuoteServer()..failBeforeExecution = 2;
      final r = await QuotedCheckout(svc(s), store: MemoryPendingQuoteStore()).run(
        uid: 'u1',
        request: req(),
        paymentMethod: 'wallet',
        walletBalance: 5000,
        confirm: (q, {previousAmount}) async => true,
      );
      expect(r, isA<CheckoutCreated>());
      expect(s.debits, 1);
    });
  });

  group('expiration et changement de tarif', () {
    test('devis expiré localement : aucun appel de création', () async {
      var t = DateTime.utc(2026, 11, 2, 12);
      final s = FakeQuoteServer(clock: () => t)..ttlMs = 60000;
      final service = DeliveryQuoteService(
          gateway: s, clock: () => t, retryDelay: Duration.zero);
      final q = await service.requestQuote(req());
      t = t.add(const Duration(minutes: 5));
      final o = await service.createOrder(
          quote: q,
          acceptedAmount: q.amount,
          paymentMethod: 'wallet',
          walletBalance: 5000);
      expect(
          o,
          isA<QuotedOrderRefused>()
              .having((x) => x.code, 'code', 'QUOTE_EXPIRED'));
      expect(s.createCalls, 0);
    });

    test('expiration entre confirmation et envoi : nouveau devis au même prix, sans nouvelle confirmation',
        () async {
      var t = DateTime.utc(2026, 11, 2, 12);
      final s = FakeQuoteServer(clock: () => t)..ttlMs = 60000;
      final service = DeliveryQuoteService(
          gateway: s, clock: () => t, retryDelay: Duration.zero);
      var confirms = 0;
      final r = await QuotedCheckout(service, store: MemoryPendingQuoteStore()).run(
        uid: 'u1',
        request: req(),
        paymentMethod: 'wallet',
        walletBalance: 5000,
        confirm: (qq, {previousAmount}) async {
          confirms++;
          t = t.add(const Duration(minutes: 5));
          return true;
        },
      );
      expect(r, isA<CheckoutCreated>());
      expect(confirms, 1, reason: 'même montant : la confirmation reste valable');
      expect(s.quoteCalls, 2);
      expect(s.debits, 1);
    });

    test('PRICE_CHANGED : rien débité, nouveau prix affiché, reconfirmation obligatoire',
        () async {
      final s = FakeQuoteServer();
      final seen = <String>[];
      final r = await QuotedCheckout(svc(s), store: MemoryPendingQuoteStore()).run(
        uid: 'u1',
        request: req(),
        paymentMethod: 'wallet',
        walletBalance: 5000,
        confirm: (q, {previousAmount}) async {
          seen.add('${q.amount}/${previousAmount ?? '-'}');
          if (seen.length == 1) s.officialStandard = 1000; // passage à la nuit
          return true;
        },
      );
      expect(seen, ['500/-', '1000/500']);
      expect(r, isA<CheckoutCreated>().having((c) => c.charged, 'charged', 1000));
      expect(s.debits, 1);
      expect(s.wallet, 4000);
    });

    test('PRICE_CHANGED refusé par le client : aucun débit', () async {
      final s = FakeQuoteServer();
      var n = 0;
      final r = await QuotedCheckout(svc(s), store: MemoryPendingQuoteStore()).run(
        uid: 'u1',
        request: req(),
        paymentMethod: 'wallet',
        walletBalance: 5000,
        confirm: (q, {previousAmount}) async {
          if (++n == 1) {
            s.officialStandard = 1000;
            return true;
          }
          return false;
        },
      );
      expect(r, isA<CheckoutCancelled>());
      expect(s.debits, 0);
      expect(s.wallet, 5000);
    });

    test('tarif instable : arrêt après 3 tours, rien débité', () async {
      final s = FakeQuoteServer();
      final r = await QuotedCheckout(svc(s), store: MemoryPendingQuoteStore()).run(
        uid: 'u1',
        request: req(),
        paymentMethod: 'wallet',
        walletBalance: 100000,
        confirm: (q, {previousAmount}) async {
          s.officialStandard += 100;
          return true;
        },
      );
      expect(r,
          isA<CheckoutFailed>().having((f) => f.code, 'code', 'PRICE_UNSTABLE'));
      expect(s.debits, 0);
    });

    test('tarif en baisse : le client paie le moindre des deux', () async {
      final s = FakeQuoteServer()..officialStandard = 1000;
      final r = await QuotedCheckout(svc(s), store: MemoryPendingQuoteStore()).run(
        uid: 'u1',
        request: req(),
        paymentMethod: 'wallet',
        walletBalance: 5000,
        confirm: (q, {previousAmount}) async {
          s.officialStandard = 500;
          return true;
        },
      );
      expect(r, isA<CheckoutCreated>().having((c) => c.charged, 'charged', 500));
    });
  });

  group('modification de la demande', () {
    test('standard → express : nouveau devis, nouveau prix', () async {
      final s = FakeQuoteServer();
      final service = svc(s);
      final std = await service.requestQuote(req());
      final exp = await service.requestQuote(req(mode: 'express'));
      expect(std.amount, 500);
      expect(exp.amount, 1000);
      expect(std.quoteId, isNot(exp.quoteId));
      expect(std.request.sameAs(exp.request), isFalse);
    });

    test('destination modifiée : détectée, et un devis détourné est refusé',
        () async {
      final s = FakeQuoteServer();
      final service = svc(s);
      final q = await service.requestQuote(req());
      expect(req().sameAs(req(destLat: 6.95)), isFalse);
      final hijack = DeliveryQuote(
          quoteId: q.quoteId,
          amount: q.amount,
          expiresAt: q.expiresAt,
          request: req(destLat: 6.95));
      final o = await service.createOrder(
          quote: hijack,
          acceptedAmount: hijack.amount,
          paymentMethod: 'wallet',
          walletBalance: 5000);
      expect(
          o,
          isA<QuotedOrderRefused>()
              .having((x) => x.code, 'code', 'QUOTE_MISMATCH'));
      expect(s.debits, 0);
    });

    test('la demande n\'envoie jamais de montant : seul le devis fait foi', () {
      final p = req().toPayload();
      expect(p.containsKey('amount'), isFalse);
      expect(p.containsKey('budget'), isFalse);
      expect(p['routeDistanceKm'], 0.01); // indicative, bornée par le serveur
    });
  });

  group('compatibilité', () {
    test('éligibilité : anonyme, mobile money et services non migrés restent sur l\'ancien parcours',
        () {
      bool e(bool anon, String service, String pay) =>
          QuotedOrderConfig.eligible(
              isAnonymous: anon, service: service, paymentMethod: pay);
      expect(e(true, 'livraison', 'cash'), isFalse);
      for (final pay in ['orange_money', 'mtn_money', 'wave']) {
        expect(e(false, 'livraison', pay), isFalse);
        expect(e(false, 'courses', pay), isFalse);
      }
      for (final name in [
        'restaurant',
        'pharmacie',
        'boulangerie',
        'colis',
        'marketplace'
      ]) {
        expect(e(false, name, 'wallet'), isFalse);
      }
      // Drapeau : faux par défaut = ancien parcours partout.
      expect(e(false, 'livraison', 'cash'), QuotedOrderConfig.cashEnabled);
      expect(e(false, 'courses', 'wallet'), QuotedOrderConfig.enabled);
    });

    test('finalisation : dispatch seulement pour une commande pending sans livreur',
        () async {
      OrderModel mk(String status, {String? driverId}) => OrderModel(
          id: 'o1',
          description: 'd',
          budget: 500,
          status: status,
          latitude: 6.7,
          longitude: -3.4,
          type: 'livraison',
          clientId: 'c',
          paymentMethod: 'wallet',
          driverId: driverId);
      var dispatched = 0;
      Future<OrderModel?> run(OrderModel? o) => QuotedOrderFinalizer(
              loader: (_) async => o,
              dispatcher: (_) async {
                dispatched++;
              })
          .finalize('o1');
      await run(mk('pending'));
      expect(dispatched, 1);
      await run(mk('assigned', driverId: 'd1')); // rejeu : déjà attribuée
      await run(mk('accepted', driverId: 'd1'));
      await run(mk('cancelled'));
      expect(dispatched, 1);
      expect(await run(null), isNull);
      expect(dispatched, 1);
    });
  });

  test('erreur transitoire reconnue (réseau)', () {
    expect(isTransientQuoteError(const SocketException('x')), isTrue);
    expect(isTransientQuoteError(StateError('x')), isFalse);
  });
}
