import 'package:flutter/material.dart';

import '../services/min_version_service.dart';

/// Rôles dont la version minimale est lue dans `config/app_versions` en plus de `driver` (déjà géré par son tableau
/// de bord). Sans entrée pour le rôle dans ce document, aucun effet : le contrôle est désactivé par défaut.
const minVersionRoleRestaurant = 'restaurant';
const minVersionRoleClient = 'client';

/// Vérifie la version minimale de [role] et affiche une invite si nécessaire : simple rappel (« Plus tard ») tant que
/// `enforce` n'est pas explicitement `true`, blocage seulement avec `enforce: true`. [check] est injectable dans les tests.
Future<void> showMinVersionDialogIfNeeded(
  BuildContext context,
  String role, {
  required String blockedMessage,
  Future<({MinVersionStatus status, String? message})> Function(String role)?
      check,
}) async {
  final r = await (check ?? MinVersionService().check)(role);
  if (!context.mounted || r.status == MinVersionStatus.ok) return;
  final required = r.status == MinVersionStatus.updateRequired;
  await showDialog<void>(
    context: context,
    barrierDismissible: !required,
    builder: (ctx) => PopScope(
      canPop: !required,
      child: AlertDialog(
        title: const Text('Mise à jour disponible'),
        content: Text(r.message ??
            (required ? blockedMessage : 'Une nouvelle version est disponible.')),
        actions: [
          if (!required)
            TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: const Text('Plus tard')),
        ],
      ),
    ),
  );
}
