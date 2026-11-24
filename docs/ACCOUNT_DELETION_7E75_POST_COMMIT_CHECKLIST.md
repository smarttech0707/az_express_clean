# Mission 7E-75 — Checklist après le commit P1 (À EXÉCUTER APRÈS COMMIT, NON EXÉCUTÉE)

Date : 2026-11-07 · Le commit n'existe pas : rien de ceci n'a été lancé sur un vrai commit. Toutes les commandes sont locales (projets `demo-*`, aucun accès distant). **Arrêt immédiat** à la première ligne [CRITIQUE] en échec : pas de commit suivant, pas de push, pas de déploiement ; consigner commande, sortie, heure.

Échecs connus et antérieurs (ne pas confondre avec une régression) : `dispatchRetry.emulator` phase 2 ; `financialConcurrency.emulator` E-Kbine 8 appels (intermittent) ; `accountQuarantineConcurrency` C2 (artefact d'émulateur, dans la suite complète seulement) ; `passwordHash` tampered (≈1/256).

| # | Vérification | Commande / critère | Niveau |
|---|---|---|---|
| 1 | Contenu du commit | `git show --stat --format=fuller HEAD` : exactement les 9 fichiers du commit 1 (ou 4 Flutter pour 1b) | CRITIQUE |
| 2 | Espaces | `git show --check HEAD` : aucune erreur (avertissements LF/CRLF attendus) | CRITIQUE |
| 3 | Aucun fichier sensible / P2 / P3 | commandes grep de `…COMMIT_COMMANDS.md` §1.3 sur `git show --name-only HEAD` | CRITIQUE |
| 4 | `index.js` | `git show HEAD -- functions/index.js` : une seule ligne ajoutée (`checkRateLimit,logAudit`) | CRITIQUE |
| 5 | Imports/exports | `cd functions && GCLOUD_PROJECT=demo-x node -e "const m=require('./index.js');console.log(Object.keys(m).length)"` → 135 ; `node -e "for (const m of ['accountDeletion','accountCleanup','partnerAccountDeletion','accountDeletionSupport']) require('./'+m)"` | CRITIQUE |
| 6 | Tests ciblés backend | `node --test test/accountDeletionHardening.test.js test/accountDeletionSupport.test.js test/manualAccountDeletion.test.js` : 51/51, sous Node 22 puis 24 | CRITIQUE |
| 7 | Règles de suppression | depuis la racine : `firebase emulators:exec --config firebase.account-deletion-emulators.json --project demo-account-deletion --only auth,firestore,storage "node --test --test-concurrency=1 rules-tests/account-deletion.test.js rules-tests/account-deletion-lifecycle.test.js rules-tests/account-deletion-real.test.js rules-tests/account-new-flows.test.js"` : 69/69 (jamais en parallèle) | CRITIQUE |
| 8 | Règles Firestore | `npm run test:rules` : 470/470 | CRITIQUE |
| 9 | Règles Storage | `npm run test:storage` : 128/128 | CRITIQUE |
| 10 | Flutter (1b) | `flutter test test/services/account_deletion_service_test.dart test/widgets/account_deletion_dialog_test.dart` : 26/26 ; `flutter analyze` sur les 4 fichiers : aucune anomalie | CRITIQUE (1b) |
| 11 | Suite sans émulateur | `cd functions && npm test` : 0 échec hors échecs connus | CRITIQUE |
| 12 | Non-régression financière | suite complète émulateurs (Node 22) : seuls les échecs connus ci-dessus | NC / décision humaine |
| 13 | Aucun changement involontaire | `git status --short` : seuls les fichiers des commits suivants et les « ne pas ajouter » ; `git diff --cached --stat` vide ; `git diff HEAD~1 HEAD --name-only | grep package` vide | CRITIQUE |
| 14 | Plafonds de production | `GCLOUD_PROJECT=az-express-b0469 node -e "console.log(JSON.stringify(require('./pilotCap').pilotLightOptions()))"` → `{}` (depuis `functions/`) | CRITIQUE |
| 15 | Aucune activation | `git grep -n "operations_control" HEAD -- functions/index.js` n'ajoute rien ; aucun document de configuration créé | CRITIQUE |

## Rappels
- Quota : **QUOTA NON CONFIRMÉ — DÉPLOIEMENT NON AUTORISÉ SUR CETTE BASE** (vérification humaine dans `az-express-preprod`, `europe-west1`).
- Ces vérifications ne prouvent pas le comportement sur Firestore/Auth réels.
- Aucune étape de cette checklist ne déploie ni ne pousse.
