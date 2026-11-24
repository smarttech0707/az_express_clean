# ACCOUNT_DELETION — L0-E : validation complète des tests avec émulateurs

Date : 2026-11-10. Mission de test et de diagnostic ; aucun fichier du dépôt modifié hormis ce rapport.

## Conclusion : PASS AVEC RÉSERVES

- Suite pure : 2418 tests, 2246 pass, **0 fail**, 172 skipped.
- 24 fichiers émulateur : 189 tests, 188 pass, **1 fail**, 0 skipped.
- L'unique échec (`accountQuarantineConcurrency` C2) est **intermittent**, **non reproduit en 3 rejeux isolés** et de **cause indéterminée** (voir §5). Il n'est ni classé environnemental ni écarté.
- Les 14 échecs de L0-B/L0-C et les 5 de L0-D sont résolus et ne réapparaissent pas.

## 1. Environnement

| Élément | Valeur |
|---|---|
| Node | 22.23.4 (copie isolée dans le dossier temporaire de session ; Node 24 global non modifié) |
| Firebase CLI | 15.18.0 global, utilisé uniquement pour démarrer les émulateurs locaux |
| Émulateurs | Auth 19099, Firestore 18080, Storage 19199, hub 14400, logging 14500 (ports libres vérifiés avant démarrage), `--only auth,firestore,storage --project demo-l0e-auth` |
| Projets des tests | `demo-l0e-auth` (défaut de l'émulateur Auth = `GCLOUD_PROJECT`, nécessaire à la connexion REST) ; `demo-az-t7e` (suites Restaurant v2 + allowlist, imposé par les tests) ; `demo-az-t7e-st` (Storage) |
| Règles | `firestore.rules` et `storage.rules` du dépôt (copies identiques, vérifiées par `cmp`) |
| Garde de sortie réseau | `test-env/emulator/egressGuard.js` chargé par `NODE_OPTIONS=--require` avant chaque fichier, y compris la suite pure |
| Variables retirées | `GOOGLE_APPLICATION_CREDENTIALS`, `FIREBASE_CONFIG`, `AZ_PILOT_DRIVER_IDS` |
| Isolation | Aucun projet réel ; `az-express-b0469` jamais contacté ; Firestore (et comptes Auth) du projet vidés avant chaque fichier ; un fichier à la fois |
| Émulateurs préexistants | ports 5001, 8080, 9099, 9199, 4000 non touchés (toujours à l'écoute en fin de mission, 6 sockets comme au départ) |

**Incident d'exécution (déclaré).** Le premier lancement du script avait été pris à tort pour interrompu et j'en ai relancé un second : les deux ont tourné **en même temps sur les mêmes émulateurs**, ce que la mission interdit. Ces résultats (nombreux échecs de concurrence) ont été **intégralement écartés** (journaux conservés sous `…\scratchpad\l0e\INVALID_concurrent_run_logs`, non utilisés), après vérification qu'aucun processus de test ne subsistait, puis la phase a été relancée **une seule fois**. Seuls les résultats de ce run propre figurent ci-dessous.

## 2. Résultats individuels (24 fichiers, run propre)

| # | Fichier | Projet | Tests | Pass | Fail | Skip | Durée |
|---|---|---|---|---|---|---|---|
| 1 | acceptOffersCleanup.emulator | demo-l0e-auth | 4 | 4 | 0 | 0 | 6 s |
| 2 | accountQuarantineConcurrency.emulator | demo-l0e-auth | 9 | **8** | **1** | 0 | 201 s |
| 3 | adminOrderDisputes.emulator | demo-l0e-auth | 8 | 8 | 0 | 0 | 37 s |
| 4 | adminPartnerAccounts.emulator | demo-l0e-auth | 11 | 11 | 0 | 0 | 8 s |
| 5 | cashPayment.emulator | demo-l0e-auth | 7 | 7 | 0 | 0 | 13 s |
| 6 | catalogConcurrency.emulator | demo-l0e-auth | 6 | 6 | 0 | 0 | 19 s |
| 7 | deliveryProofs.emulator | demo-l0e-auth | 6 | 6 | 0 | 0 | 18 s |
| 8 | deliveryQuote.emulator | demo-l0e-auth | 11 | 11 | 0 | 0 | 10 s |
| 9 | dispatchRetry.emulator | demo-l0e-auth | 13 | 13 | 0 | 0 | 47 s |
| 10 | driverRatings.emulator | demo-l0e-auth | 3 | 3 | 0 | 0 | 20 s |
| 11 | financialConcurrency.emulator | demo-l0e-auth | 12 | 12 | 0 | 0 | 63 s |
| 12 | marketplaceBoutiqueBilling.emulator | demo-l0e-auth | 6 | 6 | 0 | 0 | 26 s |
| 13 | notificationGuard.emulator | demo-l0e-auth | 1 | 1 | 0 | 0 | 1 s |
| 14 | partnerActivation.e2e.emulator (`AZ_E2E_RULES=1`) | demo-l0e-auth | 7 | 7 | 0 | 0 | 4 s |
| 15 | partnerOrderClientAllowlist.emulator | demo-az-t7e | 7 | 7 | 0 | 0 | 4 s |
| 16 | partnerOrderConcurrency.emulator | demo-l0e-auth | 27 | 27 | 0 | 0 | 254 s |
| 17 | restaurantV2CleanupSafety.emulator | demo-az-t7e | 7 | 7 | 0 | 0 | 26 s |
| 18 | restaurantV2FirstRun.emulator | demo-az-t7e | 10 | 10 | 0 | 0 | 16 s |
| 19 | restaurantV2Intruder.emulator | demo-az-t7e | 8 | 8 | 0 | 0 | 16 s |
| 20 | restaurantV2Pilot.emulator | demo-az-t7e | 8 | 8 | 0 | 0 | 39 s |
| 21 | restaurantV2Selfie.storage | demo-az-t7e-st | 2 | 2 | 0 | 0 | 2 s |
| 22 | transferSettlement.emulator | demo-l0e-auth | 7 | 7 | 0 | 0 | 26 s |
| 23 | walletDebitQuarantine.emulator | demo-l0e-auth | 6 | 6 | 0 | 0 | 210 s |
| 24 | walletDebitQuarantineOrderings.emulator | demo-l0e-auth | 3 | 3 | 0 | 0 | 290 s |
| | **Total émulateur** | | **189** | **188** | **1** | **0** | |

Couverture demandée : Restaurant v2 (17–21, 15), suppression/quarantaine de compte (2, 23, 24), portefeuille/paiements (5, 11, 23, 24, 22), E-Kbine (couvert par `financialConcurrency` et `partnerOrderConcurrency` ; il n'existe pas de fichier émulateur E-Kbine dédié parmi les 24), dispatch (9), partenaires (4, 14, 16, 12), preuves de livraison (7).

**Suite pure** (`node --test 'test/*.test.js'`, sans variable d'émulateur) : 2418 tests, 2246 pass, 0 fail, 0 cancelled, 172 skipped, ≈ 51 s.

## 3. Comparaison

| Mesure | L0-B | L0-D | L0-D.1 | L0-E |
|---|---|---|---|---|
| Pure : tests / pass / fail / skip | 2410 / 2241 / 0 / 169 | 2415 / 2238 / 5 / 172 | 2418 / 2246 / 0 / 172 | **2418 / 2246 / 0 / 172** |
| Émulateur : tests / pass / fail | 184 / 170 / 14 | (4 fichiers : 38 / 38 / 0) | — | **189 / 188 / 1** |

189 = 184 (L0-B) + 5 tests émulateur ajoutés en L0-D (FirstRun L1/L2, allowlist n° 16, dispatchRetry ×2). Les 169 → 172 skipped de la suite pure s'expliquent par ces mêmes ajouts (les trois qui exigent un émulateur). Les suites de concurrence, qui passaient 63/63 en L0-B, sont à 62/63 ici (l'échec est dans l'une d'elles).

## 4. Contrôle de la liste blanche des livreurs

| Exigence | Preuve (run propre) |
|---|---|
| Livreur explicitement listé autorisé | dispatchRetry 7E-55 (livreur listé servi) ; allowlist n° 16 (liste du lot acceptée et renvoyée) ; FirstRun 10/10 et Pilot 8/8 de bout en bout |
| Livreur absent refusé | dispatchRetry 7E-55 : non notifié, acceptation `permission-denied` / `DRIVER_NOT_IN_PILOT` ; pure `pilotDriverRestriction`, `pilotTransfer`, `restaurantV2Pilot.test.js` (driverRefusal) |
| Liste absente/vide : pilote non ouvrable | FirstRun L1 et pur `restaurantV2FirstRun.test.js` / `restaurantV2Reopen.test.js` (`PILOT_DRIVER_IDS_REQUIRED`, aucun appel) ; côté serveur : liste absente ou vide = aucun livreur (dispatchRetry) |
| Dispatch ne notifie pas les non autorisés | dispatchRetry 7E-55 ; `notInPilot` |
| Tests Restaurant v2 cohérents | 5 fichiers Restaurant v2 émulateur + 3 fichiers purs : 0 échec |

**Limite signalée séparément (non modifiée)** : `runStep.js` / `assertDataInLot` ne contrôle pas que les `pilotDriverIds` appartiennent au lot ; un uid de livreur hors lot fourni par l'opérateur ne serait pas bloqué par l'exécuteur (le serveur reste la protection : seuls les livreurs listés sont servis).

## 5. Échec restant

**`accountQuarantineConcurrency.emulator` test 7, « C2. webhook vs quarantaine : crédit si antérieur au tombstone, sinon mise en attente — jamais de crédit perdu ni double »** (`accountQuarantineConcurrency.emulator.test.js:180`).

Message complet : `3 INVALID_ARGUMENT: Transaction is invalid or closed.` (`failureType: testCodeFailure`, code 3, pile gRPC `@google-cloud/firestore` → `google-gax` → `retry-request`, sans ligne du dépôt dans la pile). Durée avant échec : 9,3 s.

Faits mesurés :
- Run propre : 1 échec sur ce test. Rejeux isolés (même Node, mêmes émulateurs, état vidé) : **3 passages sur 3** (C2 : 93 s, 101 s, 107 s ; 25 rondes « crédités » et « mis en attente » complètes). L0-B : 9/9.
- Le test lance volontairement des transactions réellement concurrentes (webhook + quarantaine) ; la suite signale elle-même des « rejets de transaction par l'émulateur » (0, 1 et 2 selon les rejeux en C1).
- Le test n'a pas échoué sur une assertion métier (aucune valeur de solde ou de statut erronée n'est rapportée) ; l'erreur vient d'un appel gRPC.

Classification : **CAUSE INDÉTERMINÉE** (échec intermittent). Hypothèse la plus plausible mais **non prouvée** : invalidation d'une transaction par l'émulateur Firestore sous forte contention (comportement que le test attend déjà en C1), non rattrapée dans C2 par le code métier ou le test. Je n'ai pas pu établir si le gestionnaire de webhook doit rejouer cette erreur (risque métier : un webhook en erreur transitoire, rejoué par le fournisseur) ou si le test devrait la tolérer comme en C1. Aucune correction n'a été tentée. Aucun lien avec `pilotDriverIds`, L0-D ou L0-D.1.

Recommandation (non appliquée) : investigation dédiée (boucle de rejeu de C2 seul, ≥ 20 passes, journal de l'émulateur) avant toute décision, car ce test protège l'absence de crédit perdu ou doublé entre webhook et quarantaine de compte.

## 6. Limites de validation

- Un seul run propre complet ; l'échec intermittent n'est pas reproduit, donc ni confirmé ni infirmé comme défaut.
- Émulateurs uniquement : aucun test sur appareil, préproduction ou production ; les émulateurs n'imitent pas fidèlement la latence ni les quotas du cloud.
- Les 24 fichiers ont tourné avec `demo-l0e-auth` comme projet commun hors suites imposées `demo-az-t7e*` (comptes Auth vidés entre fichiers).
- Pas de fichier émulateur E-Kbine dédié ; la couverture E-Kbine émulateur est indirecte.
- Les suites purs/émulateur ne prouvent pas le déploiement ni la configuration réelle de préproduction.
- Incident de lancement concurrent (écarté) documenté ci-dessus.

## 7. Préservation Git (avant et après)

- HEAD `d65c8f0`, branche `finalisation/az-express`, index vide, 0 stash.
- Empreintes des cinq fichiers sensibles inchangées (`ekbineOrders` `21a9cc9a`, `index` `9f00f1c1`, `professionalSubscriptions` `976c2396`, `adminPartnerAccounts` `1a5cde55`, `passwordReset` `26975f60`). `firestore.rules`, `storage.rules`, `functions/package.json` inchangés.
- Fichiers suivis modifiés : 20 = 11 préexistants + 9 des missions L0-D / L0-D.1 (aucun ajouté par L0-E).
- Non suivis : 108 avant la mission (dont le rapport L0-D.1) + ce rapport = 109.
- Aucun commit, push, déploiement ; aucun accès à `az-express-b0469` ; seuls mes émulateurs ont été arrêtés (ports 18080, 19099, 19199, 14400, 14500 libres).
