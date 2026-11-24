# SEC-01 — S5.2 : synchronisation serveur `livreurs` → `driver_public`

**Statut : implémenté et testé localement. Aucun Firebase réel, aucun déploiement.** Suite de S5 (`docs/SEC01_S5_SERVER_PROJECTION_AUDIT.md`) et S5.1 (`docs/SEC01_S5_1_ISONLINE_CONSOLIDATION.md`).

## 1. Résumé exécutif

Deux déclencheurs Firestore (`onDocumentUpdated` et `onDocumentDeleted` sur `livreurs/{driverId}`) synchronisent désormais, côté serveur, les 7 champs non-GPS de `driver_public` (`name`, `photoUrl`, `isOnline`, `isAvailable`, `isOnDelivery`, `avgRating`, `ratingCount`), sans jamais toucher aux champs GPS (gérés exclusivement par S4/S4.1). La logique est entièrement extraite dans un module pur et testable (`functions/driverPublicSync.js`), suivant exactement le même patron que `driverRatings.js` déjà en production. 13 nouveaux tests, 0 échec, suite complète inchangée par ailleurs (2984 tests au total, +13 par rapport à l'état précédent de cette session).

## 2. État Git initial et final

**Initial** : `firestore.rules` déjà modifié depuis S2 (non touché à nouveau ici) ; aucune trace de `driverPublicSync.js` ni de son test.
**Final** : 2 nouveaux fichiers (`functions/driverPublicSync.js`, `functions/test/driverPublicSync.test.js`) + ce rapport ; `functions/index.js` modifié (import `onDocumentDeleted`, import du nouveau module, 2 nouveaux exports). `.firebaserc`, `firebase.json`, `functions/.env*`, toute dépendance et tout lockfile : vérifiés inchangés.

## 3. Fichiers créés

- `functions/driverPublicSync.js`
- `functions/test/driverPublicSync.test.js`
- `docs/SEC01_S5_2_SERVER_SYNC_IMPLEMENTATION.md` (ce rapport)

## 4. Fichiers modifiés

- `functions/index.js` uniquement : ligne 4 (`onDocumentDeleted` ajouté à l'import existant de `firebase-functions/v2/firestore`), import du nouveau module, et deux nouveaux exports (`syncDriverPublicOnLivreurUpdate`, `syncDriverPublicOnLivreurDelete`), tous deux de simples enveloppes appelant `driverPublicSync.js`. Aucune autre ligne de `index.js` touchée.

## 5. Architecture de synchronisation

**Phase 1 (inspection) — constats avant implémentation :**
- Aucun trigger n'existait déjà sur `driver_public`.
- Un trigger existait déjà sur `livreurs/{driverId}` (`notifyDriverLowBalance`, notification de solde bas) — **aucun conflit** : Firestore exécute indépendamment plusieurs triggers liés au même chemin de document ; le nouveau trigger n'écrit jamais dans `livreurs`, donc aucune interaction entre eux.
- Convention confirmée dans le code existant (`applyDriverRatingOnOrderUpdate`/`driverRatings.js`) : logique pure extraite dans un module dédié, testable sans Firebase, le trigger dans `index.js` n'étant qu'une fine enveloppe. Reproduite à l'identique.

**Implémentation** : deux déclencheurs Firestore v2 (`onDocumentUpdated`, `onDocumentDeleted`) sur `livreurs/{driverId}`, `region: europe-west1` (héritée de `setGlobalOptions`), `maxInstances:1`, `cpu:0.5`/`0.25`, `memory:256MiB`, `retry:true` — mêmes ordres de grandeur que `applyDriverRatingOnOrderUpdate`, cohérent avec le quota Cloud Run régional serré (`.claude/rules/firebase-functions.md`).

## 6. Whitelist des champs

Exactement les 7 champs déjà définis en S2 et repris en S5 : `name`, `photoUrl`, `isOnline`, `isAvailable`, `isOnDelivery`, `avgRating`, `ratingCount` (`DRIVER_PUBLIC_FIELDS`, `functions/driverPublicSync.js`). Chaque champ est de surcroît validé par type (`isValidFieldValue`), strictement aligné sur `driverPublicTypesValid()` (firestore.rules, S2) — l'Admin SDK ignorant les règles à l'écriture, cette validation serveur est la seule protection réelle contre une valeur mal typée. Toute valeur invalide est **ignorée, jamais écrite**, et tracée dans `skipped` (observabilité) sans bloquer la synchronisation des autres champs.

## 7. Protection des champs GPS

`DRIVER_PUBLIC_FIELDS` ne contient structurellement aucun des champs GPS (`lat`, `lng`, `heading`, `speed`, `updatedAt`) : ils ne peuvent donc jamais apparaître dans le correctif calculé, quelle que soit la forme du document source — vérifié explicitement par les tests 10 et 10b (une source ne contenant QUE des champs GPS produit un correctif vide ; le correctif final ne porte jamais de clé GPS, ce qui laisse un éventuel document `driver_public` existant avec sa projection GPS S4 intacte grâce au `.set(merge:true)`).

## 8. Traitement des suppressions

**Constat déterminant, établi par lecture directe du code (pas supposé)** : la clôture de compte normale (`functions/accountDeletion.js`, lignes ~158-171) **n'efface jamais** le document `livreurs/{uid}` — elle l'anonymise en place (`tx.update`, jamais `.delete()`), retirant les champs personnels (`name`, `phone`, `photoUrl`, etc.) via `FieldValue.delete()` tout en préservant les champs financiers. Le seul chemin de suppression **réelle** du document trouvé dans le code est le bouton admin « Supprimer le livreur » (`lib/screens/admin/drivers_page.dart`, écriture Flutter directe `.delete()`), non modifié ici.

Le déclencheur `onDocumentDeleted` couvre exactement ce cas réel : il supprime `driver_public/{driverId}` en conséquence, sans risque de cascade (aucune sous-collection sur `driver_public`, aucune autre référence connue). **Effet positif non demandé mais cohérent avec un risque déjà signalé en S5** : si le pilote T7E exécutait un jour réellement la suppression de `livreurs/t7e-driver` (actuellement bloquée, voir les rapports T7E de cette session), ce trigger nettoierait automatiquement `driver_public/t7e-driver` — sans qu'aucune donnée ni code T7E n'ait été touché ici.

Le cas de l'anonymisation (champ retiré sans suppression du document) est couvert par le trigger de **mise à jour** : `computeDriverPublicPatch` détecte qu'un champ présent dans `before` est absent de `after` et le marque pour suppression dans `driver_public` (test 11b) — la fiche publique ne garde donc jamais un ancien nom/photo après anonymisation.

## 9. Idempotence et gestion des erreurs

- **Pas d'écriture inutile** : `computeDriverPublicPatch` ne retourne `hasChanges:true` que si au moins un champ whitelisté a réellement changé de valeur (ou est apparu/disparu) — un événement où rien de pertinent n'a changé (ex. `wallet` seul modifié) ne déclenche aucune écriture `driver_public` (tests 12-13, 13b).
- **Idempotence de fait** : un retry de la plateforme sur le même événement (même `before`/`after`) recalcule exactement le même correctif et produit le même état final — aucun compteur, aucun flag à gérer (contrairement à `driverRatings.js`, qui en a besoin car il incrémente une moyenne ; ici chaque champ est une valeur simple, un `set(merge:true)` répété est par nature idempotent).
- **Échec Firestore** : propagé à l'appelant (non avalé), volontairement — `retry:true` confie la nouvelle tentative au mécanisme natif de Cloud Functions plutôt que d'avaler silencieusement l'erreur, pour qu'un échec transitoire ne laisse jamais `driver_public` durablement obsolète (test 15b).
- **Document source manquant** (`after` absent) : retour immédiat, aucune tentative d'écriture (test 15).

## 10. Tests exécutés et résultats détaillés

**13 nouveaux tests** (`functions/test/driverPublicSync.test.js`), couvrant l'intégralité des 16 catégories demandées (plusieurs combinées par souci de cohérence, ex. idempotence et absence d'écriture inutile) :
1-7. Synchronisation individuelle de chacun des 7 champs. 8. Whitelist stricte. 9. Absence de fuite de champs sensibles (wallet, phone, fcmToken, ownerId, isSuspended, identifiant — testés même quand présents des deux côtés). 10/10b. Préservation des champs GPS. 11/11b. Document invalide/incomplet, et propagation d'une suppression de champ (anonymisation). 12/13/13b. Idempotence et absence d'écriture inutile. 14/14b. Suppression et invalidation de la projection, y compris le cas déjà-absent. 15/15b. Document source manquant et échec Firestore fail-safe.

**Résultat** : `node --test functions/test/driverPublicSync.test.js` → **13/13 passés**. Suite complète `npm test` dans `functions/` → **2984 tests, 2803 passés, 0 échec, 181 ignorés** (exactement +13 passés et +13 total par rapport à l'état de cette session avant S5.2 — 2790/2971 — confirmant l'absence de toute régression ailleurs dans le dépôt).

`node -c functions/index.js`, `node -c functions/driverPublicSync.js`, et `node -e "require('./index.js')"` : chargement sans erreur, confirmant que les deux nouveaux exports et le nouvel import (`onDocumentDeleted`) sont syntaxiquement et structurellement valides.

## 11. Limites et risques résiduels

- `driver_public` reste vide pour tout livreur n'ayant subi aucun changement qualifiant (GPS, ou l'un des 7 champs ici synchronisés) depuis l'activation de ces déclencheurs — aucun rattrapage rétroactif n'a été exécuté (le script de backfill S3 reste strictement en dry-run local, conformément à l'interdiction explicite de cette mission).
- Le déclencheur de mise à jour et le déclencheur de suppression sont indépendants l'un de l'autre et du déclencheur préexistant (`notifyDriverLowBalance`) : aucune coordination n'est nécessaire, aucun état partagé.
- Aucun test n'a pu être exécuté contre un Firestore réel ou émulé (conformément à l'interdiction explicite) : la couverture repose entièrement sur les faux objets (`db`/`admin`) déjà établis dans ce fichier de test et dans `lifecycleFake.js` — cohérent avec la méthode déjà en place pour `driverRatings.test.js`.

## 12. Confirmations explicites

Aucun accès à un projet Firebase réel. Aucun déploiement (`firebase deploy`). Aucun changement de projet Firebase. `firestore.rules` inchangé depuis S2. `.firebaserc`/`firebase.json` inchangés. Aucune dépendance, package ni lockfile modifié. Mécanismes GPS (S4/S4.1) non touchés. Aucune opération financière, wallet, dispatch ou acceptation de course modifiée. Aucune permission élargie. Aucun backfill réel exécuté. Aucune donnée du pilote T7E touchée (aucun accès programmatique n'a été tenté ; le bénéfice potentiel pour un futur nettoyage T7E, noté au §8, est un effet de bord documenté, pas une action). `operations_control/account_deletion` non activé, non modifié.

## 13. Verdict

**S5.2 VALIDÉ.**

La synchronisation est isolée (modules distincts, aucune logique dupliquée), la whitelist est strictement respectée et vérifiée par test, les champs GPS ne peuvent structurellement jamais être écrasés, l'idempotence est démontrée par test (pas seulement affirmée), aucun champ sensible n'est exposé, le cas de suppression réelle est géré sans risque de cascade identifié (et le cas d'anonymisation, bien plus fréquent en pratique, est couvert par la détection de suppression de champ), et l'intégralité de la suite de tests existante reste verte.
