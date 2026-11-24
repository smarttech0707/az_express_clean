import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../services/min_version_service.dart';

/// Rôles dont la version minimale est lue dans `config/app_versions`. Sans entrée pour le rôle dans ce document,
/// aucun effet : le contrôle est désactivé par défaut.
const minVersionRoleDriver = 'driver';
const minVersionRoleRestaurant = 'restaurant';
const minVersionRoleClient = 'client';
const minVersionRoleSeller = 'seller';
const minVersionRoleBoulangerie = 'boulangerie';
const minVersionRolePharmacie = 'pharmacie';
const minVersionRoleArtisan = 'artisan';
const minVersionRoleFleet = 'fleet';
const minVersionRoleImmobilier = 'immobilier';
const minVersionRoleEkbine = 'ekbine';
const minVersionRoleAdmin = 'admin';

/// Vérifie la version minimale de [role] et affiche une invite si nécessaire : simple rappel (« Plus tard ») tant que
/// `enforce` n'est pas explicitement `true`, blocage seulement avec `enforce: true`. Le bouton « Mettre à jour »
/// n'apparaît que si `config/app_versions` fournit un lien valide (aucun lien n'est inventé ici : Play et APK direct
/// n'ont pas la même signature, un mauvais lien ferait échouer l'installation). [check] et [openUrl] sont injectables
/// dans les tests.
Future<void> showMinVersionDialogIfNeeded(
  BuildContext context,
  String role, {
  required String blockedMessage,
  Future<MinVersionResult> Function(String role)? check,
  Future<bool> Function(Uri url)? openUrl,
}) async {
  final r = await (check ?? MinVersionService().check)(role);
  if (!context.mounted || r.status == MinVersionStatus.ok) return;
  final required = r.status == MinVersionStatus.updateRequired;
  final url = r.updateUrl == null ? null : Uri.tryParse(r.updateUrl!);
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
          if (url != null)
            FilledButton(
                onPressed: () => (openUrl ??
                    (u) => launchUrl(u, mode: LaunchMode.externalApplication))(url),
                child: const Text('Mettre à jour')),
        ],
      ),
    ),
  );
}
