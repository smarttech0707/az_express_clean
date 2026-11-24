# Mission 7E-75 — Manifeste final du commit P1

Date : 2026-11-07 · HEAD `aa3d1b0`, branche `finalisation/az-express`, index vide. Remplace pour le **commit 1** les listes de commandes de `7E72_COMMIT_FINAL_MANIFEST` et `7E73_FIVE_COMMITS_DEPENDENCY_MAP` (celles-ci restent archivées, non modifiées). Aucun commit, `git add`, `git apply --cached` exécuté.

## 1. Évolution depuis 7E-73
- 7E-74 : refus de `requestAccountDeletionCF` quand la passerelle est absente/fermée/illisible (`accountDeletion.js`), tests remplacés et ajoutés, gestion Flutter.
- 7E-75 : ajout **additif** d'un code machine `details.reason = 'ACCOUNT_DELETION_NOT_ENABLED'` à l'`HttpsError` (le message reste identique) pour que Flutter ne dépende plus du seul texte ; helper Flutter testable `isGateClosedRefusal`.
- Tests : Hardening 21→26, règles de suppression 63→69.

## 2. Découpage retenu pour la partie P1

| Commit | Contenu | Remarque |
|---|---|---|
| **1** — moteur P1 (backend) | 4 modules + 1 hunk `index.js` + test unitaire + 3 fichiers de règles | cœur du pilote ; indépendant de P2/P3 (vérifié, §4) |
| **1b** — client Flutter P1 | service, dialogue, 2 tests | recommandé **séparé mais immédiatement après**, avant toute diffusion de l'application ; le backend seul est sûr, mais l'application publiée n'affiche alors qu'un message générique |

La fusion 1+1b en un seul commit est possible (décision humaine) ; les listes ci-dessous restent valables.

## 3. Fichiers du commit 1

| Fichier | État | Rôle | Dépendances | Tests | Risque | Nécessaire à P1 |
|---|---|---|---|---|---|---|
| `functions/accountDeletion.js` | modifié (+81/−~) | moteur : demande (passerelle fermée → refus), traitement, statut, reprise | `accountCleanup`, `accountDeletionIdentity` (HEAD), `partnerAccountDeletion`, `node:crypto` | Hardening 26, règles 69 | moyen (suppression de comptes) | oui |
| `functions/accountCleanup.js` | **nouveau** (137 l.) | purge des données du compte (liste blanche) | aucune | Hardening (liste blanche) | moyen | oui (requis par accountDeletion/partnerAccountDeletion) |
| `functions/partnerAccountDeletion.js` | modifié (+25) | périmètre partenaires (fermé tant que `partnerInventoryVersion` absent) | `accountCleanup`, `accountDeletionScope`, `accountRelatedPersonalData` (HEAD) | Hardening, règles | faible (fermé) | oui (import d'`accountDeletion`) |
| `functions/accountDeletionSupport.js` | modifié (+6) | support/admin : état des demandes | `adminGuards` (HEAD) | `accountDeletionSupport.test.js` | faible | oui |
| `functions/index.js` | **hunk 3 seulement** (§5) | injecte `checkRateLimit`, `logAudit` dans le moteur | — | chargement + Hardening | faible | oui |
| `functions/test/accountDeletionHardening.test.js` | **nouveau** (471 l., 26 tests) | tests unitaires du moteur, dont passerelle fermée | `accountDeletion`, faux Firestore (HEAD) | lui-même | — | oui |
| `rules-tests/account-deletion.test.js` | modifié | tests d'émulateur : passerelle fermée sur état réel | émulateurs | 69 (avec les 3 autres) | — | oui |
| `rules-tests/account-deletion-lifecycle.test.js` | modifié (1 l.) | cycle de vie | idem | idem | — | oui |
| `rules-tests/account-deletion-real.test.js` | modifié (1 l.) | idem | idem | idem | — | oui |

## 4. Fichiers du commit 1b (Flutter)

| Fichier | Rôle | Dépendance | Tests | Risque | Nécessaire |
|---|---|---|---|---|---|
| `lib/services/account_deletion_service.dart` (+28) | `AccountDeletionUnavailableException`, `isGateClosedRefusal` (code `details.reason` prioritaire, texte en repli, `failed-precondition` seulement), pas de repli sur `checkLastRequest` pour ce refus | `cloud_functions`, `flutter/foundation` | service test (5 cas du helper + exception) | faible | oui pour éviter une fausse confirmation |
| `lib/widgets/account_deletion_dialog.dart` (+5) | affiche le refus ; `unauthenticated` → réauthentification | service | 3 tests widget | faible | oui |
| `test/services/account_deletion_service_test.dart` | tests | — | — | — | oui |
| `test/widgets/account_deletion_dialog_test.dart` | tests | — | — | — | oui |

## 5. Hunks de `functions/index.js`

`git diff` actuel : 9 hunks. **Un seul est P1** : le hunk 3 (`@@ -84,7 +87,7 @@`), une ligne :
```diff
-const accountDeletion=buildAccountDeletion({db,auth:admin.auth(),admin,HttpsError,
+const accountDeletion=buildAccountDeletion({db,auth:admin.auth(),admin,HttpsError,checkRateLimit,logAudit,
```
Patch : `test-env/runtime/7e73-patches/index_p1.patch` (ignoré par Git). **Vérifié en 7E-75** : appliqué à `HEAD:functions/index.js` dans un dossier hors dépôt, le résultat diffère de HEAD par cette seule ligne (comparaison sans CR). Hunks 1, 2, 4–8 = P2 ; hunk 9 (`setPharmaciePassword`) = P3.

## 6. Exclus du commit 1 (et pourquoi)
- **P2** : `accountAdmission.js`, `feexpayPayments.js`, `azia/index.js`, `azia/pendingActions.js`, `pilotCap.js`, `index.js` hunks 1, 2, 4–8, tests `accountQuarantine*`, `pilotCap`.
- **E-Kbine (commit 3 séparé)** : `ekbineOrders.js`, `ekbineQuarantineGuards.test.js`.
- **P3 (3b)** : `passwordReset.js`, `adminPartnerAccounts.js`, `professionalSubscriptions.js`, `index.js` hunk 9, `passwordReset.test.js`.
- **Commit 4** : `restaurantV2Preprod.test.js`. **Commit 5** : `test-env/deploy-account-deletion-preprod.ps1`. **Commit 6** : docs (`docs/ACCOUNT_DELETION_*`, checklist).
- **Contenu légal** : `web/legal/confidentialite.html`, `delete-account.html` (revue de contenu humaine).
- **Jamais** : `.aab`, `.patch`, `az_splash_log.txt`, `functions_after_failed_deploy.txt`, `qr-release/`, `scripts/hosting/`, `scripts/maintenance/`, `test-env/.emulators.pid`, `web/downloads/`, `.firebase/hosting.*.cache`, tout `.env`.

## 7. Reconstruction depuis HEAD (vérifiée localement, hors dépôt)
`HEAD` + les 4 modules + le test Hardening + `index_p1.patch` : `index.js` se charge (135 exports) ; `accountDeletionHardening`, `accountDeletionSupport`, `manualAccountDeletion` : **51/51 sous Node 22.23.4 et Node 24.22.1**. Le commit 1 n'a donc **aucune dépendance** sur les fichiers P2/P3.

## 8. Statut de quota
**QUOTA NON CONFIRMÉ — DÉPLOIEMENT NON AUTORISÉ SUR CETTE BASE.** Les 18,75 vCPU théoriques (P1) ne sont pas une capacité disponible ; à vérifier humainement dans `az-express-preprod`, `europe-west1`.
