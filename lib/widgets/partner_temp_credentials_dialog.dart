import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Affiche UNE SEULE FOIS l'identifiant et le mot de passe TEMPORAIRE généré par
/// le serveur pour un partenaire créé (ou réinitialisé) par l'administration.
///
/// Le mot de passe n'est ni choisi par l'administrateur, ni stocké en clair
/// (Firestore ne reçoit qu'un hachage côté serveur) : cette fenêtre est donc le
/// seul moment où il est lisible. Le partenaire devra en définir un personnel à
/// sa première connexion.
Future<void> showPartnerTempCredentialsDialog(
  BuildContext context, {
  required String title,
  required String identifier,
  required String tempPassword,
}) {
  return showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (ctx) => AlertDialog(
      title: Text(title),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Identifiant (téléphone)',
                style: TextStyle(fontSize: 12, color: Colors.grey)),
            SelectableText(identifier,
                style:
                    const TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
            const SizedBox(height: 12),
            const Text('Mot de passe temporaire',
                style: TextStyle(fontSize: 12, color: Colors.grey)),
            SelectableText(tempPassword,
                style: const TextStyle(
                    fontSize: 20,
                    fontWeight: FontWeight.bold,
                    letterSpacing: 1.2)),
            const SizedBox(height: 14),
            const Text(
              'Transmettez-les au partenaire par un canal sûr (appel ou '
              'message direct). Il devra choisir son propre mot de passe à sa '
              'première connexion. Ce mot de passe temporaire ne sera plus '
              'affiché après la fermeture de cette fenêtre.',
              style: TextStyle(fontSize: 12),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Clipboard.setData(ClipboardData(
              text: 'Identifiant : $identifier\nMot de passe temporaire : '
                  '$tempPassword')),
          child: const Text('Copier'),
        ),
        TextButton(
          onPressed: () => Navigator.pop(ctx),
          child: const Text('J\'ai transmis, fermer'),
        ),
      ],
    ),
  );
}
