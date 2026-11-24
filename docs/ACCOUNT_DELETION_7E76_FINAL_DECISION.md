# Mission 7E-76 — Décision finale : commits 1 et 1b

> **[Mise à jour 7E-80]** Rapport daté de 7E-76. La formulation du message de refus a été implémentée en 7E-79 (voir §7(a)) ; les autres réserves et conditions restent ouvertes. Les compteurs de lignes de code de ce rapport sont antérieurs à 7E-79.

Date : 2026-11-07 · Local, émulateurs uniquement. Aucun `git add`, `git apply --cached`, commit, push, merge, reset, déploiement, activation, commande distante. `operations_control/account_deletion` n'a été créé que dans des émulateurs éphémères (jamais dans le dépôt ni à distance) et reste absent partout ailleurs. Production `az-express-b0469` intacte. Rapports antérieurs non remplacés.

## 1. Git
- Avant : HEAD `aa3d1b0`, branche `finalisation/az-express`, index vide, 83 entrées `git status --short`.
- Après : HEAD `aa3d1b0`, index vide, 90 entrées (+7 documents `docs/ACCOUNT_DELETION_7E76_*` ; aucun autre fichier nouveau, aucun fichier parasite dans le dépôt).
- Fichiers de code modifiés en 7E-76 : `lib/services/account_deletion_service.dart` (+`resolveCallableFailure`), `test/services/account_deletion_service_test.dart` (+6 tests). Rien d'autre. Les 9 fichiers du commit 1 sont identiques à ceux de 7E-75 (comparaison octet à octet pour les 5 fichiers `functions/`, horodatage pour les `rules-tests`).
- Hors dépôt : `D:\h75.txt` (sortie de test créée par erreur en 7E-75, suppression refusée par la protection de sécurité — à supprimer par vous) ; fichiers de session dans le scratchpad.

## 2. Contrat d'erreur callable (voir `…CALLABLE_ERROR_CONTRACT.md`)
Sur le transport réel de l'émulateur Functions (client authentifié par l'émulateur Auth) : configuration absente / désactivée / version 2 → HTTP 400 `FAILED_PRECONDITION`, `details.reason = ACCOUNT_DELETION_NOT_ENABLED`, message inchangé, **aucune écriture** (état Firestore identique) ; erreurs d'argument et d'authentification sans `details.reason` ; passerelle ouverte → 200 avec dossier, tombstone, audit et limiteur. Côté Flutter (`cloud_functions 6.3.2`, code natif Android/iOS/web lu) : `details` arrive dans `e.details` comme `Map`. `isGateClosedRefusal` lit `details.reason` en priorité, le texte en repli, et exige `failed-precondition`.
**Limites** : SDK natif non exécuté sur appareil ; cas « Firestore illisible » sur transport réel non reproduit (test unitaire seulement) ; le cas passerelle ouverte a eu besoin d'une cale d'émulateur dans la copie de test hors dépôt.

## 3. Résultats
| Élément | Résultat |
|---|---|
| Flutter service + dialogue | 31/31 ; analyse des 4 fichiers : aucune anomalie |
| Suite Functions complète Node 22.23.4 | 2328 tests : 2280 réussis, **1 échec**, 47 ignorés, code de sortie 1, 94 min |
| Échec | `dispatchRetry.emulator` phase 2 — préexistant, indépendant de P1 |
| Tests ciblés P1 Node 22 (Hardening 26, Support, manual, quarantaine, admission) | 86/86 |
| Règles de suppression (4 fichiers) Node 22 | 69/69 (7E-75) |
| Règles Firestore 470 / Storage 128 | derniers résultats 7E-74 (non relancés, règles inchangées) |
| Chargement `index.js` (tronc reconstruit) | 135 exports (7E-75) |
Évolution : Hardening 21→26, règles de suppression 63→69, comme documenté depuis 7E-74. C2 et E-Kbine « 8 appels » ont passé cette fois (intermittence confirmée, non résolue). Détails : `…FUNCTIONS_FULL_SUITE.md`, `…HISTORICAL_FAILURES.md`.

## 3 bis. Provenance des résultats (ajout 7E-78)
| Statut | Éléments |
|---|---|
| **Exécutés pendant 7E-76** | transport callable sur émulateurs Functions + Auth (cas A–F) ; suite Functions complète Node 22.23.4 (2328 : 2280 OK, 1 échec, 47 ignorés) ; 86 tests ciblés Node 22 ; `flutter test` service + dialogue (31/31) ; `flutter analyze` des 4 fichiers |
| **Issus de missions précédentes, non relancés en 7E-76** | règles de suppression 69/69 (7E-75, Node 22) ; chargement de `index.js` à 135 exports (7E-75, arbre reconstruit) ; règles Firestore 470/470 et Storage 128/128 (7E-74, Node 22) ; reconstruction du commit 1 depuis HEAD, 51/51 (7E-75) |
| **Non exécutés** | tout essai sur appareil ou SDK natif Android/iOS ; tout essai sur Firebase réel ; suite Flutter complète ; cas « Firestore illisible » sur transport réel ; staging, commit |
| **Réserves ouvertes** | voir §6 (aucune n'est une validation) |

## 4. Fichiers exacts
**Commit 1 (9)** : `functions/accountDeletion.js`, `functions/accountCleanup.js`, `functions/partnerAccountDeletion.js`, `functions/accountDeletionSupport.js`, `functions/index.js` (hunk 3 seul via `index_p1.patch`), `functions/test/accountDeletionHardening.test.js`, `rules-tests/account-deletion.test.js`, `rules-tests/account-deletion-lifecycle.test.js`, `rules-tests/account-deletion-real.test.js`.
**Commit 1b (4)** : `lib/services/account_deletion_service.dart`, `lib/widgets/account_deletion_dialog.dart`, `test/services/account_deletion_service_test.dart`, `test/widgets/account_deletion_dialog_test.dart`. Ne contient que le refus de passerelle, la distinction réseau/refus, la réauthentification et leurs tests (revues : `…COMMIT1_REVIEW.md`, `…COMMIT1B_REVIEW.md`). Les commandes de 7E-75 (`…COMMIT_COMMANDS.md`) restent valables sans changement de liste.

## 5. Corrections locales de 7E-76
`resolveCallableFailure` extraite du `catch` (comportement identique) pour tester « ancien reçu présent » ; 6 tests de contrat. Aucune modification du backend en 7E-76.

## 6. Risques ouverts
1. Aucun essai sur appareil / SDK natif réel ; aucun essai sur Firebase réel.
2. Suite Functions non verte (`dispatchRetry`) ; cause racine non analysée ; C2 / E-Kbine intermittents d'émulateur ; exécution très lente (×6), environnement chargé.
3. Quarantaine non étendue aux chemins financiers et AZ IA tant que le commit 2 (P2) n'est pas livré.
4. Cale d'émulateur `admin.firestore.FieldValue` : écart émulateur/dépôt non expliqué ; **l'absence d'impact sur le code déployé n'est pas démontrée** (réserve ouverte, non une validation).
5. Test Flutter dépendant d'un chemin `src/` du plugin (mise à jour du plugin = adaptation éventuelle).
6. Quota : **QUOTA NON CONFIRMÉ — DÉPLOIEMENT NON AUTORISÉ SUR CETTE BASE**.

## 7. Décisions humaines nécessaires
(a) Message de refus : formulation retenue en 7E-78 — « Le service de suppression de compte n’est pas disponible pour le moment. Votre demande n’a pas été enregistrée et votre compte reste inchangé. Réessayez plus tard ou contactez le support. » — qui n'était pas implémentée à cette date (le code affichait une variante ASCII). **[Mise à jour 7E-80]** implémentée et vérifiée en 7E-79 (voir `ACCOUNT_DELETION_7E79_FLUTTER_MESSAGE.md`) ; cette condition est levée, la réserve native (e) reste ouverte; (b) accepter ou non d'ouvrir `dispatchRetry` comme point séparé ; (c) 1 et 1b séparés (recommandé) ou fusionnés ; (d) acceptation de l'écart de quarantaine avant le commit 2 ; (e) essai appareil du SDK natif avant diffusion de l'application ; (f) suppression de `D:\h75.txt`.

## Verdict
**COMMIT 1 PRÊT — COMMIT 1B SOUS CONDITIONS**

- Commit 1 : contrat prouvé sur le transport réel de l'émulateur, aucune écriture passerelle fermée, comportement ouvert conservé, 86/86 ciblés, 69/69 règles, dépendances complètes, un seul échec de suite (préexistant, indépendant). Prêt pour autorisation humaine, avec les risques ci-dessus.
- Commit 1b : conforme et testé (31/31) avec le vrai convertisseur du plugin, mais conditionné à la validation du message (a) et à un essai du SDK natif sur appareil ou à son acceptation explicite (e).

Aucune opération Git ou distante sans nouvelle autorisation explicite.
