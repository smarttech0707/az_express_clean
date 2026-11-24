# SEC-01 — S5.3.1 : projection initiale à la création d'un livreur

**Statut : implémenté et testé localement. Aucun Firebase réel, aucun déploiement.** Résout la réserve identifiée en S5.3 (`docs/SEC01_S5_3_SYNC_ROBUSTNESS_AUDIT.md`, §1 point 1).

## 1. Résumé exécutif

Un nouveau déclencheur `onDocumentCreated('livreurs/{driverId}')` alimente désormais immédiatement `driver_public/{driverId}` à la création d'un livreur, au lieu d'attendre qu'un des 7 champs change pour la première fois. L'implémentation est une **délégation d'une seule ligne** vers `syncDriverPublicOnUpdate` (déjà testée en S5.2/S5.3), appelée avec `before: {}` — **aucune nouvelle logique de calcul n'a été introduite** : le module pur `computeDriverPublicPatch` traite nativement une création comme « tout champ présent et valide est nouveau », ce qui est exactement le comportement voulu.

## 2. État Git initial et final

**Initial** : état de fin de S5.3 (`driverPublicSync.js`/`index.js` avec les triggers update+delete, `functions/test/driverPublicSync.test.js` à 30... à 19 tests avant cette phase, rapport S5.3 livré). **Final** : `functions/driverPublicSync.js` et `functions/index.js` complétés, `functions/test/driverPublicSync.test.js` porté à 30 tests, `docs/SEC01_S5_3_1_CREATE_PROJECTION.md` créé — seul nouveau fichier. Aucun autre rapport existant modifié. `firestore.rules`, `.firebaserc`, `firebase.json` : inchangés.

## 3. Fichiers inspectés

`functions/driverPublicSync.js`, `functions/index.js` (les 3 triggers `livreurs` désormais actifs — création/mise à jour/suppression — plus les 2 triggers préexistants sans rapport, `notifyDriverLowBalance` et `notifyAdminsOnNewDriver`), `functions/test/driverPublicSync.test.js`, et re-confirmation des formes exactes de document créées par `lib/screens/admin/driver_requests_page.dart` et `functions/fleetDriverCreation.js` (déjà établies en détail lors des phases S5/S5.2).

## 4. Fichiers créés et modifiés

**Créé** : `docs/SEC01_S5_3_1_CREATE_PROJECTION.md` (ce rapport) — seul fichier nouveau.
**Modifiés** :
- `functions/driverPublicSync.js` : ajout de `syncDriverPublicOnCreate({db, admin, driverId, after})`, exportée — délègue intégralement à `syncDriverPublicOnUpdate`.
- `functions/index.js` : import de `syncDriverPublicOnCreate` ajouté à la déstructuration existante ; nouvel export `exports.syncDriverPublicOnLivreurCreate`. `onDocumentCreated` était **déjà importé** depuis `firebase-functions/v2/firestore` avant cette session (confirmé par relecture de la ligne d'import, utilisée par de nombreux triggers de notification préexistants) — aucun nouvel import de package requis.
- `functions/test/driverPublicSync.test.js` : import complété, test 19 étendu (3 exports au lieu de 2), test 20 réécrit (confirme désormais que la réserve est levée, au lieu de documenter son absence), 11 nouveaux tests (21 à 31) couvrant les 14 points de la Phase 3.

## 5. Architecture du trigger

`onDocumentCreated({ document: 'livreurs/{driverId}', maxInstances: 1, cpu: 0.5, concurrency: 1, memory: '256MiB', retry: true })` — mêmes conventions exactes que le trigger de mise à jour (S5.2), mêmes valeurs. Le corps appelle `syncDriverPublicOnCreate({db, admin, driverId, after: event.data.data()})`, qui n'est qu'un renvoi vers `syncDriverPublicOnUpdate({..., before: {}, after})` — zéro logique dupliquée.

## 6. Whitelist

Inchangée — les mêmes 7 champs, appliqués par le même `computeDriverPublicPatch` déjà en production pour les mises à jour. Aucun nouveau code de validation.

## 7. Protection des champs GPS

Structurellement impossible à violer, pour la même raison qu'en S5.2 (`DRIVER_PUBLIC_FIELDS` ne contient aucun champ GPS). Vérifié spécifiquement pour la création par les tests 25 (aucune coordonnée écrite même présente dans le document source) et 26 (une projection GPS déjà présente dans `driver_public` — cas théorique d'un document créé après coup sur un uid déjà connu de S4 — n'est jamais écrasée par la création, le `.set(merge:true)` préservant les champs GPS existants).

## 8. Analyse de concurrence

**Aucun chevauchement possible entre création et mise à jour** : par construction de l'API Firestore elle-même, une écriture sur un document donné déclenche *soit* `onDocumentCreated` (document inexistant avant), *soit* `onDocumentUpdated` (document existant avant) — jamais les deux pour le même événement. Confirmé également au niveau du code (test 31) : aucune des deux fonctions n'appelle l'autre en parallèle, pas de risque de double traitement provenant du code lui-même.

Le risque résiduel déjà documenté en S5.3 (absence de garantie d'ordre strict entre déclencheurs Firestore en cas d'écritures concurrentes/rejouées) **n'est ni aggravé ni réintroduit** par cet ajout : la création d'un document ne peut par définition se produire qu'une seule fois dans le cycle de vie d'un `livreurs/{id}`, avant toute mise à jour — il n'y a donc pas de scénario où un événement de création et un événement de mise à jour pourraient s'exécuter en concurrence sur le même document.

## 9. Idempotence

Démontrée par le test 29 : rejouer le même événement de création (comme le ferait une nouvelle tentative de la plateforme après un échec) produit exactement le même état final dans `driver_public` — `computeDriverPublicPatch` étant pur et déterministe, deux appels avec les mêmes arguments produisent toujours le même correctif.

## 10. Tests exécutés et résultats

`functions/test/driverPublicSync.test.js` est passé de 19 à **30 tests** : test 19 étendu, test 20 réécrit, 11 nouveaux tests (21-31) couvrant les 14 points demandés en Phase 3 (création valide, projection des 7 champs, reproduction exacte des deux formes de document réelles — `driver_requests_page.dart` et `fleetDriverCreation.js` —, whitelist stricte, absence de champs sensibles, absence d'écriture GPS, préservation d'une projection GPS déjà présente, champs source absents, champs invalides, idempotence, échec Firestore, absence de chevauchement avec le trigger de mise à jour, export/enregistrement).

**Résultat local** : `node --test functions/test/driverPublicSync.test.js` → **30/30 passés** (deux erreurs d'énoncé de test détectées et corrigées en cours de route — `name` omis par erreur dans deux objets attendus — pas un défaut de code).

**Suite complète** : `npm test` dans `functions/` → **3001 tests, 2820 passés, 0 échec, 181 ignorés** (exactement +11/+11 par rapport à la fin de S5.3 — 2990/2809 —, confirmant l'absence de régression ailleurs dans le dépôt).

`node -c functions/index.js`, `node -c functions/driverPublicSync.js`, `node -e "require('./index.js')"` : chargement confirmé sans erreur.

## 11. Risques résiduels

Les deux constats déjà documentés en S5.3 (absence de garantie d'ordre Firestore en cas d'écritures concurrentes, impact déjà qualifié faible/auto-correcteur) demeurent inchangés — ni aggravés, ni résolus par cette phase, qui ne traitait que la réserve de projection initiale. Aucun nouveau risque identifié.

## 12. Confirmation absence de Firebase réel et de déploiement

Confirmée : tous les tests exécutés localement (`node --test`), aucune commande `firebase deploy`, aucun accès réseau à un projet Firebase réel.

## 13. Verdict

**S5.3.1 VALIDÉ.**

La réserve de S5.3 est levée par l'ajout le plus minimal possible : une délégation d'une ligne vers une fonction déjà entièrement testée, sans nouvelle logique de calcul, sans élargissement de la whitelist, sans toucher aux règles, au GPS, ni à aucun workflow métier. 30/30 tests locaux, 3001/3001-181=2820 tests de la suite complète passés, aucune régression.

STOP — fin de mission S5.3.1. Je n'entame ni S5.3.2, ni S5.4, ni S6. J'attends vos instructions.
