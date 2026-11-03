import 'delivery_quote_service.dart';
import 'pending_quote_store.dart';

/// Orchestration « devis → confirmation explicite → commande » (sans UI).
///
/// Garanties :
///  - le prix présenté au client est celui du serveur ;
///  - rien n'est débité sans une confirmation du client portant sur le montant
///    exact du devis utilisé ;
///  - PRICE_CHANGED / devis expiré : un NOUVEAU devis est demandé ; si son
///    montant diffère de celui que le client a accepté, il doit reconfirmer ;
///  - réponse réseau perdue : le même devis est renvoyé tel quel (idempotent) ;
///  - une tentative au résultat inconnu est mémorisée par compte : tant qu'elle
///    n'est pas résolue ([recover]), aucun nouveau devis n'est créé, même après
///    fermeture de l'écran ou redémarrage de l'application ;
///  - une seule exécution à la fois (double clic, écran rouvert en parallèle).
typedef ConfirmQuote = Future<bool> Function(DeliveryQuote quote,
    {int? previousAmount});

sealed class QuotedCheckoutResult {
  const QuotedCheckoutResult();
}

class CheckoutCreated extends QuotedCheckoutResult {
  const CheckoutCreated(this.orderId, this.charged, {this.replayed = false});
  final String orderId;
  final int charged;
  final bool replayed;
}

class CheckoutCancelled extends QuotedCheckoutResult {
  const CheckoutCancelled();
}

class CheckoutFailed extends QuotedCheckoutResult {
  const CheckoutFailed(this.code, this.message);
  final String code;
  final String message;
}

/// Résultat inconnu : conserver [quote] et proposer « Réessayer » (resume).
class CheckoutUncertain extends QuotedCheckoutResult {
  const CheckoutUncertain(this.quote);
  final DeliveryQuote quote;
}

class QuotedCheckout {
  QuotedCheckout(this.service, {this.maxRounds = 3, PendingQuoteStore? store})
      : store = store ?? SharedPrefsPendingQuoteStore();
  final DeliveryQuoteService service;
  final int maxRounds;
  final PendingQuoteStore store;

  bool _busy = false;

  /// Tentative inconnue de ce compte à résoudre avant toute nouvelle commande.
  Future<PendingQuote?> pending(String uid) async {
    try {
      return await store.load(uid);
    } catch (_) {
      return null;
    }
  }

  Future<void> _safe(Future<void> Function() op) async {
    try {
      await op();
    } catch (_) {
      // Le stockage local ne doit jamais empêcher ni fausser une commande ;
      // la protection en mémoire (même session) reste active.
    }
  }

  /// Vérifie auprès du serveur la tentative mémorisée, avec SON devis et SON
  /// montant déjà confirmé. Retourne :
  ///  - [CheckoutCreated] : la commande existe (rejeu, aucun nouveau débit) ;
  ///  - [CheckoutUncertain] : toujours pas de réponse, la tentative est conservée ;
  ///  - `null` : le serveur confirme qu'aucune commande n'existe, tentative effacée.
  Future<QuotedCheckoutResult?> recover(String uid) async {
    if (_busy) {
      return const CheckoutFailed(
          'CHECKOUT_BUSY', 'Une commande est déjà en cours de traitement');
    }
    final p = await pending(uid);
    if (p == null) return null;
    _busy = true;
    try {
      final outcome = await service.createOrder(
        quote: p.quote,
        acceptedAmount: p.quote.amount,
        paymentMethod: p.paymentMethod,
        walletBalance: 0,
        shoppingBudget: p.shoppingBudget,
        orderFields: p.orderFields,
        recovery: true,
      );
      if (outcome is QuotedOrderUncertain) return CheckoutUncertain(p.quote);
      await _safe(() => store.clear(uid));
      if (outcome is QuotedOrderCreated) {
        return CheckoutCreated(outcome.orderId, outcome.charged,
            replayed: outcome.replayed);
      }
      return null; // aucun débit ni commande : on peut repartir d'un devis neuf
    } finally {
      _busy = false;
    }
  }

  Future<QuotedCheckoutResult> run({
    required String uid,
    required QuoteRequest request,
    required String paymentMethod,
    required int walletBalance,
    required ConfirmQuote confirm,
    int shoppingBudget = 0,
    Map<String, dynamic> orderFields = const {},

    /// Reprise après CheckoutUncertain : même devis, montant déjà confirmé.
    DeliveryQuote? resume,
  }) async {
    if (_busy) {
      return const CheckoutFailed(
          'CHECKOUT_BUSY', 'Une commande est déjà en cours de traitement');
    }
    _busy = true;
    try {
      if (resume == null && await pending(uid) != null) {
        return const CheckoutFailed('PENDING_ORDER_UNRESOLVED',
            'Une commande précédente doit d\'abord être vérifiée');
      }
      return await _run(uid, request, paymentMethod, walletBalance, confirm,
          shoppingBudget, orderFields, resume);
    } finally {
      _busy = false;
    }
  }

  Future<QuotedCheckoutResult> _run(
    String uid,
    QuoteRequest request,
    String paymentMethod,
    int walletBalance,
    ConfirmQuote confirm,
    int shoppingBudget,
    Map<String, dynamic> orderFields,
    DeliveryQuote? resume,
  ) async {
    DeliveryQuote quote;
    int? acceptedAmount;
    int? previous;
    try {
      if (resume != null) {
        quote = resume;
        acceptedAmount = resume.amount;
      } else {
        quote = await service.requestQuote(request);
      }
    } on DeliveryQuoteException catch (e) {
      return CheckoutFailed(e.code, e.message);
    }

    for (var round = 0; round < maxRounds; round++) {
      if (acceptedAmount != quote.amount) {
        final ok = await confirm(quote, previousAmount: previous);
        if (!ok) return const CheckoutCancelled();
        acceptedAmount = quote.amount;
      }
      // Écrit AVANT l'appel : si l'application est tuée pendant l'appel, la
      // tentative reste mémorisée et sera vérifiée au prochain lancement.
      await _safe(() => store.save(PendingQuote(
            uid: uid,
            quote: quote,
            paymentMethod: paymentMethod,
            shoppingBudget: shoppingBudget,
            orderFields: orderFields,
          )));
      final outcome = await service.createOrder(
        quote: quote,
        acceptedAmount: acceptedAmount!,
        paymentMethod: paymentMethod,
        walletBalance: walletBalance,
        shoppingBudget: shoppingBudget,
        orderFields: orderFields,
      );
      if (outcome is! QuotedOrderUncertain) {
        await _safe(() => store.clear(uid));
      }
      switch (outcome) {
        case QuotedOrderCreated():
          return CheckoutCreated(outcome.orderId, outcome.charged,
              replayed: outcome.replayed);
        case QuotedOrderUncertain():
          return CheckoutUncertain(quote);
        case QuotedOrderPriceChanged():
        case QuotedOrderRefused(code: 'QUOTE_EXPIRED'):
          // Rien n'a été débité. Nouveau devis ; le client reconfirme si le prix diffère.
          if (outcome is QuotedOrderPriceChanged) previous = quote.amount;
          try {
            quote = await service.requestQuote(request);
          } on DeliveryQuoteException catch (e) {
            return CheckoutFailed(e.code, e.message);
          }
        case QuotedOrderRefused():
          return CheckoutFailed(outcome.code, outcome.message);
      }
    }
    return const CheckoutFailed(
        'PRICE_UNSTABLE', 'Le tarif change trop souvent, réessayez dans un instant');
  }
}
