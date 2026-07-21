import 'package:flutter/material.dart';

import '../services/account_deletion_service.dart';

/// Boîte de dialogue générique de demande de suppression de compte —
/// réutilisable pour n'importe lequel des 9 rôles supportés par
/// [AccountDeletionService]. Un seul écran, jamais dupliqué par rôle.
Future<void> showAccountDeletionRequestDialog(
  BuildContext context, {
  required String role,
  String? initialPhone,
}) async {
  final phoneCtrl = TextEditingController(text: initialPhone ?? '');
  final reasonCtrl = TextEditingController();
  bool sending = false;

  await showDialog(
    context: context,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setState) => AlertDialog(
        title: const Text('Supprimer mon compte'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Votre demande sera traitée par notre équipe. Votre compte sera '
                'désactivé immédiatement, puis vos données personnelles seront '
                'effacées sous 30 jours, sauf obligation légale de conservation '
                '(ex. historique financier).',
                style: TextStyle(fontSize: 13, color: Colors.grey[700]),
              ),
              const SizedBox(height: 16),
              TextField(
                controller: phoneCtrl,
                keyboardType: TextInputType.phone,
                decoration: const InputDecoration(
                  labelText: 'Numéro de téléphone',
                  border: OutlineInputBorder(),
                  isDense: true,
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: reasonCtrl,
                maxLines: 2,
                decoration: const InputDecoration(
                  labelText: 'Raison (optionnel)',
                  border: OutlineInputBorder(),
                  isDense: true,
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: sending ? null : () => Navigator.pop(ctx),
            child: const Text('Annuler'),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
                backgroundColor: Colors.red, foregroundColor: Colors.white),
            onPressed: sending
                ? null
                : () async {
                    final phone = phoneCtrl.text.trim();
                    if (phone.isEmpty) return;
                    setState(() => sending = true);
                    try {
                      await AccountDeletionService.submitRequest(
                        role: role,
                        contactPhone: phone,
                        reason: reasonCtrl.text.trim(),
                        requestedVia: 'app',
                      );
                      if (ctx.mounted) {
                        Navigator.pop(ctx);
                        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
                          content: Text(
                              'Demande envoyée. Votre compte sera désactivé sous peu.'),
                          backgroundColor: Colors.red,
                        ));
                      }
                    } catch (_) {
                      setState(() => sending = false);
                      if (ctx.mounted) {
                        ScaffoldMessenger.of(ctx).showSnackBar(const SnackBar(
                          content: Text('Erreur — réessayez plus tard.'),
                        ));
                      }
                    }
                  },
            child: sending
                ? const SizedBox(
                    width: 18, height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                : const Text('Confirmer la suppression'),
          ),
        ],
      ),
    ),
  );

  phoneCtrl.dispose();
  reasonCtrl.dispose();
}
