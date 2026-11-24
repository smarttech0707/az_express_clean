# L0-B — Base de tests sous Node 22.23.4 (suppression de compte)

Date : 2026-11-10. Branche `finalisation/az-express`, HEAD `d65c8f0`. Rapport de mesure : aucun code, test, règle, document existant ni fichier non commité n'a été modifié ; aucun commit, push, déploiement ni accès à un projet Firebase distant ; la production `az-express-b0469` n'a pas été touchée ; aucun lot L1–L8 commencé.

**Seul fichier créé dans le dépôt : ce rapport.** Tout le reste (Node 22, journaux, configuration d'émulateur, scripts) est dans le dossier temporaire de session :
`C:\Users\User\AppData\Local\Temp\claude\d--az-express-clean\c579b050-5748-4442-a523-d168d26fdffb\scratchpad\l0b\`.

Légende : **[MESURÉ]** résultat observé dans cette mission ; **[DÉDUIT]** conclusion tirée d'une lecture ; **[NON VÉRIFIÉ]** non établi.

---

## 1. Environnement Node.js

| Élément | Valeur [MESURÉ] |
|---|---|
| Node 24 de la machine | v24.22.1, `C:\Program Files\nodejs` : **inchangé**, PATH global non modifié |
| Node de test | **v22.23.4** (zip officiel `node-v22.23.4-win-x64.zip`), extrait dans `scratchpad\l0b\node22\` ; utilisé en préfixant `PATH` dans chaque commande |
| npm de Node 22 | 10.9.9 (Node 24 : npm 11.19.1, inchangé) |
| Intégrité du téléchargement | SHA-256 `cbc74b5e…ce5f20` identique à `SHASUMS256.txt` du même site (limite : la somme vient du même hôte, pas d'une signature indépendante) |
| `functions/package.json` | `engines.node: "22"` |
| `firebase.json` | `functions.runtime: "nodejs22"` |
| Dépendances | non installées, non mises à jour (`functions/node_modules` existant utilisé tel quel) ; firebase-admin 12.7.0, firebase-functions 7.3.2 |
| Firebase CLI | 15.18.0 (installation globale existante, lancée par Node 24 pour démarrer les émulateurs locaux uniquement) |
| Java | OpenJDK 21.0.11 |
| Seule opération réseau volontaire | téléchargement du zip Node et de `SHASUMS256.txt` depuis `nodejs.org` |

**Première base de tests sous la version cible.** Avant cette mission, tous les résultats avaient été obtenus sous Node 24.

## 2. Préservation du projet [MESURÉ]

| Contrôle | Avant | Après |
|---|---|---|
| Branche / HEAD | `finalisation/az-express` / `d65c8f0` | identique |
| Index | vide | vide |
| 11 fichiers suivis modifiés | empreintes `git hash-object` enregistrées | **identiques** (fichier d'empreintes comparé) |
| Cinq fichiers non commités (`ekbineOrders.js` `21a9cc9a…`, `index.js` `9f00f1c1…`, `professionalSubscriptions.js` `976c2396…`, `adminPartnerAccounts.js` `1a5cde55…`, `passwordReset.js` `26975f60…`) | enregistrées | identiques |
| 105 fichiers non suivis (avant la création de ce rapport) | liste enregistrée | **liste identique** |
| `git status --short` (empreinte) | `7f819b9f…` | identique avant la création de ce rapport |

Aucun nettoyage, déplacement, restauration, indexation. Le fichier ignoré `firestore-debug.log` à la racine date du 2026-11-07 : **pré-existant**, non créé par cette mission (les journaux d'émulateur ont été écrits dans le dossier temporaire, le démarrage étant lancé depuis ce dossier).

## 3. Décompte exact des tests ignorés

### 3.1 Résultat [MESURÉ]

Exécution fichier par fichier, sous Node 22.23.4, **sans variable d'émulateur**, avec la garde de sortie réseau du projet :

| | Valeur |
|---|---|
| Fichiers de test (`functions/test/*.test.js`) | 159 |
| Tests exécutés | **2410** |
| Réussis | 2241 |
| Échecs | **0** |
| Annulés | 0 |
| **Ignorés** | **169** |
| Durée cumulée (fichiers lancés l'un après l'autre) | ≈ 175 s |

2241 + 169 = 2410 : **le chiffre antérieur de 169 est confirmé exactement**.

### 3.2 Origine des 169 ignorés [MESURÉ]

Les 169 tests ignorés se trouvent tous dans **24 fichiers** `*.emulator.test.js` / `*.storage.test.js`. Motifs lus dans les sorties TAP :

| Motif d'ignorance | Nombre |
|---|---|
| « émulateur Firestore requis (projet demo-*) » | 67 |
| « émulateur Firestore requis (projet demo-az-t7e) » | 37 |
| « émulateur Firestore requis » | 35 |
| « émulateurs Auth/Firestore requis » | 10 |
| « FIRESTORE_EMULATOR_HOST absent (émulateur Firestore requis) » | 10 |
| « émulateurs + AZ_E2E_RULES=1 requis » (Auth + Firestore + règles) | 7 |
| « émulateurs Storage et Firestore requis (projet demo-az-t7e-st) » | 2 |
| « émulateurs Auth/Firestore/Storage requis » | 1 |
| **Total** | **169** |

Répartition par service requis : **Firestore seul** : 149 ; **Firestore + Auth** : 17 (dont 7 exigent en plus `AZ_E2E_RULES=1`, c'est-à-dire les règles chargées dans l'émulateur) ; **Firestore + Auth + Storage** : 1 ; **Firestore + Storage** : 2. Aucun test n'est ignoré pour cause de Windows ou de configuration locale : les 3 tests de `restaurantV2Preprod.test.js` conditionnés à Windows **s'exécutent** (machine Windows). Hors fichiers d'émulateur, le nombre de tests ignorés est de **0**.

### 3.3 Écart avec les 183-184 déclarations de l'inventaire statique [MESURÉ + DÉDUIT]

L'inventaire statique comptait les lignes `test(`/`it(` : 184 dans les 24 fichiers. À l'exécution **sans émulateur**, trois fichiers ne produisent qu'**un seul** résultat ignoré (le fichier est ignoré en bloc), et un fichier en produit un de plus :

| Fichier | Déclarations | Ignorés comptés |
|---|---|---|
| `accountQuarantineConcurrency.emulator` | 10 | 1 |
| `walletDebitQuarantine.emulator` | 7 | 1 |
| `walletDebitQuarantineOrderings.emulator` | 2 | 1 |
| `deliveryProofs.emulator` | 5 | 6 |

184 − 9 − 6 − 1 + 1 = **169**. Avec les émulateurs, ces suites se développent : **184 tests** sont réellement exécutés (121 + 63, §5), soit exactement le chiffre statique. Les deux chiffres sont donc cohérents : 169 = ce que l'on observe sans émulateur ; 184 = ce que les émulateurs exécutent. Un fichier supplémentaire, `emulatorEgressGuard.test.js`, a un nom en `emulator` mais est **pur** (13 tests, tous exécutés, tous réussis).

## 4. Suites sans émulateur (phase A) [MESURÉ]

Version Node : **22.23.4**. Environnement nettoyé de toute variable d'émulateur, de `GOOGLE_APPLICATION_CREDENTIALS` et de `FIREBASE_CONFIG` ; garde de sortie réseau chargée (`test-env/emulator/egressGuard.js`).

| Suite (regroupement par nom de fichier, indicatif) | Fichiers | Tests | Réussis | Échecs | Ignorés | Durée |
|---|---|---|---|---|---|---|
| Moteur `accountObligations` | 1 | 60 | 60 | 0 | 0 | < 1 s |
| Suppression de compte, quarantaine et gardes (`account-deletion*`, `accountAdmission`, `accountDeletion*`, `accountQuarantineGuards/Index`, `manualAccountDeletion`, `walletDebitQuarantineGuards`, `ekbineQuarantineGuards`, nettoyage) | 8 | 125 | 125 | 0 | 0 | ≈ 15 s |
| Financier et E-Kbine hors émulateur (`ekbine*`, `wallet*`, paiements, remboursements, commissions, cash, transferts, commandes partenaires, livraison…) | 39 | 818 | 818 | 0 | 0 | ≈ 31 s |
| Ensemble hors fichiers d'émulateur | 135 | 2241 | 2241 | 0 | 0 | — |
| Fichiers d'émulateur lancés sans émulateur | 24 | 169 | 0 | 0 | 169 | ≈ 0 s chacun |

Les regroupements sont faits par motif de nom : ils sont indicatifs ; les lignes de contrôle fiables sont « Ensemble » (2241 tests, 0 échec) et le total de 2410. Détail des fichiers ignorés : §10.

## 5. Suites avec émulateurs isolés (phase B) [MESURÉ]

### 5.1 Configuration

- Émulateurs **Firestore, Auth, Storage** démarrés par `firebase emulators:start --only auth,firestore,storage` depuis le dossier temporaire, projet `demo-*`, configuration propre (`firebase.json` du dossier temporaire), règles : copies **octet pour octet** de `firestore.rules` et `storage.rules` (vérifiées avec `cmp`).
- Ports dédiés, hôte `127.0.0.1` : Firestore **18080**, Auth **19099**, Storage **19199**, hub 14400, journalisation 14500, interface désactivée.
- Les émulateurs déjà actifs (processus tiers, ports 5001, 8080, 9099, 9199 et 4000) **n'ont pas été touchés** : leurs ports sont toujours à l'écoute en fin de mission. Seuls mes processus ont été arrêtés, désignés par leur port.
- Un seul fichier de test à la fois ; l'état Firestore du projet est vidé (appel local à l'émulateur) avant chaque fichier. Aucune suite concurrente sur les mêmes émulateurs.
- Garde de sortie réseau chargée dans chaque exécution ; `GOOGLE_APPLICATION_CREDENTIALS` et `FIREBASE_CONFIG` retirés.

### 5.2 Isolation [MESURÉ + limites]

- Projets exclusivement `demo-*` ; aucun identifiant réel, aucune donnée client ; `.firebaserc` non utilisé (le CLI a été lancé depuis le dossier temporaire, avec `--project demo-…` et sa propre configuration).
- **Connexions sortantes bloquées par la garde : 0** dans toutes les sorties de tests.
- Limite : la garde ne couvre que les processus de test Node. Je n'ai pas pu prouver que le CLI Firebase (Node 24) n'a effectué aucune requête (vérification de version, télémétrie) : un instantané `netstat` montre des connexions établies vers l'extérieur, non attribuables à mes processus. [NON VÉRIFIÉ]

### 5.3 Première passe

| Groupe | Fichiers | Tests | Réussis | Échecs | Ignorés |
|---|---|---|---|---|---|
| Firestore / Auth / Storage isolés | 18 | 121 | 94 | 27 | 0 |
| Concurrence | 6 | 63 | 63 | 0 | 0 |
| **Total** | **24** | **184** | **157** | **27** | **0** |

Les 27 échecs se répartissent en deux causes très différentes (§5.4 et §5.5).

### 5.4 Échecs d'environnement, résolus (13)

`adminPartnerAccounts.emulator` (6 échecs) et `partnerActivation.e2e.emulator` (7) échouaient à la connexion (`EMAIL_NOT_FOUND`). **Cause [MESURÉ]** : la connexion REST de l'émulateur Auth n'indique pas de projet ; elle utilise le projet par défaut du démarrage (`--project`). Mes utilisateurs étaient créés dans le projet du test, pas dans celui du démarrage. Une sonde isolée l'a confirmé. **Ce n'est pas un défaut du code.**

Les émulateurs ont été redémarrés avec `--project demo-l0b-auth` et les deux fichiers rejoués avec `GCLOUD_PROJECT=demo-l0b-auth` (et `AZ_E2E_RULES=1` pour l'E2E) :

| Fichier | Tests | Réussis | Échecs | Durée |
|---|---|---|---|---|
| `adminPartnerAccounts.emulator` | 11 | 11 | 0 | 10 s |
| `partnerActivation.e2e.emulator` | 7 | 7 | 0 | 6 s |

### 5.5 Échecs persistants (14) [MESURÉ] — dérive des tests après `aa3d1b0`

| Fichier | Échecs | Message observé |
|---|---|---|
| `restaurantV2FirstRun.emulator` | 6 sur 8 | `DISPATCH_FAILED` : « Aucun livreur proposé (GPS ? éligibilité ?) » |
| `restaurantV2Pilot.emulator` | 6 sur 8 | assertions de parcours ; « Cette commande n'est plus disponible » |
| `partnerOrderClientAllowlist.emulator` | 1 sur 6 (n° 6) | la configuration lue contient `pilotDriverIds: []`, absent de l'attendu |
| `dispatchRetry.emulator` | 1 sur 11 (n° 9) | `['dP1']` obtenu au lieu de `['dP1','dP2']` ; **reproduit 3 fois sur 3** |

**Cause probable [DÉDUIT, non prouvée par une correction, qui est interdite]** : le commit `aa3d1b0` (« restrict pilot driver dispatch », dans l'historique de HEAD) a ajouté `pilotDriverIds` et l'exclusion des livreurs hors pilote pour les commandes restaurant/boulangerie v2 (`dispatch.js`, `driverAcceptance.js`, `partnerOrdersConfig.js`). Ce commit a mis à jour des tests purs mais pas ces quatre fichiers d'émulateur ; ces derniers étaient **ignorés sans émulateur**, donc la dérive est restée invisible. Éléments à l'appui : `pilotDriverIds` n'apparaît pas dans les semences de `restaurantV2FirstRun`/`restaurantV2Pilot` ; `partnerOrderClientAllowlist` affiche exactement le champ nouveau ; le test `dispatchRetry` n° 9 utilise une commande v2 où `dP2` n'appartient à aucune liste de pilote.

**Ces 14 échecs sont antérieurs à cette mission, indépendants de la suppression de compte, et non corrigés** (modifier un test est interdit).

### 5.6 Résultat consolidé avec émulateurs

| | Tests | Réussis | Échecs | Ignorés |
|---|---|---|---|---|
| 24 fichiers d'émulateur, après correction de l'environnement Auth | 184 | **170** | **14** | **0** |

Les 169 tests ignorés sans émulateur deviennent, avec émulateurs, 184 tests : **170 réussis, 14 échoués** (les 15 tests supplémentaires viennent des suites qui se développent, §3.3).

### 5.7 Tests de concurrence (suppression de compte et argent) [MESURÉ]

| Fichier | Tests | Réussis | Échecs | Durée |
|---|---|---|---|---|
| `accountQuarantineConcurrency.emulator` | 9 | 9 | 0 | 308 s |
| `walletDebitQuarantine.emulator` | 6 | 6 | 0 | 177 s |
| `walletDebitQuarantineOrderings.emulator` | 3 | 3 | 0 | 249 s |
| `financialConcurrency.emulator` | 12 | 12 | 0 | 61 s |
| `partnerOrderConcurrency.emulator` | 27 | 27 | 0 | 261 s |
| `catalogConcurrency.emulator` | 6 | 6 | 0 | 23 s |

Ces résultats prouvent l'**absence de violation sur les entrelacements tirés dans l'émulateur** ; ils ne prouvent rien sur la charge, la latence ni la concurrence réelles de la production. Version Node de toutes les exécutions : 22.23.4.

## 6. Moteur `accountObligations` [MESURÉ + DÉDUIT]

- Tests : **60/60 réussis** sous Node 22.23.4, 0 ignoré, aucun échec ; fichiers non modifiés (empreintes `e203f2e0…` et `faa3d3d9…`).
- Le moteur et son test sont **absents de HEAD** (non suivis). Aucun module ne le `require` : il n'est intégré à aucun inspecteur.
- Incompatibilités à traiter plus tard (identifiées en lecture, non causes d'échec) : type `ekbine_order_blocked` absent ; claim `ekbine_debit` et résolutions Ekbine hors système absents ; `agentId` hors des clés de lien ; indépendance N2 contrôlée sur des identifiants et non sur des personnes ; N3 indisponible (conforme aux décisions).
- Le test ne dépend d'aucun émulateur.

## 7. État des émulateurs en fin de mission

Tous mes processus d'émulateur sont arrêtés (ports 14400, 14500, 18080, 19099, 19199 et 9151 libres). Les émulateurs préexistants (5001, 8080, 9099, 9199, 4000) sont inchangés.

## 8. Anomalies découvertes

| # | Anomalie | Gravité |
|---|---|---|
| A-1 | 14 tests d'émulateur échouent sur HEAD (dérive après `aa3d1b0`, §5.5), invisibles sans émulateur | **moyenne** : tests non fiables sur le périmètre restaurant v2 / dispatch |
| A-2 | Le projet par défaut de l'émulateur Auth doit égaler `GCLOUD_PROJECT` : une configuration incorrecte produit de faux échecs | faible (procédure à documenter) |
| A-3 | Les tests étaient exécutés jusqu'ici sous Node 24, version non conforme (`engines: 22`) | informatif : aucune différence de résultat n'est démontrée ; non comparé |
| A-4 | `accountQuarantineConcurrency` dure 308 s, `partnerOrderConcurrency` 261 s : suite lente | faible |
| A-5 | Le nom `emulatorEgressGuard.test.js` prête à confusion (test pur) | faible |
| A-6 | Trois fichiers de quarantaine sont ignorés en bloc sans émulateur : un « 0 échec » sans émulateur ne couvre pas la quarantaine concurrente | **moyenne** |
| A-7 | `firestore-debug.log` pré-existant à la racine (ignoré par Git) | informatif |
| A-8 | Je n'ai pas comparé les résultats Node 22 et Node 24 sur la suite pure | informatif |

## 9. Conditions pour autoriser L1

L1 (helper de tombstone/phase) ne doit être autorisé que si :

1. **Décision sur les 14 tests en échec (A-1)** : les corriger dans un lot dédié et autorisé, ou les consigner comme échecs connus, afin que « 0 échec » ait un sens pour les lots suivants. Sans cette décision, aucun lot ne pourra revendiquer une base entièrement verte.
2. **Procédure de test standardisée** : Node 22.23.4 isolé, émulateurs sur ports dédiés, projet Auth identique à `GCLOUD_PROJECT`, un fichier à la fois, garde de sortie réseau. Les scripts de `test-env/` existent mais n'ont pas été utilisés ici ; leur usage demande une décision.
3. **Engagement sur le moteur** : confirmer qu'il reste non suivi, ou autoriser son intégration à HEAD par un lot séparé.
4. **Gardes non commitées** : décider du rattachement par hunks avant que L1 ne touche `accountAdmission.js` ou `index.js`.
5. Les décisions en attente de 2D-2A.10 (Q1–Q4, second approbateur N2, `ADMIN_MFA_MODE`) restent des prérequis des lots qui les concernent, pas de L1.
6. Aucune opération vers `az-express-b0469` ; toute préproduction exigerait une autorisation spécifique et `--project az-express-preprod` explicite.

## 10. Détail par fichier

### 10.1 Phase A (Node 22.23.4, sans émulateur) — fichiers entièrement ignorés

| Fichier | Tests | Réussis | Échecs | Ignorés |
|---|---|---|---|---|
| `acceptOffersCleanup.emulator.test.js` | 4 | 0 | 0 | 4 |
| `accountQuarantineConcurrency.emulator.test.js` | 1 | 0 | 0 | 1 |
| `adminOrderDisputes.emulator.test.js` | 8 | 0 | 0 | 8 |
| `adminPartnerAccounts.emulator.test.js` | 11 | 0 | 0 | 11 |
| `cashPayment.emulator.test.js` | 7 | 0 | 0 | 7 |
| `catalogConcurrency.emulator.test.js` | 6 | 0 | 0 | 6 |
| `deliveryProofs.emulator.test.js` | 6 | 0 | 0 | 6 |
| `deliveryQuote.emulator.test.js` | 11 | 0 | 0 | 11 |
| `dispatchRetry.emulator.test.js` | 11 | 0 | 0 | 11 |
| `driverRatings.emulator.test.js` | 3 | 0 | 0 | 3 |
| `financialConcurrency.emulator.test.js` | 12 | 0 | 0 | 12 |
| `marketplaceBoutiqueBilling.emulator.test.js` | 6 | 0 | 0 | 6 |
| `notificationGuard.emulator.test.js` | 1 | 0 | 0 | 1 |
| `partnerActivation.e2e.emulator.test.js` | 7 | 0 | 0 | 7 |
| `partnerOrderClientAllowlist.emulator.test.js` | 6 | 0 | 0 | 6 |
| `partnerOrderConcurrency.emulator.test.js` | 27 | 0 | 0 | 27 |
| `restaurantV2CleanupSafety.emulator.test.js` | 7 | 0 | 0 | 7 |
| `restaurantV2FirstRun.emulator.test.js` | 8 | 0 | 0 | 8 |
| `restaurantV2Intruder.emulator.test.js` | 8 | 0 | 0 | 8 |
| `restaurantV2Pilot.emulator.test.js` | 8 | 0 | 0 | 8 |
| `restaurantV2Selfie.storage.test.js` | 2 | 0 | 0 | 2 |
| `transferSettlement.emulator.test.js` | 7 | 0 | 0 | 7 |
| `walletDebitQuarantine.emulator.test.js` | 1 | 0 | 0 | 1 |
| `walletDebitQuarantineOrderings.emulator.test.js` | 1 | 0 | 0 | 1 |

Les 135 autres fichiers : 0 échec, 0 ignoré. Journaux complets : `scratchpad\l0b\logsA\*.tap` ; synthèse : `phaseA_summary.tsv`.

### 10.2 Phase B (émulateurs) — première passe

| Groupe | Fichier | Tests | Réussis | Échecs | Ignorés | Durée |
|---|---|---|---|---|---|---|
| G4 | `acceptOffersCleanup.emulator` | 4 | 4 | 0 | 0 | 20 s |
| G4 | `adminOrderDisputes.emulator` | 8 | 8 | 0 | 0 | 44 s |
| G4 | `adminPartnerAccounts.emulator` | 11 | 5 | 6 | 0 | 4 s (rejeu : 11/11) |
| G4 | `cashPayment.emulator` | 7 | 7 | 0 | 0 | 16 s |
| G4 | `deliveryProofs.emulator` | 6 | 6 | 0 | 0 | 22 s |
| G4 | `deliveryQuote.emulator` | 11 | 11 | 0 | 0 | 13 s |
| G4 | `dispatchRetry.emulator` | 11 | 10 | 1 | 0 | 55 s (rejeux ×2 : même échec) |
| G4 | `driverRatings.emulator` | 3 | 3 | 0 | 0 | 8 s |
| G4 | `marketplaceBoutiqueBilling.emulator` | 6 | 6 | 0 | 0 | 21 s |
| G4 | `notificationGuard.emulator` | 1 | 1 | 0 | 0 | 1 s |
| G4 | `partnerActivation.e2e.emulator` | 7 | 0 | 7 | 0 | 7 s (rejeu : 7/7) |
| G4 | `partnerOrderClientAllowlist.emulator` | 6 | 5 | 1 | 0 | 3 s |
| G4 | `restaurantV2CleanupSafety.emulator` | 7 | 7 | 0 | 0 | 25 s |
| G4 | `restaurantV2FirstRun.emulator` | 8 | 2 | 6 | 0 | 5 s |
| G4 | `restaurantV2Intruder.emulator` | 8 | 8 | 0 | 0 | 16 s |
| G4 | `restaurantV2Pilot.emulator` | 8 | 2 | 6 | 0 | 22 s |
| G4 | `restaurantV2Selfie.storage` | 2 | 2 | 0 | 0 | 7 s |
| G4 | `transferSettlement.emulator` | 7 | 7 | 0 | 0 | 35 s |
| G5 | `accountQuarantineConcurrency.emulator` | 9 | 9 | 0 | 0 | 308 s |
| G5 | `catalogConcurrency.emulator` | 6 | 6 | 0 | 0 | 23 s |
| G5 | `financialConcurrency.emulator` | 12 | 12 | 0 | 0 | 61 s |
| G5 | `partnerOrderConcurrency.emulator` | 27 | 27 | 0 | 0 | 261 s |
| G5 | `walletDebitQuarantine.emulator` | 6 | 6 | 0 | 0 | 177 s |
| G5 | `walletDebitQuarantineOrderings.emulator` | 3 | 3 | 0 | 0 | 249 s |

Journaux : `scratchpad\l0b\logsB\` (première passe) et `logsB2\` (rejeux).

---

## 11. Confirmations

- Aucun fichier existant du dépôt n'a été créé, modifié, supprimé, déplacé, restauré ou indexé ; seul ce rapport est ajouté.
- Aucun changement de `.firebaserc`, de `firebase.json`, des règles, des tests ou du code métier.
- Aucun commit, push ni déploiement. Aucune commande Firebase vers un projet distant ; seuls des émulateurs locaux `demo-*` ont été démarrés.
- La production `az-express-b0469` n'a pas été contactée.
- Opération réseau volontaire unique : téléchargement de Node 22.23.4 depuis `nodejs.org`.

Je m'arrête ici. Aucun lot n'est commencé.
