# Mission 7E-73 — Checklist de validation après chaque commit

Date : 2026-11-07 · À exécuter **par un humain (ou après autorisation explicite)** après chaque commit. Aucune de ces commandes n'a été lancée ici sur de vrais commits (il n'y en a pas). Toutes sont locales (aucun accès distant). Chaque commit se valide ou se rejette **indépendamment** ; on ne commence le suivant que si le précédent est validé.

## 0. Procédure d'arrêt (valable pour tous)

Si une ligne marquée **[CRITIQUE]** échoue : **arrêter**, ne pas enchaîner le commit suivant, ne pas pousser, ne pas déployer. Le commit fautif se corrige par un **nouveau** commit ou s'annule par `git revert` après décision humaine (ne pas utiliser `git reset --hard`, ne pas réécrire l'historique sans accord). Consigner la commande, la sortie complète et l'heure. Un échec **non critique** (marqué [NC]) est consigné et soumis à décision, sans arrêt automatique.

Échecs connus et antérieurs à ces commits (ne pas les confondre avec une régression) : `dispatchRetry.emulator` « trois passes simultanées en phase 2 » (échoue dans toutes les suites complètes depuis 7E-69) ; `financialConcurrency.emulator` « E-Kbine création : 8 appels simultanés » (intermittent en suite complète, voir la décision E-Kbine) ; `passwordHash.test.js` « tampered hash » (probabiliste ~1/256).

## 1. Vérifications communes (après chaque commit)

```bash
git log --oneline -3                              # [CRITIQUE] un seul nouveau commit, message attendu
git show --stat --format=fuller HEAD              # [CRITIQUE] liste de fichiers = celle du manifeste, rien d'autre
git diff HEAD~1 HEAD --name-only | grep -E "(^|/)\.env|\.aab$|\.apk$|\.patch$|\.keystore$|key\.properties|GoogleService-Info|\.log$|\.pid$|runtime/" && echo "FICHIER SENSIBLE" || echo "aucun fichier sensible"   # [CRITIQUE]
git status --short                                # [CRITIQUE] seuls les fichiers des commits suivants et les « ne pas ajouter » restent
git diff --cached --stat                          # doit être vide après le commit
```
Fins de ligne : l'avertissement « LF will be replaced by CRLF » est attendu (autocrlf) ; ce n'est pas une erreur.

Imports et exports (à chaque commit touchant `functions/`) :
```bash
cd functions
node -e "require('./index.js'); console.log(Object.keys(require('./index.js')).length)"   # [CRITIQUE] se charge ; ~135 points d'entrée
node -e "for (const m of ['accountDeletion','accountCleanup','partnerAccountDeletion','accountDeletionSupport']) require('./'+m)"   # [CRITIQUE]
```

Node 22 (dépendances) : `node -p process.version` doit afficher `v22.x` pour les tests Node 22 ; `node -p "require('./package.json').engines.node"` = `22` ; ne modifier ni `package.json` ni `package-lock.json` (`git diff --name-only HEAD~1 HEAD | grep package` doit être vide) **[CRITIQUE]**.

## 2. Commit 1 — moteur P1

| Vérification | Commande / critère | Niveau |
|---|---|---|
| Fichiers | exactement : `accountDeletion.js`, `accountCleanup.js`, `partnerAccountDeletion.js`, `accountDeletionSupport.js`, `index.js` (13 lignes de diff : `checkRateLimit,logAudit`), `test/accountDeletionHardening.test.js`, 3 fichiers `rules-tests/account-deletion*.test.js` | CRITIQUE |
| `index.js` | `git show HEAD -- functions/index.js` ne contient **que** l'injection `checkRateLimit,logAudit` (pas de `pilotLightOptions`, pas de `assertNewAccountActivity`, pas de `assertTargetNotClosing`) | CRITIQUE |
| Tests unitaires | `cd functions && node --test test/accountDeletionHardening.test.js test/accountDeletionSupport.test.js test/manualAccountDeletion.test.js` : 0 échec | CRITIQUE |
| Suite sans émulateur | `npm test` : 0 échec attendu hors échecs connus | CRITIQUE |
| Règles de suppression | `firebase emulators:exec --config firebase.account-deletion-emulators.json --project demo-account-deletion --only auth,firestore,storage "node --test --test-concurrency=1 rules-tests/account-deletion.test.js rules-tests/account-deletion-lifecycle.test.js rules-tests/account-deletion-real.test.js rules-tests/account-new-flows.test.js"` : **63/63** (jamais en parallèle) | CRITIQUE |
| Règles Firestore principales | `npm run test:rules` (racine) : 470/470 | CRITIQUE |
| Règles Storage | `npm run test:storage` (racine) : 128/128 | CRITIQUE |
| Concurrence | aucun test de concurrence du commit 1 ; les tests C1-C3 appartiennent au commit 2 | — |
| Plafonds | `requestAccountDeletionCF` 0,5 vCPU ; trois autres 0,25 ; 1 instance ; concurrence 1 (lecture de `index.js`) | CRITIQUE |
| Aucune activation | `git grep -n "operations_control" -- functions/index.js` n'ajoute rien ; aucun document de configuration créé | CRITIQUE |

## 3. Commit 2 — gardes P2

| Vérification | Critère | Niveau |
|---|---|---|
| Fichiers | `accountAdmission.js`, `feexpayPayments.js`, `azia/index.js`, `azia/pendingActions.js`, `pilotCap.js`, `index.js` (hunks 1, 2, 4-8), tests `accountQuarantineGuards`, `accountQuarantineIndex`, `accountQuarantineConcurrency.emulator`, `pilotCap` | CRITIQUE |
| Unitaires | `node --test test/accountQuarantineGuards.test.js test/accountQuarantineIndex.test.js test/pilotCap.test.js` : 17 + 11 + 10, 0 échec | CRITIQUE |
| Paiements / AZ IA | `node --test test/feexpay*.test.js test/adminWalletRequests*.test.js test/azia*.test.js` (ensemble de 178 + 174 tests) : 0 échec | CRITIQUE |
| Concurrence | `firebase emulators:exec --only auth,firestore --project demo-conc "node --test test/accountQuarantineConcurrency.emulator.test.js"` : 9/9 ; **si C2 échoue avec `Transaction is invalid or closed`, relancer le fichier seul une fois** : message d'émulateur connu ; deux échecs consécutifs = **CRITIQUE** | CRITIQUE / NC |
| Règles | `test:rules` 470/470 ; `test:storage` 128/128 ; suppression 63/63 | CRITIQUE |
| Production inchangée | `GCLOUD_PROJECT=az-express-b0469 node -e "const o=require('./pilotCap').pilotLightOptions(); console.log(JSON.stringify(o))"` → `{}` | CRITIQUE |
| Plafonds préproduction | `GCLOUD_PROJECT=az-express-preprod ...` → `{"maxInstances":1,"cpu":0.25,"concurrency":1}` | CRITIQUE |

## 4. Commit 3 (E-Kbine) puis 3b (gardes P3)

| Vérification | Critère | Niveau |
|---|---|---|
| Fichiers du commit 3 | `ekbineOrders.js`, `test/ekbineQuarantineGuards.test.js` | CRITIQUE |
| Unitaires (3) | `node --test test/ekbineQuarantineGuards.test.js test/ekbineOrders.test.js test/ekbineDepositFlow.test.js test/ekbineReconciliation.test.js` : 54/54 | CRITIQUE |
| Fichiers du commit 3b | `passwordReset.js`, `adminPartnerAccounts.js`, `professionalSubscriptions.js`, `index.js` (hunk 9, `index_p3.patch`), `test/passwordReset.test.js` | CRITIQUE |
| Unitaires (3b) | `passwordReset`, `adminPartnerAccounts`, `professionalSubscriptions` : 0 échec | CRITIQUE |
| Non-régression E-Kbine concurrente | `financialConcurrency.emulator.test.js` seul : 12/12 (l'échec « 8 appels » en suite complète est connu) | NC |
| Indépendance du moteur | `git diff HEAD~1 HEAD --name-only` ne contient aucun fichier du commit 1 | CRITIQUE |

## 5. Commit 4 — correctif de test

`node --test test/restaurantV2Preprod.test.js` sous Node 22 **et** Node 24 : 12/12 ; diff = 1 ligne dans ce seul fichier. **[CRITIQUE]**

## 6. Commit 5 — script de déploiement

```powershell
powershell -NoProfile -Command "$e=$null;[void][System.Management.Automation.Language.Parser]::ParseFile('test-env\deploy-account-deletion-preprod.ps1',[ref]$null,[ref]$e);$e.Count"   # 0  [CRITIQUE]
powershell -NoProfile -ExecutionPolicy Bypass -File test-env\deploy-account-deletion-preprod.ps1 -Stage functions-deletion      # SIMULATION seulement
powershell -NoProfile -ExecutionPolicy Bypass -File test-env\deploy-account-deletion-preprod.ps1 -Project az-express-b0469     # doit afficher REFUS
```
**Ne jamais** ajouter `-Execute` sans autorisation distincte. Après le commit 3, la simulation ne doit plus signaler de fichiers non commités dans `functions/` (sinon un fichier a été oublié). **[CRITIQUE]**

## 7. Commit 6 — documentation

Diff = uniquement `docs/*.md` ; aucun secret ni identifiant de compte réel (`git diff HEAD~1 HEAD | grep -iE "password|secret|token|apikey"` à relire manuellement). [NC]

## 8. Validation finale après les six commits

1. `git status --short` : seuls les éléments « ne pas ajouter ».
2. Suite complète sous émulateurs, Node 22 puis Node 24 : mêmes résultats que 7E-72 (2 échecs connus au plus) ; tout échec supplémentaire = **CRITIQUE**.
3. Script en simulation : « fichiers deployables modifies non commites: 0 ».
4. Statut de quota : **QUOTA NON CONFIRMÉ — DÉPLOIEMENT NON AUTORISÉ SUR CETTE BASE** (inchangé par les commits).
5. Aucun `git push` avant autorisation distincte.
