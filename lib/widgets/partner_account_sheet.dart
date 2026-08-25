import 'package:flutter/material.dart';

import 'account_deletion_dialog.dart';
import 'single_photo_editor.dart';

/// Bottom sheet générique "Mon compte" pour les rôles partenaires qui n'ont
/// aujourd'hui aucun écran de profil/paramètres dédié (vendeur, restaurant,
/// pharmacie, boulangerie, agent Ekbine, agent immobilier, patron de flotte).
///
/// Affiche les données personnelles déjà connues de l'écran appelant (lecture
/// seule — aucune de ces collections n'autorise aujourd'hui une modification
/// directe par le propriétaire, voir `firestore.rules`), un bouton de
/// déconnexion (délègue à `onLogout`, propre à chaque écran) et le bouton de
/// suppression de compte déjà partagé par toute l'app (`AccountDeletionService`).
///
/// Un seul widget, jamais dupliqué par rôle — cohérent avec le pattern déjà
/// établi par `showAccountDeletionRequestDialog`.
Future<void> showPartnerAccountSheet(
  BuildContext context, {
  required String role,
  required String roleLabel,
  String? name,
  String? phone,
  required VoidCallback onLogout,
  // Photo/logo optionnels — fournis uniquement par les rôles dont la photo
  // fonctionne déjà (vendeur/restaurant/pharmacie/boulangerie). `photoUrl`
  // reflète l'état déjà connu par l'écran appelant (pas de lecture Firestore
  // ici) ; `photoStoragePath` et `onPhotoUploaded` portent respectivement le
  // chemin Storage exact du rôle et l'écriture Firestore correspondante
  // (diffère trop d'un rôle à l'autre — ex. pharmacie utilise `currentUid`,
  // pas `isOwner(docId)` — pour être généralisée ici).
  String? photoUrl,
  String? photoStoragePath,
  Future<void> Function(String url)? onPhotoUploaded,
  Future<void> Function()? onPhotoDeleted,
}) {
  return showModalBottomSheet(
    context: context,
    isScrollControlled: true,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
    ),
    builder: (ctx) => SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 20, 20, 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(children: [
              (photoStoragePath != null && onPhotoUploaded != null)
                  ? SinglePhotoEditor(
                      photoUrl: photoUrl,
                      storagePath: photoStoragePath,
                      size: 52,
                      onUploaded: onPhotoUploaded,
                      onDeleted: onPhotoDeleted,
                    )
                  : const CircleAvatar(
                      radius: 22,
                      child: Icon(Icons.person_rounded),
                    ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(name?.isNotEmpty == true ? name! : roleLabel,
                        style: const TextStyle(
                            fontSize: 16, fontWeight: FontWeight.w700)),
                    Text(phone?.isNotEmpty == true ? phone! : roleLabel,
                        style:
                            TextStyle(fontSize: 13, color: Colors.grey[600])),
                  ],
                ),
              ),
            ]),
            const SizedBox(height: 20),
            const Divider(height: 1),
            const SizedBox(height: 8),
            ListTile(
              leading: const Icon(Icons.logout_rounded, color: Colors.orange),
              title: const Text('Se déconnecter'),
              onTap: () {
                Navigator.pop(ctx);
                onLogout();
              },
            ),
            ListTile(
              leading:
                  const Icon(Icons.person_remove_outlined, color: Colors.red),
              title: const Text('Supprimer mon compte'),
              subtitle:
                  const Text('Demande de suppression de compte et de données'),
              onTap: () {
                Navigator.pop(ctx);
                showAccountDeletionRequestDialog(context,
                    role: role, initialPhone: phone);
              },
            ),
          ],
        ),
      ),
    ),
  );
}
