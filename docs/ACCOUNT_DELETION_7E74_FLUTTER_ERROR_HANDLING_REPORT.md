# Mission 7E-74 — Gestion des erreurs Flutter (passerelle fermée)

Date : 2026-11-07 · Local uniquement. Design général inchangé.

## 1. Où « Votre demande est conservée » s'affichait
`AccountDeletionService.submitRequest` appelait `requestAccountDeletionCF` ; sur toute `FirebaseFunctionsException` il se rabattait sur `checkLastRequest()` (statut du dernier dossier). Avec l'ancien backend, la passerelle fermée créait quand même un dossier, d'où « conservée ». Avec le nouveau backend, ce repli pourrait renvoyer un **ancien** reçu et faire croire à tort qu'une demande vient d'être enregistrée.

## 2. Modifications (4 fichiers de production/test + 1 test service)
- `lib/services/account_deletion_service.dart` (+17/−1) : nouvelle `AccountDeletionUnavailableException` (message : service indisponible, **demande non enregistrée**, compte inchangé, réessayer ou contacter le support). Levée quand `e.code == 'failed-precondition'` et que `e.message` contient `ACCOUNT_DELETION_NOT_ENABLED`, **sans** repli sur `checkLastRequest()`. Les autres `FirebaseFunctionsException` gardent le repli existant.
- `lib/widgets/account_deletion_dialog.dart` (+5/−1) : branche `on AccountDeletionUnavailableException` qui affiche son message ; `unauthenticated` ajouté aux codes de réauthentification.
- `test/widgets/account_deletion_dialog_test.dart` (+25) : 3 tests (passerelle fermée, panne réseau, échecs de réauthentification).
- `test/services/account_deletion_service_test.dart` (+8) : 1 test.

## 3. Comportement
| Cas | Affichage |
|---|---|
| Refus backend (passerelle fermée) | message « service indisponible, demande non enregistrée » ; aucune confirmation |
| Erreur réseau / autre erreur serveur | message générique d'erreur, n'affirme pas l'enregistrement (repli statut inchangé) |
| Erreur de réauthentification (`requires-recent-login`, `wrong-password`, `unauthenticated`…) | demande de se réauthentifier |
| Demande réellement enregistrée | confirmation existante inchangée |
| Dossier existant dont le traitement est suspendu (`server_rollout_not_enabled`) | texte « Votre demande est conservée » inchangé : vrai, le dossier existe |

La page web `lib/web/pages/delete_account_page.dart` utilise un chemin Firestore manuel (`requestedVia:'web'`) : non concernée, inchangée.

## 4. Validation
`flutter test` des deux fichiers : 25/25. `flutter analyze` des 4 fichiers : aucune anomalie. Les tests utilisent des faux services : **aucun essai sur appareil ou émulateur Android/iOS n'a été fait**.

## 5. Limites
La détection repose sur le texte `ACCOUNT_DELETION_NOT_ENABLED` dans `FirebaseFunctionsException.message` (message de l'`HttpsError` backend, couvert côté backend par les tests) ; non vérifiée sur un vrai appel callable. Une erreur réseau garde le repli `checkLastRequest()` : si un ancien dossier existe, l'utilisateur voit son statut réel (comportement antérieur).
