import 'package:flutter/material.dart';

import '../models/order_model.dart';
import '../services/delivery_quote_service.dart';
import '../services/quoted_checkout.dart';
import '../services/quoted_order_finalizer.dart';
import 'quote_confirmation_dialog.dart';

/// Champs de commande que le client peut fournir au serveur (liste blanche
/// côté `createOrderFromQuoteCF`). Montants, statut, villes, zones, nom et
/// téléphone du client sont posés par le serveur.
Map<String, dynamic> quotedOrderFields(OrderModel draft) => {
      'description': draft.description,
      if (draft.deliveryAddress != null) 'deliveryAddress': draft.deliveryAddress,
      if (draft.pickupAddress != null) 'pickupAddress': draft.pickupAddress,
      if (draft.pickupContactName != null)
        'pickupContactName': draft.pickupContactName,
      if (draft.pickupContactPhone != null)
        'pickupContactPhone': draft.pickupContactPhone,
      if (draft.recipientName != null) 'recipientName': draft.recipientName,
      if (draft.recipientPhone != null) 'recipientPhone': draft.recipientPhone,
      if (draft.gpsDetectedCityId != null)
        'gpsDetectedCityId': draft.gpsDetectedCityId,
      if (draft.activeCityId != null) 'activeCityId': draft.activeCityId,
      if (draft.citySelectionSource != null)
        'citySelectionSource': draft.citySelectionSource,
      if (draft.pickupCoordinateSource != null)
        'pickupCoordinateSource': draft.pickupCoordinateSource,
      if (draft.deliveryCoordinateSource != null)
        'deliveryCoordinateSource': draft.deliveryCoordinateSource,
    };

String paymentLabelFor(String method) =>
    method == 'wallet' ? 'Wallet AZ' : 'Espèces à la livraison';

/// Déroule le parcours devis avec ses boîtes de dialogue : confirmation du
/// prix officiel, nouvelle confirmation si le tarif change, « Réessayer » si
/// la réponse du serveur est perdue. Ne débite jamais sans confirmation.
Future<QuotedCheckoutResult> runQuotedCheckoutWithUi(
  BuildContext context, {
  required QuotedCheckout checkout,
  required String uid,
  required QuoteRequest request,
  required String paymentMethod,
  required int walletBalance,
  required OrderModel draft,
  int shoppingBudget = 0,
}) async {
  Future<bool> confirm(DeliveryQuote quote, {int? previousAmount}) {
    if (!context.mounted) return Future.value(false);
    return showQuoteConfirmation(
      context,
      quote: quote,
      paymentLabel: paymentLabelFor(paymentMethod),
      shoppingBudget: shoppingBudget,
      previousAmount: previousAmount,
    );
  }

  Future<bool> askRetry() async =>
      await showDialog<bool>(
        context: context,
        barrierDismissible: false,
        builder: (ctx) => AlertDialog(
          key: const Key('quote-uncertain'),
          title: const Text('Réponse non reçue'),
          content: const Text(
              'La connexion a été interrompue. Votre commande a peut-être été '
              'enregistrée : vérifier ne vous débitera pas deux fois.'),
          actions: [
            TextButton(
                key: const Key('quote-close'),
                onPressed: () => Navigator.of(ctx).pop(false),
                child: const Text('Fermer')),
            FilledButton(
                key: const Key('quote-retry'),
                onPressed: () => Navigator.of(ctx).pop(true),
                child: const Text('Vérifier')),
          ],
        ),
      ) ==
      true;

  // 1) Une tentative précédente au résultat inconnu (réponse perdue, application
  //    fermée) doit être vérifiée AVANT toute nouvelle commande : sinon un
  //    second devis pourrait produire un second débit.
  //    Toujours sur action explicite du client (« Vérifier ») : jamais en silence.
  while (await checkout.pending(uid) != null) {
    if (!context.mounted || !await askRetry()) return const CheckoutCancelled();
    final recovered = await checkout.recover(uid);
    if (recovered == null || recovered is CheckoutUncertain) continue;
    return recovered; // commande retrouvée, ou refus technique (occupé)
  }

  // 2) Parcours normal.
  var result = await checkout.run(
    uid: uid,
    request: request,
    paymentMethod: paymentMethod,
    walletBalance: walletBalance,
    shoppingBudget: shoppingBudget,
    orderFields: quotedOrderFields(draft),
    confirm: confirm,
  );
  while (result is CheckoutUncertain) {
    if (!context.mounted || !await askRetry()) break;
    result = await checkout.run(
      uid: uid,
      request: request,
      paymentMethod: paymentMethod,
      walletBalance: walletBalance,
      shoppingBudget: shoppingBudget,
      orderFields: quotedOrderFields(draft),
      confirm: confirm,
      resume: result.quote,
    );
  }
  return result;
}

/// Message utilisateur pour un refus du serveur.
String quotedFailureMessage(CheckoutFailed f) => switch (f.code) {
      'SOLDE_INSUFFISANT' => f.message,
      'OUTSIDE_SERVICE' => 'Cette adresse est hors des zones desservies.',
      'LATE_NIGHT_RESTRICTED' => f.message,
      'CLIENT_NOT_FOUND' => 'Connectez-vous avec votre compte client pour commander.',
      'QUOTE_MISMATCH' => 'L\'adresse a changé : veuillez recommencer la commande.',
      _ when isAccountClosingRefusal(f) => 'Votre compte est en cours de suppression : '
          'aucune nouvelle commande ne peut être passée. Rien n\'a été débité.',
      _ => f.message,
    };

/// Refus du serveur parce que le compte est supprimé ou en cours de suppression :
/// `permission-denied` / `ACCOUNT_DELETION_IN_PROGRESS` (contrôle d'entrée des
/// fonctions) ou `failed-precondition` (garde relue dans la transaction de
/// `createOrderFromQuoteCF`). Dans les deux cas rien n'est débité ni créé.
bool isAccountClosingRefusal(CheckoutFailed f) =>
    (f.code == 'permission-denied' &&
        f.message == 'ACCOUNT_DELETION_IN_PROGRESS') ||
    (f.code == 'failed-precondition' &&
        f.message.startsWith('Compte supprime ou en cours de suppression'));

/// Relit la commande créée et lance la recherche de livreur.
Future<OrderModel?> finalizeQuotedOrder(String orderId,
        {QuotedOrderFinalizer? finalizer}) =>
    (finalizer ?? QuotedOrderFinalizer()).finalize(orderId);
