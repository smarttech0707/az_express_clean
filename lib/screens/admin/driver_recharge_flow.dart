import 'package:cloud_functions/cloud_functions.dart';
import 'package:flutter/material.dart';

import '../../services/firestore_service.dart';

/// Recharge manuelle d'un livreur (espèces remises au bureau) : confirmation explicite du montant, puis un seul
/// appel serveur. La clé d'idempotence est créée APRÈS la confirmation et liée à ce seul appel : un second appui
/// ou un rejeu réseau ne peut donc pas créditer deux fois ; une nouvelle confirmation = une nouvelle recharge voulue.
Future<bool> confirmAndRechargeDriver(
  BuildContext context, {
  required String driverId,
  required String driverName,
  required int amount,
  String note = '',
}) async {
  final messenger = ScaffoldMessenger.of(context);
  final confirmed = await showDialog<bool>(
    context: context,
    barrierDismissible: false,
    builder: (ctx) => AlertDialog(
      title: const Text('Confirmer la recharge'),
      content: Text(
          'Créditer $amount FCFA au portefeuille de $driverName ?\n\n'
          'Vérifiez que les espèces ont bien été remises. Cette opération est enregistrée à votre nom.'),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Annuler')),
        ElevatedButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text('Créditer $amount FCFA')),
      ],
    ),
  );
  if (confirmed != true) return false;
  try {
    final key = FirestoreService.newRechargeKey();
    await FirestoreService().rechargeDriverWallet(driverId, amount,
        adminNote: note, idempotencyKey: key);
    messenger.showSnackBar(SnackBar(
        content: Text('$amount FCFA ajoutés à $driverName'),
        backgroundColor: Colors.green));
    return true;
  } on FirebaseFunctionsException catch (e) {
    messenger.showSnackBar(SnackBar(
        content: Text(e.message ?? 'Recharge refusée'),
        backgroundColor: Colors.red));
  } catch (_) {
    messenger.showSnackBar(const SnackBar(
        content: Text('Recharge non confirmée : vérifiez le solde avant de réessayer'),
        backgroundColor: Colors.red));
  }
  return false;
}
