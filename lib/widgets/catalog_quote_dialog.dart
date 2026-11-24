import 'package:flutter/material.dart';
import '../services/catalog_order_service.dart';
import '../theme/app_theme.dart';

/// Confirmation du devis officiel (montant calculé par le serveur). Retourne true si le client confirme,
/// false (ou fermeture) s'il revient en arrière.
Future<bool> showCatalogQuoteDialog(
  BuildContext context, {
  required CatalogQuote quote,
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
              Text(notice, style: const TextStyle(fontSize: 12, color: Colors.orange)),
              const SizedBox(height: 10),
            ],
            for (final l in quote.lines)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 2),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Expanded(child: Text(l.label, style: const TextStyle(fontSize: 13))),
                    const SizedBox(width: 8),
                    Text('${l.amount} FCFA', style: const TextStyle(fontSize: 13)),
                  ],
                ),
              ),
            const Divider(),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                const Text('Total', style: TextStyle(fontWeight: FontWeight.bold)),
                Text('${quote.total} FCFA', style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              wallet ? 'Ce montant sera débité de votre wallet.' : 'À régler en espèces au livreur.',
              style: TextStyle(fontSize: 12, color: AppColors.premiumTextSecondary(brightness)),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Retour')),
        ElevatedButton(
          onPressed: () => Navigator.pop(ctx, true),
          style: ElevatedButton.styleFrom(backgroundColor: AppColors.primary),
          child: Text(wallet ? 'Payer ${quote.total} FCFA' : 'Confirmer', style: const TextStyle(color: Colors.white)),
        ),
      ],
    ),
  );
  return ok == true;
}

/// Parcours commun : devis serveur → confirmation du montant → commande. Retourne true si la commande est créée.
/// Un devis périmé ou un tarif modifié (jusqu'à 2 fois) ramène à la confirmation avec le nouveau montant.
/// [notify] reçoit les messages à afficher (message, erreur ?).
Future<bool> runCatalogCheckout(
  BuildContext context, {
  required CatalogCheckout checkout,
  required String service,
  required String paymentMethod,
  required int walletBalance,
  required Map<String, dynamic> choices,
  required Map<String, dynamic> details,
  required void Function(String message, bool isError) notify,
}) async {
  String? notice;
  try {
    for (var attempt = 0; attempt < 3; attempt++) {
      final quote = await checkout.prepare(service, choices);
      if (paymentMethod == 'wallet' && walletBalance < quote.total) {
        notify('Solde insuffisant. Vous avez $walletBalance FCFA, il faut ${quote.total} FCFA', true);
        return false;
      }
      if (!context.mounted) return false;
      final confirmed =
          await showCatalogQuoteDialog(context, quote: quote, paymentMethod: paymentMethod, notice: notice);
      if (!confirmed) return false;
      try {
        await checkout.confirm(quote: quote, paymentMethod: paymentMethod, choices: choices, details: details);
        return true;
      } on CatalogException catch (e) {
        if (e.needsNewQuote && attempt < 2) {
          notice = e.userMessage;
          continue;
        }
        notify(e.userMessage, true);
        return false;
      }
    }
  } on CatalogException catch (e) {
    notify(e.userMessage, true);
  } catch (e) {
    notify('Erreur : $e', true);
  }
  return false;
}
