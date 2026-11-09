import 'dart:io';

import 'package:az_express/services/delivery_quote_service.dart';
import 'package:az_express/services/pending_quote_store.dart';
import 'package:az_express/services/quoted_checkout.dart';
import 'package:az_express/widgets/quoted_checkout_runner.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fake_quote_server.dart';

// Mission 7E-91 : refus de `createOrderFromQuoteCF` pour un compte supprimé / en quarantaine.
// Le serveur répond par une HttpsError (pas par l'enveloppe {success:false}) :
//  - `permission-denied` / `ACCOUNT_DELETION_IN_PROGRESS` (contrôle d'entrée de toutes les fonctions) ;
//  - `failed-precondition` / `Compte supprime ou en cours de suppression` (garde dans la transaction).
// Dans les deux cas : aucun succès affiché, aucune commande, aucun débit, pas de reprise bloquante ; une erreur de
// transaction transitoire (`internal`) ou réseau reste une incertitude, jamais un refus métier.

class _ClosingServer extends FakeQuoteServer {
  _ClosingServer(this.errorFactory);
  final Object Function() errorFactory;

  @override
  Future<Map<String, dynamic>> call(String name, Map<String, dynamic> p) {
    if (name == 'createOrderFromQuoteCF') {
      createCalls++;
      throw errorFactory();
    }
    return super.call(name, p);
  }
}

FirebaseFunctionsException _fx(String code, String message) =>
    FirebaseFunctionsException(code: code, message: message);

QuoteRequest _req() => const QuoteRequest(
      serviceType: 'livraison',
      mode: 'standard',
      pickupLat: 6.7290,
      pickupLng: -3.4950,
      destLat: 6.7310,
      destLng: -3.4925,
    );

DeliveryQuoteService _svc(FakeQuoteServer s) => DeliveryQuoteService(
    gateway: s,
    clock: () => s.now(),
    retryDelay: Duration.zero,
    allowedPayments: const {'wallet'});

Future<QuotedCheckoutResult> _go(QuotedCheckout c) => c.run(
      uid: 'u1',
      request: _req(),
      paymentMethod: 'wallet',
      walletBalance: 5000,
      confirm: (q, {previousAmount}) async => true,
    );

void main() {
  const closingMessage =
      'Votre compte est en cours de suppression : aucune nouvelle commande ne peut être passée. Rien n\'a été débité.';

  group('refus « compte en suppression » (HttpsError du serveur)', () {
    test(
        'failed-precondition : refus métier unique, sans nouvelle tentative, rien de créé ni de débité, aucune reprise en attente',
        () async {
      final s = _ClosingServer(() => _fx(
          'failed-precondition', 'Compte supprime ou en cours de suppression'));
      final store = MemoryPendingQuoteStore();
      final r = await _go(QuotedCheckout(_svc(s), store: store));
      expect(r, isA<CheckoutFailed>());
      final f = r as CheckoutFailed;
      expect(f.code, 'failed-precondition');
      expect(isAccountClosingRefusal(f), isTrue);
      expect(quotedFailureMessage(f), closingMessage);
      expect(s.createCalls, 1, reason: 'un refus métier ne se rejoue pas');
      expect(s.orders, isEmpty);
      expect(s.debits, 0);
      expect(await store.load('u1'), isNull,
          reason: 'aucune reprise « Vérifier » ne doit rester');
    });

    test(
        'permission-denied / ACCOUNT_DELETION_IN_PROGRESS : même traitement, jeton technique jamais affiché',
        () async {
      final s = _ClosingServer(
          () => _fx('permission-denied', 'ACCOUNT_DELETION_IN_PROGRESS'));
      final store = MemoryPendingQuoteStore();
      final r = await _go(QuotedCheckout(_svc(s), store: store));
      final f = r as CheckoutFailed;
      expect(f.code, 'permission-denied');
      expect(isAccountClosingRefusal(f), isTrue);
      expect(quotedFailureMessage(f), closingMessage);
      expect(quotedFailureMessage(f),
          isNot(contains('ACCOUNT_DELETION_IN_PROGRESS')));
      expect(s.createCalls, 1);
      expect(s.orders, isEmpty);
      expect(await store.load('u1'), isNull);
    });

    test(
        'un autre permission-denied ou failed-precondition n\'est PAS présenté comme une suppression de compte',
        () {
      for (final f in [
        const CheckoutFailed('permission-denied', 'Accès refusé'),
        const CheckoutFailed('failed-precondition', 'Zone indisponible'),
        const CheckoutFailed('permission-denied', 'autre'),
      ]) {
        expect(isAccountClosingRefusal(f), isFalse);
        expect(quotedFailureMessage(f), f.message);
      }
      expect(quotedFailureMessage(const CheckoutFailed('OUTSIDE_SERVICE', 'x')),
          'Cette adresse est hors des zones desservies.');
    });
  });

  group('refus métier ≠ panne technique', () {
    test(
        'erreur de transaction transitoire (internal) : rejouée puis INCERTAINE, jamais présentée comme un refus ni un succès',
        () async {
      final s = _ClosingServer(() =>
          _fx('internal', '3 INVALID_ARGUMENT: Transaction is invalid or closed.'));
      final store = MemoryPendingQuoteStore();
      final r = await _go(QuotedCheckout(_svc(s), store: store));
      expect(r, isA<CheckoutUncertain>());
      expect(s.createCalls, 3,
          reason: 'rejouée (idempotent par devis) puis abandonnée');
      expect(s.orders, isEmpty);
      expect(await store.load('u1'), isNotNull,
          reason: 'la reprise explicite « Vérifier » reste possible');
    });

    test(
        'reprise après incertitude, le serveur répondant « compte en suppression » : aucune commande, reprise effacée, pas de faux succès',
        () async {
      var mode = 'internal';
      final s = _ClosingServer(() => mode == 'internal'
          ? _fx('internal', 'transaction')
          : _fx('failed-precondition',
              'Compte supprime ou en cours de suppression'));
      final store = MemoryPendingQuoteStore();
      final c = QuotedCheckout(_svc(s), store: store);
      expect(await _go(c), isA<CheckoutUncertain>());
      mode = 'closing';
      final recovered = await c.recover('u1');
      expect(recovered, isNull,
          reason: 'aucune commande retrouvée, aucun succès');
      expect(await store.load('u1'), isNull);
      expect(s.orders, isEmpty);
    });

    test('panne réseau : incertitude, pas un refus de compte', () async {
      final s = _ClosingServer(() => const SocketException('hors ligne'));
      final r =
          await _go(QuotedCheckout(_svc(s), store: MemoryPendingQuoteStore()));
      expect(r, isA<CheckoutUncertain>());
    });
  });
}
