import 'package:flutter/material.dart';
import '../services/partner_order_service.dart';
import '../theme/app_theme.dart';

/// Confirmation du devis officiel (montants calculés par le serveur) : produits, livraison et total distincts.
/// Retourne true si le client confirme le montant exact, false (ou retour) sinon.
Future<bool> showPartnerQuoteDialog(
  BuildContext context, {
  required PartnerQuote quote,
  required String paymentMethod,
  String? notice,
}) async {
  final brightness = Theme.of(context).brightness;
  final wallet = paymentMethod == 'wallet';
  final ok = await showDialog<bool>(
    context: context,
    barrierDismissible: false,
    builder: (ctx) => AlertDialog(
      backgroundColor: AppColors.premiumSurface(brightness),
      title: const Text('Confirmer le montant'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (notice != null) ...[
              Text(notice,
                  style: const TextStyle(fontSize: 12, color: Colors.orange)),
              const SizedBox(height: 10),
            ],
            for (final l in quote.lines)
              _row('${l.qty} × ${l.name}', '${l.subtotal} FCFA', size: 13),
            const Divider(),
            _row('Produits', '${quote.productAmount} FCFA'),
            _row('Frais de livraison', '${quote.deliveryFee} FCFA'),
            const Divider(),
            _row('Total à payer', '${quote.total} FCFA', bold: true, size: 16),
            const SizedBox(height: 8),
            Text(
              wallet
                  ? 'Ce montant sera débité de votre wallet.'
                  : 'À régler en espèces au livreur.',
              style: TextStyle(
                  fontSize: 12,
                  color: AppColors.premiumTextSecondary(brightness)),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Retour')),
        ElevatedButton(
          onPressed: () => Navigator.pop(ctx, true),
          style: ElevatedButton.styleFrom(backgroundColor: AppColors.primary),
          child: Text(
              wallet
                  ? 'Payer ${quote.total} FCFA'
                  : 'Confirmer ${quote.total} FCFA',
              style: const TextStyle(color: Colors.white)),
        ),
      ],
    ),
  );
  return ok == true;
}

Widget _row(String label, String value, {bool bold = false, double size = 14}) {
  final style = TextStyle(
      fontSize: size, fontWeight: bold ? FontWeight.bold : FontWeight.normal);
  return Padding(
    padding: const EdgeInsets.symmetric(vertical: 2),
    child: Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Expanded(child: Text(label, style: style)),
        const SizedBox(width: 8),
        Text(value, style: style),
      ],
    ),
  );
}

enum PartnerCheckoutStatus {
  /// Commande créée par le serveur.
  created,

  /// Le client a renoncé (retour dans la confirmation) ou un contrôle préalable l'a arrêté (message déjà affiché).
  stopped,

  /// Le partenaire n'est pas sur le nouveau parcours (hors pilote) : rien n'a été débité, l'ancien parcours s'applique.
  useLegacy,
}

class PartnerCheckoutOutcome {
  final PartnerCheckoutStatus status;
  final String? orderId;
  final int? total;
  const PartnerCheckoutOutcome(this.status, {this.orderId, this.total});
}

/// Parcours commun : devis serveur → confirmation explicite du montant exact → création serveur.
/// Un devis périmé ou un tarif modifié (jusqu'à 2 fois) ramène à la confirmation avec le NOUVEAU montant : un montant
/// différent de celui vu par le client n'est jamais validé automatiquement. [notify] reçoit les messages à afficher.
/// Aucun repli sur l'ancien parcours en cas d'erreur réseau ou de création fermée : seul `PARTNER_NOT_IN_PILOT` (hors pilote confirmé par le serveur) au premier devis
/// renvoie [PartnerCheckoutStatus.useLegacy].
Future<PartnerCheckoutOutcome> runPartnerCheckout(
  BuildContext context, {
  required PartnerCheckout checkout,
  required String sellerType,
  required String sellerId,
  required Map<String, int> cart,
  required String paymentMethod,
  required int walletBalance,
  required String deliveryAddress,
  required Future<({double lat, double lng})> Function() locate,
  required void Function(String message, bool isError) notify,
}) async {
  const stopped = PartnerCheckoutOutcome(PartnerCheckoutStatus.stopped);
  PartnerCheckoutOutcome created(PartnerOrderResult r, int? total) =>
      PartnerCheckoutOutcome(PartnerCheckoutStatus.created,
          orderId: r.orderId, total: r.totalAmount ?? total);
  String? notice;
  try {
    // Issue inconnue d'un envoi précédent : on la retrouve (rejeu sûr) avant toute nouvelle commande.
    if (checkout.hasUnresolved) {
      try {
        final r = await checkout.resolveUnresolved();
        if (r != null) return created(r, null);
      } on PartnerOrderException catch (e) {
        if (e.retryable) {
          notify(e.userMessage, true);
          return stopped;
        }
        // Refus définitif : le serveur n'a rien créé pour ce devis, on repart d'un panier propre.
      }
    }
    for (var attempt = 0; attempt < 3; attempt++) {
      final PartnerQuote quote;
      try {
        quote = await checkout.prepare(
            sellerType: sellerType,
            sellerId: sellerId,
            cart: cart,
            locate: locate);
      } on PartnerOrderException catch (e) {
        if (attempt == 0 && e.notInPilot) {
          return const PartnerCheckoutOutcome(PartnerCheckoutStatus.useLegacy);
        }
        notify(e.userMessage, true);
        return stopped;
      }
      if (paymentMethod == 'wallet' && walletBalance < quote.total) {
        notify(
            'Solde insuffisant. Vous avez $walletBalance FCFA, il faut ${quote.total} FCFA',
            true);
        return stopped;
      }
      if (!context.mounted) return stopped;
      final confirmed = await showPartnerQuoteDialog(context,
          quote: quote, paymentMethod: paymentMethod, notice: notice);
      if (!confirmed) return stopped;
      try {
        final r = await checkout.confirm(
            quote: quote,
            paymentMethod: paymentMethod,
            deliveryAddress: deliveryAddress);
        return created(r, quote.total);
      } on PartnerOrderException catch (e) {
        if (e.needsNewQuote && attempt < 2) {
          notice = e.userMessage;
          continue;
        }
        notify(e.userMessage, true);
        return stopped;
      }
    }
  } on PartnerOrderException catch (e) {
    notify(e.userMessage, true);
  } catch (e) {
    notify('Erreur : $e', true);
  }
  return stopped;
}
