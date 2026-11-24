import 'package:flutter/material.dart';

import '../services/delivery_quote_service.dart';
import '../theme/app_theme.dart';

/// Confirmation explicite du prix OFFICIEL (celui du serveur) avant toute
/// création de commande. Retourne `true` uniquement sur « Confirmer ».
///
/// [previousAmount] : si non nul, le tarif a changé depuis la dernière
/// confirmation ; l'ancien prix est rappelé et le client doit reconfirmer.
Future<bool> showQuoteConfirmation(
  BuildContext context, {
  required DeliveryQuote quote,
  required String paymentLabel,
  int shoppingBudget = 0,
  int? previousAmount,
}) async {
  final ok = await showDialog<bool>(
    context: context,
    barrierDismissible: false,
    builder: (_) => QuoteConfirmationDialog(
      quote: quote,
      paymentLabel: paymentLabel,
      shoppingBudget: shoppingBudget,
      previousAmount: previousAmount,
    ),
  );
  return ok == true;
}

class QuoteConfirmationDialog extends StatelessWidget {
  const QuoteConfirmationDialog({
    super.key,
    required this.quote,
    required this.paymentLabel,
    this.shoppingBudget = 0,
    this.previousAmount,
  });

  final DeliveryQuote quote;
  final String paymentLabel;
  final int shoppingBudget;
  final int? previousAmount;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final express = quote.request.mode == 'express';
    final total = quote.amount + shoppingBudget;
    return AlertDialog(
      key: const Key('quote-confirmation'),
      title: Text(previousAmount == null ? 'Confirmer le prix' : 'Le tarif a changé'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (previousAmount != null)
            Padding(
              padding: const EdgeInsets.only(bottom: AppSpacing.sm),
              child: Text(
                'Ancien prix : $previousAmount FCFA. Nouveau prix : ${quote.amount} FCFA. '
                'Rien n\'a été débité.',
                key: const Key('quote-price-changed'),
                style: text.bodyMedium,
              ),
            ),
          Text('Livraison ${express ? 'Express' : 'Standard'}'
              '${quote.isNight ? ' (tarif de nuit)' : ''}',
              style: text.bodyMedium),
          const SizedBox(height: AppSpacing.xs),
          Text('${quote.amount} FCFA',
              key: const Key('quote-amount'), style: text.headlineSmall),
          if (shoppingBudget > 0) ...[
            const SizedBox(height: AppSpacing.xs),
            Text('Budget d\'achat : $shoppingBudget FCFA', style: text.bodyMedium),
            Text('Total : $total FCFA',
                key: const Key('quote-total'), style: text.titleMedium),
          ],
          const SizedBox(height: AppSpacing.sm),
          Text('Paiement : $paymentLabel', style: text.bodySmall),
          Text('Prix calculé par AZ Express, valable quelques minutes.',
              style: text.bodySmall),
        ],
      ),
      actions: [
        TextButton(
          key: const Key('quote-cancel'),
          onPressed: () => Navigator.of(context).pop(false),
          child: const Text('Annuler'),
        ),
        FilledButton(
          key: const Key('quote-confirm'),
          onPressed: () => Navigator.of(context).pop(true),
          child: const Text('Confirmer'),
        ),
      ],
    );
  }
}
