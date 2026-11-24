# ACCOUNT_DELETION — L0-C : Analyse des 14 échecs persistants (émulateurs)

Date : 2026-11-10 — Mission strictement en lecture seule (aucun correctif appliqué). Branche `finalisation/az-express`, HEAD `d65c8f00bdcedba570a66a5633913db46127be3d`.

## 1. Résumé exécutif

- Les 14 échecs observés en L0-B (170 pass / 14 fail sur 184 tests émulateur) ont **une seule cause commune démontrée** : le commit `aa3d1b0` (« security(restaurant-v2): restrict pilot driver dispatch… ») introduit une liste blanche de livreurs `config/partnerOrdersV2.pilotDriverIds` appliquée **fail-closed** aux commandes partenaire v2. Les fichiers de test émulateur et l'outillage d'essai pilote n'ont pas été mis à jour (le message du commit indique que les fichiers émulateur n'ont pas été exécutés).
- **Preuve par bissection** (copies d'archives isolées, émulateurs `demo-*`) : avant `aa3d1b0` (`f32f41d`) tout passe ; à `aa3d1b0` et à HEAD les échecs sont **identiques** (FirstRun 2,3,4,5,7,8 ; Allowlist 6 ; Pilot 3–8 ; dispatchRetry 9). Les commits de suppression de compte (65e738b, 294332e, d65c8f0) ne changent rien.
- **Preuve par suffisance** (copies scratch, code serveur inchangé) : FirstRun 8/8 en autorisant le livreur dans `lot.js` ; Pilot 8/8 en autorisant le livreur dans `openPilot()` ; Allowlist 6/6 en corrigeant la forme attendue ; dispatchRetry 11/11 en semant la config.
- **Aucun bug métier démontré dans le code serveur** : le comportement (refus si livreur hors liste) est le comportement voulu et documenté ; ses tests purs passent.
- **Point d'attention opérationnel** : `scripts/restaurant-v2-pilot/lot.js` (non modifié par `aa3d1b0`) et le plan `docs/RESTAURANT_V2_FIRST_RUN_PLAN.md` ne prévoient aucune autorisation de livreur. Un vrai premier essai suivant ce plan ne dispatcherait à **personne** (échec sûr, mais bloquant). L'intention (étape manuelle séparée ou oubli d'outillage) est **indéterminée**.
- Aucun lien avec la suppression de compte.

## 2. Tableau des 14 échecs

| # | Fichier | Test | Catégorie | Primaire / cascade | Confiance |
|---|---|---|---|---|---|
| 1 | restaurantV2FirstRun | 2 (DISPATCH_FAILED) | Régression introduite par un commit (outillage/données non alignés) | Primaire | Élevée |
| 2 | restaurantV2FirstRun | 3 (`expectedVersion: 2` codé en dur) | Cascade | Cascade de 1 | Élevée |
| 3 | restaurantV2FirstRun | 4 (version réelle 1 vs 3) | Cascade | Cascade | Élevée |
| 4 | restaurantV2FirstRun | 5 (deepEqual [true,4,true]) | Cascade | Cascade | Élevée |
| 5 | restaurantV2FirstRun | 7 (DISPATCH_FAILED) | Régression introduite par un commit | Primaire | Élevée |
| 6 | restaurantV2FirstRun | 8 (pilote fermé au départ) | Cascade | Cascade | Élevée |
| 7 | restaurantV2Pilot | 3 (ligne 212, aucun dispatch) | Test/données non alignés | Primaire | Élevée |
| 8 | restaurantV2Pilot | 4 (ligne 293, acceptation refusée) | Test/données non alignés | Primaire | Élevée |
| 9 | restaurantV2Pilot | 5 (nettoyage : « commande non terminée (pending) ») | Cascade | Cascade de 7/8 | Élevée |
| 10 | restaurantV2Pilot | 6 (idem) | Cascade | Cascade | Élevée |
| 11 | restaurantV2Pilot | 7 (idem) | Cascade | Cascade | Élevée |
| 12 | restaurantV2Pilot | 8 (ligne 462, « Missing expected rejection ») | Cascade | Cascade | Moyenne-élevée |
| 13 | partnerOrderClientAllowlist | 6 (ligne 189/207) | TEST OBSOLÈTE | Indépendant | Élevée |
| 14 | dispatchRetry | 9 (ligne 204) | CONFIGURATION OU DONNÉES DE TEST | Indépendant | Élevée |

Les numéros de test sont ceux des fichiers `functions/test/*.emulator.test.js` (ordre d'exécution du fichier).

## 3. Analyse du commit `aa3d1b0`

Modifications pertinentes :
- `functions/partnerOrdersConfig.js` : `parsePilotConfig` ajoute `driverIds` (Set) et `driverListDeclared` ; `driverRefusal(config, driverId)` retourne `null` seulement si `clientAccess==='open'` sans liste déclarée, ou si le livreur est dans la liste ; sinon `DRIVER_NOT_IN_PILOT`. `isPartnerV2Order` : `amountsVersion===2` et `sellerType` ∈ {restaurant, boulangerie}. `validateConfigChange` accepte `pilotDriverIds` (max 50) ; `view()` l'expose.
- `functions/dispatch.js` : filtre des candidats (`excluded.notInPilot`) + relecture transactionnelle (`txPilot`).
- `functions/driverAcceptance.js` : `permission-denied` (`DRIVER_NOT_IN_PILOT`) pour les commandes v2.
- `functions/driverTransfer.js` : même contrôle sur candidats, acceptation, passation.
- `scripts/restaurant-v2-pilot/cleanup.js` : livreurs étrangers = conflit ; `pilotDriverIds: []` remis à zéro au nettoyage.
- Tests purs mis à jour/ajoutés (`pilotDriverRestriction`, `pilotTransfer`, `partnerOrderClientAllowlist`, `partnerOrdersAdminConfig`) et `restaurantV2CleanupSafety.emulator` (ajoute `pilotDriverIds: [DRIVER]`) : **passent**.
- **Non modifiés** : `lot.js` (`pilotConfigPlan()` sans `pilotDriverIds`), `restaurantV2FirstRun.emulator.test.js`, `restaurantV2Pilot.emulator.test.js`, `dispatchRetry.emulator.test.js`, `partnerOrderClientAllowlist.emulator.test.js`.

Hypothèse vérifiée (et non supposée) : oui, `aa3d1b0` est le commit déclencheur ; preuve = bissection + expériences de suffisance + log de dispatch `notInPilot:1`. La cause n'est cependant pas strictement identique pour les 4 fichiers (voir ci-dessous).

## 4. Détail par groupe

### 4.1 restaurantV2FirstRun (6 échecs : 2,3,4,5,7,8)
- Fonction métier : dispatch après création de commande v2 ; configuration créée par `lot.js` `pilotConfigPlan()` : `{pilotPartnerIds:[resto], pilotClientIds:[client], clientAccess:'restricted', creationOpen:true, managementFrozen:false}` (+ `version:1`).
- Condition d'échec : `clientAccess` restreint et aucune liste `pilotDriverIds` ⇒ `driverRefusal` refuse tout livreur ⇒ aucun candidat ⇒ `DISPATCH_FAILED` (tests 2 et 7, **primaires**). Les tests 3, 4, 5, 8 dépendent de l'état laissé (version de config, compteurs, pilote ouvert/fermé) : **cascades**.
- Attendu : le premier essai dispatche au livreur du lot. Obtenu : aucun dispatch.
- Preuve : copie scratch avec `pilotDriverIds` ajouté au plan de `lot.js` ⇒ 8/8.
- Classification : RÉGRESSION INTRODUITE PAR UN COMMIT (outillage `lot.js`/plan/tests non alignés sur la nouvelle contrainte). Pas de bug serveur. Confiance : élevée.
- Conséquence : l'outillage de premier essai échouerait en réel ; fail-closed donc sans danger financier.

### 4.2 restaurantV2Pilot (6 échecs : 3–8)
- `openPilot()` (ligne 138) utilise `lot.pilotConfigPlan().request` sans livreur. Test 3 (ligne 212) : aucun dispatch ; test 4 (ligne 293) : acceptation refusée (`permission-denied`) ; tests 5–7 : le nettoyage refuse car la commande reste `pending` (conséquence de 3/4) ; test 8 (ligne 462) : « Missing expected rejection » (état résiduel).
- Preuve : (a) modifier `lot.js` seul a produit des échecs artefacts (plan lui-même modifié : `expectedDocument` et nombre d'opérations différents) — **non retenu comme preuve de correction** ; (b) autoriser le livreur dans `openPilot()` seulement ⇒ 8/8.
- Classification : tests 3 et 4 = TEST/DONNÉES NON ALIGNÉS (même racine que 4.1) ; 5–8 = cascades. Confiance : élevée (3–7), moyenne-élevée (8).

### 4.3 partnerOrderClientAllowlist #6
- Fonction : lecture/écriture de la config via `getPartnerOrdersConfig` ; ligne 207 : `assert.deepEqual(res.data.config, {…, version: 1})` sans `pilotDriverIds`. `view()` retourne désormais `pilotDriverIds: []`.
- Écart attendu/obtenu : champ supplémentaire dans la config retournée. Les tests purs frères ont été mis à jour par le même commit, pas celui-ci.
- Preuve : forme attendue corrigée en scratch ⇒ 6/6.
- Classification : TEST OBSOLÈTE. Confiance : élevée. Pas de cause commune de fond avec les autres sinon le même commit.

### 4.4 dispatchRetry #9
- Fonction : dispatch/relance sur une commande v2 préparée (`v2prepared`, lignes 199-202) avec livreurs dP1/dP2, **sans** document `config/partnerOrdersV2`. Config absente ⇒ fail-closed ⇒ aucun candidat. Reproduit 3/3.
- Preuve : semer une config déclarant les livreurs ⇒ 11/11 ; log `notInPilot`.
- Classification : CONFIGURATION OU DONNÉES DE TEST (cohérent avec le comportement documenté fail-closed). Confiance : élevée.

## 5. Bugs réels vs tests obsolètes

- **Bug métier serveur démontré : aucun.**
- **Régression par commit (outillage non aligné)** : FirstRun (primaires 2,7) ; Pilot (3,4) via `lot.js` et le plan documentaire.
- **Test obsolète** : Allowlist #6.
- **Données de test** : dispatchRetry #9.
- **Cascades** : FirstRun 3,4,5,8 ; Pilot 5–8.

## 6. Corrections recommandées (NON appliquées)

1. `lot.js` : décider si `pilotConfigPlan()` doit inclure `pilotDriverIds` (livreur du lot) — modifie `expectedDocument`, le nombre d'opérations et `assertDataInLot`/`assertPilotConfig` de `runStep.js` (qui contrôlent la config exacte). Modification à arbitrer par le propriétaire : l'alternative est une étape manuelle séparée documentée dans le plan.
2. Mettre à jour `docs/RESTAURANT_V2_FIRST_RUN_PLAN.md` en conséquence.
3. `restaurantV2Pilot.emulator.test.js` : autoriser le livreur dans `openPilot()` (modèle de `restaurantV2CleanupSafety`).
4. `restaurantV2FirstRun.emulator.test.js` : aligner sur la décision 1 ; revoir les valeurs codées en dur (version 2, compteurs).
5. `partnerOrderClientAllowlist.emulator.test.js` ligne 207 : ajouter `pilotDriverIds: []`.
6. `dispatchRetry.emulator.test.js` : semer `config/partnerOrdersV2` avec dP1/dP2 pour #9.
7. Ne **pas** assouplir `driverRefusal` pour faire passer les tests.

## 7. Risques pour AZ Express

- Premier essai réel : si l'équipe suit le plan actuel, aucun livreur ne recevrait la commande (blocage opérationnel, sans perte d'argent).
- Les 14 tests émulateur ne protègent plus le parcours pilote tant qu'ils échouent : régression future potentiellement masquée.
- Tout test `*.emulator` ajouté depuis `aa3d1b0` reste non exécuté en routine (169 tests ignorés sans émulateur).
- Aucun impact sur les travaux de suppression de compte (identique avant/après les commits associés).

## 8. Décision recommandée par échec

| Échecs | Recommandation |
|---|---|
| FirstRun 2,7 | Corriger l'outillage/config (décision propriétaire sur `lot.js` vs étape manuelle) |
| FirstRun 3,4,5,8 | Se résorbent après la correction ci-dessus ; revérifier, puis éventuellement mettre à jour les valeurs en dur |
| Pilot 3,4 | Mettre à jour le test (autorisation du livreur dans `openPilot()`) |
| Pilot 5–8 | Cascades : revérifier après correction de 3,4 |
| Allowlist 6 | Mettre à jour le test |
| dispatchRetry 9 | Corriger les données de test (semer la config) |

## 9. Limites de l'investigation

- Intention de conception sur le livreur du premier essai non déterminée.
- Les corrections ont été validées uniquement sur des copies scratch ; aucun fichier du dépôt n'a été modifié.
- Environnement : Node 22.23.4 isolé, émulateurs `demo-*` locaux uniquement ; aucun test device ; aucune vérification sur preprod/production.
- Les cascades (FirstRun 3,4,5,8 ; Pilot 5–8) sont démontrées par la résolution conjointe, pas par une analyse ligne à ligne de chacune.
- Pilot 8 : confiance moyenne-élevée.

## 10. Contrôle final

- HEAD `d65c8f00bdcedba570a66a5633913db46127be3d`, branche `finalisation/az-express`, index vide, 0 stash.
- 11 fichiers suivis modifiés : empreintes identiques à la base L0-B.
- Fichiers non suivis : 105 d'origine + rapport L0-B + le présent rapport.
- Aucun commit, push, déploiement ; aucun accès à `az-express-b0469` ; émulateurs préexistants (5001, 8080, 9099, 9199, 4000) non touchés ; aucune dépendance installée.
