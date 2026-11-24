# SEC-01 — S5.3.5 : Security & CI Reservations Resolution

## 1. Les 3 réserves initiales (rapport S5.3.4)

- **R1** — Les Rules Firestore permettaient au livreur propriétaire d'écrire directement
  `name`, `photoUrl` et `isOnline` dans `driver_public`, alors que ces 3 champs sont déjà
  synchronisés depuis `livreurs` par le mécanisme serveur (S5.2/S5.3.3).
- **R2** — `rules-tests/driver-public.rules.test.js` (17 tests) n'était inclus ni dans
  `package.json::test:rules` ni, par conséquent, dans le job CI `firestore-rules` —
  les tests existaient et passaient, mais ne s'exécutaient jamais automatiquement.
- **R3** — Un commentaire de `firestore.rules` (lignes 453-458 avant cette phase)
  affirmait « rien ne la lit ni ne l'écrit encore », obsolète depuis S4 (GPS) et
  S5.2/S5.3.3 (champs non-GPS).

## 2. Analyse et décisions

### R1 — Analyse (Phase 3.1)

Inspection effectuée avant toute modification :

- **Bloc Rules `driver_public`** (`firestore.rules`, alors lignes 459-486) : la branche
  `create` excluait déjà `avgRating`/`ratingCount`/`isAvailable`/`isOnDelivery` de
  l'écriture propriétaire, mais acceptait `name`/`photoUrl`/`isOnline` sans restriction ;
  la branche `update` protégeait les 4 mêmes champs serveur via `unchanged()`, mais pas
  ces 3 champs.
- **Écritures Flutter réelles** : `lib/services/driver_public_projection.dart`
  (`buildDriverPublicGpsProjection`) ne construit et n'écrit **que** `lat`, `lng`,
  `heading`, `speed`, `updatedAt` — confirmé par lecture du code et par son propre
  commentaire (« `name`/`photoUrl` : … volontairement absents de cette phase »,
  « `isOnline` : hors périmètre explicite de la mission S4 »). Aucun autre fichier
  Flutter n'écrit dans `driver_public` (`grep -rn "driver_public" lib` : seuls
  `driver_location_service.dart` et `driver_public_projection.dart` apparaissent, tous
  deux liés exclusivement au flux GPS).
- **Écritures Functions (S5)** : `functions/driverPublicSync.js` synchronise les 7 champs
  non-GPS (dont `name`/`photoUrl`/`isOnline`) depuis `livreurs`, via Admin SDK — hors
  règles, donc non affecté par une restriction des Rules.
- **Tests Rules existants** : `rules-tests/driver-public.rules.test.js` contenait deux
  assertions `assertSucceeds` exerçant précisément cette écriture propriétaire directe
  (`update({ isOnline: false })`, `update({ photoUrl: ... })`) — c'était la preuve
  factuelle citée dans le rapport S5.3.4.
- **Dépendance S4/S5** vérifiée : aucune des deux (projection GPS cliente, synchronisation
  serveur non-GPS) ne dépend de la capacité du livreur à écrire `name`/`photoUrl`/
  `isOnline` directement dans `driver_public`. La fonction GPS cliente utilise un
  `.set(..., {merge:true})` qui n'envoie jamais ces 3 champs ; les retirer de ce que le
  livreur peut écrire ne change donc rien à son comportement actuel.

**Conclusion** : l'écriture propriétaire directe de ces 3 champs n'est exercée par aucun
code applicatif existant — elle n'était qu'une fenêtre de permission ouverte mais inutilisée.

### R1 — Décision (Phase 3.2)

Retenu : supprimer uniquement ces 3 permissions directes, sans toucher au mécanisme GPS
(S4) ni à la synchronisation serveur (S5.2/S5.3.3), ni aux règles du document `livreurs`
lui-même.

- `allow create` : ajout de `!('name' in request.resource.data)`,
  `!('photoUrl' in request.resource.data)`, `!('isOnline' in request.resource.data)`
  — même pattern que les 4 champs serveur déjà exclus.
- `allow update` : ajout de `unchanged('name') && unchanged('photoUrl') &&
  unchanged('isOnline')` — même pattern que les 4 champs serveur déjà protégés.
- Résultat : le livreur ne peut plus écrire, créer ou modifier que les 5 champs GPS
  (`lat`, `lng`, `heading`, `speed`, `updatedAt`) dans `driver_public`. Tous les autres
  champs (7 non-GPS) sont désormais exclusivement posés par
  `functions/driverPublicSync.js`.
- Aucun problème architectural non résolu rencontré : pas de STOP nécessaire sur ce point.

### R1 — Tests (Phase 3.3)

`rules-tests/driver-public.rules.test.js` modifié (voir §4) :

- Introduction d'un `gpsDoc()` (5 champs GPS seulement) à côté du `publicDoc()` existant
  (conservé pour le seed hors-règles et les tests de champs interdits/types), reflétant
  ce que le livreur peut réellement écrire depuis cette phase.
- Les deux tests de succès propriétaire (création/mise à jour) basculés sur `gpsDoc()`.
- **2 tests ajoutés** (nouveaux, pas de remplacement) :
  - `création : name, photoUrl, isOnline refusés même seuls (désormais réservés au serveur)`
  - `mise à jour : le livreur ne peut plus changer name/photoUrl/isOnline directement`
- Le test `modification conforme du document propriétaire autorisée`, qui prouvait
  auparavant l'inverse (`assertSucceeds` sur `isOnline`/`photoUrl`), a été renommé
  `modification GPS conforme du document propriétaire autorisée` et ne couvre plus que
  l'écriture GPS — la preuve qu'il apportait avant (succès sur ces 2 champs) est
  désormais contredite intentionnellement par les 2 nouveaux tests ci-dessus.
- Tests déjà existants couvrant les 4 champs serveur (`avgRating`/`ratingCount`/
  `isAvailable`/`isOnDelivery`), les champs privés (`wallet`/`phone`/…), la lecture, la
  suppression, et les permissions admin/sous-admin/autre-livreur/anonyme : **conservés
  sans suppression**, seule leur base document (`publicDoc()` → `gpsDoc()`) a été ajustée
  là où la présence de `name`/`photoUrl`/`isOnline` dans le document de base aurait
  changé la raison de l'échec/succès attendu (`updatedAt`, `types incorrects`, champs
  privés à la création).
- Aucune suppression de test pour faire passer la suite : tous les tests pré-existants
  restent présents ; 2 ont été reformulés pour tester exactement ce qu'ils prétendent
  tester sous les nouvelles règles, 2 ont été ajoutés.

### R2 — Intégration CI (section 4)

Inspection :

- `rules-tests/driver-public.rules.test.js` : fichier `node:test` autonome, même
  structure que les 24 autres fichiers déjà listés dans `test:rules`.
- `package.json::scripts.test:rules` : une seule commande
  `firebase emulators:exec --only firestore "node --test <24 fichiers listés>"`.
- `.github/workflows/ci.yml`, job `firestore-rules` (ligne 39-54) : `npm ci`,
  `npm install -g firebase-tools`, puis `npm run test:rules` — aucun credential, aucun
  accès externe, Java déjà préinstallé sur les runners `ubuntu-latest` pour l'émulateur.

**Modification retenue (minimale)** : ajout de
`rules-tests/driver-public.rules.test.js` à la liste de fichiers déjà passée à
`node --test` dans `package.json::scripts.test:rules`. Aucune autre modification :
même émulateur, même commande, même job CI, aucune nouvelle dépendance, aucune
deuxième architecture de test.

**Validation** :

1. Les 19 tests du fichier s'exécutent via la routine intégrée — confirmé (voir §6).
2. Ils restent exécutables individuellement (`node --test rules-tests/driver-public.rules.test.js`
   sous l'émulateur) — confirmé, utilisé pendant le développement de R1.
3. Aucune donnée Firebase réelle : exécution exclusivement contre l'émulateur local
   démarré par `firebase emulators:exec`, comme les 24 autres fichiers.
4. Le job CI utilise bien l'émulateur Rules (`.github/workflows/ci.yml` inchangé,
   toujours `npm run test:rules`).
5. Les 24 autres fichiers Rules restent inchangés dans leur comportement — confirmé par
   la routine intégrée complète (§6 : 490/490, dont les 466 tests déjà existants dans
   les 24 fichiers).
6. Aucun lockfile ni dépendance modifié (`package-lock.json` non touché par cette phase ;
   seul `package.json::scripts.test:rules` a changé, une chaîne de caractères).

### R3 — Commentaire obsolète (section 5)

Commentaire identifié : `firestore.rules`, juste avant `match /driver_public/{driverId}`
(« rien ne la lit ni ne l'écrit encore (aucun écran, aucune Cloud Function) tant que les
étapes suivantes du plan ne sont pas exécutées »).

Corrigé pour refléter l'état réel : la collection est déjà écrite par la projection GPS
cliente (S4) et par la synchronisation serveur non-GPS (S5.2/S5.3.3) ; seules les
**lectures applicatives** restent non migrées (S6, non commencé). Aucune Rule modifiée
à cette occasion — uniquement le texte du commentaire.

## 3. Fichiers réellement modifiés par cette phase

| Fichier | Nature de la modification |
|---|---|
| `firestore.rules` | R1 (restriction create/update de `driver_public`) + R3 (commentaire) + mise à jour du commentaire de `driverPublicKeysValid()` pour retirer la référence à une fonction `driverPublicOwnFieldsOnly()` inexistante (trouvée en cours d'inspection R1, directement liée au bloc modifié — corrigée pour éviter de documenter un mécanisme qui n'existe pas) |
| `package.json` | R2 (ajout d'un fichier à la liste `test:rules`) |
| `rules-tests/driver-public.rules.test.js` | R1 (tests adaptés/ajoutés à la nouvelle restriction) |
| `docs/SEC01_S5_3_5_SECURITY_CI_RESOLUTION.md` | Nouveau document (ce rapport) |

Fichiers **non modifiés** par cette phase (vérifié par statut Git ciblé, voir §8) :
`functions/driverPublicSync.js`, `functions/test/driverPublicSync.test.js`,
`functions/index.js`, `.github/workflows/ci.yml`, `docs/SEC01_S5_3_4_FINAL_CONSISTENCY_AUDIT.md`.

## 4. Tests exécutés et résultats

- `firebase emulators:exec --only firestore "node --test rules-tests/driver-public.rules.test.js"`
  (fichier seul, émulateur local) : **19/19 passés** (17 pré-existants + 2 ajoutés pour R1).
- `npm run test:rules` (routine intégrée complète, 25 fichiers dont le nouveau) :
  **490/490 passés**, 0 échec — confirme à la fois R1 (nouveaux tests dans la routine
  réelle) et R2 (intégration effective, aucune régression sur les 24 autres fichiers).
- `node --test test/driverPublicSync.test.js` (dans `functions/`) : **32/32 passés**,
  inchangé par rapport à S5.3.3/S5.3.4 — confirme que la synchronisation serveur
  non-GPS n'a pas été affectée par les changements de Rules (elle utilise l'Admin SDK,
  hors règles).

## 5. Risques résiduels

- Les Rules protègent désormais `driver_public` contre une écriture propriétaire directe
  des 7 champs non-GPS, mais `livreurs` lui-même reste ouvert à l'écriture directe de
  `name`/`photoUrl`/`isOnline` par son propriétaire (règle inchangée, hors périmètre de
  cette phase) — une incohérence relevée en S5.3.4 (le propriétaire pouvait déjà changer
  ces champs sur la source) qui, elle, demeure : ce n'est pas un nouveau risque introduit
  ici, seulement un risque pré-existant non traité par cette phase (hors des 3 réserves
  demandées).
- Le délai entre une écriture GPS propriétaire valide et la prochaine synchronisation
  serveur (si jamais `livreurs` change un champ non-GPS) reste celui déjà documenté en
  S5.3.3/S5.3.4 ; cette phase ne modifie pas le mécanisme de reconciliation.
- Aucun risque résiduel nouveau identifié sur R2/R3 : modifications strictement
  documentaires (R3) ou d'intégration de test déjà écrit et déjà validé (R2).

## 6. Modifications préexistantes préservées

Confirmé par `git status --porcelain` ciblé avant et après cette phase :

- `firestore.rules` et `functions/index.js` portaient déjà la marque « M » avant cette
  phase (S5.3.3 et antérieur) ; cette phase ajoute ses propres lignes à `firestore.rules`
  (le diff cumulé reflète l'historique complet depuis S2, pas seulement S5.3.5) et ne
  touche pas du tout `functions/index.js`.
- `functions/driverPublicSync.js`, `functions/test/driverPublicSync.test.js` et
  `docs/SEC01_S5_3_4_FINAL_CONSISTENCY_AUDIT.md` restaient non suivis (`??`) avant cette
  phase et le sont restés, inchangés par cette phase.
- `rules-tests/driver-public.rules.test.js` restait non suivi (`??`) avant cette phase ;
  il l'est resté après (son contenu a changé, pas son statut de suivi Git).
- Aucune opération destructive (`git reset`, `git clean`, `git checkout --`, stash) n'a
  été utilisée à aucun moment.

## 7. Confirmations explicites

- Aucun déploiement effectué.
- Aucun accès à Firebase réel (production ou préprod) — seul l'émulateur Firestore local
  (`firebase emulators:exec`), comme dans toutes les phases SEC-01 précédentes.
- Aucune donnée de production touchée.
- Aucune intervention sur le pilote T7E.
- Aucun changement de dépendance ni de lockfile (`package-lock.json`,
  `functions/package-lock.json` non touchés).
- Aucune migration S6 commencée (aucun nouveau lecteur de `driver_public` introduit).
- Aucun commit, aucun push, aucun changement de branche, de remote, de projet Firebase
  ou de configuration Firebase.

## 8. Verdict

**VALIDÉ** — les trois réserves (R1, R2, R3) sont traitées et vérifiées :

- R1 : permissions d'écriture propriétaire restreintes au GPS, mécanisme source-to-
  projection (S4/S5) intact, 19/19 tests Rules passent (2 nouveaux, 2 reformulés).
- R2 : les 19 tests `driver-public.rules.test.js` s'exécutent désormais dans la routine
  intégrée (`npm run test:rules`, donc dans le job CI `firestore-rules`) — 490/490 passés.
- R3 : commentaire corrigé pour refléter l'état réel (écrit depuis S4/S5, lu nulle part
  encore).

Ce verdict ne constitue pas une autorisation de commencer S6.

**STOP après ce rapport. Pas d'enchaînement automatique sur S6.**
