import 'package:flutter/material.dart';

const String kPasswordResetEmailGuidance =
    'Un lien de réinitialisation a été envoyé à votre adresse e-mail.\n'
    'Vérifiez votre boîte de réception ainsi que le dossier Spam/Indésirables.\n'
    'Si le lien n’est pas cliquable, copiez-le puis ouvrez-le dans Chrome ou un navigateur.\n'
    'Ne partagez jamais ce lien avec quelqu’un.';

Future<void> sendResetEmailAndShowGuidance({
  required BuildContext context,
  required Future<void> Function() sendEmail,
}) async {
  await sendEmail();
  if (!context.mounted) return;

  await showDialog<void>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      scrollable: true,
      title: const Text('Vérifiez votre e-mail'),
      content: const SelectableText(kPasswordResetEmailGuidance),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(dialogContext),
          child: const Text('Compris'),
        ),
      ],
    ),
  );
}
