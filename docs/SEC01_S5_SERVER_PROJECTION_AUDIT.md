# SEC-01 — S5 : audit des sources de vérité et architecture de synchronisation serveur `driver_public`

**Statut : audit et conception uniquement. Strictement read-only, aucun code fonctionnel modifié.** Suite de S1→S4.1 (`docs/DRIVER_PUBLIC_MIGRATION_PLAN.md`, `docs/SEC01_S3_BACKFILL_PREPARATION.md`, `docs/SEC01_S4_DUAL_WRITE_GPS.md`).

## 1. Inventaire des sources de vérité, par champ

### Profil

| Champ | Source de vérité | Fichier / fonction | Acteur | Déclencheur | Risque |
|---|---|---|---|---|---|
| `name` | Écrit une seule fois, à la création | `lib/screens/admin/driver_requests_page.dart:31` (approbation individuelle) **et** `functions/fleetDriverCreation.js::buildCreateFleetDriver` (création par un propriétaire de flotte, HTTPS callable) — **deux chemins de création parallèles, même forme de document** (`lat:0,lng:0`, `photoUrl:''`, `avgRating:0.0`, `ratingCount:0`) | Admin (Flutter) / propriétaire de flotte (Cloud Function) | Approbation d'une candidature ou création directe par une flotte | Aucun : écriture unique, jamais modifiée ensuite (`driver_profil.dart` ne touche jamais `name`) |
| `photoUrl` | Écrit à la création (vide), puis librement par le livreur | `lib/screens/driver/driver_profil.dart:399-402` (dépôt), `:405-408` (suppression, `FieldValue.delete()`) | Flutter, livreur | Action manuelle du livreur | Aucun : un seul écrivain après création |

### Statut

| Champ | Sources de vérité (toutes identifiées) | Acteur | Déclencheur | Risque |
|---|---|---|---|---|
| `isOnline` | **6 sites distincts** : (1) `driver_location_service.dart::_saveToFirestore` → `true`, à chaque écriture GPS throttlée ; (2) `driver_location_service.dart::goOffline` → `false`, à l'arrêt du suivi ; (3) **`driver_profil.dart:327-330`** (boîte de dialogue de déconnexion) → `false`, **écriture directe dupliquée** du même événement logique que (2), sans passer par `goOffline()` ; (4) **`drivers_page.dart:651-659`** (bascule de suspension admin) → `false`, **écriture Flutter directe** (pas une Cloud Function), protégée uniquement par la règle `isAdmin()` ; (5) `functions/accountDeletion.js:108,165` → `false` (transactionnel, groupé avec `isAvailable:false,isSuspended:true`) ; (6) `functions/staleDriverCleanup.js:48` → `false`, **cron Cloud Scheduler toutes les 5 minutes**, par lot (non transactionnel), seul correcteur des livreurs « fantômes en ligne » | Flutter (livreur ×3, admin ×1) / Cloud Function (×2) | Connexion/déconnexion, suspension admin, clôture de compte, péremption GPS | Les sites (2) et (3) dupliquent la même logique sans conflit de valeur (même direction) — à consolider (S5.1). Le site (6) peut courir en parallèle du site (1) (reconnexion pile au passage du cron) : bénin, auto-corrigé à la prochaine position GPS. |
| `isAvailable` | **Uniquement mis à `false`**, jamais à `true` dans le code de production : `functions/accountDeletion.js:108,165` seul (confirmé — `partnerAccountDeletion.js` ne touche **pas** `livreurs`, voir note de correction ci-dessous ; `driverLifecycle.js`, `driverDecline.js`, `driverRelease.js`, `driverTransfer.js`, `assignedTimeout.js` vérifiés : aucun n'écrit ce champ) | Cloud Function | Mise en quarantaine / clôture de compte | Aucun risque de source multiple : un seul écrivain, une seule direction |
| `isOnDelivery` | `true` : `functions/driverAcceptance.js:164` (acceptation), `functions/driverTransfer.js:277,476` (transfert accepté). `false` : `functions/driverLifecycle.js::terminalDriverPatch`, appliqué par `settleTerminalOrder` (commande `delivered`/`cancelled`), par `assignedTimeout.js` (expiration sans réponse) et `driverDecline.js`/`driverRelease.js` (refus/libération volontaire) | Cloud Function (toutes transactionnelles) | Cycle de vie complet d'une commande | Aucun : événements métier disjoints et séquentiels ; `settleTerminalOrder` relit explicitement l'état de la commande pour éviter de libérer un livreur sur un événement tardif |
| `avgRating` / `ratingCount` | **Un seul écrivain** : `functions/driverRatings.js::applyDriverRating`, déclenché par le trigger Firestore `onDocumentUpdated` sur `orders` (`functions/index.js:137,143`) | Cloud Function (trigger) | Passage d'une commande à `delivered` avec une note posée | Aucun : transactionnel, idempotent (drapeau `driverRatingApplied` posé dans la même transaction) |

**Note de correction** : l'inventaire initial (session précédente) mentionnait par erreur `functions/partnerAccountDeletion.js:57,107` comme source de `isOnline`/`isAvailable`. Vérification directe par recherche exhaustive (`grep "livreurs" functions/partnerAccountDeletion.js`) : **aucune occurrence**. Ce fichier ne touche jamais `livreurs` — seul `functions/accountDeletion.js` gère la clôture des comptes livreurs. Corrigé ici.

### GPS

| Champ | Source de vérité | Fichier / fonction | Acteur | Déclencheur | Risque |
|---|---|---|---|---|---|
| `lat`/`lng`/`heading`/`speed`/`updatedAt` | **Un seul site réellement actif** : `driver_location_service.dart::_saveToFirestore` (`lib/screens/driver/driver_map.dart::_writePosition` est du code mort, jamais instancié, confirmé en S4) | Flutter, livreur | Position GPS (throttle 5 s/15 m + battement 90 s/30 s) | Aucun : déjà projeté vers `driver_public` par la double écriture S4, hors périmètre de cette mission |

## 2. Inventaire des Cloud Functions affectant `livreurs`

| Fonction | Fichier | Déclencheur | Champs `livreurs` touchés | Transactionnel | Risque noté |
|---|---|---|---|---|---|
| `readDriverState`/`terminalDriverPatch`/`settleTerminalOrder`/`diagnoseDriver`/`clearAcceptedOffers` | `functions/driverLifecycle.js` | Module partagé, appelé par les fonctions ci-dessous (pas un déclencheur en soi) | `isOnDelivery`, `currentOrderId`/`pendingOrderId` | Oui (transaction du module) | `settleTerminalOrder` relit l'état de la commande pour éviter un événement tardif |
| `requeueUnansweredAssignment` | `functions/assignedTimeout.js` | Mécanisme de reprise après 3 min sans réponse (commande `assigned`) | `isOnDelivery`, refs de commande (via `terminalDriverPatch`) | Oui | Relit statut/commission/horodatages avant d'agir |
| `buildReleaseOrderBeforePickup` | `functions/driverRelease.js` | Callable HTTPS (libération volontaire) | `wallet` (remboursement commission), `isOnDelivery` (via `terminalDriverPatch`) | Oui | Rejeu idempotent via `excludedDriverIds` |
| `buildCreateFleetDriver` | `functions/fleetDriverCreation.js` | Callable HTTPS (propriétaire de flotte) | Création initiale (`name`,`photoUrl:''`,`wallet:0`,`isOnline:false`,`lat:0,lng:0`,`avgRating:0.0`,`ratingCount:0`,`ownerId`) | Création simple (`.create()`), rollback Auth si échec Firestore | Second chemin de création, même forme placeholder que `driver_requests_page.dart` |
| `buildAdminDriverRecharge` | `functions/adminDriverRecharge.js` | Callable HTTPS, `requireAdminPermission('recharges')` | `wallet` uniquement | Oui | Sans rapport avec `driver_public` |
| `buildDeclineLegacyOrder` | `functions/driverDecline.js` | Callable HTTPS (refus volontaire) | `isOnDelivery` (via `terminalDriverPatch`) | Oui | — |
| `assertDriverRechargeAllowed` | `functions/driverWalletPolicy.js` | Helper lecture seule | Lecture seule | — | Aucun |
| `buildRecipientProofAccess` | `functions/deliveryProofGuests.js` | Garde anti-fraude (identité) | Lecture seule (`livreurs/{uid}` existence) | — | Aucun |
| `runStaleDriverCleanup` | `functions/staleDriverCleanup.js` | **Cloud Scheduler, cron toutes les 5 min** | `isOnline:false` par lot, sur GPS périmé (`STALE_MINUTES`, importé de `dispatch.js`) | Non (`db.batch()`) | **Seul correcteur de `isOnline` fantôme** — directement pertinent pour une future synchronisation `driver_public.isOnline` |
| `enrichWithDriverNames` (AZ IA) | `functions/azia/tools/delivery.js` | Outil AZ IA `track_order` | Lecture seule (`name`) | — | Les écritures réelles (annulation/dispatch) passent par `dispatch.js`/`orderActions.js`, déjà couverts |
| Notifications push | `functions/index.js` | Triggers `orders` onCreate/onUpdate | Lecture seule (`fcmToken`, `isOnline` pour diffusion) | — | Aucun |
| `mapsProxy.js` | — | — | Aucune écriture `livreurs` (confirmé, déjà audité) | — | — |
| `adminPartnerAccounts.js`, `professionalSubscriptions.js`, `partnerAccountDeletion.js` | — | — | **Aucun lien réel avec `livreurs`** (vérifié par recherche exhaustive, pas supposé) | — | — |
| `ekbineOrders.js` | — | — | Une seule référence, lecture seule (garde anti-double-rôle) | — | Aucun |
| `functions/lot.js` | — | **N'existe pas** (seul `scripts/restaurant-v2-pilot/lot.js` existe, pilote T7E, sans rapport) | — | — | Déjà signalé en S3 |

`dispatch.js`, `driverAcceptance.js`, `driverTransfer.js`, `orderActions.js`, `adminBilling.js`, `partnerOrderActions.js`, `transferSettlement.js`, `adminOrderDisputes.js`, `driverRatings.js` : déjà audités en détail dans des phases précédentes de cette session (sécurité, S1-S4), non répétés ici.

## 3. Architecture recommandée

**Un trigger Firestore dédié `onDocumentUpdated('livreurs/{driverId}')`, et non une duplication par site d'écriture.**

Raisonnement : le GPS (S4) n'avait qu'**un seul** site d'écriture réel, ce qui rendait une double écriture directe au point d'appel optimale (coût minimal, pas de Cloud Function supplémentaire). Les champs de statut/évaluation ont **6 sites d'écriture distincts** (`isOnline` seul) répartis entre Flutter (3) et Cloud Functions (3, dont un cron). Dupliquer la logique de projection dans chacun de ces 6 sites violerait directement la consigne « éviter de dupliquer inutilement la logique métier » et laisserait un angle mort à chaque nouveau site futur. Un trigger unique, côté serveur, capture **tous** les sites actuels et futurs sans les toucher individuellement.

**Conception précise** :
- Fonction `functions/driverPublicSync.js` (nouveau fichier, hors périmètre d'implémentation de cette mission), déclenchée par `onDocumentUpdated('livreurs/{driverId}')`.
- Compare `before`/`after` sur exactement 7 champs : `name`, `photoUrl`, `isOnline`, `isAvailable`, `isOnDelivery`, `avgRating`, `ratingCount`. **Retour immédiat si aucun n'a changé** (évite un coût Cloud Function sur chaque écriture GPS, qui ne touche pas ces champs sauf `isOnline` — voir point suivant).
- **Exclut explicitement** `lat`/`lng`/`heading`/`speed`/`updatedAt` : ces champs restent exclusivement gérés par la double écriture client S4, déjà validée et testée — ne jamais les réécrire depuis ce trigger, pour ne pas dupliquer un mécanisme qui fonctionne déjà et pour ne pas multiplier les écritures sur le champ le plus fréquemment modifié.
- Écrit uniquement les champs qui ont changé, en `.set(merge:true)`, vers `driver_public/{driverId}` — jamais une projection du document `livreurs` complet.
- Idempotent par construction : un trigger Firestore ne se déclenche que sur un changement réel ; rejouer le même événement (retry de la plateforme) produit la même écriture, sans effet cumulatif (aucun champ n'est un compteur incrémental ici).
- Pas de risque de trigger récursif : il écrit vers `driver_public`, jamais vers `livreurs` ; rien ne lit `driver_public` pour réécrire `livreurs`.

**Interaction avec l'écriture GPS S4** : au moment précis où `_saveToFirestore` écrit `isOnline:true` en même temps que `lat`/`lng`, le trigger se déclenchera pour projeter `isOnline` **séparément** de la double écriture GPS déjà en place — deux écritures `driver_public` au lieu d'une à cet instant précis. Coût mineur et accepté : évite de modifier le mécanisme GPS déjà validé (S4/S4.1, 59 tests) pour cette seule coïncidence.

**Suspension et clôture de compte** : lorsque `accountDeletion.js` pose `isOnline:false,isAvailable:false` (et `isSuspended:true`, jamais projeté — hors liste blanche), le même trigger générique les propage automatiquement vers `driver_public`, sans aucune modification de `accountDeletion.js` lui-même. **Point non couvert, à trancher avant implémentation** : la suppression définitive du document `livreurs/{uid}` (anonymisation complète) ne supprime pas automatiquement `driver_public/{uid}` — un trigger `onDocumentUpdated` ne se déclenche pas sur une suppression de document ; il faudrait soit un second trigger `onDocumentDeleted`, soit une suppression explicite ajoutée dans `accountDeletion.js` au moment du scellement final (cohérent avec le fait que ce fichier possède déjà la responsabilité du cycle de vie terminal du compte).

**Livreurs de flotte** : `fleetDriverCreation.js` crée un document `livreurs` identique en forme à celui de `driver_requests_page.dart` — le trigger s'applique de façon identique, aucune distinction nécessaire.

## 4. Analyse de compatibilité

- **Whitelist et Rules S2** : aucune modification nécessaire — le trigger utilise l'Admin SDK (règles ignorées à l'écriture) et ne projette que des champs déjà dans `driverPublicKeysValid()`.
- **Mapping S3** : inchangé, reste un outil de rattrapage local en dry-run, non affecté.
- **Double écriture GPS S4 / tests S4.1** : compatibles par construction (exclusion explicite des champs GPS du nouveau trigger, voir §3) — aucun des 59 tests existants ne serait affecté.
- **Lecteurs existants (`livreurs`), tableaux de bord flotte, dispatch, clients, partenaires, suivi, classements, admins/sous-admins** : tous continuent de lire `livreurs` sans aucun changement (aucune migration de lecteur dans cette mission ni dans cette architecture) ; le trigger est purement additif côté écriture.
- **Pilote T7E** : **incompatibilité potentielle à signaler, pas à corriger ici**. Un trigger générique sur `livreurs/{driverId}` se déclencherait aussi pour `t7e-admin`... non, `t7e-driver` (le livreur du lot de test), créant/mettant à jour un document `driver_public/t7e-driver` à chaque changement de statut pendant un parcours de test réel. Ni `cleanup.js` ni aucun autre script du pilote ne référence `driver_public` (confirmé, zéro occurrence dans tout le dépôt en dehors de la planification et de l'implémentation S2-S4). **Si ce trigger est implémenté avant un futur nettoyage T7E, `cleanup.js` devra être étendu pour inclure `driver_public/t7e-driver` dans sa liste blanche de suppression** — sans quoi un document résiduel subsisterait après le nettoyage du lot. Ceci est une dépendance identifiée pour une mission future, pas une action à entreprendre ici.
- **Champs non alimentables actuellement sans changement de source** : aucun des 12 champs de la liste blanche n'est structurellement bloqué — tous ont une source de vérité claire et unique (ou consolidable, voir S5.1 pour `isOnline`).

## 5. Plan de migration S5.1 → S8

| Étape | Périmètre | Fichiers | Tests | Risques | Critère de validation | Retour arrière |
|---|---|---|---|---|---|---|
| **S5.1** | Consolider les 2 écritures `isOnline:false` dupliquées (déconnexion) en un seul appel | `lib/screens/driver/driver_profil.dart` (appeler `goOffline()` au lieu d'écrire directement) | Régression sign-out, `goOffline()` idempotent sans tracking actif | `goOffline()` arrête aussi le GPS — à confirmer que c'est le comportement voulu à la déconnexion (vraisemblablement oui) | Un seul site Flutter écrit `isOnline:false` pour l'événement déconnexion | Revert trivial, un seul fichier |
| **S5.2** | Trigger Firestore unique projetant `isOnline`/`isAvailable`/`isOnDelivery`/`avgRating`/`ratingCount` vers `driver_public`, jamais les champs GPS | Nouveau `functions/driverPublicSync.js`, export dans `functions/index.js` | Un test par champ, non-déclenchement sur changement `wallet`/`phone`/autre champ privé, non-déclenchement sur changement GPS seul, comportement sur clôture de compte | Coût Cloud Run additionnel (fréquence faible, acceptable) ; double écriture ponctuelle au moment d'un cycle GPS qui change aussi `isOnline` ; effet de bord sur `t7e-driver` (voir §4) | Tests verts ; aucun champ GPS ni hors liste blanche jamais écrit par ce trigger | Suppression du trigger, sans effet rétroactif |
| **S5.3** | Étendre le même trigger à `name`/`photoUrl` (recommandé : fusionner techniquement avec S5.2, un seul trigger pour les 7 champs non-GPS) | Idem S5.2 | Changement de `photoUrl` (pose et suppression) projeté correctement | Aucun nouveau | Idem S5.2 | Idem S5.2 |
| **S5.4** | Validation globale : suite complète (`rules-tests`, `functions` test, `flutter test`) après S5.1-S5.3 | Aucun nouveau fichier | Suite complète | Aucun nouveau | 100 % des tests existants et nouveaux verts | Sans objet |
| **S6** | Migration des lecteurs par groupes (A : suivi client assigné, B : carte/visiteurs anonymes, D : admin), avec repli vers `livreurs` | Fichiers déjà listés dans le rapport SEC-01/S1 (`realtime_tracking_service.dart`, `tracking_service.dart`, `live_marker_cache.dart`, `destination_picker.dart`, etc.) | Non-régression par écran, test de repli | Écran cassé si `driver_public` pas encore peuplé (géré par le repli) | Données identiques avant/après migration, aucun champ privé exposé | Revert du fichier migré |
| **S7** | Observation du taux de repli (< 1 % pendant 14 jours) + version minimale étendue aux rôles `client`/`partner` | Instrumentation, `MinVersionService` | Tests de l'extension `MinVersionService` | Sous-estimation du repli si instrumentation incomplète | Critères du plan `DRIVER_PUBLIC_MIGRATION_PLAN.md` §5 respectés | Observation seule, aucune action irréversible |
| **S8** | Fermeture de la lecture `livreurs` (propriétaire + admin + les 6 clés de permission identifiées en S1 : `livreurs`/`classement`/`carte`/`gains`/`demandes`/`recharges`, + branche flotte `ownerId`) | `firestore.rules`, nouveaux tests de règles | Suite `rules-tests` complète, scénarios positifs/négatifs par rôle | **Seule étape réellement risquée** : casse les anciennes versions non migrées | Critère de repli S7 respecté | Republier l'ancienne règle `livreurs` (immédiat) |

## 6. Confirmation

- Aucune modification de fichier fonctionnel (Flutter ou Cloud Function) dans cette mission.
- Aucune modification des règles Firestore.
- Aucun accès Firebase réel, aucun déploiement, aucune commande modifiant des données.
- Seul fichier créé : ce rapport.
