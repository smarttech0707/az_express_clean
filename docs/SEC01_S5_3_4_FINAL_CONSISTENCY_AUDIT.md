# SEC-01 — S5.3.4 : audit final de cohérence — `driver_public`

**Statut : audit terminé, strictement en lecture. Aucun fichier modifié, aucune Rule modifiée, aucun Firebase réel, aucun déploiement.** Porte sur l'ensemble du système `driver_public` après S2 → S5.3.3, en préparation d'une décision d'ouverture de S6 (non prise ici).

## Objet et périmètre

Vérifier la cohérence architecturale globale de `driver_public` (Rules, Functions, Flutter, tests) avant d'autoriser l'ouverture de S6 (migration des lectures). Ce rapport ne décide pas d'ouvrir S6 ; il fournit les éléments pour que cette décision soit prise séparément.

## Fichiers réellement inspectés

`firestore.rules` (bloc `driver_public` lignes 82-108 et 453-486, intégral), `functions/driverPublicSync.js` (intégral, état post-S5.3.3), `functions/index.js` (les trois triggers `livreurs/{driverId}` relatifs à `driver_public`, plus `notifyDriverLowBalance`/`notifyAdminsOnNewDriver`, confirmés sans rapport), `functions/test/driverPublicSync.test.js` (intégral, 32 tests), `lib/services/driver_public_projection.dart` (intégral), `lib/services/driver_location_service.dart` (`_saveToFirestore`, `goOffline`, import de la projection), `test/services/driver_public_projection_test.dart` et `test/services/driver_location_service_test.dart` (lus, non exécutés — voir §Tests), `rules-tests/driver-public.rules.test.js` (intégral, exécuté), `package.json` (script `test:rules`), `.github/workflows/ci.yml` (job `firestore-rules`), `docs/SEC01_S5_SERVER_PROJECTION_AUDIT.md`, `docs/SEC01_S5_1_ISONLINE_CONSOLIDATION.md`, `docs/SEC01_S5_2_SERVER_SYNC_IMPLEMENTATION.md`, `docs/SEC01_S5_3_SYNC_ROBUSTNESS_AUDIT.md`, `docs/SEC01_S5_3_1_CREATE_PROJECTION.md`, `docs/SEC01_S5_3_2_CONCURRENCY_AUDIT.md`, `docs/SEC01_S5_3_3_CONCURRENCY_FIX.md`, `docs/DRIVER_PUBLIC_MIGRATION_PLAN.md` (consultés pour confronter le code actuel aux décisions documentées, pas supposés à jour).

## Architecture actuelle reconstruite (depuis le code, pas depuis les rapports)

Trois écrivains serveur/client vers `driver_public/{driverId}`, aucun lecteur :

1. **GPS (S4/S4.1)** — `lib/services/driver_public_projection.dart::writeDriverPublicGpsProjection`, appelée depuis `driver_location_service.dart::_saveToFirestore` au même rythme que l'écriture `livreurs` (throttle 5 s/15 m). Écrit `lat`, `lng`, `updatedAt` (toujours), `heading`/`speed` (si finis). N'écrit jamais `isOnline` ni aucun des 7 champs non-GPS. Erreurs isolées (jamais levées).
2. **Non-GPS serveur (S5.2 → S5.3.3)** — `functions/driverPublicSync.js::reconcileDriverPublicFromSource`, déclenchée par `onDocumentCreated`/`onDocumentUpdated` sur `livreurs/{driverId}` (`functions/index.js`). Relit `livreurs` et `driver_public` dans une transaction, projette les 7 champs non-GPS, n'écrit jamais les champs GPS. `onDocumentDeleted` relit `livreurs` avant de supprimer (garde de recréation, S5.3.3).
3. **Client direct (Rules, S2, jamais exercé par le code applicatif actuel)** — le propriétaire (`isOwner(driverId)`) peut, selon les Rules, créer/mettre à jour `driver_public` avec `name`/`photoUrl`/`isOnline` (en plus des champs GPS) directement depuis le SDK client, sans passer par aucune Cloud Function. Aucun écran Flutter n'exerce ce chemin aujourd'hui pour les champs non-GPS (confirmé par recherche exhaustive, voir §Écarts, point 1) ; les tests Rules le confirment pourtant explicitement autorisé (`rules-tests/driver-public.rules.test.js:221-222`).

**Aucun lecteur** : recherche exhaustive (`grep -rn "driver_public" lib`) ne trouve aucune lecture de cette collection dans tout le code Flutter, en dehors des deux fichiers qui l'écrivent. `driver_public` n'est donc consommée par aucun écran à ce jour — S6 n'a pas commencé, conforme à l'attendu.

## Whitelist exacte (reconstruite depuis le code, pas supposée)

| Champ | Nature | Rules (`driverPublicKeysValid`) | Functions (`DRIVER_PUBLIC_FIELDS`/`GPS_PROJECTION_FIELDS`) | Flutter (`driver_public_projection.dart`) |
|---|---|---|---|---|
| `name` | non-GPS | ✓ | ✓ (`DRIVER_PUBLIC_FIELDS`) | — (jamais écrit par ce fichier) |
| `photoUrl` | non-GPS | ✓ | ✓ | — |
| `isOnline` | non-GPS | ✓ | ✓ | — (hors périmètre S4, documenté dans le fichier lui-même) |
| `isAvailable` | non-GPS, protégé | ✓ (client ne peut jamais le changer, `unchanged()`) | ✓ | — |
| `isOnDelivery` | non-GPS, protégé | ✓ (idem) | ✓ | — |
| `avgRating` | non-GPS, protégé | ✓ (idem) | ✓ | — |
| `ratingCount` | non-GPS, protégé | ✓ (idem) | ✓ | — |
| `lat` | GPS | ✓ | ✓ (`GPS_PROJECTION_FIELDS`) | ✓ |
| `lng` | GPS | ✓ | ✓ | ✓ |
| `heading` | GPS | ✓ | ✓ | ✓ (si fini) |
| `speed` | GPS | ✓ | ✓ | ✓ (si fini) |
| `updatedAt` | GPS | ✓ (doit être `request.time`) | ✓ | ✓ (`FieldValue.serverTimestamp()`) |

**12 champs au total, identiques dans les trois couches** : les 7 non-GPS de `DRIVER_PUBLIC_FIELDS` + les 5 GPS de `GPS_PROJECTION_FIELDS` (Functions) correspondent exactement aux 12 clés de `driverPublicKeysValid()` (Rules) — aucun écart. Aucun champ sensible (`wallet`, `phone`, `fcmToken`, `ownerId`, `isSuspended`, `identifiant`, etc.) ne figure dans aucune des trois listes — confirmé par les tests 9, 25, 26 (`functions/test/driverPublicSync.test.js`) et par la structure même de `driverPublicKeysValid()` (`hasOnly()`, pas d'ajout possible côté Rules).

## Analyse GPS (S4/S4.1)

`_saveToFirestore` écrit `livreurs` (écriture principale) puis appelle `unawaited(writeDriverPublicGpsProjection(...))` (projection secondaire, jamais bloquante, jamais levée — `try/catch` avec `debugPrint` seul). Séparation des responsabilités confirmée : `buildDriverPublicGpsProjection` est pure, ignore tout ce qui n'est pas GPS, rejette les coordonnées placeholder `(0,0)` posées à la création (`driver_requests_page.dart`) pour ne jamais publier une position fictive. `updatedAt` utilise `FieldValue.serverTimestamp()`, cohérent avec la contrainte Rules `d.updatedAt == request.time`. Le point d'injection `driverPublicWriter` (S4.1, `@visibleForTesting`) reste en place, toujours initialisé à `defaultDriverPublicWriter` par défaut — aucune régression de comportement de production possible par ce biais. Aucun ancien site GPS mort (`driver_map.dart::_writePosition`, identifié en S4 comme jamais instancié) n'a été réactivé — confirmé par relecture : ce fichier n'apparaît dans aucun import actif, inchangé depuis S4.

## Analyse trigger create/update/delete

`syncDriverPublicOnCreate` et `syncDriverPublicOnUpdate` délèguent, mot pour mot, à `reconcileDriverPublicFromSource` (vérifié par le test 33, par lecture de code, pas par supposition) — un seul chemin de calcul pour les deux événements. `syncDriverPublicOnDelete` relit `livreurs` avant de supprimer et annule la suppression si le document a été recréé (garde de recréation, S5.3.3, testée). Les trois sont correctement exportées et raccordées dans `functions/index.js` sur `livreurs/{driverId}` (confirmé par le test 32, `require('../index.js')`). Gestion de la disparition de la source : `invalidateIfOrphaned` ne recrée jamais de contenu, nettoie au plus les 7 champs non-GPS en préservant toute projection GPS déjà présente — pas de projection fantôme persistante (RISK B de S5.3.2, traité en S5.3.3, retesté ici par simple relecture, pas réimplémenté). Risques de retry/événements tardifs : traités par construction (relecture live, pas de dépendance aux données de l'événement) — voir `docs/SEC01_S5_3_3_CONCURRENCY_FIX.md` pour l'analyse détaillée, non reproduite ici mais revérifiée par relecture complète du fichier : le code correspond fidèlement à ce rapport (pas d'écart constaté).

## Analyse transactionnelle

`db.runTransaction` est utilisé correctement dans les trois fonctions (lecture avant écriture, à l'intérieur de la même transaction). La garantie réelle (cohérence d'instantané + rejeu automatique si un document lu change avant validation) a déjà été caractérisée précisément en S5.3.3 §7, y compris sa limite honnête (ne garantit pas d'ordre entre deux exécutions séparées — c'est la relecture live, pas l'atomicité seule, qui élimine l'obsolescence persistante). Relecture de ce chapitre confirme qu'il reste exact au regard du code actuel : aucun écart.

## Analyse Rules

Bloc `driver_public` (lignes 459-486) : lecture `isAuth()` (tout authentifié, anonymes compris, cohérent avec `livreurs` aujourd'hui) ; création/mise à jour réservées au propriétaire (`isOwner`), conditionnées à l'existence du document `livreurs` correspondant (empêche la fabrication d'une fiche pour un uid qui n'est pas un livreur connu) ; les 4 champs serveur (`avgRating`, `ratingCount`, `isAvailable`, `isOnDelivery`) sont protégés à la création (absence forcée) et à la mise à jour (`unchanged()`) — le client ne peut jamais les falsifier, cohérent avec le fait que l'Admin SDK (Cloud Functions) les écrit hors règles ; suppression réservée à l'admin. **Compatibilité réelle avec S4/S5 confirmée** : les Cloud Functions utilisent l'Admin SDK, qui ignore ces règles — aucune des conditions ci-dessus ne bloque jamais `reconcileDriverPublicFromSource`/`syncDriverPublicOnDelete`.

**Écart constaté (voir aussi §Écarts)** : les Rules autorisent aussi le propriétaire à écrire directement `name`/`photoUrl`/`isOnline` (non protégés par `unchanged()`), un chemin que confirme explicitement `rules-tests/driver-public.rules.test.js:221-222` (`assertSucceeds`). Aucun écran Flutter n'exerce ce chemin aujourd'hui, mais rien dans le code ne l'interdit — voir §Écarts, point 2, pour l'implication.

## Résultats des tests

- **`functions/test/driverPublicSync.test.js`** : exécuté (`node --test`), **32/32 passés**, inchangé depuis S5.3.3.
- **`rules-tests/driver-public.rules.test.js`** : exécuté via `firebase emulators:exec --only firestore` (émulateur Firestore **local**, pas Firebase réel — même protocole que celui déjà utilisé en S2), **17/17 passés**. Confirme notamment que la whitelist, la protection des 4 champs serveur, le contrôle d'existence `livreurs`, et la restriction admin pour la suppression fonctionnent réellement contre l'émulateur, pas seulement en lecture de code.
- **Suite complète Functions** (`npm test` dans `functions/`) : **non ré-exécutée dans cette mission** — déjà confirmée à 3 003/2 822/0/181 en fin de S5.3.3 (quelques minutes avant cet audit), aucun fichier source n'a changé depuis ; relancer l'intégralité n'aurait apporté aucune information nouvelle pour un audit en lecture seule.
- **Tests Flutter** (`test/services/driver_public_projection_test.dart`, `test/services/driver_location_service_test.dart`) : **lus intégralement, non exécutés** — la commande `flutter` n'est pas disponible dans cet environnement d'exécution (`flutter: command not found` / non reconnue). Aucune régression de code n'étant intervenue sur `driver_public_projection.dart` ni `driver_location_service.dart` depuis leur dernière exécution confirmée (S4.1, 64/64 tests, rapport `docs/SEC01_S4_DUAL_WRITE_GPS.md` et sa mise à jour S4.1), ce résultat historique est cité comme dernière preuve disponible, **pas comme une ré-exécution de cette mission** — distinction faite explicitement pour ne jamais prétendre qu'un test a été rejoué s'il ne l'a pas été.

Aucun test n'a été modifié pour faire passer cet audit.

## Risques résiduels

Les risques déjà documentés et non corrigés par choix explicite restent inchangés : fenêtre transitoire inhérente à toute projection asynchrone (S5.3.3 §13), limite de livraison Firestore « au moins une fois » (S5.3 §1), absence de garantie d'ordre absolue entre exécutions séparées (S5.3.2/S5.3.3). Aucun nouveau risque de cette nature n'a été découvert pendant cet audit — la correction S5.3.3 a été revérifiée par relecture, pas remise en cause.

## Écarts éventuels (nouveaux constats de cet audit, non corrigés)

1. **Permission Rules plus large que l'usage actuel du code** : le propriétaire peut écrire directement `name`/`photoUrl`/`isOnline` sur `driver_public` via le SDK client (confirmé par Rules + test 221-222), alors qu'aucun écran Flutter n'exerce ce chemin aujourd'hui pour ces trois champs (seul le chemin GPS, S4, écrit directement depuis le client, et uniquement les champs GPS). Ce n'est pas une élévation de privilège nouvelle : le livreur a déjà, sur son propre document `livreurs`, le droit d'écrire librement ces trois mêmes champs sans aucune garde `unchanged()` (`firestore.rules:416-425`) — la permission sur `driver_public` reflète donc une confiance déjà accordée ailleurs, pas une nouvelle. **Implication concrète pour une future ouverture de S6** : un client (légitime ou compromis) pourrait écrire sur `driver_public` une valeur de `name`/`photoUrl`/`isOnline` qui diverge de `livreurs`, et cette divergence persisterait jusqu'à la prochaine écriture sur `livreurs` (qui déclencherait une reconciliation et rétablirait la valeur réelle) — car aucun déclencheur ne réagit à une écriture sur `driver_public` elle-même. Sans conséquence aujourd'hui (aucun lecteur n'existe), mais pertinent à trancher **avant** que des utilisateurs ne lisent effectivement `driver_public` (S6) : fermer ce chemin (retirer `name`/`photoUrl`/`isOnline` de ce que le propriétaire peut écrire directement, en s'appuyant uniquement sur la synchronisation serveur) est une option à évaluer, pas décidée ici.
2. **Couverture CI/test incomplète pour les Rules `driver_public`** : `rules-tests/driver-public.rules.test.js` (17 tests, créé en S2) n'est inclus ni dans le script `package.json::test:rules`, ni donc dans le job CI `firestore-rules` (`.github/workflows/ci.yml:54`, qui exécute `npm run test:rules`). Les tests existent, sont corrects et passent (vérifié ci-dessus contre l'émulateur), mais ne s'exécutent **automatiquement nulle part** — ni en local via la commande standard, ni en CI. Une régression future sur ce bloc de Rules ne serait détectée que si quelqu'un pense à lancer ce fichier manuellement. Constat factuel, non corrigé (modifier `package.json` ou `.github/workflows/ci.yml` sort du périmètre strictement en lecture de cette mission).
3. **Commentaire obsolète dans `firestore.rules`** (lignes 453-458) : le commentaire du bloc `driver_public` affirme encore « rien ne la lit ni ne l'écrit encore (aucun écran, aucune Cloud Function) tant que les étapes suivantes du plan ne sont pas exécutées » — vrai au moment de S2, **faux aujourd'hui** : S4/S4.1 (GPS) et S5.2→S5.3.3 (serveur) écrivent activement cette collection depuis plusieurs phases. Dérive de documentation mineure, sans impact fonctionnel (le commentaire ne pilote aucun comportement), signalée pour exactitude plutôt que corrigée (modification de `firestore.rules` hors périmètre de cette mission en lecture seule).

Aucun de ces trois constats ne constitue un défaut de sécurité exploitable aujourd'hui (le point 1 reflète une confiance déjà accordée ailleurs ; le point 2 est une lacune de couverture de test, pas une faille active ; le point 3 est purement documentaire).

## Points de cohérence transversale (vérifiés un par un)

1. **Source de vérité = `livreurs`** : confirmé — toute projection dérive de `livreurs`, jamais l'inverse.
2. **`driver_public` ne devient jamais une source de vérité métier** : confirmé structurellement (aucun lecteur n'existe) ; nuancé par l'écart 1 (un client pourrait y écrire une valeur divergente, sans qu'aucun mécanisme actuel la corrige avant la prochaine écriture `livreurs`) — pertinent seulement une fois des lecteurs introduits (S6).
3. **GPS géré par le mécanisme dédié** : confirmé, S4/S4.1 inchangés.
4. **Le trigger non-GPS ne prend pas possession du GPS** : confirmé, `GPS_PROJECTION_FIELDS` jamais dans `DRIVER_PUBLIC_FIELDS`, testé (19, 22, 27).
5. **Les transactions de reconciliation n'effacent pas les champs GPS** : confirmé, `invalidateIfOrphaned` cible exclusivement les 7 champs non-GPS (test 22).
6. **Whitelist cohérente entre Rules, Flutter et Functions** : confirmé exactement, voir tableau ci-dessus — aucun écart.
7. **Le traitement des suppressions ne produit pas de projection fantôme** : confirmé (S5.3.3, retesté ici par relecture, tests 20-24).
8. **Les données sensibles de `livreurs` ne sont jamais exposées** : confirmé (tests 9, 25, 26 ; `hasOnly()` côté Rules).
9. **Les retries ne produisent pas de corruption persistante** : confirmé pour la classe de risque démontrée en S5.3.2 (relecture live élimine l'obsolescence persistante — fenêtre transitoire résiduelle documentée, pas une corruption).
10. **Aucun conflit architectural non documenté** : confirmé pour le code Functions/Flutter ; les écarts 1-3 ci-dessus sont les seuls constats non documentés avant cet audit, et ils sont désormais documentés ici.

## Recommandation pour S6

Ce rapport ne décide pas d'ouvrir S6. Si une décision d'ouverture est prise séparément, les trois écarts ci-dessus méritent d'être tranchés d'abord (en particulier l'écart 1, qui devient pertinent dès qu'un lecteur existe) — sans que cela bloque nécessairement S6 dans l'absolu : S6 pourrait commencer par des lecteurs à faible enjeu (ex. affichage non critique) pendant que l'écart 1 est évalué séparément. Ce compromis n'est qu'une piste, pas une décision.

## Verdict final

**VALIDÉ AVEC RÉSERVES.**

Aucun blocker architectural ou sécuritaire n'empêche d'envisager S6 : la whitelist est strictement cohérente sur les trois couches, le GPS et le non-GPS restent correctement séparés, les suppressions ne produisent pas de fantôme, les événements obsolètes ne corrompent plus durablement la projection. Trois réserves honnêtes sont documentées (permission Rules plus large que l'usage actuel, couverture CI incomplète pour les Rules `driver_public`, commentaire obsolète) — aucune n'est un défaut de sécurité actif, mais la première devient pertinente dès que des lecteurs existeront. Ce verdict ne vaut pas autorisation d'implémenter S6.

## Confirmations explicites

- Aucun code modifié.
- Aucun test modifié.
- Aucune Rule modifiée.
- Aucun Firebase réel utilisé (seul l'émulateur Firestore local a été utilisé pour `rules-tests/driver-public.rules.test.js`, comme en S2).
- Aucun déploiement.
- Aucune migration S6 commencée.
- Aucune production touchée.

STOP après ce rapport. Je n'enchaîne pas automatiquement sur S6 et j'attends vos instructions.
