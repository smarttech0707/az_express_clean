# Mission 7E-79 — Harmonisation du message de refus Flutter

Date : 2026-11-07 · Strictement local. Aucun `git add`, `git apply --cached`, commit, push, pull, merge, reset, déploiement ni commande distante. `operations_control/account_deletion` non créé. Production `az-express-b0469` non touchée. Backend, Cloud Functions, règles, quarantaine, paiements, écrans et navigation non modifiés.

## 1. Fichiers modifiés (tous dans le périmètre du commit 1B)
| Fichier | Modification |
|---|---|
| `lib/services/account_deletion_service.dart` | uniquement le texte de `AccountDeletionUnavailableException.message` (2 lignes) |
| `test/services/account_deletion_service_test.dart` | assertions d'égalité exacte sur le nouveau message ; test « ancien reçu » : l'exception porte le message exact ; boucle sur les autres codes d'erreur (`unauthenticated`, `invalid-argument`, `resource-exhausted`, `unknown`, `internal`) vérifiant qu'ils suivent le chemin du reçu serveur et ne deviennent jamais un refus de suppression |
| `test/widgets/account_deletion_dialog_test.dart` | refus de passerelle : `find.text(<message exact>)` ; erreur réseau et réauthentification : le texte « pas disponible » est absent |
`lib/widgets/account_deletion_dialog.dart` : **inchangé** (il affiche `e.message` tel quel). Aucun autre fichier modifié. Le périmètre du commit 1B reste de **4 fichiers**, mêmes noms.

## 2. Ancien et nouveau message
- Ancien (ASCII) : « Le service de suppression de compte n est pas disponible pour le moment. Votre demande n a pas ete enregistree et votre compte reste inchange. Reessayez plus tard ou contactez le support. »
- **Nouveau** : « Le service de suppression de compte n’est pas disponible pour le moment. Votre demande n’a pas été enregistrée et votre compte reste inchangé. Réessayez plus tard ou contactez le support. » (apostrophes typographiques ’ et accents ; vérifié caractère pour caractère par les tests, dont la chaîne attendue est écrite indépendamment du code).
Le fichier contenait déjà des accents (« Compte supprimé ») : pas d'incident d'encodage ; les tests affichent et retrouvent bien les caractères.

## 3. Comportement vérifié
| Exigence | Preuve |
|---|---|
| Message exact affiché pour `details.reason = ACCOUNT_DELETION_NOT_ENABLED` | test dialogue `find.text(exact)` ; test service `message == exact` ; le chemin `details.reason` → `isGateClosedRefusal` → `resolveCallableFailure` reste couvert par les 6 tests de contrat de 7E-76 (convertisseur réel du plugin, message reformulé, détails Web) |
| Refus sans faux reçu | `resolveCallableFailure` : le reçu n'est jamais lu (compteur 0) ; « Votre demande est conservee » absent, aucun SnackBar |
| Ancien reçu présent | refus de passerelle : ancien reçu ignoré ; autre erreur : reçu serveur toujours consulté (comportement antérieur) |
| Erreur réseau distincte | `unavailable` (même avec le bon texte/détails) : pas un refus ; test dialogue : message « Enregistrement non confirme… », « pas disponible » absent |
| Erreur d'authentification | `requires-recent-login`/`unauthenticated` : « Reauthentification requise… », « pas disponible » absent |
| Autres erreurs non transformées en refus | boucle de 5 codes + cas `failed-precondition` sans détails ou autre raison (7E-76) |
| Comportement métier inchangé | seuls des textes de message et d'assertions ont changé ; aucune logique de décision modifiée |

## 4. Tests
**Exécutés (7E-79)** : `flutter test` service + dialogue : **31/31 PASS** ; `flutter analyze` des 4 fichiers du commit 1B : **No issues found** ; `flutter test` de `admin_menu_test.dart` et `web_startup_test.dart` (fichiers voisins référençant la suppression de compte) : **19/19 PASS** ; `git diff --check` sur `lib` et `test` : aucune erreur d'espaces (avertissements LF/CRLF attendus).
**Non exécutés** : suite Flutter complète ; tout test sur appareil, émulateur mobile ou SDK natif ; tests backend et règles (hors périmètre, aucun fichier concerné modifié) ; aucun essai sur Firebase réel.

## 5. Contrôles finaux
- HEAD `aa3d1b0`, branche `finalisation/az-express` ; index **vide** (0 fichier) ; `git status --short` identique avant/après (la mission ne crée que ce rapport, + 1 entrée).
- SHA-256 avant/après : seuls les 3 fichiers prévus ont changé ; **les 9 fichiers du commit 1 sont identiques**, ainsi que `account_deletion_dialog.dart` et les manifestes `7E75_FINAL_P1_MANIFEST` / `7E75_COMMIT_COMMANDS`.
- Aucun fichier parasite créé dans le dépôt. `D:\h75.txt` toujours présent, non lu, non supprimé.
- Aucune opération distante.

## 6. Réserves et effets sur les documents antérieurs
- Les rapports 7E-76/7E-77/7E-78 décrivent l'ancien texte ASCII comme « présent dans le code » : cet état est **dépassé** par cette mission (historique conservé, non modifié). La mention « formulation non implémentée » du rapport 7E-78 est désormais levée.
- Les deux fichiers de test référencent la nouvelle chaîne en dur : toute évolution future du texte exigera de les mettre à jour (comportement voulu).
- Le contenu du commit 1B change (3 fichiers sur 4) ; les listes de fichiers de 7E-75/77 restent exactes, les compteurs +lignes ne le sont plus exactement.
- Réserves inchangées : SDK natif non testé sur appareil ; `dispatchRetry.emulator` en échec (hors périmètre) ; couverture financière incomplète avant le commit 2 ; `admin.firestore.FieldValue` sous l'émulateur (impact sur le code déployé non démontré) ; « Firestore illisible » non validé sur transport réel ; quota **QUOTA NON CONFIRMÉ — DÉPLOIEMENT NON AUTORISÉ SUR CETTE BASE**.

## Verdict
**MESSAGE HARMONISÉ — COMMIT 1B PRÊT SOUS CONDITIONS**
(conditions : essai du SDK natif sur appareil ou acceptation explicite de s'en passer ; autorisation humaine distincte avant toute opération Git).
