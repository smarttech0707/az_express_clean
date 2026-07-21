import 'package:flutter/material.dart';

import 'scale_button.dart';

/// Boîte de confirmation générique avant déconnexion (Master Prompt 135) —
/// un seul widget, réutilisé par tous les tableaux de bord qui appelaient
/// jusqu'ici leur `_logout()` directement sans confirmation, cohérent avec
/// le pattern déjà établi par `showPartnerAccountSheet`/
/// `showAccountDeletionRequestDialog` (jamais dupliqué par écran).
///
/// `onConfirm` porte toute la vraie logique de déconnexion déjà existante
/// et inchangée par écran (signOut, nettoyage SharedPreferences, arrêt de
/// service, redirection) — ce widget n'ajoute qu'une étape de confirmation
/// devant, il ne remplace ni ne duplique cette logique.
Future<void> showLogoutConfirmDialog(
  BuildContext context, {
  required Future<void> Function() onConfirm,
  String title = 'Se déconnecter',
  String message = 'Voulez-vous vraiment vous déconnecter ?',
}) {
  return showDialog(
    context: context,
    builder: (ctx) => AlertDialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      title: Row(children: [
        const Icon(Icons.logout_rounded, color: Colors.orange, size: 22),
        const SizedBox(width: 8),
        Text(title),
      ]),
      content: Text(message, style: const TextStyle(fontSize: 14)),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx),
          child: const Text('Annuler'),
        ),
        ScaleButton(
          style: ElevatedButton.styleFrom(
            backgroundColor: Colors.orange.shade800,
            foregroundColor: Colors.white,
          ),
          onPressed: () async {
            Navigator.pop(ctx);
            await onConfirm();
          },
          child: const Text('Se déconnecter'),
        ),
      ],
    ),
  );
}
