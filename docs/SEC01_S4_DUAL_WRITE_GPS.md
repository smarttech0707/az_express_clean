# SEC-01 — S4 : double écriture GPS vers `driver_public`

**Statut : implémenté localement, non déployé.** Suite de S2 (règle additive `driver_public`, 471/471 + 17/17) et S3 (mapping/backfill en dry-run local, 26/26). Référence : `docs/DRIVER_PUBLIC_MIGRATION_PLAN.md`.

## 1. Constat préalable qui change le périmètre réel de la mission

La mission partait de l'hypothèse de **deux** sites d'écriture GPS vers `livreurs` (`DriverLocationService._saveToFirestore` et `driver_map.dart::_writePosition`). La lecture du code et des tests existants montre que **`driver_map.dart` n'est jamais instancié dans l'application** :

- Le test existant `test/services/driver_location_service_test.dart` (groupe « Écran de navigation et écritures », test « seul le service ouvre un flux GPS parmi les écrans actifs ») le documente déjà explicitement : *« DriverMap (jamais instancié) est conservé tel quel ; aucun nouvel appel ne doit apparaître. »*
- Recherche exhaustive (`grep "DriverMap("` sur `lib/`) : la classe n'apparaît que dans son propre fichier (déclaration + un appel statique interne jamais référencé ailleurs) — aucun import, aucune navigation, depuis aucun autre écran.
- L'écran de navigation réellement utilisé en production, `lib/screens/driver_tracking_screen.dart`, ne contient **aucune** écriture Firestore propre (confirmé par grep) : il ne fait que gérer un `FinePrecisionScope` (filtre GPS plus fin), toute l'écriture GPS passant par le service partagé `DriverLocationService`.

**Conséquence** : il n'existe qu'**un seul site d'écriture GPS réellement actif**. `driver_map.dart` n'a donc pas été modifié — ce n'est pas une omission, c'est la conclusion de l'audit demandé en Phase 1, documentée ici plutôt que masquée. Toute évolution future de `driver_map.dart` (s'il redevenait actif un jour) devrait appliquer le même traitement, décrit ci-dessous.

## 2. Architecture retenue

Nouveau fichier **`lib/services/driver_public_projection.dart`**, deux fonctions :

- `buildDriverPublicGpsProjection(Position pos)` — fonction **pure**, construit la projection ou retourne `null` si la position est invalide ou correspond au placeholder de création.
- `writeDriverPublicGpsProjection(String driverId, Position pos)` — écrit `driver_public/{driverId}` en `merge: true`, **ne lève jamais** (try/catch interne), journalise uniquement le type d'erreur (jamais de coordonnées ni d'identifiant).

Appelée depuis **`lib/services/driver_location_service.dart::_saveToFirestore`**, juste après la ligne `_lastSave = DateTime.now();` (c'est-à-dire seulement si l'écriture `livreurs` a réussi), via `unawaited(...)` — la projection ne bloque jamais le flux principal et ne peut pas, par construction, provoquer l'exception attrapée par le `catch` de l'écriture `livreurs` (puisqu'elle ne lève jamais elle-même).

## 3. Champs projetés

`lat`, `lng`, `heading` (si fini), `speed` (si fini), `updatedAt` (`FieldValue.serverTimestamp()` — jamais une horloge cliente).

## 4. Champs explicitement exclus

- **Tous les champs interdits** de la liste blanche S2 (`wallet`, `phone`, `fcmToken`, `token`, `ownerId`, `isSuspended`, `deletionRequested`, `pendingOrderId`, `identifiant`, KYC, etc.) — jamais lus ni transmis par ce module, qui ne manipule qu'un objet `Position` (GPS brut), jamais le document `livreurs`.
- **`name`/`photoUrl`** : différés. Ni `DriverLocationService` ni l'écran de navigation ne les ont en mémoire au moment de l'écriture GPS ; les lire exigerait un appel Firestore supplémentaire rien que pour ces deux champs, ce que la mission interdit explicitement (« ne pas créer une projection à partir d'un document complet `livreurs` »). Une synchronisation dédiée (par exemple au moment où `driver_profil.dart` modifie `photoUrl`) est hors périmètre de cette phase.
- **`isOnline`** : hors périmètre explicite de la mission S4, qui ne liste que `name/photoUrl/lat/lng/heading/speed/updatedAt` — differé à une phase ultérieure.
- **Placeholder `lat:0, lng:0`** (posé à la création par `driver_requests_page.dart`) : détecté et exclu, jamais projeté comme une position réelle.

Les 4 champs serveur protégés par `unchanged()` en règles (S2) — `isAvailable`, `isOnDelivery`, `avgRating`, `ratingCount` — ne sont jamais inclus dans la projection : aucune adaptation de règle n'était donc nécessaire.

## 5. Gestion des erreurs

- `writeDriverPublicGpsProjection` encapsule tout dans un `try/catch` : une erreur réseau, un `permission-denied` (par exemple si `livreurs/{uid}` n'existait pas encore — cas qui ne se produit jamais en pratique puisqu'un livreur ne peut s'authentifier qu'après approbation admin), ou toute autre exception Firestore est journalisée (type d'erreur seulement, jamais de coordonnées ni d'identifiant) puis absorbée.
- Aucune tentative de nouvelle tentative agressive n'a été ajoutée : la position suivante (au même throttle qu'aujourd'hui) retentera naturellement.
- L'écriture principale `livreurs` n'est en aucun cas affectée : la projection n'est même tentée qu'après le succès de cette écriture, et son échec éventuel ne peut pas remonter dans le `catch` prévu pour l'écriture principale.
- Position invalide ou placeholder : retour immédiat (`null`), **aucun appel Firestore n'est même tenté** — ni échec, ni journalisation d'erreur, juste une absence de projection pour ce cycle.

## 6. Throttling

**Totalement inchangé et réutilisé tel quel** : aucun nouveau `Timer`, aucun nouveau `Stream`, aucune nouvelle fréquence. La projection est appelée depuis le même point d'exécution que l'écriture `livreurs` existante (`_saveToFirestore`), donc soumise exactement au même double throttle (5 s et 15 m, `_maybeSave`) et au même battement de cœur (30 s de vérification, 90 s d'âge maximal, `_heartbeatTick`). Les constantes `_minSaveInterval`, `_minDistanceMeters`, `_heartbeatMaxAge`, `_heartbeatCheckInterval` n'ont pas été touchées (vérifié par le test de régression existant, toujours vert).

## 7. Tests

**Nouveau fichier `test/services/driver_public_projection_test.dart`, 14 tests**, tous locaux, aucun accès Firebase réel :
- Mapping strict (position valide → exactement les 5 clés attendues, rien de plus ; timestamp toujours `FieldValue.serverTimestamp()`).
- Absence de champs sensibles (aucune clé hors `lat/lng/heading/speed/updatedAt`, quelle que soit l'entrée).
- Position invalide (latitude/longitude hors plage, `NaN`, infini) → aucune projection.
- Placeholder `0,0` exclu ; une vraie position à `0` sur un seul axe reste projetée (pas une sur-correction).
- `heading`/`speed` non finis : omis individuellement sans bloquer le reste.
- Garde de source : la projection est appelée *après* `_lastSave`, jamais avant ; appel `unawaited`, jamais attendu par le flux principal ; toujours avec `_currentDriverId`, jamais un autre UID.
- Erreur isolée : `writeDriverPublicGpsProjection('d1', pos())` **se termine sans lever**, même sans `Firebase.initializeApp()` dans le test (donc avec un échec `[core/no-app]` garanti en interne) — preuve directe, pas seulement déclarative, que l'absorption d'erreur fonctionne.
- Garde de source confirmant que `driver_map.dart` n'a reçu aucune modification liée à `driver_public`.

**Résultat** : **54/54 tests passés** (`flutter test test/services/driver_public_projection_test.dart test/services/driver_location_service_test.dart test/screens/driver_map_update_throttle_test.dart`) — les 14 nouveaux tests, plus l'intégralité de la suite GPS/tracking déjà existante, sans aucune régression.

## 8. Risques et limites

- **Mise à jour S4.1** : la limite ci-dessous (absence de vérification du payload exact) est désormais levée. `driver_public_projection.dart` expose un point d'injection `@visibleForTesting` (`driverPublicWriter`, défaut `defaultDriverPublicWriter`), suivant exactement le même pattern que `positionStreamFactory`/`foregroundServiceStarter` dans `driver_location_service.dart` — aucune nouvelle dépendance, aucun nouveau service, comportement de production inchangé par défaut. 5 nouveaux tests (`test/services/driver_public_projection_test.dart`, groupe « injection du writer (S4.1) ») vérifient : le payload exact transmis (`docId` + clés/valeurs), l'absence d'appel sur position invalide/placeholder (le court-circuit reste actif même avec un writer injecté), l'absorption d'un échec simulé, le bon déroulement d'un succès simulé, et deux appels successifs avec des données distinctes. Les tests originaux « erreur de projection isolée » (sur le vrai `defaultDriverPublicWriter`, sans Firebase initialisé) restent inchangés et toujours verts, chaque test d'injection restaurant `driverPublicWriter = defaultDriverPublicWriter` en `tearDown`.
- Reste néanmoins hors périmètre : aucun test contre un **véritable** Firestore (émulateur ou projet réel) — l'injection valide le contrat interne (quel payload la fonction *tenterait* d'envoyer), pas la compatibilité réelle avec les règles `driver_public` déployées en S2 (déjà validées séparément par `rules-tests/driver-public.rules.test.js`, 17/17).
- `name`/`photoUrl`/`isOnline` restent absents de `driver_public` à l'issue de cette phase — cohérent avec le périmètre demandé, mais `driver_public` reste donc incomplet pour un usage de lecture réel (hors périmètre ici, aucun lecteur n'a été migré).
- Le document `driver_public/{uid}` ne sera réellement peuplé qu'au prochain cycle d'écriture GPS d'un livreur déjà en ligne ou lors de sa prochaine connexion — aucun rattrapage immédiat n'est inclus dans cette phase (le script de backfill S3 reste en dry-run local uniquement).
- Si `driver_map.dart` redevenait un jour un écran actif, il faudrait lui appliquer le même traitement (il ne l'a pas reçu ici, puisqu'il est mort).

## 9. Ce qui n'a pas été exécuté

Aucun accès à un Firebase réel (production, préproduction ou émulateur), aucun déploiement (`firebase deploy`), aucune modification des règles Firestore (`driver_public` et `livreurs` restent exactement comme en S2), aucune modification de Cloud Function, aucune migration d'écran lecteur, aucune génération d'APK/AAB, aucun accès au pilote T7E, aucune activation de `operations_control/account_deletion`.
