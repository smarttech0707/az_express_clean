# Mission 7E-71 — Validation sous Node.js 22 (runtime Cloud Functions cible)

Date : 2026-11-06 · Les validations des missions 7E-64 à 7E-70 ont été faites sous **Node 24.22.1** alors que le runtime cible est **Node 22** (`firebase.json` : `nodejs22`, `functions/package.json` : `"engines": {"node": "22"}`). Ce document sépare strictement ce qui a été exécuté sous Node 22 de ce qui ne l'a pas été.

## 1. Environnement utilisé

| Élément | Valeur |
|---|---|
| Node par défaut de la machine | v24.22.1 (`C:\Program Files\nodejs`) |
| Node 22 | **22.23.4**, obtenu par `npm install node@22` dans le **dossier temporaire de session** (téléchargement du paquet public ; aucun fichier du dépôt modifié, aucun Node installé globalement, aucun gestionnaire de versions) |
| Lancement | binaire direct `…\scratchpad\node22\node_modules\node\bin\node.exe --test …` ; le CLI Firebase (émulateurs) reste lancé par Node 24 et exécute les suites avec le binaire Node 22 |
| Gestionnaires de versions présents | aucun (nvm, fnm, volta absents) |
| `functions/node_modules` | **non réinstallé** : les dépendances installées sous Node 24 sont utilisées telles quelles. Un `npm ci` sous Node 22 (celui de Cloud Build) n'a **pas** été fait → **NON VÉRIFIÉ** |

## 2. Analyse statique (aucune exécution)

| Contrôle | Résultat |
|---|---|
| `engines` du projet | `node: 22` |
| Fichier de verrouillage | `package-lock.json`, `lockfileVersion 3`, 544 paquets (252 de production) |
| Paquets avec champ `engines.node` | 326 ; **aucun incompatible** avec 22.23.4 (vérifié avec `semver`, y compris pour 24.22.1) |
| Dépendances directes | `firebase-functions` 7.3.2 (`>=18`), `firebase-admin` 12.7.0 (`>=14`), `axios` 1.16.1, `@anthropic-ai/sdk` 0.109.0, `openai` 6.49.0 ; `@google-cloud/firestore` 7.11.6, `@grpc/grpc-js` 1.14.3 (pur JavaScript) |
| Paquets avec script d'installation | `fsevents` (macOS, optionnel), `protobufjs`, `unrs-resolver` (outillage de test) → aucun module natif requis à l'exécution en production |
| API JavaScript postérieures à Node 22 | recherche de `Array.fromAsync`, `Object.groupBy`, `Promise.try`, méthodes d'ensembles, `using`, `RegExp.escape`, `Iterator.from`, `Float16Array`, `Uint8Array.fromBase64`, `Math.sumPrecise`… dans `functions/` hors `node_modules` : **aucune occurrence** |
| Scripts de test | `"test": "node --test test/*.test.js"` : le glob est étendu par l'interpréteur de commandes ; Node 22 accepte la même syntaxe |
| Versions de dépendances | **aucune modification** (consigne respectée) |
| Dérive d'environnement relevée | `.github/workflows/ci.yml` utilise `node-version: '20'` pour deux jobs ; le runtime déployé est 22 ; la machine locale est 24. Trois versions différentes, aucune décision prise ici |

## 3. Résultats d'exécution

| Suite | Node 22.23.4 | Node 24.22.1 | Statut Node 22 |
|---|---|---|---|
| `functions` complète sans émulateur (`node --test test/*.test.js`) | 2304 tests · 2137 réussis · **1 échec** · 166 ignorés | 2304 · 2138 · **0** · 166 | **FAIL (1)** — voir §4 |
| `restaurantV2Preprod.test.js` isolé, rapport `spec` | 12 · 11 · **1** | — | FAIL (même cause) |
| Tests enfants de ce test (`deliveryProofs.test.js`, mêmes variables) | 35 · 35 · 0 | 35 · 35 · 0 | **PASS** |
| `accountQuarantineConcurrency.emulator.test.js`, fichier complet, émulateur Firestore — 1ʳᵉ exécution | 9 · 8 · **1** (`C2`) | 9 · 9 · 0 | FAIL (intermittent, voir §5) |
| idem — 2ᵉ exécution | **9 · 9 · 0** | 9 · 9 · 0 (3 exécutions : 7E-69, 7E-71 ×2) | PASS |
| `C2` seul, 6 essais, émulateur remis à zéro entre essais | **6/6** | **6/6** | PASS |
| Règles de suppression (4 fichiers, `--test-concurrency=1`, Auth + Firestore + Storage) | **63 · 63 · 0** | 63 · 63 · 0 | **PASS** |
| Suite `functions` complète sous émulateurs Auth + Firestore | **NON EXÉCUTÉE sous Node 22** | voir rapport de consolidation | NON VÉRIFIÉ |
| Règles Firestore principales (470), règles Storage (128) | **NON EXÉCUTÉES sous Node 22** | 470 / 128 réussis | NON VÉRIFIÉ — ces tests évaluent des règles dans l'émulateur et ne chargent pas le code de `functions/` ; non revendiqués comme validation Node 22 |
| Installation et chargement sous l'image de build de Cloud Build / Cloud Run `nodejs22` | **non fait** (aucun déploiement) | — | NON VÉRIFIÉ |

Les 3 tests de plafond ajoutés (`pilotCap.test.js`) font partie des 2304 et ont tourné sous Node 22 (PASS).

## 4. L'échec sous Node 22 : un défaut du test, pas du code

`functions/test/restaurantV2Preprod.test.js:121` lance un processus fils (`node --test deliveryProofs.test.js`) puis vérifie `assert.match(out, /ℹ fail 0/)` et `/ℹ pass [1-9]/`. Le préfixe `ℹ` appartient au rapporteur `spec`, rapporteur par défaut de Node 24 en sortie non interactive ; **Node 22 produit du TAP** (`# fail 0`) quand la sortie est redirigée. Le fils réussit (35/35), seule l'expression régulière ne reconnaît pas le format.

- Fichier suivi par Git, **non modifié** (hors périmètre, antérieur à ces missions, commit `68c7150`).
- Conséquence probable : ce test échouerait aussi dans la CI actuelle (Node 20, même rapporteur TAP) — **non vérifié**, la CI n'a pas été exécutée.
- Correctif proposé, **non appliqué** :
  ```diff
  -  assert.match(out, /ℹ fail 0/);
  -  assert.match(out, /ℹ pass [1-9]/);
  +  assert.match(out, /^(ℹ|#) fail 0$/m);
  +  assert.match(out, /^(ℹ|#) pass [1-9]/m);
  ```
  (ou passer `--test-reporter=spec` au processus fils). À traiter dans une mission distincte.

## 5. L'échec de `C2` sous Node 22 : contention de l'émulateur

Message : `3 INVALID_ARGUMENT: Transaction is invalid or closed` levé par l'émulateur Firestore pendant l'essai « webhook contre quarantaine » (trois transactions en conflit sur les mêmes documents). C'est exactement le comportement documenté en 7E-69 (présent aussi sur le code antérieur à 7E-68 ; Firestore de production renvoie `ABORTED` et le SDK réessaie). Preuves que ce n'est pas une régression propre à Node 22 : 2ᵉ exécution complète 9/9 sous Node 22 ; 6/6 sous chaque version quand l'essai est isolé et l'émulateur remis à zéro. **Limite** : le taux d'apparition n'est pas démontré identique entre versions (2 exécutions complètes sous Node 22 : 1 intermittence ; 3 sous Node 24 : 0) ; l'échantillon est trop petit pour conclure à l'égalité.

## 6. Conclusion

- **Code de `functions/` : aucun défaut propre à Node 22 trouvé.** Dépendances compatibles, aucune API trop récente, 2137 tests réussis, règles de suppression 63/63, concurrence 9/9 (après une intermittence d'émulateur).
- **Un échec de test reproductible sous Node 22** (format de rapport), hors périmètre et non corrigé ; un correctif d'une ligne est fourni.
- **Non fait / non vérifié** : `npm ci` et chargement sous l'image de build `nodejs22`, suite émulateurs complète sous Node 22, règles principales et Storage sous Node 22.
- **Ce n'est pas** une validation Node 22 complète : c'est une validation Node 22 des tests exécutables localement, avec les exceptions ci-dessus.
