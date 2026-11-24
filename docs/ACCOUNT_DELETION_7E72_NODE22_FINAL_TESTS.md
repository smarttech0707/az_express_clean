# Mission 7E-72 — Validation finale sous Node.js 22

Date : 2026-11-07 · Complète `ACCOUNT_DELETION_7E71_NODE22_VALIDATION.md` (non remplacé). Aucune commande distante ; émulateurs locaux (`demo-*`) uniquement.

## 1. Environnement réellement utilisé

| Élément | Valeur |
|---|---|
| Node 22 | **v22.23.4** (V8 12.4), binaire obtenu en 7E-71 dans le dossier temporaire de session (aucune installation globale) ; appelé directement : `…\scratchpad\node22\node_modules\node\bin\node.exe` |
| npm | **11.19.1** (celui de la machine, **exécuté par Node 22.23.4**) ; ce n'est pas la version npm de Cloud Build |
| Node par défaut de la machine | v24.22.1 (sert de lanceur au CLI Firebase des émulateurs ; les suites de tests sont lancées par le binaire Node 22) |
| Runtime déclaré | `firebase.json` `nodejs22` ; `functions/package.json` `engines.node` `22` |

Vérification : `node -p process.version` appelé par le binaire utilisé affiche `v22.23.4`.

## 2. `npm ci` sous Node 22

Pour ne pas toucher aux `node_modules` du dépôt, `npm ci` a été exécuté dans une **copie** du dépôt (dossier temporaire de session), séparément à la racine (règles) et dans `functions/`, **avec Node 22.23.4**. Résultats :

| Contrôle | Résultat |
|---|---|
| `npm ci` dans `functions/` | **PASS** (code 0), 520 paquets de premier et second niveau |
| `npm ci` à la racine | **PASS** (code 0) |
| `EBADENGINE` / erreurs | aucun ; avertissements `deprecated` seulement (`inflight`, `glob@7/10`, `uuid@8-10`) — présents dans le verrou, non modifiés |
| Comparaison avec les `node_modules` du dépôt (installés sous Node 24) | **0 différence** de version sur les 520 (functions) et 87 (racine) paquets comparés |
| Scripts d'installation | npm 11 les bloque (`allowScripts`) : `protobufjs`, `unrs-resolver`, `@firebase/util` ; aucun module natif requis à l'exécution (analyse 7E-71) |

Ce que cela ne prouve pas : le comportement de `npm ci` avec la version de npm **de Cloud Build**, ni l'image `nodejs22` de production.

## 3. « Build » `nodejs22` (analyse locale du manifeste)

Le CLI Firebase construit le manifeste des fonctions en chargeant `index.js` avec le SDK `firebase-functions`. Reproduit localement **sous Node 22.23.4** avec les dépendances issues de `npm ci` Node 22 et `GCLOUD_PROJECT=az-express-preprod` :

| Contrôle | Résultat |
|---|---|
| Chargement de `index.js` + génération du manifeste | **PASS** : 135 points d'entrée |
| Comparaison avec le manifeste généré en 7E-71 sous Node 24 | **0 point d'entrée en plus ou en moins ; 0 différence** de cpu / maxInstances / concurrence / mémoire / délai / région |
| Plafonds P1 (`requestAccountDeletionCF` 0,5 ; `getAccountDeletionStatusCF`, `retryAccountDeletions`, `manageAccountDeletionCF` 0,25 ; 1 instance ; concurrence 1) | conformes |

**NON VÉRIFIÉ** : build réel dans Cloud Build / Cloud Run avec l'image `nodejs22` (exigerait un déploiement, interdit).

## 4. Résultats des suites sous Node 22.23.4 (dépôt réel, dépendances ci-dessus)

| Suite | Résultat Node 22 | Statut |
|---|---|---|
| Règles de suppression (4 fichiers, Auth + Firestore + Storage, `--test-concurrency=1`) | **63 / 63** | PASS |
| Règles Firestore principales (`test:rules`, 24 fichiers) | **470 / 470** | PASS |
| Règles Storage (`test:storage`, 3 fichiers) | **128 / 128** | PASS |
| Suite `functions` complète, émulateurs Auth + Firestore, `--test-concurrency=1` | **2323 tests · 2274 réussis · 2 échecs · 47 ignorés** | **FAIL (2)** |
| — échec 1 : `dispatchRetry.emulator` « trois passes simultanées en phase 2 » | `dP1` attendu avec `dP2` | FAIL — **préexistant** (aussi sous Node 24, voir §5), sans lien avec la mission |
| — échec 2 : `financialConcurrency.emulator` « E-Kbine création : 8 appels simultanés » | 7 réussis sur 8 | FAIL — voir `…EKBINE_CONCURRENCY_ANALYSIS.md` |
| Tests exécutés sans émulateur | inclus dans les 2323 | PASS (moins les 2 ci-dessus) |
| 47 tests ignorés | exigent Storage / `AZ_E2E_RULES` / Java supplémentaire | **SKIP** (non exécutés, non comptés comme réussis) |
| Tests Flutter / appareil / émulateur Android | non exécutés | NON VÉRIFIÉ |

`dispatchRetry` échoue dans les 3 exécutions de 7E-72 (et déjà en 7E-69/7E-71) : indépendant de la version de Node. L'échec E-Kbine est apparu sous Node 22 (n° 1) et sous Node 24 en 7E-71, mais pas dans les 2 exécutions complètes Node 24 de 7E-72 : le lien avec la version de Node n'est ni démontré ni exclu (voir l'analyse de concurrence).

## 5. Comparaison avec Node 24.22.1 (même dépôt, même jour)

| Exécution complète (émulateurs) | Tests | Réussis | Échecs | Ignorés |
|---|---|---|---|---|
| Node 22.23.4 | 2323 | 2274 | 2 (`dispatchRetry`, E-Kbine) | 47 |
| Node 24.22.1 — exécution n° 1 | 2323 | 2275 | 1 (`dispatchRetry`) | 47 |
| Node 24.22.1 — exécution n° 2 | 2323 | 2275 | 1 (`dispatchRetry`) | 47 |

## 6. Défaut de rapport `restaurantV2Preprod.test.js:121`

Cause confirmée : le test fils (`deliveryProofs.test.js`) réussit ; l'assertion cherchait `ℹ fail 0` (rapporteur `spec` de Node 24) alors que Node 22 émet du TAP (`# fail 0`) quand la sortie est redirigée. **Correctif minimal appliqué (1 ligne, aucune assertion métier modifiée)** : forcer le rapporteur du processus fils.

```diff
-  const out = execFileSync(process.execPath, ['--test', path.join(__dirname, 'deliveryProofs.test.js')], …
+  const out = execFileSync(process.execPath, ['--test', '--test-reporter=spec', path.join(__dirname, 'deliveryProofs.test.js')], …
```
Vérifié : `restaurantV2Preprod.test.js` **12 / 12 sous Node 22 et 12 / 12 sous Node 24**. Ce fichier est suivi par Git et sans lien avec la suppression de compte → à committer **séparément** (voir le manifeste).

## 7. Reste à faire / non vérifié

- Build réel `nodejs22` dans Cloud Build ; `npm ci` avec le npm de Cloud Build.
- Fiabiliser (ou accepter explicitement) les deux tests d'émulateur intermittents/défaillants ci-dessus.
- Aligner `.github/workflows/ci.yml` (Node 20) sur le runtime 22.

## 8. Erreur d'outillage rencontrée et corrigée (transparence)

Une première copie de travail du dépôt, faite avec `robocopy` en PowerShell, a écrit par erreur des **copies parasites dans le dépôt** (`functions/functions`, `docs/docs`, `rules-tests/rules-tests`, `test-env/test-env`, `lib/lib`, `scripts/scripts` et 12 fichiers racine copiés dans `scripts/`) : cause, `$D` et `$d` désignent la même variable en PowerShell. Ces copies (aucune suivie par Git, toutes identiques aux originaux, y compris des copies de fichiers `.env` ignorés) ont été **supprimées** après vérification (`cmp` contre les originaux, aucun fichier suivi). Les résultats obtenus pendant qu'elles existaient (une exécution complète Node 22 : 5 échecs, dont 4 dus à ces copies ou à l'absence de `.git` dans la copie de travail) ont été **écartés** et toutes les suites ci-dessus ont été **rejouées sur le dépôt propre**. `git status` après nettoyage : aucun fichier inattendu.
