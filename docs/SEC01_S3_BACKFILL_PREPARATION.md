# SEC-01 — S3 : préparation du backfill `driver_public` (dry-run seulement)

**Statut : préparation uniquement. Aucune écriture Firebase, aucun déploiement, aucun accès à un projet réel.** Suite de S2 (règle additive `driver_public` validée, 17/17 tests dédiés + 471/471 suite Rules existante). Référence : `docs/DRIVER_PUBLIC_MIGRATION_PLAN.md`.

## 1. Inventaire source

Lecture directe du code (pas de supposition) :

- **Création** (`lib/screens/admin/driver_requests_page.dart:30-48`) : un livreur approuvé obtient `name`, `phone`, `email`, `identifiant`, `photoUrl` (souvent vide `""` à ce stade), `idPhotoUrl`, `selfieUrl`, `wallet:0`, `isOnline:false`, `lat:0`, `lng:0`, `deliveries:0`, `avgRating:0.0`, `ratingCount:0`, `createdAt`. **`lat`/`lng` valent 0/0 à la création — ce n'est pas une position réelle**, c'est un placeholder qu'il ne faut jamais recopier tel quel.
- **GPS/statut** (`lib/services/driver_location_service.dart::_saveToFirestore`) : réécrit ensuite `lat`, `lng`, `heading`, `speed`, `fcmToken`, `isOnline:true`, `currentCityId`/`registeredCityId`, `updatedAt` — absents tant que le livreur ne s'est jamais connecté/géolocalisé.
- **Photo** (`lib/screens/driver/driver_profil.dart`) : peut modifier ou supprimer `photoUrl` après coup. `name` n'est en revanche jamais modifié par le livreur lui-même.
- **`isOnDelivery`** : jamais écrit par un écran livreur — uniquement par `functions/driverAcceptance.js` et `functions/driverTransfer.js`.
- **`isAvailable`** : jamais mis à `true` par du code de production (seuls des tests unitaires le font) ; mis à `false` uniquement par `functions/accountDeletion.js` et `functions/partnerAccountDeletion.js` (suspension/suppression). Absent de l'immense majorité des documents réels.
- **`avgRating` / `ratingCount`** : recalculés par `functions/driverRatings.js` après chaque commande notée.

**Point de confusion identifié et documenté, pas contourné** : la mission demandait de lire `functions/lot.js`. Ce fichier **n'existe pas** dans le dépôt. Le seul `lot.js` présent est `scripts/restaurant-v2-pilot/lot.js`, qui définit le lot de test T7E (Restaurant V2) — sans aucun rapport avec `livreurs`/`driver_public`, et explicitement hors périmètre de cette mission (« ne pas toucher au pilote T7E »). Il n'a donc pas été lu ni utilisé ; l'inventaire ci-dessus s'appuie uniquement sur le code réel qui écrit `livreurs`.

## 2. Mapping retenu

12 champs, strictement alignés sur `firestore.rules` (`driverPublicKeysValid`/`driverPublicTypesValid`, phase S2) :

| Champ | Type exigé | Traitement si absent | Traitement si invalide |
|---|---|---|---|
| `name` | string non vide, ≤160 car. | omis, averti | omis, averti |
| `photoUrl` | string non vide, ≤2048 car. | omis, averti | omis, averti |
| `lat`/`lng` | nombres, plages valides | omis, averti | exclu (comptabilisé) |
| `heading`/`speed` | nombre | omis, averti | exclu |
| `updatedAt` | Timestamp Firestore ou nombre de ms | omis, averti | exclu |
| `isOnline`/`isAvailable`/`isOnDelivery` | booléen | omis, averti | exclu |
| `avgRating` | nombre | omis, averti | exclu |
| `ratingCount` | entier ≥ 0 | omis, averti | exclu |

**Cas particulier `lat`/`lng` = 0/0** : traité comme « jamais positionné réellement », exclu et signalé par un avertissement dédié, **jamais** copié comme une vraie coordonnée (éviterait de placer visuellement un livreur jamais connecté au large du golfe de Guinée).

## 3. Exclusions

Liste explicite, jamais recopiée quel que soit le contenu de la source : `wallet`, `phone`, `fcmToken`, `token`, `ownerId`, `ownerName`, `isSuspended`, `deletionRequested`, `pendingOrderId`, `identifiant`, `idPhotoUrl`, `selfieUrl`, `email`, `currentCityId`, `registeredCityId`, `createdAt`, `deliveries`. Garde-fou redondant dans le code (`mapping.js`) : une exception est levée si l'un de ces champs apparaissait malgré tout dans la sortie, ou si une clé hors liste blanche était produite — ce sont des bugs à corriger, pas des cas à masquer.

## 4. Architecture du script

`scripts/driver-public-backfill/` :

- **`mapping.js`** — fonction pure `mapDriverToPublic(driverId, source)`. Aucun accès réseau ni Firebase. Chaque champ est traité individuellement (inclus / exclu avec raison / absent avec avertissement).
- **`guard.js`** — garde-fous : refuse toute variable d'environnement signalant un Firebase réel (`GOOGLE_APPLICATION_CREDENTIALS`, `FIREBASE_CONFIG`, `GCLOUD_PROJECT`, `FIRESTORE_EMULATOR_HOST`, etc.), refuse les identifiants de projet `az-express-b0469`/`az-express-clean`/`az-express-preprod`, refuse toute source autre qu'un fichier JSON local, refuse tout mode différent de `dry-run`, refuse toute option ressemblant à des identifiants (`credentials`, `serviceAccount`, `keyFile`, `adc`, `token`).
- **`backfill.js`** — CLI : `node scripts/driver-public-backfill/backfill.js --source <fixture.json>`. Lit un tableau JSON local `[{id, data}, ...]`, applique le mapping, affiche **uniquement un résumé agrégé** (compteurs par champ inclus, par raison d'exclusion, par avertissement, nombre de positions placeholder ignorées) — **jamais** les données individuelles d'un livreur précis.
- **`fixtures/sample-livreurs.json`** — 4 documents fictifs couvrant : livreur neuf (placeholder 0/0, champs serveur absents), livreur actif (tous les champs), livreur suspendu (champs interdits présents dans la source, pour vérifier qu'ils sont bien exclus), document aux types volontairement incorrects.

**Garantie de sécurité centrale, au-delà d'un simple indicateur `--dry-run`** : il n'existe **aucun code de connexion Firestore/Admin SDK** dans ce dossier, à ce stade. Ce n'est pas un indicateur qu'on pourrait retirer par erreur un jour — c'est une absence de fonctionnalité. Une lecture Firestore réelle (même en lecture seule, même sur préproduction) et un mode d'écriture réelle sont explicitement reportés à une phase S4 distincte, qui nécessitera sa propre autorisation explicite et son propre mécanisme de garde — ne pas les ajouter ici aurait été contourner la demande ; les documenter comme reportés est la réponse correcte.

## 5. Tests

26 tests locaux, fixtures en mémoire ou fichier JSON local, aucun accès Firebase :

- `mapping.test.js` (16 tests) : mapping correct, absence de champs sensibles, omission des champs manquants, document source invalide, validation de types (y compris un bug réel détecté et corrigé en cours de route : les valeurs numériques étaient converties via `Number(...)` avant vérification, ce qui acceptait à tort une chaîne comme `'12'` pour `ratingCount` — corrigé par une vérification stricte `typeof === 'number'`, cohérente avec le comportement réel de Firestore qui ne convertit jamais un type), coordonnées invalides, placeholder 0/0, timestamp invalide/valide, cohérence avec `FIELD_MAP`, champs texte vides.
- `guard.test.js` (6 tests) : refus des project IDs réels, refus des variables d'environnement Firebase, refus des sources distantes, refus des sources absentes, refus de tout mode non-`dry-run`, refus des options de type identifiants.
- `backfill.test.js` (8 tests, dont 2 fusionnés dans le compte ci-dessus si recoupement) : dry-run bout-en-bout sur la fixture (0 écriture, résumé agrégé sans donnée personnelle), comptage correct du résumé, refus de `--project`/`--credentials`/argument inconnu, refus si variable d'environnement Firebase présente, refus de fixture inexistante ou mal formée.

**Résultat** : 26/26 passés (`node --test scripts/driver-public-backfill/*.test.js`).

## 6. Risques résiduels

- Le mapping repose sur l'inventaire de code actuel ; si un futur écran ou une future fonction ajoute un nouveau champ à `livreurs`, ce mapping ne le découvrira pas automatiquement — il faudra le mettre à jour manuellement, en miroir de toute évolution de `driverPublicKeysValid()` dans `firestore.rules` (même principe de double maintenance que `adminPermissionsKnown()`/`PERMISSION_KEYS`/`adminPermissionKeys`).
- Ce script ne lit aujourd'hui que des fixtures locales : la phase S4 (lecture réelle de `livreurs`, écriture réelle de `driver_public`) reste entièrement à concevoir et à autoriser séparément — rien n'a été préparé au-delà de la logique de transformation elle-même.
- Le cas `lat`/`lng` = 0/0 suppose que 0,0 n'est jamais une position légitime pour Abengourou/Côte d'Ivoire (vrai en pratique) — à revalider si le service s'étendait un jour à une zone incluant réellement ces coordonnées.

## 7. Ce qui n'a pas été exécuté

Aucune lecture de `livreurs` réel, aucune écriture dans `driver_public` réel, aucune commande Firebase (`firebase deploy`, `firebase firestore:*`), aucun accès à un projet Firebase (production ou préproduction), aucune modification des règles `livreurs` existantes, aucune modification de Cloud Function, aucune activation de `operations_control/account_deletion`, aucun accès au pilote T7E.
