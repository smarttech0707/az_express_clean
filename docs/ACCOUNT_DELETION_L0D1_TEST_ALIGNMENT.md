# ACCOUNT_DELETION — L0-D.1 : alignement des 5 tests purs

Date : 2026-11-10. Branche `finalisation/az-express`, HEAD `d65c8f0`. Node 22.23.4 isolé.

## 1. Fichiers modifiés (3, tous dans `functions/test/`)

| Fichier | Modification |
|---|---|
| `restaurantV2FirstRun.test.js` | Test « catalogue : actions de partnerOrderActionCF… » : la fixture fournit `AZ_PILOT_DRIVER_IDS=t7e-driver` (restaurée en `finally`) et vérifie que S0 transmet `pilotDriverIds`. Nouveau test : S0 sans liste lève `PILOT_DRIVER_IDS_REQUIRED`. |
| `restaurantV2Pilot.test.js` | Constante `DRIVERS = ['t7e-driver']` ; `pilotConfigPlan({ driverIds: DRIVERS, env: {} })` dans les 2 tests existants (config du pilote, porte de création). Nouveau test : livreur listé accepté, non listé / vide / `undefined` / `null` refusé (`DRIVER_NOT_IN_PILOT`), liste absente ou vide = refus, plan sans liste (undefined, `[]`, `['']`, `['a/b']`) bloqué. |
| `restaurantV2Reopen.test.js` | Fixture `closedConfig` avec `pilotDriverIds` ; helper `withDrivers` (variable d'environnement restaurée) pour « réouverture… » et « REOPEN : DRY-RUN… » ; assertions sur `pilotDriverIds` renvoyé. Nouveau test : réouverture sans liste bloquée avant tout appel, configuration inchangée. |

Rien d'autre n'a été modifié par cette mission : ni `lot.js`, ni les quatre tests émulateur de L0-D, ni le code serveur, ni les règles, ni les dépendances. Aucune validation n'a été supprimée ni rendue facultative ; aucun identifiant n'est introduit dans le code métier (seulement dans les fixtures).

## 2. Les cinq tests corrigés

| # (L0-D) | Fichier | Test |
|---|---|---|
| 2202 | restaurantV2FirstRun.test.js | catalogue : actions de partnerOrderActionCF reconnues par la fonction réelle |
| 2245 | restaurantV2Pilot.test.js | configuration du pilote : acceptée par la validation réelle… |
| 2246 | restaurantV2Pilot.test.js | porte de création : fermée sans configuration… |
| 2266 | restaurantV2Reopen.test.js | réouverture depuis une configuration fermée en version 2… |
| 2275 | restaurantV2Reopen.test.js | REOPEN : DRY-RUN sans réseau, production refusée… |

Cause (démontrée en L0-D) : ces tests appelaient `pilotConfigPlan()` sans liste de livreurs, désormais exigée. Ils fournissent maintenant une liste explicite.

## 3. Résultats exacts (sans émulateur, `FIRESTORE_EMULATOR_HOST` et `AZ_PILOT_DRIVER_IDS` non définis)

- Les trois fichiers : **55 tests, 55 pass, 0 fail** (52 avant, + 3 nouveaux tests de refus).
- Les 5 tests ci-dessus : pass.
- Suite pure complète (`node --test 'test/*.test.js'`) : **2418 tests, 2246 pass, 0 fail, 172 skipped, 0 cancelled.**

| Mesure | L0-B (base) | L0-D (avant D.1) | L0-D.1 |
|---|---|---|---|
| Tests | 2410 | 2415 | 2418 |
| Pass | 2241 | 2238 | 2246 |
| Fail | 0 | 5 | **0** |
| Skipped | 169 | 172 | 172 |

Écarts expliqués : +3 skipped depuis L0-B = 3 tests émulateur ajoutés en L0-D (allowlist 16, dispatchRetry ×2) ignorés sans émulateur ; +8 tests au total depuis L0-B = 5 ajoutés en L0-D (2 pures FirstRun L1/L2 + 3 émulateur) + 3 en D.1. Les tests émulateur de L0-D (FirstRun 10/10, Pilot 8/8, Allowlist 7/7, dispatchRetry 13/13) n'ont pas été relancés dans cette mission (aucun fichier concerné n'a changé depuis).

## 4. Régressions

Aucune : 0 échec, aucun test supprimé, aucun contrôle assoupli. Les tests de refus (liste absente, vide, invalide, livreur non listé) sont conservés et renforcés. Je n'ai pas relancé les 12 autres suites émulateur de L0-B.

## 5. Limites restantes

- Les tests de refus d'un livreur non autorisé côté dispatch/acceptation restent des tests émulateur (`dispatchRetry`, L0-D) et `pilotDriverRestriction.test.js` (pur, passe) ; D.1 ajoute seulement le contrôle pur `driverRefusal` sur la config du lot.
- `runStep.js` ne vérifie pas que les `pilotDriverIds` appartiennent au lot (hors périmètre, non traité).
- Aucun test sur appareil, preprod ou production.

## 6. Contrôle de préservation

- HEAD `d65c8f0`, branche `finalisation/az-express`, index vide, 0 stash.
- Cinq fichiers sensibles inchangés (`git hash-object` : ekbineOrders `21a9cc9a`, index `9f00f1c1`, professionalSubscriptions `976c2396`, adminPartnerAccounts `1a5cde55`, passwordReset `26975f60`).
- Non suivis : 107 + ce rapport = 108.
- Fichiers suivis modifiés par les missions L0-D / L0-D.1 : `lot.js`, `RESTAURANT_V2_FIRST_RUN_PLAN.md`, 4 tests émulateur, 3 tests purs. Les autres fichiers suivis modifiés (dont `.firebase/hosting…`, `passwordReset.test.js`, `restaurantV2Preprod.test.js`, pages légales) n'ont pas été touchés.
- Aucun commit, push, déploiement ; aucun accès à `az-express-b0469`.
